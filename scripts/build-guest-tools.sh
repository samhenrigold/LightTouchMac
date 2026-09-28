#!/bin/bash
# Build the package's guest payloads without writing into the QEMU checkout.
# Usage: ARMV6_SDK=/path/to/iPhoneOS3.1.3.sdk build-guest-tools.sh NEW-WORK-DIRECTORY
# QEMU_IOS_DIR selects the source checkout; LDID selects the existing signer.
# The flat output directory is NEW-WORK-DIRECTORY/guest-tools.
# When the checkout has the iPad helpers (contrib/ipad1-guest), they are built
# too, into NEW-WORK-DIRECTORY/ipad-guest-tools: the flat directory firmwarekit
# reads (SystemEdits.Helpers). IPAD_SDK selects the iPhoneOS3.2.sdk.
set -euo pipefail

fail() { echo "build-guest-tools: $*" >&2; exit 1; }
if [ "$#" -ne 1 ]; then
    fail "usage: ARMV6_SDK=/path/to/iPhoneOS3.1.3.sdk $0 NEW-WORK-DIRECTORY"
fi
ROOT="$1"
SCRIPT="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"
QEMU="${QEMU_IOS_DIR:-$(dirname "$(dirname "$SCRIPT")")/../qemu-ios}"
SDK="${ARMV6_SDK:-}"
[ ! -e "$ROOT" ] && [ ! -L "$ROOT" ] || fail "use a new build directory: $ROOT"
[ -n "$SDK" ] || fail "set ARMV6_SDK to the iPhoneOS3.1.3.sdk directory"
for input in usr/include/stdio.h usr/lib/libSystem.dylib; do
    [ -f "$SDK/$input" ] || fail "missing SDK input: $SDK/$input"
done
for tool in python3 xcrun file; do
    command -v "$tool" >/dev/null || fail "required tool not found: $tool"
done
LDID="${LDID:-ldid}"
command -v "$LDID" >/dev/null || fail "required guest signer not found: $LDID"
LDID="$(command -v "$LDID")"
export LDID
xcrun --find clang >/dev/null
xcrun --find ld >/dev/null
ARMV6_SDK="$(cd "$SDK" && pwd)"
export ARMV6_SDK

COMPONENTS=(it-gles it-instprogress it-halt it-agent it-status it-media it-proxy it-orientation)
[ -f "$QEMU/contrib/armv6-toolchain/armv6.sh" ] || fail "missing armv6 toolchain in $QEMU"
for component in "${COMPONENTS[@]}"; do
    [ -f "$QEMU/contrib/$component/build.sh" ] || fail "missing build recipe: $component"
done
# The iPad helpers, built by their own contrib recipes (as the FirmwareKit tests use them).
IPAD_RECIPES=(ipad1-guest appsync ipad1-gles)
IPAD_SOURCES=(it-pasteboard it-ethlink it-seal it-prefs it-keybag it-heading it-cctest it-gltest it-msmquiet)
IPAD=0
IPAD_SDK_DIR=""
if [ -f "$QEMU/contrib/ipad1-guest/build.sh" ]; then
    IPAD=1
    IPAD_SDK_DIR="${IPAD_SDK:-$HOME/Developer/qemu-ios-files/ipad1/sdk/x-iPhoneSDK3_2_2/Payload/Platforms/iPhoneOS.platform/Developer/SDKs/iPhoneOS3.2.sdk}"
    [ -f "$IPAD_SDK_DIR/usr/lib/libSystem.dylib" ] || fail "missing iPad SDK (IPAD_SDK): $IPAD_SDK_DIR"
    IPAD_SDK_DIR="$(cd "$IPAD_SDK_DIR" && pwd)"
    for component in "${IPAD_RECIPES[@]}" "${IPAD_SOURCES[@]}"; do
        [ -d "$QEMU/contrib/$component" ] || fail "missing iPad guest source: $component"
    done
    ls "$QEMU"/docs/ipad1/gli-dispatch-*.tsv >/dev/null || fail "missing docs/ipad1/gli-dispatch-*.tsv"
    COPY_EXTRA=("${IPAD_RECIPES[@]}" "${IPAD_SOURCES[@]}")
else
    COPY_EXTRA=()
fi

mkdir -p "$(dirname "$ROOT")"
mkdir "$ROOT"
ROOT="$(cd "$ROOT" && pwd)"
mkdir -p "$ROOT/src/contrib" "$ROOT/logs"

# Preserve the toolchain's relative layout, copying source inputs only.
# In particular, tracked or ignored binaries from earlier builds are not inputs.
for component in armv6-toolchain "${COMPONENTS[@]}" ${COPY_EXTRA[@]+"${COPY_EXTRA[@]}"}; do
    mkdir "$ROOT/src/contrib/$component"
    for input in "$QEMU/contrib/$component/"*; do
        case "$input" in
            */gles_stubs.h|*/gli_fwd.h) continue ;;
            *.c|*.h|*.sh|*.py|*.xml|*.plist|*.entitlements|*.txt)
                [ -f "$input" ] || continue
                cp -p "$input" "$ROOT/src/contrib/$component/"
                ;;
        esac
    done
done
if [ "$IPAD" = 1 ]; then
    mkdir -p "$ROOT/src/docs/ipad1"
    cp -p "$QEMU"/docs/ipad1/gli-dispatch-*.tsv "$ROOT/src/docs/ipad1/"
fi

# Keep the package recipe here: the component build.sh files also build probes
# that are not shipped and should not become release prerequisites. These are
# their existing cc6/link6 calls for the shipped payloads, using armv6.sh as-is.
build_component() (
    HERE="$ROOT/src/contrib/$1"
    . "$ROOT/src/contrib/armv6-toolchain/armv6.sh"
    case "$1" in
        it-gles)
            python3 "$HERE/genstubs.py" "$HERE/gles_stubs.h"
            cc6 "$HERE/mbxshim.c" "$HERE/mbxshim.o"
            link6 -bundle "$HERE/MBXGLEngine" "$HERE/mbxshim.o"
            ;;
        it-instprogress|it-halt|it-orientation)
            case "$1" in
                it-instprogress) name=sbdlicon ;;
                it-halt) name=ithalt ;;
                it-orientation) name=itorient ;;
            esac
            cc6 "$HERE/$name.c" "$HERE/$name.o"
            link6 -execute "$HERE/$name" "$HERE/$name.o" -e __start
            ;;
        it-agent)
            cc6 "$HERE/it_agent.c" "$HERE/it_agent.o" -isystem "$(xcrun clang -print-resource-dir)/include"
            link6 -execute "$HERE/it_agent" "$HERE/it_agent.o"
            "$LDID" -S"$HERE/../it-gles/sblaunch-entitlements.xml" "$HERE/it_agent"
            cc6 "$HERE/it_typein.c" "$HERE/it_typein.o"
            link6 -dylib "$HERE/it_typein.dylib" "$HERE/it_typein.o" -install_name /usr/lib/it_typein.dylib
            ;;
        it-status)
            cc6 "$HERE/itstatus.c" "$HERE/itstatus.o"
            link6 -execute "$HERE/itstatus" "$HERE/itstatus.o" -e _main
            ;;
        it-media)
            cc6 "$HERE/itmedia.c" "$HERE/itmedia.o" -Wall -Wextra -isystem "$(xcrun clang -print-resource-dir)/include"
            link6 -execute "$HERE/itmedia" "$HERE/itmedia.o" -e __start
            cc6 "$HERE/itphoto.c" "$HERE/itphoto.o" -Wall -Wextra
            link6 -execute "$HERE/itphoto" "$HERE/itphoto.o" -e __start
            ;;
        it-proxy)
            for name in itproxy ittrust; do
                cc6 "$HERE/$name.c" "$HERE/$name.o"
                link6 -execute "$HERE/$name" "$HERE/$name.o" -e __start
            done
            "$LDID" -S"$HERE/ittrust.entitlements" "$HERE/ittrust"
            ;;
    esac
    rm -f "$HERE/"*.o
)
export -f build_component

# Capture the actual source snapshot before generated files appear. The final
# record next to guest-tools/ adds output hashes for the product release driver.
python3 - "$ROOT" "$SCRIPT" "$QEMU" "$ARMV6_SDK" "$LDID" "$IPAD_SDK_DIR" <<'PY'
import hashlib
import json
from pathlib import Path
import sys

root, script, qemu, sdk, signer = map(Path, sys.argv[1:6])
ipad_sdk = sys.argv[6]
def sha256(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()
record = {
    "schema": 1,
    "builder": {"path": str(script), "sha256": sha256(script)},
    "qemu_source": str(qemu.resolve()),
    "sdk": str(sdk),
    "signer": {"path": str(signer), "sha256": sha256(signer)},
    "ipad_sdk": ipad_sdk or None,
    "source_inputs": [
        {"path": str(path.relative_to(root / "src")), "sha256": sha256(path)}
        for path in sorted((root / "src").rglob("*")) if path.is_file()
    ],
}
(root / "guest-tools-inputs.json").write_text(json.dumps(record, indent=2) + "\n")
PY

for component in "${COMPONENTS[@]}"; do
    echo "building guest tools: $component"
    # A separate shell keeps `set -e` effective inside the recipe even while
    # this caller captures failure to print the log.
    if ! ROOT="$ROOT" bash -eu -o pipefail -c 'build_component "$1"' _ "$component" >"$ROOT/logs/$component.log" 2>&1; then
        cat "$ROOT/logs/$component.log" >&2
        fail "$component failed; build inputs and logs retained in $ROOT"
    fi
done
if [ "$IPAD" = 1 ]; then
    C="$ROOT/src/contrib"
    echo "building guest tools: iPad"
    if ! (IPAD_SDK="$IPAD_SDK_DIR" IPOD_SDK="$ARMV6_SDK" bash "$C/ipad1-guest/build.sh" "$ROOT/ipad-build" &&
          IPAD_SDK="$IPAD_SDK_DIR" IPOD_SDK="$ARMV6_SDK" bash "$C/appsync/build.sh" "$ROOT/ipad-build" &&
          IPAD_SDK="$IPAD_SDK_DIR" bash "$C/ipad1-gles/build.sh") >"$ROOT/logs/ipad.log" 2>&1; then
        cat "$ROOT/logs/ipad.log" >&2
        fail "iPad guest tools failed; build inputs and logs retained in $ROOT"
    fi
fi

# Publish only the app's payload set, after every build has succeeded.
mkdir "$ROOT/guest-tools.incomplete"
stage_payload() {
    local input="$ROOT/src/contrib/$1/$2"
    [ -s "$input" ] || fail "build did not produce required payload: $input"
    cp -p "$input" "$ROOT/guest-tools.incomplete/$2"
}
stage_payload it-gles MBXGLEngine
stage_payload it-instprogress sbdlicon
stage_payload it-halt ithalt
stage_payload it-agent it_agent
stage_payload it-agent it_typein.dylib
stage_payload it-agent com.qemu.it-agent.plist
stage_payload it-status itstatus
stage_payload it-media itmedia
stage_payload it-media itphoto
stage_payload it-proxy itproxy
stage_payload it-proxy ittrust
stage_payload it-orientation itorient
# The iPad set, by the file names firmwarekit reads (SystemEdits.Helpers, Preparer's
# it_keybag). Each Mach-O keeps its ldid signature: these run in the guest, and the
# app's signature seals them as resources. GLRendererFloatQEMU ships as the flat
# Mach-O (firmwarekit installs it into the .bundle), so no nested bundle is signed.
if [ "$IPAD" = 1 ]; then
    mkdir "$ROOT/ipad-guest-tools.incomplete"
    ipad_payload() {
        [ -s "$1" ] || fail "build did not produce required iPad payload: $1"
        cp -p "$1" "$ROOT/ipad-guest-tools.incomplete/"
    }
    for t in it_pbd it_ethlink it_prefs it_msmquiet.dylib it_seal it_keybag libappsync.dylib; do
        ipad_payload "$ROOT/ipad-build/$t"
    done
    for j in it-pasteboard/com.qemu.it-pbd.plist it-ethlink/com.qemu.it-ethlink.plist \
             it-prefs/com.qemu.it-prefs.plist it-seal/com.qemu.it-seal.plist; do
        ipad_payload "$C/$j"
    done
    for tsv in "$ROOT"/src/docs/ipad1/gli-dispatch-*.tsv; do
        b="${tsv##*gli-dispatch-}"; b="${b%.tsv}"
        ipad_payload "$tsv"
        ipad_payload "$C/ipad1-gles/GLEngine-$b"
    done
    ipad_payload "$C/ipad1-gles/GLRendererFloatQEMU.bundle/GLRendererFloatQEMU"
    chmod 0644 "$ROOT"/ipad-guest-tools.incomplete/*.plist "$ROOT"/ipad-guest-tools.incomplete/*.tsv
fi
python3 - "$ROOT" <<'PY'
import hashlib
import json
from pathlib import Path
import sys

root = Path(sys.argv[1])
record = json.loads((root / "guest-tools-inputs.json").read_text())
def outputs(directory):
    return [{"path": path.name, "sha256": hashlib.sha256(path.read_bytes()).hexdigest()}
            for path in sorted(directory.iterdir())]
record["outputs"] = outputs(root / "guest-tools.incomplete")
if (root / "ipad-guest-tools.incomplete").is_dir():
    record["ipad_outputs"] = outputs(root / "ipad-guest-tools.incomplete")
(root / "guest-tools.json").write_text(json.dumps(record, indent=2) + "\n")
PY
[ "$IPAD" = 1 ] && mv "$ROOT/ipad-guest-tools.incomplete" "$ROOT/ipad-guest-tools"
mv "$ROOT/guest-tools.incomplete" "$ROOT/guest-tools"
printf '\nGuest payloads ready. Package with:\nLTM_GUEST_TOOLS_DIR=%q\n' "$ROOT/guest-tools"
