#!/bin/bash
set -eu
export GUEST_ARCH=armv6 ARMV6_SDK=${LTM_BASH_SDK:?} LEGACY_LINK=0
. "${LTM_QEMU_SOURCE_DIR:?}/contrib/armv6-toolchain/armv6.sh"
set +u
out=a.out; outgiven=0; mode=link; src=(); flags=(-isystem "$(xcrun clang -print-resource-dir)/include"); link=()
while [ "$#" -gt 0 ]; do
 case "$1" in
 -o) out="$2"; outgiven=1; shift 2;;
 -c) mode=compile; shift;;
 -E) mode=preprocess; flags+=("$1");shift;;
 *.c) src+=("$1");shift;;
 *.o|*.a|-l*|-L*) link+=("$1");shift;;
 -Wl,*) IFS=, read -r -a parts <<< "$1";link+=("${parts[@]:1}");shift;;
 --version|-v|-V|-qversion) exec xcrun clang "$@";;
 *) flags+=("$1");shift;;
 esac
done
if [ "$mode" = preprocess ]; then
 output=();[ "$outgiven" = 0 ] || output=(-o "$out")
 exec xcrun clang -target armv6-apple-ios5.0 -nostdinc -isystem "$ARMV6_SDK/usr/include" "${flags[@]}" "${src[@]}" "${output[@]}"
fi
if [ "$mode" = compile ]; then
 [ "$out" != a.out ] || out="$(basename "${src[0]}" .c).o"
 cc6 "${src[0]}" "$out" "${flags[@]}" -D_FORTIFY_SOURCE=0
else
 objects=()
 for source in "${src[@]}"; do
  object="${out}.$(basename "$source").o";cc6 "$source" "$object" "${flags[@]}" -D_FORTIFY_SOURCE=0;objects+=("$object")
 done
 LEGACY_LINK=0 link6 -execute "$out" -no_pie -alias start _ltm_sdk_start -e _ltm_sdk_start "${LTM_BASH_WORK:?}/link-sdk/crt1.o" "${objects[@]}" "${link[@]}" "${LTM_BASH_WORK:?}/link-sdk/libgcc_s.1.dylib"
fi
