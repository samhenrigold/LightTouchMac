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

APP_BIN="$APP/Contents/MacOS/LightTouchMac"

# ---------------------------------------------------------- tools the app runs
#
# The app is meant to work on a Mac with no Homebrew and no source checkout, so
# everything it shells out to ships inside it: Contents/Resources/tools for the
# executables and scripts, Contents/Frameworks for the dylibs they need.
# Bundled.swift looks there first and falls back to the checkout, so a dev build
# and a packaged one take the same code path.
#
# libimobiledevice is here rather than in the app's link line on purpose: the
# app dlopens it (see IMobileDevice.swift), because Homebrew builds its dylibs
# for whatever macOS the build machine runs and hard-linking one would stop the
# app launching on anything older.
TOOLS="$APP/Contents/Resources/tools"
mkdir -p "$TOOLS"
MISSING=""

copy_tool() {
    local src="$1" base; base="$(basename "$src")"
    if [ ! -f "$src" ]; then MISSING="$MISSING $base"; return; fi
    cp -f "$src" "$TOOLS/$base"
    chmod u+wx "$TOOLS/$base"
    # Scripts have no load commands; otool just says so and the loop is empty.
    local deps
    deps="$(otool -L "$TOOLS/$base" 2>/dev/null | tail -n +2 | awk '{print $1}' \
            | grep -E '^(/opt/homebrew|/usr/local)/' || true)"
    for dep in $deps; do
        install_name_tool -change "$dep" "@rpath/$(basename "$dep")" "$TOOLS/$base"
        copy_with_deps "$dep"
    done
    # tools/ is two levels under Contents, so its way back to Frameworks is not
    # the app binary's.
    if [ -n "$deps" ]; then
        install_name_tool -add_rpath "@executable_path/../../Frameworks" "$TOOLS/$base" 2>/dev/null || true
    fi
}

echo "embedding tools…"
BREW="$(brew --prefix 2>/dev/null || echo /opt/homebrew)"
for tool in ideviceinstaller ideviceinfo idevicesyslog iproxy idevicepair; do
    copy_tool "$BREW/bin/$tool"
done
copy_tool "${USBMUXD_QEMU:-$HOME/Developer/usbmuxd-qemu}/usbmuxd/src/usbmuxd"
copy_tool "$QEMU/imgtools/install-ipa.sh"
copy_tool "$QEMU/contrib/it-ssh-terminal.sh"
# Guest-side binaries install-ipa.sh copies onto the device, and the helper that
# stands in for the python3 a clean Mac does not have.
copy_tool "$QEMU/contrib/it-gles/MBXGLEngine"
copy_tool "$QEMU/contrib/it-instprogress/sbdlicon"
# The quit-time shutdown helper: reboot(RB_HALT) in 20 lines, because the guest
# has no /sbin/halt and the gesture needs a UI that may not be there.
copy_tool "$QEMU/contrib/it-halt/ithalt"
# ipod-helper is built, not committed (contrib/macos-app/ipod-helper.c), and the
# qemu-ios app pipeline is what compiles it — take its copy.
copy_tool "${IT_HELPER_BIN:-$QEMU/build/iPod touch.app/Contents/Resources/tools/ipod-helper}"

if [ -n "$MISSING" ]; then
    echo "  NOT bundled:$MISSING" >&2
    echo "  The app still runs, but on a Mac without Homebrew or a qemu-ios" >&2
    echo "  checkout the features these back will be unavailable." >&2
fi

# The usbmuxd config dir. USBMux.swift passes this as `-C`; without a bundle
# copy a packaged app pointed at a nonexistent path (Bundled.resource returns
# nil and it fell back to the dev checkout, which a clean Mac does not have).
CONF_SRC="${USBMUXD_QEMU:-$HOME/Developer/usbmuxd-qemu}/run/conf"
CONF_DST="$APP/Contents/Resources/usbmuxd-conf"
if [ -d "$CONF_SRC" ]; then
    echo "embedding usbmuxd-conf…"
    rm -rf "$CONF_DST"; mkdir -p "$CONF_DST"
    # Only the plists (pairing record + SystemConfiguration); skip logs/.DS_Store.
    find "$CONF_SRC" -maxdepth 1 -name '*.plist' -exec cp {} "$CONF_DST/" \;
else
    echo "  NOT bundled: usbmuxd-conf (no $CONF_SRC) — app management may fail on a clean Mac" >&2
fi

# Drop the build-tree rpath so resolution goes through Contents/Frameworks only.
install_name_tool -delete_rpath "$BUILD" "$APP_BIN" 2>/dev/null || true

# Seal: refuse to ship if any embedded Mach-O still resolves outside the bundle.
echo "sealing…"
bad=0
for f in "$FRAMEWORKS"/*.dylib "$TOOLS"/*; do
    [ -f "$f" ] || continue
    while read -r dep; do
        case "$dep" in
            /opt/homebrew/*|/usr/local/*)
                echo "  LEAK: $(basename "$f") still needs $dep" >&2; bad=1 ;;
        esac
    done < <(otool -L "$f" 2>/dev/null | tail -n +2 | awk '{print $1}')
done
[ "$bad" = 0 ] || { echo "sealing failed — unresolved external dylibs" >&2; exit 1; }

# Sign inside-out: frameworks first, then the app with entitlements.
echo "signing (id: $SIGN_ID)…"
for f in "$FRAMEWORKS"/*.dylib "$TOOLS"/*; do
    # Scripts are not signable and do not need to be; the app's signature covers
    # them as resources.
    [ -f "$f" ] && file "$f" | grep -q Mach-O && codesign -f -o runtime -s "$SIGN_ID" "$f"
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
