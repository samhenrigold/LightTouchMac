#!/bin/bash
# The one gate for the app: a thin wrapper over tests/run.py (which owns the tiers, the inputs and the XFAIL list).
#
#   scripts/gate.sh --quick   host only: swift test (Packages/FirmwareKit), tests/run.py offline, tests/run.py release
#                             (without the network check)
#   scripts/gate.sh --full    quick, then tests/run.py sessions (helper + emulator, one at a time, -audio driver=none)
#
# JOBS (default 4) is the offline/release parallelism; OUT (default mktemp) collects every log. The sessions tier's
# inputs (QEMU_IOS_DIR, LTM_QEMU_DYLIB, LTM_IPAD_DEVICE, LTM_IPOD_DEVICE, LTM_ITPACK) are documented in tests/run.py.
# Exit 1 if any tier reports a FAIL.
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TIER="${1:---quick}"
case "$TIER" in --quick|--full) ;; *) sed -n '2,10p' "$0"; exit 2 ;; esac
export OUT="${OUT:-$(mktemp -d /tmp/gate.XXXXXX)}"
export JOBS="${JOBS:-4}"
export QEMU_IOS_DIR="${QEMU_IOS_DIR:-$(python3 "$ROOT/scripts/sources.py" qemu-ios)}"
export FIRMWAREKIT_QEMU_IOS="${FIRMWAREKIT_QEMU_IOS:-$QEMU_IOS_DIR}"
cd "$ROOT" && mkdir -p "$OUT" || exit 2
status=0

echo "== swift test --package-path Packages/FirmwareKit"
t0=$SECONDS
if swift test --package-path Packages/FirmwareKit > "$OUT/swift-test.log" 2>&1; then
    printf 'PASS  %5ds  swift test (Packages/FirmwareKit)\n' $((SECONDS - t0))
else
    printf 'FAIL  %5ds  swift test (Packages/FirmwareKit)  (log: %s)\n' $((SECONDS - t0)) "$OUT/swift-test.log"; status=1
fi
for tier in offline release; do
    echo "== tests/run.py $tier"
    python3 tests/run.py "$tier" -j "$JOBS" --out "$OUT/$tier" || status=1
done
if [ "$TIER" = --full ]; then
    echo "== tests/run.py sessions"
    python3 tests/run.py sessions --out "$OUT/sessions" || status=1
fi
echo "== $TIER: $([ $status = 0 ] && echo green || echo FAIL); logs in $OUT"
exit $status
