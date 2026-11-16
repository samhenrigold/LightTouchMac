#!/bin/bash
# Build ANGLE's libEGL and libGLESv2 (Metal only, static, macOS 14.4) at the commit build-support/dependencies.json
# pins (the "angle" group: ANGLE's commit as its version, depot_tools' as "depot_tools"), one slice per LTM_ARCH
# (default "arm64 x86_64"), into OUT-DIR: the universal dylibs, ANGLE's include/ (the headers qemu-ios's experimental
# ANGLE renderer builds against), licenses/ (ANGLE's and what it links in: Abseil, zlib) and SOURCE.txt.
# CHECKOUT is gclient's tree, fetched on first use (about 9 GB) and reused while the pin stays.
#
#     build-angle.sh CHECKOUT OUT-DIR
set -euo pipefail
unset CPATH C_INCLUDE_PATH CPLUS_INCLUDE_PATH LIBRARY_PATH CCC_OVERRIDE_OPTIONS
export SDKROOT="$(xcrun --sdk macosx --show-sdk-path)"
CHECKOUT="${1:?usage: build-angle.sh checkout out-dir}"
OUT="${2:?usage: build-angle.sh checkout out-dir}"
HERE="$(cd "$(dirname "$0")/../.." && pwd)"
DEPS="$HERE/build-support/dependencies.json"
NINJA="${NINJA:-$(command -v ninja)}"   # resolved before depot_tools' wrapper shadows it on PATH
[ -x "$NINJA" ] || { echo "missing build tool: ninja" >&2; exit 1; }
i=0
while name="$(plutil -extract "packages.$i.name" raw -o - "$DEPS" 2>/dev/null)" && [ "$name" != ANGLE ]; do i=$((i + 1)); done
[ "$name" = ANGLE ] || { echo "no ANGLE package in $DEPS" >&2; exit 1; }
angle() { plutil -extract "packages.$i.$1" raw -o - "$DEPS"; }
COMMIT="$(angle version)" TOOLS="$(angle depot_tools)" LICENSE="$(angle license)" URL="$(angle repository)"
fetch() {   # DIR URL COMMIT
    git init -q "$1"
    git -C "$1" fetch -q --depth 1 "$2" "$3"
    git -C "$1" checkout -q --detach FETCH_HEAD
}
mkdir -p "$CHECKOUT"
CHECKOUT="$(cd "$CHECKOUT" && pwd)"
if [ "$(git -C "$CHECKOUT/angle" rev-parse HEAD 2>/dev/null)" != "$COMMIT" ] || [ ! -f "$CHECKOUT/.synced" ]; then
    rm -rf "$CHECKOUT/angle" "$CHECKOUT/depot_tools" "$CHECKOUT/.synced"
    fetch "$CHECKOUT/angle" "$URL" "$COMMIT"
    fetch "$CHECKOUT/depot_tools" https://chromium.googlesource.com/chromium/tools/depot_tools.git "$TOOLS"
    cat > "$CHECKOUT/.gclient" <<EOF
solutions=[{"name":"angle","url":"$URL","managed":False,"custom_deps":{},"custom_vars":{"checkout_angle_cl_deps":False,"checkout_angle_dawn_deps":False,"checkout_angle_internal":False,"checkout_angle_restricted_traces":False,"checkout_angle_mesa":False,"download_remoteexec_cfg":False}}]
EOF
    (cd "$CHECKOUT" && PATH="$CHECKOUT/depot_tools:$PATH" DEPOT_TOOLS_UPDATE=0 gclient sync --shallow --no-history -j6)
    touch "$CHECKOUT/.synced"
fi
A="$CHECKOUT/angle"
# build-support/patches/angle-metal-strong.patch: Metal linked strongly (applied once to the checkout, which keeps it).
PATCH="$HERE/build-support/patches/angle-metal-strong.patch"
git -C "$A" apply --reverse --check "$PATCH" 2>/dev/null || git -C "$A" apply "$PATCH"
ARGS='is_debug=false is_component_build=false angle_enable_metal=true angle_enable_gl=false angle_enable_vulkan=false'
ARGS="$ARGS angle_enable_null=false angle_build_tests=false angle_build_all=false angle_has_frame_capture=false"
ARGS="$ARGS angle_enable_perfetto=false angle_has_astc_encoder=false use_remoteexec=false use_siso=false"
ARGS="$ARGS clang_use_chrome_plugins=false use_custom_libcxx=false use_lld=false mac_deployment_target=\"14.4\""
# GN supports an explicit compiler launcher, including its bundled absolute Clang toolchain.
if [[ ${LTM_CCACHE:-1} != 0 ]] && command -v ccache >/dev/null; then
    ARGS="$ARGS cc_wrapper=\"ccache\""
    export CCACHE_BASEDIR=""
fi
rm -rf "$OUT"
mkdir -p "$OUT/licenses"
SLICES=()
for arch in ${LTM_ARCH:-arm64 x86_64}; do
    case "$arch" in arm64) cpu=arm64 ;; x86_64) cpu=x64 ;; *) echo "unsupported LTM_ARCH: $arch" >&2; exit 1 ;; esac
    (cd "$A" && buildtools/mac/gn gen "out/ltm-$arch" --args="$ARGS target_cpu=\"$cpu\"" > /dev/null)
    "$NINJA" -C "$A/out/ltm-$arch" -j"${LTM_JOBS:-8}" libEGL libGLESv2 > "$OUT/ninja-$arch.log"
    SLICES+=("$A/out/ltm-$arch")
done
for lib in libEGL libGLESv2; do
    lipo -create "${SLICES[@]/%//$lib.dylib}" -output "$OUT/$lib.dylib"
    install_name_tool -id "@rpath/$lib.dylib" "$OUT/$lib.dylib"
    "$HERE/scripts/ltm-build" check-macho --no-weak-imports --minos 14.4 "$OUT/$lib.dylib"
done
cp -R "$A/include" "$OUT/include"
cp "$A/LICENSE" "$OUT/licenses/LICENSE"
cp "$A/third_party/abseil-cpp/LICENSE" "$OUT/licenses/LICENSE.abseil-cpp"
cp "$A/third_party/zlib/LICENSE" "$OUT/licenses/LICENSE.zlib"
cp "$PATCH" "$OUT/licenses/"
printf '%s\n' "ANGLE $COMMIT: $URL (depot_tools $TOOLS; the rest from its DEPS)" \
    "License: $LICENSE (LICENSE); libGLESv2 links in Abseil (Apache-2.0, LICENSE.abseil-cpp) and zlib (Zlib, LICENSE.zlib)." \
    "Modified: $(basename "$PATCH") (alongside) applied to that source." \
    "Built by build-support/recipes/build-angle.sh: gn args $ARGS, for ${LTM_ARCH:-arm64 x86_64}." \
    "The emulator opens libEGL and libGLESv2 for its experimental ANGLE renderer (Settings ▸ General)." > "$OUT/licenses/SOURCE.txt"
