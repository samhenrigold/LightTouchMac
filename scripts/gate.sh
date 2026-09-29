#!/bin/bash
# The one gate for the app.
#
#   scripts/gate.sh --quick   host only: swift test (Packages/FirmwareKit), tests/run-catalog-checks.py, every
#                             offline tests/check-*.py (swiftc slices on temp fixtures; no helper, no emulator) and
#                             scripts/test-*.py except the network one (test-dependency-sources.py); JOBS at a
#                             time (default 4)
#   scripts/gate.sh --full    quick, then the emulator-backed checks one after another: check-helper-boot.py,
#                             check-sessions.py --ipad-device, check-sessions.py --guest, check-guest-package.py,
#                             scripts/regress-app.sh
#
# Inputs, resolved here once and otherwise the checks' own defaults:
#   QEMU_IOS_DIR     the qemu-ios checkout (default: the pin, scripts/sources.py qemu-ios);
#                    also FIRMWAREKIT_QEMU_IOS for swift test and --qemu-ios for check-guest-package
#   LTM_QEMU_DYLIB   the emulator dylib the helper is linked against (default
#                    $(scripts/sources.py qemu-build)/libqemu-arm.dylib, Shared.xcconfig's QEMU_BUILD_DIR)
#   LTM_IPAD_DEVICE  a device.py iPad (default ~/Developer/qemu-ios-files/ipad1/repro/default-iboot, the
#                    qemu-ios harness's default device)
#   LTM_IPOD_DEVICE  --guest: a fresh device.py 7E18 iPod with a baked seed package (no default; make one with
#                    qemu-ios tests/ipod/fresh-device.sh or device.py create --guest-package)
#   LTM_ITPACK       --guest: the armv6 package (default $QEMU_IOS_DIR/build/guest-package/armv6.itpack, what
#                    contrib/guest-package/build.sh writes)
# A check whose input is missing is SKIP with the path it wanted. Every boot is headless with -audio driver=none
# (the checks' own doing). Checks listed in KNOWN below fail on today's code for the reason given; they run and
# report XFAIL (or XPASS once they pass again), and neither fails the gate. Delete the line when the check is
# fixed. One line per check, PASS/FAIL/SKIP/XFAIL/XPASS with seconds; exit 1 if anything FAILs. Logs under OUT
# (default mktemp). The offline checks each compile into their own temp dir; a shared module cache waits for
# the test move (docs/sweep/PLAN.md E4), since the checks pin -module-cache-path themselves.
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TIER="${1:---quick}"
case "$TIER" in --quick|--full) ;; *) sed -n '2,31p' "$0"; exit 2 ;; esac
export QEMU_IOS_DIR="${QEMU_IOS_DIR:-$(python3 "$ROOT/scripts/sources.py" qemu-ios)}"
export FIRMWAREKIT_QEMU_IOS="${FIRMWAREKIT_QEMU_IOS:-$QEMU_IOS_DIR}"
LTM_QEMU_DYLIB="${LTM_QEMU_DYLIB:-$(python3 "$ROOT/scripts/sources.py" qemu-build)/libqemu-arm.dylib}"
LTM_IPAD_DEVICE="${LTM_IPAD_DEVICE:-$HOME/Developer/qemu-ios-files/ipad1/repro/default-iboot}"
LTM_IPOD_DEVICE="${LTM_IPOD_DEVICE:-}"
LTM_ITPACK="${LTM_ITPACK:-$QEMU_IOS_DIR/build/guest-package/armv6.itpack}"
export OUT="${OUT:-$(mktemp -d /tmp/gate.XXXXXX)}"
JOBS="${JOBS:-4}"
export TIMEOUT="$(command -v timeout || true)"   # coreutils; without it a hung check hangs the gate
cd "$ROOT"
mkdir -p "$OUT" && : > "$OUT/results" || exit 2

# Failing on today's code (2026-09-28), each for a known reason.
export KNOWN='
tests/check-device-menus.py     check.swift:133: a fresh MainWindowController no longer reports canTakeScreenshot/canStartRecording (capture follows the selected device)
scripts/test-zoom.py            its slice reads Screen.screenCutout/nativeScreenPixels on an instance; they are static now
scripts/regress-app.sh          its env checks parse EmulatorController.swift for a boot configuration that moved to DeviceSession.swift (BootRecipe); the snapshot round trip passes
'
known_reason() { printf '%s\n' "$KNOWN" | awk -v n="$1" '$1 == n { $1 = ""; sub(/^ +/, ""); print }'; }
export -f known_reason

# NAME CMD...: one check, its own log, one line in $OUT/results (whole line appended at once).
run1() {
    local name=$1 t0=$SECONDS state why; shift
    if ${TIMEOUT:+$TIMEOUT 1800} "$@" > "$OUT/${name//[\/ ]/_}.log" 2>&1; then state=PASS; else state=FAIL; fi
    why=$(known_reason "$name")
    if [ -n "$why" ]; then
        if [ "$state" = FAIL ]; then state=XFAIL; else state=XPASS; fi
    fi
    printf '%-5s %5ds  %s%s\n' "$state" $((SECONDS - t0)) "$name" "${why:+  ($why)}" >> "$OUT/results"
}
skip() { printf 'SKIP      -  %s  (%s)\n' "$1" "$2" >> "$OUT/results"; }
export -f run1

# Boots an emulator, so not offline: the four session checks and the guest-package oracle check (a qemu-ios
# checkout); check-files-native and check-media-native are in no tier yet, run them by hand.
EMULATOR_CHECKS=" tests/check-helper-boot.py tests/check-sessions.py tests/check-files-native.py tests/check-media-native.py tests/check-guest-package.py "

# --- quick: host-only checks, in parallel
{
    echo "swift test --package-path Packages/FirmwareKit"
    echo tests/run-catalog-checks.py
    for c in tests/check-*.py; do
        [[ "$EMULATOR_CHECKS" == *" $c "* ]] || echo "$c"
    done
    for c in scripts/test-*.py; do
        [ "$c" = scripts/test-dependency-sources.py ] || echo "$c"
    done
} | xargs -P "$JOBS" -I{} bash -c '
    case "$1" in
        "swift test"*) run1 "$1" swift test --package-path Packages/FirmwareKit ;;
        *) run1 "$1" python3 "$1" ;;
    esac' _ {}
skip tests/check-files-native.py "boots an emulator; in no tier yet, run by hand"
skip tests/check-media-native.py "boots an emulator; in no tier yet, run by hand"

# --- full: the emulator-backed checks, one at a time; each prints its own PASS/FAIL lines
suite() {   # NAME CMD...
    local name=$1; shift
    echo "== $name"
    run1 "$name" "$@"
    grep -E '^ *(PASS|FAIL|SKIP)\b' "$OUT/${name//[\/ ]/_}.log" | sed 's/^ */     /'
}
if [ "$TIER" = --full ]; then
    ipad=(); [ -d "$LTM_IPAD_DEVICE" ] && ipad=(--ipad-device "$LTM_IPAD_DEVICE")
    if [ -f "$LTM_QEMU_DYLIB" ]; then
        # check-helper-boot's own iPad recipe is the direct-kernel bring-up (kboot.bin + nand/); a device that
        # boots through its iBoot (iBoot.bin, nor.bin) has no kboot.bin, so its iPad cases run only for a kboot
        # device and are otherwise skipped by the check itself (check-sessions boots the iBoot device below).
        if [ -f "$LTM_IPAD_DEVICE/kboot.bin" ]; then
            suite "tests/check-helper-boot.py" python3 tests/check-helper-boot.py "${ipad[@]}" --dylib "$LTM_QEMU_DYLIB"
        else
            suite "tests/check-helper-boot.py" python3 tests/check-helper-boot.py --dylib "$LTM_QEMU_DYLIB"
            skip "tests/check-helper-boot.py iPad cases" "$LTM_IPAD_DEVICE has no kboot.bin: the check's iPad recipe is the kboot bring-up, not the device's iBoot"
        fi
        if [ ${#ipad[@]} -gt 0 ]; then
            suite "tests/check-sessions.py --ipad-device" python3 tests/check-sessions.py "${ipad[@]}" --dylib "$LTM_QEMU_DYLIB"
        else
            skip "tests/check-sessions.py --ipad-device" "no iPad device at $LTM_IPAD_DEVICE (LTM_IPAD_DEVICE)"
        fi
        # The shipping image has no loader, so --guest upgrades its components from the checkout's own builds
        # (contrib/*/build.sh) and imports the photo with the host-side itphoto from there.
        tool=""; for t in it-agent/it_agent it-agent/it_typein.dylib it-gles/MBXGLEngine it-media/itphoto; do
            [ -e "$QEMU_IOS_DIR/contrib/$t" ] || { tool=$t; break; }
        done
        if [ -z "$LTM_IPOD_DEVICE" ]; then
            skip "tests/check-sessions.py --guest" "LTM_IPOD_DEVICE unset: a fresh device.py 7E18 iPod"
        elif [ ! -f "$LTM_ITPACK" ]; then
            skip "tests/check-sessions.py --guest" "no armv6 package at $LTM_ITPACK (LTM_ITPACK)"
        elif [ -n "$tool" ]; then
            skip "tests/check-sessions.py --guest" "no $QEMU_IOS_DIR/contrib/$tool: build it with its build.sh"
        else
            suite "tests/check-sessions.py --guest" python3 tests/check-sessions.py --guest --ipod-device "$LTM_IPOD_DEVICE" \
                --itpack "$LTM_ITPACK" --contrib "$QEMU_IOS_DIR/contrib" --dylib "$LTM_QEMU_DYLIB"
        fi
    else
        for c in "tests/check-helper-boot.py" "tests/check-sessions.py --ipad-device" "tests/check-sessions.py --guest"; do
            skip "$c" "no emulator dylib at $LTM_QEMU_DYLIB (LTM_QEMU_DYLIB)"
        done
    fi
    if [ -f "$QEMU_IOS_DIR/contrib/guest-package/mkpkg.py" ]; then
        suite "tests/check-guest-package.py" python3 tests/check-guest-package.py --qemu-ios "$QEMU_IOS_DIR"
    else
        skip "tests/check-guest-package.py" "no mkpkg.py under $QEMU_IOS_DIR (QEMU_IOS_DIR)"
    fi
    suite "scripts/regress-app.sh" scripts/regress-app.sh
fi

echo "== $TIER"
sort -k3 "$OUT/results"
printf '%d passed, %d failed, %d skipped, %d known failing, %d passing again; logs in %s\n' \
    "$(grep -c '^PASS' "$OUT/results")" "$(grep -c '^FAIL' "$OUT/results")" "$(grep -c '^SKIP' "$OUT/results")" \
    "$(grep -c '^XFAIL' "$OUT/results")" "$(grep -c '^XPASS' "$OUT/results")" "$OUT"
! grep -q '^FAIL' "$OUT/results"
