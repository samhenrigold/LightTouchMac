#!/bin/bash
#
# Make the built LightTouchMac.app self-contained: embed libqemu-arm.dylib and
# its Homebrew dylib dependency closure into Contents/Frameworks, repointed to
# @rpath, then re-sign. After this the app runs on a Mac that has neither the
# qemu-ios build tree nor Homebrew.
#
#     scripts/package.sh [path/to/LightTouchMac.app]
#
# Signing:
#   ad-hoc by default. Set SIGN_ID to a "Developer ID Application: …" identity
#   for a distributable build, and NOTARY_PROFILE to a notarytool keychain
#   profile to also notarize + staple.
#
# Device assets (bootrom/NAND/NOR/iBoot) are NOT copied here — the 1 GB NAND is
# compressed and staged by the existing contrib/macos-app/build-app.sh pipeline
# (nandpack + first-run unpack). Point that at this app for a shippable, or run
# the app with the dev files-root on this machine.
set -euo pipefail

APP="${1:-}"
SRC="$(cd "$(dirname "$0")/.." && pwd)"
QEMU="${QEMU_IOS_DIR:-$HOME/Developer/qemu-ios}"
BUILD="$QEMU/build-min12b"
DYLIB="$BUILD/libqemu-arm.dylib"
ENTITLEMENTS="$QEMU/contrib/macos-app/entitlements.plist"
SIGN_ID="${SIGN_ID:--}"          # '-' == ad-hoc

if [ -z "$APP" ]; then
    APP="$(find "$HOME/Library/Developer/Xcode/DerivedData" -type d \
        -path "*LightTouchMac*/Build/Products/*/LightTouchMac.app" 2>/dev/null | head -1)"
fi
[ -d "$APP" ] || { echo "no LightTouchMac.app found; build it first or pass a path" >&2; exit 1; }
[ -f "$DYLIB" ] || { echo "no $DYLIB; run contrib/macos-app/make-dylib-macos.sh" >&2; exit 1; }

FRAMEWORKS="$APP/Contents/Frameworks"
mkdir -p "$FRAMEWORKS"
echo "app:        $APP"
echo "dylib:      $DYLIB"

# Copy a Mach-O and every non-system dylib it needs, transitively, into
# Frameworks; rewrite each install name and inter-dependency to @rpath.
# (Plain string set, so this runs under the stock macOS bash 3.2.)
COPIED=" "
copy_with_deps() {
    local src="$1" base; base="$(basename "$src")"
    case "$COPIED" in *" $base "*) return ;; esac
    COPIED="$COPIED$base "

    local dst="$FRAMEWORKS/$base"
    if [ "$src" != "$dst" ]; then cp -f "$src" "$dst"; chmod u+w "$dst"; fi
    install_name_tool -id "@rpath/$base" "$dst" 2>/dev/null || true

    # Snapshot the Homebrew/local deps BEFORE repointing — otherwise the repoint
    # rewrites them to @rpath and the recursion below never sees the originals.
    local deps
    deps="$(otool -L "$dst" | tail -n +2 | awk '{print $1}' \
            | grep -E '^(/opt/homebrew|/usr/local)/' || true)"

    for dep in $deps; do
        install_name_tool -change "$dep" "@rpath/$(basename "$dep")" "$dst"
    done
    # Recurse in this shell (a for-loop, not a pipe) so the COPIED set persists.
    for dep in $deps; do
        copy_with_deps "$dep"
    done
}

echo "embedding dylib + dependency closure…"
copy_with_deps "$DYLIB"

# Drop the build-tree rpath so resolution goes through Contents/Frameworks only.
APP_BIN="$APP/Contents/MacOS/LightTouchMac"
install_name_tool -delete_rpath "$BUILD" "$APP_BIN" 2>/dev/null || true

# Seal: refuse to ship if any embedded Mach-O still resolves outside the bundle.
echo "sealing…"
bad=0
for f in "$FRAMEWORKS"/*.dylib; do
    while read -r dep; do
        case "$dep" in
            /opt/homebrew/*|/usr/local/*)
                echo "  LEAK: $(basename "$f") still needs $dep" >&2; bad=1 ;;
        esac
    done < <(otool -L "$f" | tail -n +2 | awk '{print $1}')
done
[ "$bad" = 0 ] || { echo "sealing failed — unresolved external dylibs" >&2; exit 1; }

# Sign inside-out: frameworks first, then the app with entitlements.
echo "signing (id: $SIGN_ID)…"
for f in "$FRAMEWORKS"/*.dylib; do
    codesign -f -o runtime -s "$SIGN_ID" "$f"
done
codesign -f -o runtime --entitlements "$ENTITLEMENTS" -s "$SIGN_ID" "$APP"
codesign -dv "$APP" 2>&1 | grep -E "Identifier|Signature" || true

if [ -n "${NOTARY_PROFILE:-}" ] && [ "$SIGN_ID" != "-" ]; then
    echo "notarizing…"
    ZIP="$(mktemp -d)/LightTouchMac.zip"
    ditto -c -k --keepParent "$APP" "$ZIP"
    xcrun notarytool submit "$ZIP" --keychain-profile "$NOTARY_PROFILE" --wait
    xcrun stapler staple "$APP"
fi

echo "done: $APP"
