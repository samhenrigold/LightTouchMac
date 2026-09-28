#!/bin/sh
set -eu
cd "$(dirname "$0")"
mkdir -p build
"${CC:-cc}" -std=c11 -O1 -g -Wall -Wextra -Werror -fsanitize=address,undefined test.c -o build/test-activation
ASAN_OPTIONS=abort_on_error=1 UBSAN_OPTIONS=halt_on_error=1:abort_on_error=1 build/test-activation
