#!/bin/bash
#
# Make the built LightTouchMac.app self-contained: embed libqemu-arm.dylib and
# its compatible dylib dependency closure into Contents/Frameworks, repointed to
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
# Build compatible dependencies with scripts/build-package-native.sh first; it
# prints the QEMU_BUILD_DIR/LTM_DEPS_PREFIX/USBMUXD_BIN settings to use here.
# Device assets are embedded below unless LTM_ASSETS=none (development only).
set -euo pipefail

APP="${1:-}"
SRC="$(cd "$(dirname "$0")/.." && pwd)"
QEMU="${QEMU_IOS_DIR:-$HOME/Developer/qemu-ios}"
BUILD="${QEMU_BUILD_DIR:-$QEMU/build-native14/qemu-build}"
DYLIB="$BUILD/libqemu-arm.dylib"
ENTITLEMENTS="$QEMU/contrib/macos-app/entitlements.plist"
DEPS="${LTM_DEPS_PREFIX:-$QEMU/build-native14/prefix}"
CHECK="$SRC/scripts/check-macho.py"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
SIGN_ID="${SIGN_ID:--}"          # '-' == ad-hoc

if [ -z "$APP" ]; then
    # Not Index.noindex — Xcode's index-build app there is not a signable bundle.
    APP="$(find "$HOME/Library/Developer/Xcode/DerivedData" -type d \
        -path "*LightTouchMac*/Build/Products/*/LightTouchMac.app" \
        -not -path "*/Index.noindex/*" 2>/dev/null | head -1)"
fi
[ -d "$APP" ] || { echo "no LightTouchMac.app found; build it first or pass a path" >&2; exit 1; }
[ -f "$DYLIB" ] || { echo "no $DYLIB; run contrib/macos-app/make-dylib-macos.sh" >&2; exit 1; }

# A Debug build is not shippable: its binary is a stub loading
# LightTouchMac.debug.dylib, and its SPM frameworks live in DerivedData's
# PackageFrameworks OUTSIDE the bundle — it packages cleanly and then fails
# on any other Mac. Build Release: xcodebuild -scheme LightTouchMac
# -configuration Release.
APP_EXECUTABLE="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$APP/Contents/Info.plist")"
APP_BIN="$APP/Contents/MacOS/$APP_EXECUTABLE"
if otool -L "$APP_BIN" | grep -q '\.debug\.dylib'; then
    echo "$APP is a Debug build (loads a .debug.dylib); package a Release build" >&2
    exit 1
fi

MINOS="$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' "$APP/Contents/Info.plist")"
# Check the emulator closure before modifying the app. The app is checked after embedding.
python3 "$CHECK" --minos "$MINOS" "$DYLIB"

FRAMEWORKS="$APP/Contents/Frameworks"
mkdir -p "$FRAMEWORKS"
echo "app:        $APP"
echo "dylib:      $DYLIB"

# Copy a Mach-O and every non-system dylib it needs, transitively, into
# Frameworks; rewrite each install name and inter-dependency to @rpath.
# (Plain string set, so this runs under the stock macOS bash 3.2.)
COPIED=" "
copy_with_deps() {
    local src base
    src="$(python3 -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' "$1")"
    base="$(basename "$src")"
    case "$COPIED" in *" $base "*) return ;; esac
    COPIED="$COPIED$base "

    python3 "$CHECK" --minos "$MINOS" "$src"
    local dst="$FRAMEWORKS/$base"
    if [ "$src" != "$dst" ]; then cp -f "$src" "$dst"; chmod u+w "$dst"; fi
    install_name_tool -id "@rpath/$base" "$dst"

    local dep resolved
    while IFS=$'\t' read -r dep resolved; do
        install_name_tool -change "$dep" "@rpath/$(basename "$resolved")" "$dst"
        copy_with_deps "$resolved"
    done < <(python3 "$CHECK" --deps "$src")
    install_name_tool -add_rpath "@loader_path" "$dst" 2>/dev/null || true

}

echo "embedding dylib + dependency closure…"
copy_with_deps "$DYLIB"
# Ship the source provenance and license alongside the optional AAC decoder.
case "$COPIED" in
    *" libavcodec."*)
        [ -f "$DEPS/share/licenses/ffmpeg/COPYING.LGPLv2.1" ] || {
            echo "missing FFmpeg license/provenance in $DEPS/share/licenses/ffmpeg" >&2
            exit 1
        }
        mkdir -p "$APP/Contents/Resources/licenses"
        cp -R "$DEPS/share/licenses/ffmpeg" "$APP/Contents/Resources/licenses/"
        ;;
esac

APP_BIN="$APP/Contents/MacOS/$APP_EXECUTABLE"

# ---------------------------------------------------------- tools the app runs
#
# The app is meant to work on a Mac with no Homebrew and no source checkout, so
# Native helper executables live in Contents/MacOS, a standard nested-code
# location. Scripts and guest upload payloads remain in Resources/tools.
# Bundled.swift searches both, with native helpers first.
#
# IMobileDevice.swift dlopens compatible libimobiledevice and libplist; their
# deployment targets must satisfy the same minimum as the linked emulator.
TOOLS="$APP/Contents/Resources/tools"
mkdir -p "$TOOLS"
HOST_TOOLS=()
copy_tool() {
    local src="$1" base dst
    base="$(basename "$src")"
    [ -f "$src" ] || { echo "missing required tool: $src" >&2; exit 1; }
    dst="$TOOLS/$base"
    if [ "${2:-host}" = host ] && file "$src" | grep -q Mach-O; then
        python3 "$CHECK" --minos "$MINOS" "$src"
        dst="$APP/Contents/MacOS/$base"
        HOST_TOOLS+=("$dst")
        # Remove the previous packaging layout's copy on incremental runs.
        rm -f "$TOOLS/$base"
    fi
    cp -f "$src" "$dst"
    chmod u+wx "$dst"
    [ "${2:-host}" = guest ] && return
    file "$src" | grep -q Mach-O || return 0
    local dep resolved
    while IFS=$'\t' read -r dep resolved; do
        install_name_tool -change "$dep" "@rpath/$(basename "$resolved")" "$dst"
        copy_with_deps "$resolved"
    done < <(python3 "$CHECK" --deps "$src")
    install_name_tool -add_rpath "@executable_path/../Frameworks" "$dst" 2>/dev/null || true
}

echo "embedding compatible tools…"
for tool in ideviceinstaller ideviceinfo idevicesyslog iproxy idevicepair; do
    copy_tool "$DEPS/bin/$tool"
done
# Explicitly ship dlopen libraries even when the command-line tools are static.
for stem in libimobiledevice-1.0 libplist-2.0; do
    python3 "$CHECK" --minos "$MINOS" "$DEPS/lib/$stem.dylib"
    copy_with_deps "$DEPS/lib/$stem.dylib"
    canonical="$(python3 -c 'import os,sys; print(os.path.basename(os.path.realpath(sys.argv[1])))' "$DEPS/lib/$stem.dylib")"
    if [ "$canonical" != "$stem.dylib" ]; then
        ln -sf "$canonical" "$FRAMEWORKS/$stem.dylib"
    fi
done
TZ_BIN="$WORK/lockdown-tz"
cc -O2 -mmacosx-version-min="$MINOS" -o "$TZ_BIN" "$SRC/scripts/lockdown-tz.c" \
   -I"$DEPS/include" -L"$DEPS/lib" -limobiledevice-1.0 -lplist-2.0
copy_tool "$TZ_BIN"
CFLAGS="-mmacosx-version-min=$MINOS" bash "$QEMU/contrib/it-webproxy/build.sh"
copy_tool "$QEMU/contrib/it-webproxy/itwebproxy"
copy_tool "${USBMUXD_BIN:-$QEMU/build-native14/build/usbmuxd/src/usbmuxd}"

# NOTE: usbmuxd's -C directory is writable state (it stores SystemConfiguration
# and a pairing record per device). The app copies the bundled seed out to
# Application Support before use — see USBMux.confDirectory — because the bundle
# is read-only and signed. Ship only the seed, never a pairing record.
copy_tool "$QEMU/imgtools/install-ipa.sh"
copy_tool "$QEMU/contrib/it-ssh-terminal.sh"
# Guest-side binaries install-ipa.sh copies onto the device, and the helper that
# stands in for the python3 a clean Mac does not have.
copy_tool "$QEMU/contrib/it-gles/MBXGLEngine" guest
copy_tool "$QEMU/contrib/it-instprogress/sbdlicon" guest
# The quit-time helper asks launchd to shut down through reboot2(RB_HALT);
# the host still waits for an actual guest PMU power-off event.
copy_tool "$QEMU/contrib/it-halt/ithalt" guest
copy_tool "$QEMU/contrib/it-agent/it_agent" guest
copy_tool "$QEMU/contrib/it-agent/it_typein.dylib" guest
copy_tool "$QEMU/contrib/it-agent/com.qemu.it-agent.plist" guest
copy_tool "$QEMU/contrib/it-status/itstatus" guest
copy_tool "$QEMU/contrib/it-media/itmedia" guest
copy_tool "$QEMU/contrib/it-media/itphoto" guest
copy_tool "$QEMU/contrib/it-proxy/itproxy" guest
copy_tool "$QEMU/contrib/it-proxy/ittrust" guest
# Auto-rotation's guest-side reporter. Without it the feature is silently absent
# from every packaged build — the app resolves it bundle-first and then falls
# back to a checkout path a user's Mac does not have.
copy_tool "$QEMU/contrib/it-orientation/itorient" guest
# ipod-helper is built, not committed (contrib/macos-app/ipod-helper.c), and the
# qemu-ios app pipeline is what compiles it — take its copy.
copy_tool "${IT_HELPER_BIN:-$QEMU/build/iPod touch.app/Contents/Resources/tools/ipod-helper}"

# The usbmuxd config dir. USBMux.swift passes this as `-C`; without a bundle
# copy a packaged app pointed at a nonexistent path (Bundled.resource returns
# nil and it fell back to the dev checkout, which a clean Mac does not have).
CONF_SRC="${USBMUXD_QEMU:-$HOME/Developer/usbmuxd-qemu}/run/conf"
CONF_DST="$APP/Contents/Resources/usbmuxd-conf"
if [ -d "$CONF_SRC" ]; then
    echo "embedding usbmuxd-conf…"
    rm -rf "$CONF_DST"; mkdir -p "$CONF_DST"
    [ -f "$CONF_SRC/SystemConfiguration.plist" ] &&
        cp "$CONF_SRC/SystemConfiguration.plist" "$CONF_DST/"
    # SystemConfiguration.plist ONLY. The per-device files are PAIRING RECORDS
    # — copying "*.plist" shipped this developer's own pairing record and host
    # SystemBUID to every user, and a pairing record is a device credential.
    # usbmuxd writes its own on first use, into the copy the app makes in
    # Application Support (the bundle is read-only and signed).
else
    echo "missing required usbmuxd configuration: $CONF_SRC" >&2; exit 1
fi

# -------------------------------------------------------------- device assets
#
# The guest firmware and NAND, read from Resources/device (see
# LaunchOptions.defaultFilesRoot). Copied raw and uncompressed: the app boots
# the NAND directory read-only with a per-user overlay in Application Support,
# so a signed read-only copy works as-is — no first-run unpack step to break.
# Costs ~1.2 GB of bundle; LTM_ASSETS=none skips it for a dev-machine build
# that keeps using the checkout's files-root.
FILES="${LTM_ASSETS:-$HOME/Developer/qemu-ios-files}"
# Prefer the validated current guest-tool image for new devices. Keep the
# legacy asset layout usable, and always honor an explicit image selection.
NAND_NAME="${LTM_NAND:-nand-ultimate}"
if [ -z "${LTM_NAND:-}" ]; then
    for candidate in nand-agent-v4 nand-agent-v3; do
        if [ -d "$FILES/$candidate" ]; then
            NAND_NAME="$candidate"
            break
        fi
    done
fi
if [ "$FILES" != none ]; then
    for f in "$FILES/bootrom_240_4" "$FILES/ios3/iBoot.bin" \
             "$FILES/ios3/nor_7E18.bin" "$FILES/$NAND_NAME"; do
        [ -e "$f" ] || { echo "missing device asset: $f (LTM_ASSETS=none to skip)" >&2; exit 1; }
    done
    DEVICE="$APP/Contents/Resources/device"
    echo "embedding device assets ($NAND_NAME, packed)…"
    rm -rf "$DEVICE"
    mkdir -p "$DEVICE/ios3"
    cp "$FILES/bootrom_240_4" "$DEVICE/"
    cp "$FILES/ios3/iBoot.bin" "$FILES/ios3/nor_7E18.bin" "$DEVICE/ios3/"
    # The NAND goes in as ONE opaque blob, never raw pages: the notary walks
    # every file in the bundle and rejects the armv6 Mach-Os a raw iOS
    # filesystem contains — and it opens tarballs too, so only a format it
    # cannot recognise works (see qemu-ios contrib/macos-app/nandpack.py).
    # The app unpacks it into Application Support on first boot.
    python3 "$QEMU/contrib/macos-app/nandpack.py" pack "$FILES/$NAND_NAME" "$DEVICE/nand.itnand"
    shasum -a 256 "$DEVICE/nand.itnand" | awk '{print $1}' > "$DEVICE/nand.itnand.sha256"
fi

# Drop the build-tree rpath so resolution goes through Contents/Frameworks only.
for f in "$APP_BIN" "$FRAMEWORKS"/*.dylib "${HOST_TOOLS[@]}"; do
    while IFS= read -r path; do
        case "$path" in /*) install_name_tool -delete_rpath "$path" "$f" ;; esac
    done < <(python3 "$CHECK" --rpaths "$f")
done

# Check all host Mach-Os, including the app and its complete load closure.
# Guest ARMv6 helpers are resources, not executable on macOS.
echo "sealing…"
python3 "$CHECK" --minos "$MINOS" --bundle "$APP" \
    "$APP_BIN" "$FRAMEWORKS"/*.dylib "${HOST_TOOLS[@]}"

# Sign inside-out: frameworks first, then the app with entitlements.
echo "signing (id: $SIGN_ID)…"
for f in "$FRAMEWORKS"/*.dylib "${HOST_TOOLS[@]}"; do
    [ -L "$f" ] && continue
    # Scripts are not signable and do not need to be; the app's signature covers
    # them as resources.
    [ -f "$f" ] && file "$f" | grep -q Mach-O && codesign -f -o runtime -s "$SIGN_ID" "$f"
done
codesign -f -o runtime --entitlements "$ENTITLEMENTS" -s "$SIGN_ID" "$APP"
codesign --verify --deep --strict "$APP"
codesign -dv "$APP" 2>&1 | grep -E "Identifier|Signature" || true

if [ -n "${NOTARY_PROFILE:-}" ] && [ "$SIGN_ID" != "-" ]; then
    echo "notarizing…"
    ZIP="$(mktemp -d)/LightTouchMac.zip"
    ditto -c -k --keepParent "$APP" "$ZIP"
    xcrun notarytool submit "$ZIP" --keychain-profile "$NOTARY_PROFILE" --wait
    xcrun stapler staple "$APP"
fi

echo "done: $APP"
