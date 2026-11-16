#!/bin/bash
# CLI regression: a bad Git revision must refuse the gate, never describe an empty change and pass.
# Build sessions first, then pass that executable: tests/sessions/affected-test.sh tests/sessions/.build/debug/sessions
set -euo pipefail
binary="${1:?pass the built sessions executable}"
scratch="${LTM_SCRATCH_ROOT:-$HOME/Developer/ltm-scratch.noindex}"
mkdir -p "$scratch"
work="$(mktemp -d "$scratch/affected-test.XXXXXX")"
trap 'rm -rf "$work"' EXIT
status=0
"$binary" affected "refs/heads/missing-$(uuidgen)" --run > "$work/result" 2>&1 || status=$?
if [[ "$status" != 2 ]] || ! grep -q '^FAIL sessions: git diff refused' "$work/result"; then
    echo "FAIL: invalid revision exited $status instead of refusing the gate"
    cat "$work/result"
    exit 1
fi
echo 'PASS: affected refuses an invalid Git revision before running any checks'
