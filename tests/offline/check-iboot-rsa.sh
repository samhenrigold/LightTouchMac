#!/bin/bash
# Run after scripts/build-iboot32patcher.sh; uses synthetic instructions only.
set -euo pipefail
PATCHER="${1:?usage: check-iboot-rsa.sh extracted-patched-source-dir}"
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
OUT="$(mktemp -d "${TMPDIR:-/tmp}/iboot-rsa.XXXXXX")"
trap 'rm -rf "$OUT"' EXIT
clang -g -fsanitize=address -Wno-multichar -Wno-int-conversion -I"$PATCHER" \
    "$ROOT/tests/offline/fixtures/iboot-rsa-result.c" "$PATCHER/src/functions.c" -o "$OUT/test"
"$OUT/test"
