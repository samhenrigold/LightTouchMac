#!/bin/bash
#
# Make the built LightTouchMac.app self-contained: embed libqemu-arm.dylib and
# its compatible dylib dependency closure into Contents/Frameworks, repointed to
# @rpath, then re-sign. After this the app runs on a Mac that has neither the
# qemu-ios build tree nor Homebrew.
#
#     scripts/package.sh path/to/Light\ Touch.app
# Prefer scripts/build-release.py for a fresh, complete product build.
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

APP="${1:?usage: package.sh path/to/Light Touch.app (or use scripts/build-release.py)}"
SRC="$(cd "$(dirname "$0")/.." && pwd)"
QEMU="${QEMU_IOS_DIR:-$SRC/../qemu-ios}"
BUILD="${QEMU_BUILD_DIR:-$QEMU/build-native14/qemu-build}"
DYLIB="$BUILD/libqemu-arm.dylib"
ENTITLEMENTS="$QEMU/contrib/macos-app/entitlements.plist"
DEPS="${LTM_DEPS_PREFIX:-$QEMU/build-native14/prefix}"
STATIC="${LTM_STATIC_DEPS:-$SRC/../qemu-ios-deps12}"
GUEST="${LTM_GUEST_TOOLS_DIR:-}"
CHECK="$SRC/scripts/check-macho.py"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
SIGN_ID="${SIGN_ID:--}"          # '-' == ad-hoc

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
python3 "$CHECK" --no-weak-imports --minos "$MINOS" "$DYLIB"

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

    python3 "$CHECK" --no-weak-imports --minos "$MINOS" "$src"
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

# The per-device helper (the LightTouchDevice target, embedded by Xcode). It
# links only system libraries and dlopens Frameworks/libqemu-arm.dylib, whose
# closure is embedded above; its build-tree rpath is dropped below.
DEVICE_HELPER="$APP/Contents/MacOS/LightTouchDevice"
[ -f "$DEVICE_HELPER" ] || { echo "missing $DEVICE_HELPER; build the LightTouchMac scheme (it embeds the helper)" >&2; exit 1; }
python3 "$CHECK" --minos "$MINOS" "$DEVICE_HELPER"   # Swift binaries weak-import their FORCE_LOAD markers
# The firmware preparer (Packages/FirmwareKit's CLI), when built: hardened
# runtime only, no entitlements. Signed with the other Contents/MacOS tools.
FIRMWAREKIT=()
if [ -n "${LTM_FIRMWAREKIT:-}" ]; then
    python3 "$CHECK" --minos "$MINOS" "$LTM_FIRMWAREKIT"
    cp -f "$LTM_FIRMWAREKIT" "$APP/Contents/MacOS/firmwarekit"
    chmod u+rwx "$APP/Contents/MacOS/firmwarekit"
    FIRMWAREKIT=("$APP/Contents/MacOS/firmwarekit")
fi

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
        python3 "$CHECK" --no-weak-imports --minos "$MINOS" "$src"
        dst="$APP/Contents/MacOS/$base"
        HOST_TOOLS+=("$dst")
        # Remove the previous packaging layout's copy on incremental runs.
        rm -f "$TOOLS/$base"
    fi
    cp -f "$src" "$dst"
    chmod u+rw "$dst"
    case "$base" in
        *.plist) chmod a-x "$dst" ;;
        *) chmod u+x "$dst" ;;
    esac
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
for tool in ideviceinstaller ideviceinfo idevicesyslog idevice_id iproxy idevicepair; do
    copy_tool "$DEPS/bin/$tool"
done
# Explicitly ship dlopen libraries even when the command-line tools are static.
for stem in libimobiledevice-1.0 libplist-2.0; do
    python3 "$CHECK" --no-weak-imports --minos "$MINOS" "$DEPS/lib/$stem.dylib"
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
MC_BIN="$WORK/lockdown-mcinstall"
cc -O2 -mmacosx-version-min="$MINOS" -o "$MC_BIN" "$SRC/scripts/lockdown-mcinstall.c" \
   -I"$DEPS/include" -L"$DEPS/lib" -limobiledevice-1.0 -lplist-2.0
copy_tool "$MC_BIN"
mkdir -p "$WORK/it-webproxy"
for source in build.sh itwebproxy.c tls-bridge.h weather.m; do
    cp "$QEMU/contrib/it-webproxy/$source" "$WORK/it-webproxy/"
done
OPENSSL_PREFIX="$STATIC" CFLAGS="-mmacosx-version-min=$MINOS" \
    bash "$WORK/it-webproxy/build.sh"
copy_tool "$WORK/it-webproxy/itwebproxy"
copy_tool "${USBMUXD_BIN:-$QEMU/build-native14/build/usbmuxd/src/usbmuxd}"

# NOTE: usbmuxd's -C directory is writable state (it stores SystemConfiguration
# and a pairing record per device). The app copies the bundled seed out to
# Application Support before use — see USBMux.confDirectory — because the bundle
# is read-only and signed. Ship only the seed, never a pairing record.
copy_tool "$QEMU/imgtools/install-ipa.sh"
copy_tool "$QEMU/contrib/it-ssh-terminal.sh"
# Guest-side binaries install-ipa.sh copies onto the device, and the helper that
# stands in for the python3 a clean Mac does not have.
copy_guest() {
    if [ -n "$GUEST" ]; then
        copy_tool "$GUEST/$(basename "$1")" guest
    else
        # Compatibility for explicitly packaging an existing developer build.
        copy_tool "$QEMU/contrib/$1" guest
    fi
}
copy_guest it-gles/MBXGLEngine
copy_guest it-instprogress/sbdlicon
# The quit-time helper asks launchd to shut down through reboot2(RB_HALT);
# the host still waits for an actual guest PMU power-off event.
copy_guest it-halt/ithalt
copy_guest it-agent/it_agent
copy_guest it-agent/it_typein.dylib
copy_guest it-agent/com.qemu.it-agent.plist
copy_guest it-status/itstatus
copy_guest it-media/itmedia
copy_guest it-media/itphoto
copy_guest it-proxy/itproxy
copy_guest it-proxy/ittrust
# Auto-rotation's guest-side reporter. Without it the feature is silently absent
# from every packaged build — the app resolves it bundle-first and then falls
# back to a checkout path a user's Mac does not have.
copy_guest it-orientation/itorient
# Build directly from source; the old launcher app is no longer a dependency.
cc -O2 -Wall -mmacosx-version-min="$MINOS" \
    "$QEMU/contrib/macos-app/ipod-helper.c" -lz -o "$WORK/ipod-helper"
copy_tool "$WORK/ipod-helper"

# The usbmuxd config dir. USBMux.swift passes this as `-C`; without a bundle
# copy a packaged app pointed at a nonexistent path (Bundled.resource returns
# nil and it fell back to the dev checkout, which a clean Mac does not have).
CONF_DST="$APP/Contents/Resources/usbmuxd-conf"
echo "embedding empty usbmuxd configuration seed…"
rm -rf "$CONF_DST"; mkdir -p "$CONF_DST"
# usbmuxd creates its host identity and pairing records in the writable copy.
# Never consume developer runtime state as a build input.
cat > "$CONF_DST/SystemConfiguration.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict/></plist>
PLIST

# -------------------------------------------------------------- device assets
#
# The guest firmware and NAND, read from Resources/device (see
# LaunchOptions.defaultFilesRoot). The packed NAND is extracted on first boot;
# all writable device state stays in Application Support. Import is future work.
FILES="${LTM_ASSETS:-$SRC/../qemu-ios-files}"
# nand-current names the shipping image; resolve it so provenance records the real one.
NAND_NAME="${LTM_NAND:-$(basename "$(readlink "$FILES/nand-current" 2>/dev/null)")}"
DEVICE="$APP/Contents/Resources/device"
rm -rf "$DEVICE"
if [ "$FILES" != none ]; then
    for f in "$FILES/bootrom_240_4" "$FILES/ios3/iBoot.bin" \
             "$FILES/ios3/nor_7E18.bin" "$FILES/$NAND_NAME"; do
        [ -e "$f" ] || { echo "missing device asset: $f (LTM_ASSETS=none to skip)" >&2; exit 1; }
    done
    echo "embedding device assets ($NAND_NAME, packed)…"
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

mkdir -p "$APP/Contents/Resources/licenses/qemu"
cp "$QEMU/LICENSE" "$QEMU/COPYING" "$QEMU/COPYING.LIB" "$APP/Contents/Resources/licenses/qemu/"
if [ -d "$DEPS/share/licenses" ]; then
    cp -R "$DEPS/share/licenses/." "$APP/Contents/Resources/licenses/"
fi
if [ -d "$STATIC/share/licenses" ]; then
    cp -R "$STATIC/share/licenses/." "$APP/Contents/Resources/licenses/"
fi
if [ -n "${LTM_BUILD_RECORD:-}" ]; then
    cp "$LTM_BUILD_RECORD" "$APP/Contents/Resources/build-inputs.json"
fi

# Drop the build-tree rpath so resolution goes through Contents/Frameworks only.
for f in "$APP_BIN" "$DEVICE_HELPER" "$FRAMEWORKS"/*.dylib "${HOST_TOOLS[@]}" ${FIRMWAREKIT[@]+"${FIRMWAREKIT[@]}"}; do
    while IFS= read -r path; do
        case "$path" in /*) install_name_tool -delete_rpath "$path" "$f" ;; esac
    done < <(python3 "$CHECK" --rpaths "$f")
done

# Check all host Mach-Os, including the app and its complete load closure.
# Guest ARMv6 helpers are resources, not executable on macOS.
echo "sealing…"
python3 "$CHECK" --minos "$MINOS" --bundle "$APP" \
    "$APP_BIN" "$DEVICE_HELPER" "$FRAMEWORKS"/*.dylib "${HOST_TOOLS[@]}" ${FIRMWAREKIT[@]+"${FIRMWAREKIT[@]}"}

# Ad-hoc signatures have no Team ID, so hardened library validation cannot
# establish shared identity between a helper and its bundled dylibs. Use plain
# ad-hoc signing for local builds. Identity-signed helpers retain the hardened
# runtime and its same-Team-ID library validation without entitlement exceptions.
sign_nested_code() {
    local options=runtime
    [ "$SIGN_ID" != "-" ] || options=0
    codesign -f -o "$options" -s "$SIGN_ID" "$1"
}

# Sign inside-out: frameworks, then Contents/MacOS/* (the device helper with the
# QEMU entitlements: JIT, unsigned executable memory, no library validation),
# then the app with entitlements.
echo "signing (id: $SIGN_ID)…"
for f in "$FRAMEWORKS"/*.dylib "${HOST_TOOLS[@]}" ${FIRMWAREKIT[@]+"${FIRMWAREKIT[@]}"}; do
    [ -L "$f" ] && continue
    # Scripts are not signable and do not need to be; the app's signature covers
    # them as resources.
    [ -f "$f" ] && file "$f" | grep -q Mach-O && sign_nested_code "$f"
done
codesign -f -o runtime --entitlements "$ENTITLEMENTS" -s "$SIGN_ID" "$DEVICE_HELPER"
codesign -f -o runtime --entitlements "$ENTITLEMENTS" -s "$SIGN_ID" "$APP"
codesign --verify --deep --strict "$APP"
codesign -dv "$APP" 2>&1 | grep -E "Identifier|Signature" || true

if [ -n "${NOTARY_PROFILE:-}" ] && [ "$SIGN_ID" != "-" ]; then
    echo "notarizing…"
    ZIP="$WORK/LightTouchMac.zip"
    ditto -c -k --keepParent "$APP" "$ZIP"
    xcrun notarytool submit "$ZIP" --keychain-profile "$NOTARY_PROFILE" --wait
    xcrun stapler staple "$APP"
fi

echo "done: $APP"
