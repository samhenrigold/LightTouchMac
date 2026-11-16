# Sourced by the native recipes after PATH is set. Absolute compilers need an explicit launcher: the masquerade
# directory alone cannot intercept /usr/bin/clang. LTM_CCACHE=0 disables caching without changing compiler flags.
COMPILER_CACHE=""
COMPILER_CACHE_MESON=""
if [[ ${LTM_CCACHE:-1} != 0 ]] && command -v ccache >/dev/null; then
    COMPILER_CACHE="ccache "
    COMPILER_CACHE_MESON="'ccache', "
    # Relative input rewriting can defeat the product's -fmacro-prefix-map and change __FILE__ literals.
    export CCACHE_BASEDIR=""
fi
