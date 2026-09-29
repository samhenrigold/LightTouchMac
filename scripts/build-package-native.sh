#!/bin/bash
# Build the macOS 14 closure in a disposable directory; never rewrite Homebrew.
# Requires Xcode, meson, ninja, pkg-config and autotools.
# Usage: build-package-native.sh NEW-WORK-DIRECTORY
# Builds static dependencies from pinned sources unless LTM_STATIC_DEPS is explicit.
set -euo pipefail
ROOT="${1:?usage: build-package-native.sh new-work-directory}"
[ ! -e "$ROOT" ] || { echo "use a new build directory: $ROOT" >&2; exit 1; }
SRC="$(cd "$(dirname "$0")/.." && pwd)"
QEMU="$(python3 "$SRC/scripts/sources.py" qemu-ios)"    # the pin; QEMU_IOS_DIR overrides
USB="$(python3 "$SRC/scripts/sources.py" usbmuxd)"      # USBMUXD_SOURCE_DIR overrides
MESON="${MESON:-meson}"
JOBS="${LTM_JOBS:-$(sysctl -n hw.ncpu)}"
[[ "$JOBS" =~ ^[1-9][0-9]*$ ]] || { echo 'LTM_JOBS must be a positive integer' >&2; exit 1; }
[[ "$(uname -s)" == Darwin && "$(uname -m)" == arm64 ]] || { echo 'requires an Apple Silicon Mac' >&2; exit 1; }
for tool in python3 curl make ninja pkg-config glibtoolize autoreconf "$MESON"; do
    command -v "$tool" >/dev/null || { echo "missing build tool: $tool" >&2; exit 1; }
done
[ -f "$QEMU/configure" ] || { echo "missing QEMU source: $QEMU" >&2; exit 1; }
[ -f "$USB/configure.ac" ] || { echo "missing usbmuxd fork source: $USB" >&2; exit 1; }
QEMU="$(cd "$QEMU" && pwd)"
USB="$(cd "$USB" && pwd)"
mkdir -p "$ROOT/src" "$ROOT/build" "$ROOT/prefix"
ROOT="$(cd "$ROOT" && pwd)"
python3 "$SRC/scripts/dependency-sources.py" stage-git --source "$USB" \
    --destination "$ROOT/build/usbmuxd" --record "$ROOT/usbmuxd-source.json"
# Autotools requires a source version even though the staged tree omits .git.
git -C "$USB" describe --tags --always --dirty > "$ROOT/build/usbmuxd/.tarball-version"
if [ -n "${LTM_STATIC_DEPS:-}" ]; then
    STATIC="$(cd "$LTM_STATIC_DEPS" && pwd)"
else
    bash "$SRC/scripts/build-static-deps.sh" "$ROOT/static"
    STATIC="$ROOT/static/prefix"
fi
P="$ROOT/prefix"
export MACOSX_DEPLOYMENT_TARGET=14.0
export CFLAGS='-O2 -mmacosx-version-min=14.0' CXXFLAGS='-O2 -mmacosx-version-min=14.0'
export LDFLAGS='-mmacosx-version-min=14.0' CC=/usr/bin/clang CXX=/usr/bin/clang++
export PKG_CONFIG_LIBDIR="$P/lib/pkgconfig" PKG_CONFIG_PATH=
# Some Darwin libtool configure probes return an empty ARG_MAX. Avoid its
# broken partial-link fallback (which loses private symbols).
export lt_cv_sys_max_cmd_len=131072
unset CPATH C_INCLUDE_PATH CPLUS_INCLUDE_PATH LIBRARY_PATH
[ -f "$STATIC/lib/libcrypto.a" ] || { echo "missing static prefix: $STATIC" >&2; exit 1; }
fetch_group() {   # GROUP: its pinned archives into src/, from the caches when they have them
    local args=(fetch --group "$1" --destination "$ROOT/src")
    if [ -n "${LTM_SOURCE_CACHE:-}" ]; then args+=(--cache "$LTM_SOURCE_CACHE"); fi
    if [ -d "$ROOT/static/src" ]; then args+=(--cache "$ROOT/static/src"); fi
    if [ "${LTM_OFFLINE:-0}" = 1 ]; then args+=(--offline); fi
    python3 "$SRC/scripts/dependency-sources.py" "${args[@]}"
}
fetch_group native
cd "$ROOT/build"
for archive in glib-2.88.3.tar.xz pcre2-10.48.tar.bz2 pixman-0.46.4.tar.gz libslirp-v4.9.4.tar.gz libusb-1.0.30.tar.bz2 libplist-2.7.0.tar.bz2 libimobiledevice-1.4.0.tar.bz2 ffmpeg-9.0.1.tar.xz; do
    tar -xf "$ROOT/src/$archive"
done
tar -xf "$ROOT/src/proxy-libintl-0.5.tar.gz" -C glib-2.88.3/subprojects
# Keep SDK feature detection tied to the deployment target. A headerless
# pipe2 probe incorrectly accepts the macOS 27 symbol for a macOS 14 build.
(cd glib-2.88.3 && patch -p1 < "$SRC/build-support/patches/glib-pipe2-availability.patch")
(cd pcre2-10.48 && ./configure --prefix="$P" --disable-shared --enable-static --disable-pcre2grep-libz --disable-pcre2grep-libbz2 && make -j"$JOBS" && make install)
SDK="$(xcrun --sdk macosx --show-sdk-path)"
cat > "$P/lib/pkgconfig/libffi.pc" <<EOF
Name: libffi
Description: macOS system libffi
Version: 3.4.0
Libs: -lffi
Cflags: -I$SDK/usr/include/ffi
EOF
"$MESON" setup glib-out glib-2.88.3 --prefix="$P" --buildtype=release -Ddefault_library=static -Dnls=disabled -Dtests=false -Dintrospection=disabled -Dman-pages=disabled -Dlibmount=disabled -Dselinux=disabled -Dsysprof=disabled --wrap-mode=nodownload
ninja -C glib-out -j"$JOBS" && ninja -C glib-out install
mkdir -p "$P/share/licenses/glib"
cp glib-2.88.3/COPYING "$SRC/build-support/patches/glib-pipe2-availability.patch" "$P/share/licenses/glib/"
"$MESON" setup pixman-out pixman-0.46.4 --prefix="$P" --buildtype=release -Ddefault_library=static -Dtests=disabled -Ddemos=disabled --wrap-mode=nofallback
ninja -C pixman-out -j"$JOBS" && ninja -C pixman-out install
"$MESON" setup slirp-out libslirp-v4.9.4 --prefix="$P" --buildtype=release -Ddefault_library=static --wrap-mode=nofallback
ninja -C slirp-out -j"$JOBS" && ninja -C slirp-out install
# libusb: only the usbmuxd fork's configure.ac asks for it (PKG_CHECK_MODULES, no flag); its QEMU backend
# compiles no libusb code and the static archive contributes no symbol, so nothing of it ships.
(cd libusb-1.0.30 && ./configure --prefix="$P" --disable-shared --enable-static && make -j"$JOBS" && make install)
# Shared exports are required by IMobileDevice.swift's dlopen/dlsym API; the
# corresponding static archives intentionally hide these public symbols.
export PKG_CONFIG_LIBDIR="$P/lib/pkgconfig:$STATIC/lib/pkgconfig"
(cd libplist-2.7.0 && ./configure --prefix="$P" --enable-shared --disable-static --without-cython && make -j"$JOBS" && make install)
# iPhone OS 1.x lockdownd speaks SSLv3 only: offer exactly SSLv3 below ProductVersion 2.0 (smoke.md #51).
(cd libimobiledevice-1.4.0 && patch -p1 < "$SRC/build-support/patches/libimobiledevice-sslv3-ios1.patch")
(cd libimobiledevice-1.4.0 && LDFLAGS="$LDFLAGS -framework SystemConfiguration -framework CoreFoundation" ./configure --prefix="$P" --enable-shared --disable-static --without-cython && make -j"$JOBS" && make install)
mkdir -p "$P/share/licenses/libimobiledevice"
cp libimobiledevice-1.4.0/COPYING "$SRC/build-support/patches/libimobiledevice-sslv3-ios1.patch" "$P/share/licenses/libimobiledevice/"
(cd usbmuxd && glibtoolize --copy --force && autoreconf -fi)
(cd usbmuxd && LDFLAGS="$LDFLAGS -framework IOKit -framework CoreFoundation -framework Security" ./configure --prefix="$P" --without-systemd && make -j"$JOBS")
# iBoot32Patcher (GPL-3.0, the "tools" group of the manifest): firmwarekit runs it for the k48 real-iBoot
# recipe. Built into build/iBoot32Patcher with its LICENSE, our patch and a SOURCE.txt; package.sh ships them.
fetch_group tools
bash "$SRC/scripts/build-iboot32patcher.sh" "$ROOT/src" "$ROOT/build/iBoot32Patcher"
# AMC audio and incremental H.264 slices use libavcodec/libavutil. Keep the closure native
# to macOS 14, with no automatically discovered Homebrew codec dependencies.
(cd ffmpeg-9.0.1 && patch -p1 < "$QEMU/contrib/ffmpeg/h264-chunk-er.patch" && patch -p1 < "$QEMU/contrib/ffmpeg/h264-cavlc-pcm-offset.patch")
(cd ffmpeg-9.0.1 && ./configure --prefix="$P" \
    --disable-everything --disable-autodetect --disable-programs --disable-doc \
    --disable-avdevice --disable-avformat --disable-avfilter --disable-swscale --disable-swresample \
    --enable-decoder=aac,mp3,alac,h264 --enable-shared --disable-static --install-name-dir=@rpath \
    --extra-cflags=-mmacosx-version-min=14.0 \
    --extra-ldflags='-mmacosx-version-min=14.0 -Wl,-rpath,@loader_path' \
    && make -j"$JOBS" && make install)
mkdir -p "$P/share/licenses/ffmpeg"
cp ffmpeg-9.0.1/COPYING.LGPLv2.1 "$P/share/licenses/ffmpeg/"
printf '%s\n' 'FFmpeg 9.0.1: https://ffmpeg.org/releases/ffmpeg-9.0.1.tar.xz' \
    'SHA256: cf38e0e28c7e5605942c4a77755349b0145804a397af37eb1fb4c77cb237f635' \
    'Apply h264-chunk-er.patch and h264-cavlc-pcm-offset.patch; build options are in build-package-native.sh.' \
    > "$P/share/licenses/ffmpeg/SOURCE.txt"
cp "$SRC/scripts/build-package-native.sh" "$QEMU/contrib/ffmpeg/h264-chunk-er.patch" "$QEMU/contrib/ffmpeg/h264-cavlc-pcm-offset.patch" "$P/share/licenses/ffmpeg/"
# Retain the native UI, CGL renderer, CoreAudio and Wi-Fi/slirp; avoid accidental optional
# Homebrew dependencies. Board AES/SHA use the declared static libcrypto.
export PKG_CONFIG_LIBDIR="$P/lib/pkgconfig"
mkdir "$ROOT/qemu-build"
cd "$ROOT/qemu-build"
"$QEMU/configure" --target-list=arm-softmmu --without-default-features --enable-cocoa --enable-coreaudio --enable-pixman --enable-slirp --disable-pie \
    --python="${QEMU_PYTHON:-python3.12}" \
    --extra-cflags="-I$STATIC/include -mmacosx-version-min=14.0" \
    --extra-ldflags="-L$STATIC/lib -lcrypto -mmacosx-version-min=14.0"
ninja -j"$JOBS" qemu-system-arm
bash "$QEMU/contrib/macos-app/make-dylib-macos.sh" "$ROOT/qemu-build"
python3 "$SRC/scripts/check-macho.py" --no-weak-imports "$ROOT/qemu-build/libqemu-arm.dylib" "$P/lib/libimobiledevice-1.0.dylib" "$P/lib/libplist-2.0.dylib" "$ROOT/build/usbmuxd/src/usbmuxd" "$ROOT/build/iBoot32Patcher/iBoot32Patcher"
python3 "$SRC/scripts/test-glib-compat.py" --native-build "$ROOT"
python3 - "$SRC" "$ROOT" "$STATIC" "$QEMU" "$USB" <<'PY'
import hashlib, json, pathlib, subprocess, sys
source, root, static, qemu, usb = map(pathlib.Path, sys.argv[1:])
def digest(path):
    result = hashlib.sha256()
    with path.open('rb') as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b''):
            result.update(block)
    return result.hexdigest()
def git(*args):
    return subprocess.check_output(['git', '-C', str(qemu), *args])
record = {
    'schema_version': 1, 'static_deps': str(static), 'qemu_source': str(qemu),
    'usbmuxd_source': str(usb), 'qemu_build': str(root / 'qemu-build'),
    'deps_prefix': str(root / 'prefix'), 'usbmuxd_binary': str(root / 'build/usbmuxd/src/usbmuxd'),
    'deployment_target': '14.0', 'architecture': 'arm64',
    'sources': json.loads((root / 'src/native-sources.json').read_text()),
    'usbmuxd': json.loads((root / 'usbmuxd-source.json').read_text()),
    'iboot32patcher': json.loads((root / 'build/iBoot32Patcher/build.json').read_text()),
    'qemu_commit': git('rev-parse', 'HEAD').decode().strip(),
    'qemu_tracked_diff_sha256': hashlib.sha256(git('diff', '--binary', 'HEAD')).hexdigest(),
    'recipes': {str(path.relative_to(source)): digest(path) for path in (
        source / 'scripts/build-package-native.sh', source / 'scripts/build-static-deps.sh',
        source / 'scripts/dependency-sources.py', source / 'build-support/dependencies.json', source / 'scripts/build-iboot32patcher.sh',
        source / 'build-support/patches/glib-pipe2-availability.patch', source / 'build-support/patches/iBoot32Patcher-ltm.patch',
        source / 'build-support/patches/libimobiledevice-sslv3-ios1.patch',
        source / 'scripts/test-glib-compat.py', source / 'scripts/check-macho.py')},
    'static_inputs': [{'path': str(path.relative_to(static)), 'sha256': digest(path)}
                      for path in sorted(static.rglob('*')) if path.is_file()],
    'xcode': subprocess.check_output(['xcodebuild', '-version'], text=True).strip(),
    'sdk': subprocess.check_output(['xcrun', '--sdk', 'macosx', '--show-sdk-version'], text=True).strip(),
}
if (root / 'static/static-build.json').is_file():
    record['static_build'] = json.loads((root / 'static/static-build.json').read_text())
elif (static.parent / 'static-build.json').is_file():
    record['static_build'] = json.loads((static.parent / 'static-build.json').read_text())
    record['static_build']['origin'] = 'explicit LTM_STATIC_DEPS override'
else:
    record['static_build'] = {'origin': 'explicit LTM_STATIC_DEPS override'}
(root / 'native-build.json').write_text(json.dumps(record, indent=2) + '\n')
PY
printf '\nPackage with:\nQEMU_BUILD_DIR=%q LTM_DEPS_PREFIX=%q LTM_STATIC_DEPS=%q USBMUXD_BIN=%q bash %q /path/to/LightTouchMac.app\n' "$ROOT/qemu-build" "$P" "$STATIC" "$ROOT/build/usbmuxd/src/usbmuxd" "$SRC/scripts/package.sh"
