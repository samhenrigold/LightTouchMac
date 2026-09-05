#!/bin/bash
# Build the macOS 14 closure in a disposable directory; never rewrite Homebrew.
# Requires the existing qemu-ios-deps12 static prefix, Xcode, meson, ninja,
# pkg-config and autotools. Usage: build-package-native.sh NEW-WORK-DIRECTORY
# qemu-ios-deps12/build-deps12.sh records how that reusable static prefix was built.
set -euo pipefail
ROOT="${1:?usage: build-package-native.sh new-work-directory}"
[ ! -e "$ROOT" ] || { echo "use a new build directory: $ROOT" >&2; exit 1; }
mkdir -p "$ROOT/src" "$ROOT/build" "$ROOT/prefix"
ROOT="$(cd "$ROOT" && pwd)"
SRC="$(cd "$(dirname "$0")/.." && pwd)"
QEMU="${QEMU_IOS_DIR:-$HOME/Developer/qemu-ios}"
STATIC="${LTM_STATIC_DEPS:-$HOME/Developer/qemu-ios-deps12}"
USB="${USBMUXD_QEMU:-$HOME/Developer/usbmuxd-qemu}"
P="$ROOT/prefix"
export MACOSX_DEPLOYMENT_TARGET=14.0
export CFLAGS='-O2 -mmacosx-version-min=14.0' CXXFLAGS='-O2 -mmacosx-version-min=14.0'
export LDFLAGS='-mmacosx-version-min=14.0' CC=/usr/bin/clang CXX=/usr/bin/clang++
export PKG_CONFIG_LIBDIR="$P/lib/pkgconfig" PKG_CONFIG_PATH=
# Some Darwin libtool configure probes return an empty ARG_MAX. Avoid its
# broken partial-link fallback (which loses private symbols).
export lt_cv_sys_max_cmd_len=131072
MESON="${MESON:-meson}"
for tool in ideviceinstaller ideviceinfo idevicesyslog iproxy idevicepair; do
    python3 "$SRC/scripts/check-macho.py" "$STATIC/bin/$tool"
done
[ -f "$STATIC/lib/libcrypto.a" ] || { echo "missing static prefix: $STATIC" >&2; exit 1; }
fetch() {
    curl -fL "$2" -o "$ROOT/src/$1"
    printf '%s  %s\n' "$3" "$ROOT/src/$1" | shasum -a 256 -c -
}
fetch glib.tar.xz https://download.gnome.org/sources/glib/2.88/glib-2.88.3.tar.xz ab24d24e698dfa1e408b7bcdb508f4aafc906185a8b8ce72fdf79bbbdc9b383b
fetch pcre2.tar.bz2 https://github.com/PCRE2Project/pcre2/releases/download/pcre2-10.48/pcre2-10.48.tar.bz2 b6c68fdf6f3ac31388b50aa89ff0fc49c00c987c16e7b5146491d12003f2c8ed
fetch pixman.tar.gz https://cairographics.org/releases/pixman-0.46.4.tar.gz d09c44ebc3bd5bee7021c79f922fe8fb2fb57f7320f55e97ff9914d2346a591c
fetch slirp.tar.gz https://gitlab.freedesktop.org/slirp/libslirp/-/archive/v4.9.4/libslirp-v4.9.4.tar.gz 3998863b020aeda34bddc567097c6efba55a78cdf6eeee6bcd42c11ef23967da
fetch libusb.tar.bz2 https://github.com/libusb/libusb/releases/download/v1.0.30/libusb-1.0.30.tar.bz2 fea36f34f9156400209595e300840767ab1a385ede1dc7ee893015aea9c6dbaf
fetch proxy-libintl.tar.gz https://github.com/frida/proxy-libintl/archive/refs/tags/0.5.tar.gz f7a1cbd7579baaf575c66f9d99fb6295e9b0684a28b095967cfda17857595303
fetch libplist.tar.bz2 https://github.com/libimobiledevice/libplist/releases/download/2.7.0/libplist-2.7.0.tar.bz2 7ac42301e896b1ebe3c654634780c82baa7cb70df8554e683ff89f7c2643eb8b
fetch libimobiledevice.tar.bz2 https://github.com/libimobiledevice/libimobiledevice/releases/download/1.4.0/libimobiledevice-1.4.0.tar.bz2 23cc0077e221c7d991bd0eb02150a0d49199bcca1ddf059edccee9ffd914939d
fetch ffmpeg.tar.xz https://ffmpeg.org/releases/ffmpeg-9.0.1.tar.xz cf38e0e28c7e5605942c4a77755349b0145804a397af37eb1fb4c77cb237f635
cd "$ROOT/build"
for archive in glib.tar.xz pcre2.tar.bz2 pixman.tar.gz slirp.tar.gz libusb.tar.bz2 libplist.tar.bz2 libimobiledevice.tar.bz2 ffmpeg.tar.xz; do
    tar -xf "$ROOT/src/$archive"
done
tar -xf "$ROOT/src/proxy-libintl.tar.gz" -C glib-2.88.3/subprojects
(cd pcre2-10.48 && ./configure --prefix="$P" --disable-shared --enable-static --disable-pcre2grep-libz --disable-pcre2grep-libbz2 && make -j8 && make install)
SDK="$(xcrun --sdk macosx --show-sdk-path)"
cat > "$P/lib/pkgconfig/libffi.pc" <<EOF
Name: libffi
Description: macOS system libffi
Version: 3.4.0
Libs: -lffi
Cflags: -I$SDK/usr/include/ffi
EOF
"$MESON" setup glib-out glib-2.88.3 --prefix="$P" --buildtype=release -Ddefault_library=static -Dnls=disabled -Dtests=false -Dintrospection=disabled -Dman-pages=disabled -Dlibmount=disabled -Dselinux=disabled -Dsysprof=disabled --wrap-mode=nodownload
ninja -C glib-out -j8 && ninja -C glib-out install
"$MESON" setup pixman-out pixman-0.46.4 --prefix="$P" --buildtype=release -Ddefault_library=static -Dtests=disabled -Ddemos=disabled --wrap-mode=nofallback
ninja -C pixman-out -j8 && ninja -C pixman-out install
"$MESON" setup slirp-out libslirp-v4.9.4 --prefix="$P" --buildtype=release -Ddefault_library=static --wrap-mode=nofallback
ninja -C slirp-out -j8 && ninja -C slirp-out install
(cd libusb-1.0.30 && ./configure --prefix="$P" --disable-shared --enable-static && make -j8 && make install)
# Shared exports are required by IMobileDevice.swift's dlopen/dlsym API; the
# corresponding deps12 archives intentionally hide these public symbols.
export PKG_CONFIG_LIBDIR="$P/lib/pkgconfig:$STATIC/lib/pkgconfig"
(cd libplist-2.7.0 && ./configure --prefix="$P" --enable-shared --disable-static --without-cython && make -j8 && make install)
LDFLAGS="$LDFLAGS -framework SystemConfiguration -framework CoreFoundation" bash -c 'cd "$1" && ./configure --prefix="$2" --enable-shared --disable-static --without-cython && make -j8 && make install' _ libimobiledevice-1.4.0 "$P"
for tool in ideviceinstaller ideviceinfo idevicesyslog iproxy idevicepair; do cp "$STATIC/bin/$tool" "$P/bin/"; done
cp -R "$USB/usbmuxd" usbmuxd
(cd usbmuxd && glibtoolize --copy --force && autoreconf -fi)
find usbmuxd -name '*.o' -delete
find usbmuxd -name '*.lo' -delete
(cd usbmuxd && LDFLAGS="$LDFLAGS -framework IOKit -framework CoreFoundation -framework Security" ./configure --prefix="$P" --without-systemd && make -j8)
# AMC audio and incremental H.264 slices use libavcodec/libavutil. Keep the closure native
# to macOS 14, with no automatically discovered Homebrew codec dependencies.
(cd ffmpeg-9.0.1 && patch -p1 < "$QEMU/contrib/ffmpeg/h264-chunk-er.patch" && patch -p1 < "$QEMU/contrib/ffmpeg/h264-cavlc-pcm-offset.patch")
(cd ffmpeg-9.0.1 && ./configure --prefix="$P" \
    --disable-everything --disable-autodetect --disable-programs --disable-doc \
    --disable-avdevice --disable-avformat --disable-avfilter --disable-swscale --disable-swresample \
    --enable-decoder=aac,mp3,alac,h264 --enable-shared --disable-static --install-name-dir=@rpath \
    --extra-cflags=-mmacosx-version-min=14.0 \
    --extra-ldflags='-mmacosx-version-min=14.0 -Wl,-rpath,@loader_path' \
    && make -j8 && make install)
mkdir -p "$P/share/licenses/ffmpeg"
cp ffmpeg-9.0.1/COPYING.LGPLv2.1 "$P/share/licenses/ffmpeg/"
printf '%s\n' 'FFmpeg 9.0.1: https://ffmpeg.org/releases/ffmpeg-9.0.1.tar.xz' \
    'SHA256: cf38e0e28c7e5605942c4a77755349b0145804a397af37eb1fb4c77cb237f635' \
    'Apply h264-chunk-er.patch and h264-cavlc-pcm-offset.patch; build options are in build-package-native.sh.' \
    > "$P/share/licenses/ffmpeg/SOURCE.txt"
cp "$SRC/scripts/build-package-native.sh" "$QEMU/contrib/ffmpeg/h264-chunk-er.patch" "$QEMU/contrib/ffmpeg/h264-cavlc-pcm-offset.patch" "$P/share/licenses/ffmpeg/"
# Retain the native UI, CGL renderer, CoreAudio and Wi-Fi/slirp; avoid accidental optional
# Homebrew dependencies. Board AES/SHA use the existing static libcrypto.
export PKG_CONFIG_LIBDIR="$P/lib/pkgconfig"
mkdir "$ROOT/qemu-build"
cd "$ROOT/qemu-build"
"$QEMU/configure" --target-list=arm-softmmu --without-default-features --enable-cocoa --enable-coreaudio --enable-pixman --enable-slirp --disable-pie \
    --python="${QEMU_PYTHON:-python3.12}" \
    --extra-cflags="-I$STATIC/include -mmacosx-version-min=14.0" \
    --extra-ldflags="-L$STATIC/lib -lcrypto -mmacosx-version-min=14.0"
ninja -j8 qemu-system-arm
bash "$QEMU/contrib/macos-app/make-dylib-macos.sh" "$ROOT/qemu-build"
python3 "$SRC/scripts/check-macho.py" "$ROOT/qemu-build/libqemu-arm.dylib" "$P/lib/libimobiledevice-1.0.dylib" "$P/lib/libplist-2.0.dylib" "$ROOT/build/usbmuxd/src/usbmuxd"
printf '\nPackage with:\nQEMU_BUILD_DIR=%q LTM_DEPS_PREFIX=%q USBMUXD_BIN=%q bash %q /path/to/LightTouchMac.app\n' "$ROOT/qemu-build" "$P" "$ROOT/build/usbmuxd/src/usbmuxd" "$SRC/scripts/package.sh"
