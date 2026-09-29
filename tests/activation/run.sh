#!/bin/sh
set -eu
cd "$(dirname "$0")/../.."
work=$(mktemp -d "${TMPDIR:-/tmp}/lt-activation.XXXXXX")
trap 'rm -rf "$work"' EXIT
cc -O1 -g -Wall -Wextra -Werror -fsanitize=address,undefined tests/activation/finish.c \
    $(pkg-config --cflags --libs libimobiledevice-1.0 libplist-2.0) -o "$work/finish"
ASAN_OPTIONS=abort_on_error=1 UBSAN_OPTIONS=halt_on_error=1 "$work/finish"
sh tools/activation/test.sh
swift test --package-path Packages/FirmwareKit --filter ActivationTests
python3 tests/sessions/check-activation-gate.py --offline
