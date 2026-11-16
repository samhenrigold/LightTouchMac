#!/bin/bash
# Native recipes must cache even absolute compiler paths, and allow a deliberate opt-out. Compile real objects in
# a private cache rather than resetting the developer's shared cache statistics.
set -euo pipefail
SRC="$(cd "$(dirname "$0")/../.." && pwd)"
T="$(mktemp -d "${TMPDIR:-/tmp}/compiler-cache-test.XXXXXX")"
trap 'rm -rf "$T"' EXIT
if ! command -v ccache >/dev/null; then echo 'SKIP ccache not installed (brew install ccache)'; exit 0; fi
export CCACHE_DIR="$T/cache"
export LTM_CCACHE=1
source "$SRC/build-support/recipes/compiler-cache.sh"
[[ "$COMPILER_CACHE" = 'ccache ' && "$COMPILER_CACHE_MESON" = "'ccache', " ]] || exit 1
printf 'int cached_value = 42;\nconst char *cached_source = __FILE__;\n' > "$T/input.c"
CC="${COMPILER_CACHE}$(xcrun -f clang)"
$CC "-fmacro-prefix-map=$T/=" -c "$T/input.c" -o "$T/first.o"
$CC "-fmacro-prefix-map=$T/=" -c "$T/input.c" -o "$T/second.o"
hits="$(ccache --print-stats | awk '$1 == "direct_cache_hit" || $1 == "preprocessed_cache_hit" { n += $2 } END { print n+0 }')"
[[ "$hits" -gt 0 ]] || { echo 'FAIL absolute compiler did not use ccache'; exit 1; }
cmp "$T/first.o" "$T/second.o"
LTM_CCACHE=0
source "$SRC/build-support/recipes/compiler-cache.sh"
[[ -z "$COMPILER_CACHE" && -z "$COMPILER_CACHE_MESON" ]] || exit 1
"$(xcrun -f clang)" "-fmacro-prefix-map=$T/=" -c "$T/input.c" -o "$T/direct.o"
cmp "$T/first.o" "$T/direct.o"
echo 'ok   absolute compiler gets a real cache hit; opt-out and macro prefix maps preserve identical objects'
