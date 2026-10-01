#!/bin/bash
# Build the minimal GNU shell from source, retaining complete source inputs.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
DEST="${1:?usage: build-shell.sh NEW-OUTPUT-DIRECTORY}"
[ ! -e "$DEST" ] || { echo 'destination exists' >&2; exit 1; }
export LTM_QEMU_SOURCE_DIR="${LTM_QEMU_SOURCE_DIR:-$HOME/Developer/qemu-ios-ipad1}"
export LTM_BASH_SDK="${LTM_BASH_SDK:-$HOME/Developer/ipod2g-re/OldSDK/iPhoneOS3.1.3.sdk}"
export LTM_BASH_WORK="$(mktemp -d "${TMPDIR:-/tmp}/ltm-bash-source.XXXXXX")"
trap 'rm -rf "$LTM_BASH_WORK"' EXIT
mkdir -p "$LTM_BASH_WORK/sources" "$LTM_BASH_WORK/build" "$LTM_BASH_WORK/link-sdk"
SOURCE="$LTM_BASH_WORK/sources"
curl -fLsS https://ftp.gnu.org/gnu/bash/bash-4.0.tar.gz -o "$SOURCE/bash-4.0.tar.gz"
for n in $(seq 1 40); do
    patch="bash40-$(printf '%03d' "$n")"
    curl -fLsS "https://ftp.gnu.org/gnu/bash/bash-4.0-patches/$patch" -o "$SOURCE/$patch"
done
(cd "$SOURCE"; shasum -a256 -c "$HERE/bash-source.sha256")
tar -xzf "$SOURCE/bash-4.0.tar.gz" -C "$LTM_BASH_WORK"
for patch in "$SOURCE"/bash40-*; do patch -d "$LTM_BASH_WORK/bash-4.0" -p0 < "$patch"; done
# Build-host recognition only; GNU's 2009 config.sub predates Apple Silicon.
sed -i '' 's/| arm-\*  | armbe-\*/| arm64-* | arm-*  | armbe-*/' "$LTM_BASH_WORK/bash-4.0/support/config.sub"
# Official patch39 changes configure.in. Regenerate explicitly, not mid-build.
(cd "$LTM_BASH_WORK/bash-4.0"; autoconf)
# ld no longer accepts this historical SDK dylib's missing platform tag.
# Only a private link input changes; the guest still loads its stock libgcc.
xcrun vtool -set-build-version ios 3.1 3.1 -replace -output "$LTM_BASH_WORK/link-sdk/libgcc_s.1.dylib" "$LTM_BASH_SDK/usr/lib/libgcc_s.1.dylib"
# Use the SDK's stock startup object, not QEMU's custom GPLv2 startup C code.
xcrun lipo "$LTM_BASH_SDK/usr/lib/crt1.3.1.o" -thin armv6 -output "$LTM_BASH_WORK/link-sdk/crt1.o"
python3 "$LTM_QEMU_SOURCE_DIR/contrib/armv6-toolchain/subtype.py" "$LTM_BASH_WORK/link-sdk/crt1.o" 9
(cd "$LTM_BASH_WORK/build"
 CC="$HERE/shell-cc.sh" CFLAGS='-O1 -Wno-error=implicit-function-declaration' \
 "$LTM_BASH_WORK/bash-4.0/configure" --host=arm-apple-darwin --build=arm64-apple-darwin \
 --disable-readline --disable-history --disable-nls --disable-largefile --without-bash-malloc --prefix=/usr \
 bash_cv_dev_fd=absent bash_cv_sys_named_pipes=present bash_cv_job_control_missing=present \
 bash_cv_func_sigsetjmp=present bash_cv_func_ctype_nonascii=no bash_cv_must_reinstall_sighandlers=no \
 bash_cv_func_strcoll_broken=yes ac_cv_c_stack_direction=-1 ac_cv_func_mmap_fixed_mapped=yes \
 gt_cv_int_divbyzero_sigfpe=no ac_cv_func_setvbuf_reversed=no ac_cv_func_strcoll_works=yes \
 ac_cv_func_working_mktime=yes ac_cv_type_getgroups=gid_t bash_cv_dup2_broken=no ac_cv_prog_cc_g=no
 # Freeze the version before recursive parallel make: Bash's sub-makes
 # otherwise race to regenerate version.h and increment the build counter.
 printf '2\n' > .build
 /bin/sh "$LTM_BASH_WORK/bash-4.0/support/mkversion.sh" -S "$LTM_BASH_WORK/bash-4.0" -s release -d 4.0 -o version.h
 make -o version.h -j4 CC_FOR_BUILD=/usr/bin/cc CFLAGS_FOR_BUILD=-O1 LDFLAGS_FOR_BUILD= \
 CFLAGS='-O1 -std=gnu89 -Wno-error=implicit-function-declaration'
 ldid -S bash
)
mkdir -p "$DEST/Sources" "$DEST/Licenses"
cp "$LTM_BASH_WORK/build/bash" "$DEST/bash"
cp "$SOURCE"/* "$DEST/Sources/"
cp "$HERE/bash-source.sha256" "$HERE/build-shell.sh" "$HERE/shell-cc.sh" "$DEST/Sources/"
# Retain the QEMU build adapters used by the recipe and their copyright notice.
mkdir -p "$DEST/Sources/armv6-toolchain"
for adapter in armv6.sh legacy.h crt1old.c subtype.py mkold.py README.md; do
    cp "$LTM_QEMU_SOURCE_DIR/contrib/armv6-toolchain/$adapter" "$DEST/Sources/armv6-toolchain/"
done
# Normalize a development-only default in the retained upstream build adapter.
# shell-cc always supplies ARMV6_SDK explicitly; this does not change built bytes.
sed -i '' 's|/[^" ]*/OldSDK/iPhoneOS3.1.3.sdk|$HOME/Developer/ipod2g-re/OldSDK/iPhoneOS3.1.3.sdk|' "$DEST/Sources/armv6-toolchain/armv6.sh"
cp "$LTM_QEMU_SOURCE_DIR/COPYING" "$DEST/Licenses/QEMU-COPYING"
cp "$HERE/licenses/Bash-GPL-3.txt" "$DEST/Licenses/"
xcrun clang --version | sed '/^InstalledDir:/d' > "$DEST/Sources/toolchain.txt"
autoconf --version >> "$DEST/Sources/toolchain.txt"
shasum -a256 "$LTM_BASH_SDK/usr/lib/libSystem.B.dylib" "$LTM_BASH_SDK/usr/lib/libgcc_s.1.dylib" | awk '{ n = split($2, p, "/"); print $1 " " p[n] }' >> "$DEST/Sources/toolchain.txt"
otool -L "$DEST/bash"
shasum -a256 "$DEST/bash"
