#!/bin/bash
# Build the macOS 14 closure in a disposable directory; never rewrite Homebrew.
# Requires Xcode, meson, ninja, pkg-config and autotools.
# Usage: build-package-native.sh NEW-WORK-DIRECTORY
# Builds static dependencies from pinned sources unless LTM_STATIC_DEPS is explicit.
# LTM_ARCH=x86_64 cross-compiles the Intel slice (default arm64, built exactly as before);
# scripts/vendor builds both and merges them (scripts/ltm-build merge-native), and passes the pinned checkouts:
# QEMU_IOS_DIR (a tree at the qemu-ios pin), USBMUXD_SOURCE_DIR and USBMUXD_COMMIT (build-support/sources.json).
set -euo pipefail
ROOT="${1:?usage: build-package-native.sh new-work-directory}"
[ ! -e "$ROOT" ] || { echo "use a new build directory: $ROOT" >&2; exit 1; }
SRC="$(cd "$(dirname "$0")/../.." && pwd)"
QEMU="${QEMU_IOS_DIR:?set by scripts/vendor}"
USB="${USBMUXD_SOURCE_DIR:?set by scripts/vendor}"
TOOL="$SRC/scripts/ltm-build"
MESON="${MESON:-meson}"
JOBS="${LTM_JOBS:-$(sysctl -n hw.ncpu)}"
[[ "$JOBS" =~ ^[1-9][0-9]*$ ]] || { echo 'LTM_JOBS must be a positive integer' >&2; exit 1; }
[[ "$(uname -s)" == Darwin && "$(uname -m)" == arm64 ]] || { echo 'requires an Apple Silicon Mac' >&2; exit 1; }
ARCH="${LTM_ARCH:-arm64}"
case "$ARCH" in
    arm64) ARCH_FLAG='' HOST=() MESON_CROSS=() QEMU_CROSS=() FFMPEG_CROSS=() ;;
    x86_64) ARCH_FLAG='-arch x86_64 ' HOST=(--host=x86_64-apple-darwin) MESON_CROSS=()
        QEMU_CROSS=(--cross-prefix= --cpu=x86_64 --cc='clang -arch x86_64' --cxx='clang++ -arch x86_64' --objcc='clang -arch x86_64')
        FFMPEG_CROSS=(--enable-cross-compile --arch=x86_64 --target-os=darwin) ;;
    *) echo "unsupported LTM_ARCH: $ARCH" >&2; exit 1 ;;
esac
for tool in curl make ninja pkg-config glibtoolize autoreconf "$MESON"; do
    command -v "$tool" >/dev/null || { echo "missing build tool: $tool" >&2; exit 1; }
done
[ -f "$QEMU/configure" ] || { echo "missing QEMU source: $QEMU" >&2; exit 1; }
[ -f "$USB/configure.ac" ] || { echo "missing usbmuxd fork source: $USB" >&2; exit 1; }
QEMU="$(cd "$QEMU" && pwd)"
USB="$(cd "$USB" && pwd)"
mkdir -p "$ROOT/src" "$ROOT/build" "$ROOT/prefix"
ROOT="$(cd "$ROOT" && pwd)"
# usbmuxd from its pinned commit (build-support/sources.json) through a temporary worktree,
# never the checkout's working tree (10-06: a one-step build shipped the checkout's
# 41631a7 while the pin was e19fac2, and only recorded it).
USB_COMMIT="${USBMUXD_COMMIT:?set by scripts/vendor}"
USB_TREE="$ROOT/usbmuxd-worktree"
git -C "$USB" worktree add --detach "$USB_TREE" "$USB_COMMIT"
"$TOOL" sources stage-git --source "$USB_TREE" \
    --destination "$ROOT/build/usbmuxd" --record "$ROOT/usbmuxd-source.json"
# Autotools requires a source version even though the staged tree omits .git.
git -C "$USB_TREE" describe --tags --always --dirty > "$ROOT/build/usbmuxd/.tarball-version"
git -C "$USB" worktree remove --force "$USB_TREE"
STAGED="$(plutil -extract commit raw -o - "$ROOT/usbmuxd-source.json")"
[ "$STAGED" = "$USB_COMMIT" ] || { echo "usbmuxd staged at $STAGED, pinned $USB_COMMIT" >&2; exit 1; }
if [ -n "${LTM_STATIC_DEPS:-}" ]; then
    STATIC="$(cd "$LTM_STATIC_DEPS" && pwd)"
else
    LTM_ARCH="$ARCH" bash "$SRC/build-support/recipes/build-static-deps.sh" "$ROOT/static"
    STATIC="$ROOT/static/prefix"
fi
P="$ROOT/prefix"
export MACOSX_DEPLOYMENT_TARGET=14.0
export CFLAGS="$ARCH_FLAG-O2 -mmacosx-version-min=14.0" CXXFLAGS="$ARCH_FLAG-O2 -mmacosx-version-min=14.0"
export LDFLAGS="$ARCH_FLAG-mmacosx-version-min=14.0" CC=/usr/bin/clang CXX=/usr/bin/clang++
export PKG_CONFIG_LIBDIR="$P/lib/pkgconfig" PKG_CONFIG_PATH=
# Some Darwin libtool configure probes return an empty ARG_MAX. Avoid its
# broken partial-link fallback (which loses private symbols).
export lt_cv_sys_max_cmd_len=131072
unset CPATH C_INCLUDE_PATH CPLUS_INCLUDE_PATH LIBRARY_PATH
[ -f "$STATIC/lib/libcrypto.a" ] || { echo "missing static prefix: $STATIC" >&2; exit 1; }
fetch_group() {   # GROUP: its pinned archives into src/, from the caches when they have them
    local args=(sources fetch --group "$1" --destination "$ROOT/src")
    if [ -n "${LTM_SOURCE_CACHE:-}" ]; then args+=(--cache "$LTM_SOURCE_CACHE"); fi
    if [ -d "$ROOT/static/src" ]; then args+=(--cache "$ROOT/static/src"); fi
    if [ "${LTM_OFFLINE:-0}" = 1 ]; then args+=(--offline); fi
    "$TOOL" "${args[@]}"
}
# What a library compiles in about its own prefix (glib's GIO module and locale dirs, FFmpeg's configure
# line) must not name this build's path: glib and FFmpeg are configured for NEUTRAL, which cannot hold
# anything (/var/empty is root-owned and empty), installed under stage/, then moved into $P.
NEUTRAL=/var/empty
restage() {   # stage/$NEUTRAL into $P, its pkg-config files pointed at $P
    local pc
    for pc in "$ROOT/stage$NEUTRAL"/lib/pkgconfig/*.pc; do sed -i '' "s|$NEUTRAL|$P|g" "$pc"; done
    cp -R "$ROOT/stage$NEUTRAL/." "$P/"
    rm -rf "$ROOT/stage"
}
# LICENSE-NAME DIR FILES...: license texts into $P/share/licenses/NAME, with a SOURCE.txt naming the pinned archive
license() {
    local name="$1" dir="$2"; shift 2
    mkdir -p "$P/share/licenses/$name"
    (cd "$dir" && cp "$@" "$P/share/licenses/$name/")
}
source_note() {   # MANIFEST-NAME LICENSE-NAME [PATCH...]
    local package="$1" name="$2"; shift 2
    "$TOOL" sources note "$package" "$@" > "$P/share/licenses/$name/SOURCE.txt"
}
fetch_group native
cd "$ROOT/build"
for archive in glib-2.88.3.tar.xz pcre2-10.48.tar.bz2 pixman-0.46.4.tar.gz libslirp-v4.9.4.tar.gz libusb-1.0.30.tar.bz2 libplist-2.8.0.tar.bz2 libimobiledevice-1.4.0.tar.bz2 ffmpeg-9.0.1.tar.xz; do
    tar -xf "$ROOT/src/$archive"
done
tar -xf "$ROOT/src/proxy-libintl-0.5.tar.gz" -C glib-2.88.3/subprojects
# Keep SDK feature detection tied to the deployment target. A headerless
# pipe2 probe incorrectly accepts the macOS 27 symbol for a macOS 14 build.
(cd glib-2.88.3 && patch -p1 < "$SRC/build-support/patches/glib-pipe2-availability.patch")
(cd pcre2-10.48 && ./configure --prefix="$P" ${HOST[@]+"${HOST[@]}"} --disable-shared --enable-static --disable-pcre2grep-libz --disable-pcre2grep-libbz2 && make -j"$JOBS" && make install)
SDK="$(xcrun --sdk macosx --show-sdk-path)"
cat > "$P/lib/pkgconfig/libffi.pc" <<EOF
Name: libffi
Description: macOS system libffi
Version: 3.4.0
Libs: -lffi
Cflags: -I$SDK/usr/include/ffi
EOF
# Meson ignores -arch in CFLAGS when choosing the host machine, so declare it.
if [ "$ARCH" = x86_64 ]; then
MESON_CROSS=(--cross-file "$ROOT/x86_64-darwin.meson")
cat > "$ROOT/x86_64-darwin.meson" <<EOF
[binaries]
c = ['/usr/bin/clang', '-arch', 'x86_64']
cpp = ['/usr/bin/clang++', '-arch', 'x86_64']
objc = ['/usr/bin/clang', '-arch', 'x86_64']
pkg-config = '$(command -v pkg-config)'
[host_machine]
system = 'darwin'
subsystem = 'macos'
kernel = 'xnu'
cpu_family = 'x86_64'
cpu = 'x86_64'
endian = 'little'
EOF
fi
"$MESON" setup glib-out glib-2.88.3 ${MESON_CROSS[@]+"${MESON_CROSS[@]}"} --prefix="$NEUTRAL" --buildtype=release -Ddefault_library=static -Dnls=disabled -Dtests=false -Dintrospection=disabled -Dman-pages=disabled -Dlibmount=disabled -Dselinux=disabled -Dsysprof=disabled --wrap-mode=nodownload
ninja -C glib-out -j"$JOBS" && DESTDIR="$ROOT/stage" ninja -C glib-out install && restage
license glib glib-2.88.3 COPYING "$SRC/build-support/patches/glib-pipe2-availability.patch"
source_note glib glib glib-pipe2-availability.patch
license proxy-libintl glib-2.88.3/subprojects/proxy-libintl-0.5 COPYING
source_note proxy-libintl proxy-libintl
license pcre2 pcre2-10.48 LICENCE.md
license pixman pixman-0.46.4 COPYING
license libslirp libslirp-v4.9.4 COPYRIGHT LICENSE
"$MESON" setup pixman-out pixman-0.46.4 ${MESON_CROSS[@]+"${MESON_CROSS[@]}"} --prefix="$P" --buildtype=release -Ddefault_library=static -Dtests=disabled -Ddemos=disabled --wrap-mode=nofallback
ninja -C pixman-out -j"$JOBS" && ninja -C pixman-out install
# qemu-ios's libslirp patches, in its wrap's order (subprojects/slirp.wrap diff_files): slirp_set_restricted(), the
# in-place restrict flip behind netdev_set_restrict / qemu_ios_ui_net_restrict (5.x networking on after Setup), and
# slirp_add_guestfwd_connector(), behind guestfwd's fdpass: (a sandboxed helper's web proxy). Older qemu-ios pins
# lack one or both files; their qemu-ios builds take a found libslirp only with both functions.
SLIRP_PATCHES=()
for name in libslirp-set-restricted.patch libslirp-guestfwd-connector.patch; do
    patch_file="$QEMU/subprojects/packagefiles/$name"
    [ -f "$patch_file" ] || continue
    (cd libslirp-v4.9.4 && patch -p1 < "$patch_file")
    cp "$patch_file" "$P/share/licenses/libslirp/"
    SLIRP_PATCHES+=("$name")
done
source_note slirp libslirp ${SLIRP_PATCHES[@]+"${SLIRP_PATCHES[@]}"}
"$MESON" setup slirp-out libslirp-v4.9.4 ${MESON_CROSS[@]+"${MESON_CROSS[@]}"} --prefix="$P" --buildtype=release -Ddefault_library=static --wrap-mode=nofallback
ninja -C slirp-out -j"$JOBS" && ninja -C slirp-out install
# libusb: only the usbmuxd fork's configure.ac asks for it (PKG_CHECK_MODULES, no flag); its QEMU backend
# compiles no libusb code and the static archive contributes no symbol, so nothing of it ships.
(cd libusb-1.0.30 && ./configure --prefix="$P" ${HOST[@]+"${HOST[@]}"} --disable-shared --enable-static && make -j"$JOBS" && make install)
# Shared exports are required by IMobileDevice.swift's dlopen/dlsym API; the
# corresponding static archives intentionally hide these public symbols.
export PKG_CONFIG_LIBDIR="$P/lib/pkgconfig:$STATIC/lib/pkgconfig"
# A binary plist's object can be referenced from anywhere and libplist copies it per reference, so a device's
# 127-byte reply can stand for gigabytes; libplist-bin-limits.patch refuses a parse past 2^20 nodes or 32 MiB.
(cd libplist-2.8.0 && patch -p1 < "$SRC/build-support/patches/libplist-bin-limits.patch")
(cd libplist-2.8.0 && ./configure --prefix="$P" ${HOST[@]+"${HOST[@]}"} --enable-shared --disable-static --without-cython && make -j"$JOBS" && make install)
license libplist libplist-2.8.0 COPYING COPYING.LESSER "$SRC/build-support/patches/libplist-bin-limits.patch"
source_note libplist libplist libplist-bin-limits.patch
doubling() {   # LEVELS: a binary plist of LEVELS arrays, each two references to the next, down to one integer
    local levels="$1" i
    hex() { printf "\\x$(printf %02x "$1")"; }
    printf 'bplist00'
    for ((i = 0; i < levels; i++)); do printf '\xa2'; hex $((i + 1)); hex $((i + 1)); done
    printf '\x10\x00'
    for ((i = 0; i <= levels; i++)); do hex $((8 + 3 * i)); done
    printf '\0\0\0\0\0\0\x01\x01\0\0\0\0\0\0\0'; hex $((levels + 1))
    printf '\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0'; hex $((8 + 3 * levels + 2))
}
if [ "$ARCH" = arm64 ]; then   # the built library itself: 19 levels (2^20 - 1 nodes) parse, 20 are refused
    doubling 19 > "$ROOT/doubling-19.bplist" && doubling 20 > "$ROOT/doubling-20.bplist"
    "$P/bin/plistutil" -i "$ROOT/doubling-19.bplist" -o /dev/null -f xml
    if "$P/bin/plistutil" -i "$ROOT/doubling-20.bplist" -o /dev/null -f xml 2>/dev/null; then
        echo 'libplist parsed a binary plist of 2^21 - 1 nodes: libplist-bin-limits.patch is not in effect' >&2
        exit 1
    fi
fi
# iPhone OS 1.x lockdownd speaks SSLv3 only: offer exactly SSLv3 below ProductVersion 2.0 (smoke.md #51); no ECDHE
# suites below 10.0 (5.0 beta 1 lockdownd aborts a ClientHello that offers one; smoke.md "9A5220p USB lockdown").
(cd libimobiledevice-1.4.0 && patch -p1 < "$SRC/build-support/patches/libimobiledevice-sslv3-ios1.patch")
# The device names the length of each reply (a plist service's length prefix, an AFC packet, an ostrace message, a
# debugserver response) and the library allocates it: libimobiledevice-reply-limits.patch refuses more than 32 MiB.
(cd libimobiledevice-1.4.0 && patch -p1 < "$SRC/build-support/patches/libimobiledevice-reply-limits.patch")
(cd libimobiledevice-1.4.0 && LDFLAGS="$LDFLAGS -framework SystemConfiguration -framework CoreFoundation" ./configure --prefix="$P" ${HOST[@]+"${HOST[@]}"} --enable-shared --disable-static --without-cython && make -j"$JOBS" && make install)
license libimobiledevice libimobiledevice-1.4.0 COPYING COPYING.LESSER "$SRC/build-support/patches/libimobiledevice-sslv3-ios1.patch" "$SRC/build-support/patches/libimobiledevice-reply-limits.patch"
source_note libimobiledevice libimobiledevice libimobiledevice-sslv3-ios1.patch libimobiledevice-reply-limits.patch
if [ "$ARCH" = arm64 ]; then   # the built library itself: a 1 KiB plist reply arrives, a 40 MiB one is refused
    (cd libimobiledevice-1.4.0 && xcrun clang -O2 -I. -Isrc -Iinclude -I"$P/include" -I"$STATIC/include" \
        "$SRC/build-support/checks/reply-limit.c" -L"$P/lib" -limobiledevice-1.0 -lplist-2.0 -o "$ROOT/reply-limit")
    "$ROOT/reply-limit"
fi
(cd usbmuxd && glibtoolize --copy --force && autoreconf -fi)
(cd usbmuxd && LDFLAGS="$LDFLAGS -framework IOKit -framework CoreFoundation -framework Security" ./configure --prefix="$P" ${HOST[@]+"${HOST[@]}"} --without-systemd && make -j"$JOBS")
# iBoot32Patcher (GPL-3.0, the "tools" group of the manifest): firmwarekit runs it for the k48 real-iBoot
# recipe. Built into build/iBoot32Patcher with its LICENSE, our patch and a SOURCE.txt; scripts/vendor ships them.
fetch_group tools
LTM_ARCH="$ARCH" bash "$SRC/build-support/recipes/build-iboot32patcher.sh" "$ROOT/src" "$ROOT/build/iBoot32Patcher"
# AMC audio and incremental H.264 slices use libavcodec/libavutil. Keep the closure native
# to macOS 14, with no automatically discovered Homebrew codec dependencies.
(cd ffmpeg-9.0.1 && patch -p1 < "$QEMU/contrib/ffmpeg/h264-chunk-er.patch" && patch -p1 < "$QEMU/contrib/ffmpeg/h264-cavlc-pcm-offset.patch")
(cd ffmpeg-9.0.1 && ./configure --prefix="$NEUTRAL" ${FFMPEG_CROSS[@]+"${FFMPEG_CROSS[@]}"} \
    --disable-everything --disable-autodetect --disable-programs --disable-doc \
    --disable-avdevice --disable-avformat --disable-avfilter --disable-swscale --disable-swresample \
    --enable-decoder=aac,mp3,alac,h264 --enable-encoder=aac --enable-shared --disable-static --install-name-dir=@rpath \
    --extra-cflags="$ARCH_FLAG-mmacosx-version-min=14.0" \
    --extra-ldflags="$ARCH_FLAG-mmacosx-version-min=14.0 -Wl,-rpath,@loader_path" \
    && make -j"$JOBS" && make install DESTDIR="$ROOT/stage") && restage
mkdir -p "$P/share/licenses/ffmpeg"
cp ffmpeg-9.0.1/COPYING.LGPLv2.1 "$P/share/licenses/ffmpeg/"
printf '%s\n' 'FFmpeg 9.0.1: https://ffmpeg.org/releases/ffmpeg-9.0.1.tar.xz' \
    'SHA256: cf38e0e28c7e5605942c4a77755349b0145804a397af37eb1fb4c77cb237f635' \
    'Apply h264-chunk-er.patch and h264-cavlc-pcm-offset.patch; build options are in build-package-native.sh.' \
    > "$P/share/licenses/ffmpeg/SOURCE.txt"
cp "$SRC/build-support/recipes/build-package-native.sh" "$QEMU/contrib/ffmpeg/h264-chunk-er.patch" "$QEMU/contrib/ffmpeg/h264-cavlc-pcm-offset.patch" "$P/share/licenses/ffmpeg/"
# Retain the native UI, CGL renderer, CoreAudio and Wi-Fi/slirp; avoid accidental optional
# Homebrew dependencies. Board AES/SHA use the declared static libcrypto; QEMU's own cipher API, the static Nettle.
export PKG_CONFIG_LIBDIR="$P/lib/pkgconfig:$STATIC/lib/pkgconfig"
mkdir "$ROOT/qemu-build"
cd "$ROOT/qemu-build"
# LTM_ANGLE (build-support/recipes/build-angle.sh's output): the experimental ANGLE renderer is built against its headers, beside CGL.
"$QEMU/configure" ${QEMU_CROSS[@]+"${QEMU_CROSS[@]}"} --target-list=arm-softmmu --without-default-features --enable-cocoa --enable-coreaudio --enable-pixman --enable-slirp --enable-nettle --disable-pie \
    ${LTM_ANGLE:+"-Dltm_angle_prefix=$LTM_ANGLE"} \
    --python="${QEMU_PYTHON:-python3.12}" \
    --extra-cflags="-I$STATIC/include -mmacosx-version-min=14.0 -fmacro-prefix-map=$QEMU/= -fmacro-prefix-map=$ROOT/qemu-build/=" \
    --extra-ldflags="-L$STATIC/lib -lcrypto -mmacosx-version-min=14.0"
ninja -j"$JOBS" qemu-system-arm
# make-dylib-macos.sh compiles the entry files itself: CCC_OVERRIDE_OPTIONS gives its clang the same prefix maps.
CCC_OVERRIDE_OPTIONS="+-fmacro-prefix-map=$QEMU/= +-fmacro-prefix-map=$ROOT/qemu-build/=" \
    bash "$QEMU/contrib/macos-app/make-dylib-macos.sh" "$ROOT/qemu-build"
"$TOOL" check-macho --no-weak-imports --arch "$ARCH" "$ROOT/qemu-build/libqemu-arm.dylib" "$P/lib/libimobiledevice-1.0.dylib" "$P/lib/libplist-2.0.dylib" "$ROOT/build/usbmuxd/src/usbmuxd" "$ROOT/build/iBoot32Patcher/iBoot32Patcher"
# GLib's macOS API selection: the SDK's pipe2 (macOS 26) must not be picked for a macOS 14 build (a real Meson probe),
# the generated config and QEMU must not import it, and the built static GLib's pipe fallback must work.
GLIB_CHECK="$ROOT/glib-compat"
mkdir -p "$GLIB_CHECK/probe"
cat > "$GLIB_CHECK/probe/meson.build" <<'EOF'
project('glib-pipe-compatibility', 'c')
cc = meson.get_compiler('c')
# This declaration carries the SDK's macOS introduction version.
if cc.has_function('pipe2', prefix: '#include <unistd.h>')
  error('pipe2 must not be selected for the macOS 14 deployment target')
endif
assert(cc.has_function('pipe', prefix: '#include <unistd.h>'))
EOF
(unset LDFLAGS CXXFLAGS; CC=/usr/bin/clang CFLAGS='-O2 -mmacosx-version-min=14.0' LDFLAGS='-mmacosx-version-min=14.0' \
    "$MESON" setup "$GLIB_CHECK/probe-build" "$GLIB_CHECK/probe" --wrap-mode=nodownload > "$GLIB_CHECK/probe.log" 2>&1) \
    || { cat "$GLIB_CHECK/probe.log" >&2; echo "the Meson/SDK probe selects pipe2 for macOS 14" >&2; exit 1; }
! grep -Eq '^[[:space:]]*#[[:space:]]*define[[:space:]]+HAVE_PIPE2\b' "$ROOT/build/glib-out/config.h" \
    || { echo "build/glib-out/config.h defines HAVE_PIPE2 for the macOS 14 build" >&2; exit 1; }
no_pipe2() { ! xcrun nm -m "$1" | grep '(undefined)' | grep -Eq '\b_pipe2\b' || { echo "$1 imports pipe2, unavailable on macOS 14" >&2; exit 1; }; }
no_pipe2 "$ROOT/qemu-build/libqemu-arm.dylib"
cat > "$GLIB_CHECK/pipe-check.c" <<'EOF'
#include <glib-unix.h>
#include <fcntl.h>
#include <string.h>
#include <unistd.h>
int main(void)
{
    int fds[2];
    GError *error = NULL;
    if (!g_unix_open_pipe(fds, O_CLOEXEC | O_NONBLOCK, &error)) return 1;
    for (int i = 0; i < 2; ++i) {
        int fd_flags = fcntl(fds[i], F_GETFD), status = fcntl(fds[i], F_GETFL);
        if (fd_flags < 0 || !(fd_flags & FD_CLOEXEC) || status < 0 || !(status & O_NONBLOCK)) return 2;
    }
    const char expected[] = "GLib pipe compatibility";
    char actual[sizeof expected] = {0};
    if (write(fds[1], expected, sizeof expected) != sizeof expected || read(fds[0], actual, sizeof actual) != sizeof actual
        || memcmp(expected, actual, sizeof expected)) return 3;
    return close(fds[0]) || close(fds[1]) ? 4 : 0;
}
EOF
# shellcheck disable=SC2046
/usr/bin/clang -arch "$ARCH" -mmacosx-version-min=14.0 -Wl,-no_weak_imports "$GLIB_CHECK/pipe-check.c" -o "$GLIB_CHECK/pipe-check" \
    $(PKG_CONFIG_PATH= PKG_CONFIG_LIBDIR="$P/lib/pkgconfig:$P/share/pkgconfig" pkg-config --static --cflags --libs glib-2.0 \
      | sed "s|-lglib-2.0|$P/lib/libglib-2.0.a|")
no_pipe2 "$GLIB_CHECK/pipe-check"
"$GLIB_CHECK/pipe-check" || { echo "the built GLib's pipe fallback failed ($?)" >&2; exit 1; }
rm -rf "$GLIB_CHECK"
echo "GLib: no pipe2 for macOS 14 (Meson probe, config.h, QEMU), pipe fallback works"
"$TOOL" native-record "$ROOT" "$STATIC" "$QEMU" "$USB" "$ARCH"
