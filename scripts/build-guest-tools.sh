#!/bin/bash
# Build the package's guest payloads: a thin caller of qemu-ios contrib/export-guest-artifacts.sh, the
# emulator repository's export (the recipes live there; this script only resolves the checkout and the SDKs).
# Usage: ARMV6_SDK=/path/to/iPhoneOS3.1.3.sdk build-guest-tools.sh NEW-WORK-DIRECTORY
# QEMU_IOS_DIR selects the source checkout (default: the pin, scripts/sources.py); IPAD_SDK the iPhoneOS3.2.sdk;
# LDID the existing signer. The export writes NEW-WORK-DIRECTORY/guest-tools (the flat iPod set the app uploads),
# NEW-WORK-DIRECTORY/ipad-guest-tools (the flat directory firmwarekit reads: helpers, the two GL engines
# GLEngine and MBXGLEngine with gles-names.h, armv6.itpack and armv7.itpack) and manifest.json (source commit, dirty flag, sha256 per input and output),
# which build-release.py validates. Nothing is written into the checkout.
set -euo pipefail

fail() { echo "build-guest-tools: $*" >&2; exit 1; }
if [ "$#" -ne 1 ]; then
    fail "usage: ARMV6_SDK=/path/to/iPhoneOS3.1.3.sdk $0 NEW-WORK-DIRECTORY"
fi
ROOT="$1"
HERE="$(cd "$(dirname "$0")" && pwd)"
QEMU="$(python3 "$HERE/sources.py" qemu-ios)"
EXPORT="$QEMU/contrib/export-guest-artifacts.sh"
[ ! -e "$ROOT" ] && [ ! -L "$ROOT" ] || fail "use a new build directory: $ROOT"
[ -n "${ARMV6_SDK:-}" ] || fail "set ARMV6_SDK to the iPhoneOS3.1.3.sdk directory"
[ -f "$ARMV6_SDK/usr/lib/libSystem.dylib" ] || fail "missing SDK input: $ARMV6_SDK/usr/lib/libSystem.dylib"
[ -f "$EXPORT" ] || fail "no contrib/export-guest-artifacts.sh in $QEMU: a qemu-ios ipad1 checkout at or after the pin (build-support/sources.json)"
export ARMV6_SDK
bash "$EXPORT" "$ROOT"
# the runtime-dispatch GL engines (qemu-ios gl-runtime): an older export stages per-build engines and tables instead
for f in GLEngine MBXGLEngine gles-names.h; do
    [ -s "$ROOT/ipad-guest-tools/$f" ] || fail "the export staged no ipad-guest-tools/$f: $QEMU predates gl-runtime (see build-support/sources.json)"
done
printf '\nGuest payloads ready. Package with:\nLTM_GUEST_TOOLS_DIR=%q\n' "$ROOT/guest-tools"
