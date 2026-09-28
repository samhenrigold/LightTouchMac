#!/bin/sh
set -eu
cd "$(dirname "$0")"
mkdir -p build
case "${1:-}" in
  '') set -- ;;
  --universal)
    [ "$(uname -s)" = Darwin ] || { echo 'Universal builds require macOS.' >&2; exit 2; }
    set -- -arch arm64 -arch x86_64 ;;
  *) echo 'Usage: build.sh [--universal]' >&2; exit 2 ;;
esac
"${CC:-cc}" -std=c11 -O2 -Wall -Wextra -Werror "$@" activation.c -o build/lt-activation
