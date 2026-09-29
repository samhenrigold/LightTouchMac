#!/bin/bash
# Build the static libraries from the product's pinned recipes: OpenSSL (the emulator's AES/SHA, the
# web proxy's TLS) and the libimobiledevice stack the native shared libimobiledevice links against.
# No command-line tools ship: the app calls libimobiledevice directly (IMobileDevice.swift).
# Usage: build-static-deps.sh NEW-WORK-DIRECTORY (output: WORK-DIRECTORY/prefix)
# LTM_SOURCE_CACHE optionally names a directory of source archives; each is verified.
set -euo pipefail
ROOT="${1:?usage: build-static-deps.sh new-work-directory}"
[ ! -e "$ROOT" ] || { echo "use a new build directory: $ROOT" >&2; exit 1; }
SRC="$(cd "$(dirname "$0")/.." && pwd)"
JOBS="${LTM_JOBS:-$(sysctl -n hw.ncpu)}"
[[ "$JOBS" =~ ^[1-9][0-9]*$ ]] || { echo 'LTM_JOBS must be a positive integer' >&2; exit 1; }
for tool in python3 curl make pkg-config xcrun; do
    command -v "$tool" >/dev/null || { echo "missing build tool: $tool" >&2; exit 1; }
done
[[ "$(uname -s)" == Darwin && "$(uname -m)" == arm64 ]] || { echo 'requires an Apple Silicon Mac' >&2; exit 1; }
mkdir -p "$ROOT/src" "$ROOT/build" "$ROOT/logs" "$ROOT/prefix/lib/pkgconfig"
ROOT="$(cd "$ROOT" && pwd)"
trap 'echo "Static dependency build failed; see $ROOT/logs" >&2' ERR
PREFIX="$ROOT/prefix"
LOG="$ROOT/logs"
SOURCE_ARGS=(fetch --group static --destination "$ROOT/src")
if [ -n "${LTM_SOURCE_CACHE:-}" ]; then SOURCE_ARGS+=(--cache "$LTM_SOURCE_CACHE"); fi
if [ "${LTM_OFFLINE:-0}" = 1 ]; then SOURCE_ARGS+=(--offline); fi
python3 "$SRC/scripts/dependency-sources.py" "${SOURCE_ARGS[@]}"

# Preserve the former deps12 source versions and build options, targeting the
# application's supported macOS 14 baseline. Never discover Homebrew libraries.
export MACOSX_DEPLOYMENT_TARGET=14.0
MIN="-mmacosx-version-min=$MACOSX_DEPLOYMENT_TARGET"
export CFLAGS="$MIN -O2" CXXFLAGS="$MIN -O2" LDFLAGS="$MIN"
export PKG_CONFIG_LIBDIR="$PREFIX/lib/pkgconfig" PKG_CONFIG_PATH=
export SDKROOT="$(xcrun --sdk macosx --show-sdk-path)"
export CC="$(xcrun -f clang)" CXX="$(xcrun -f clang++)"
export lt_cv_sys_max_cmd_len=131072
unset CPATH C_INCLUDE_PATH CPLUS_INCLUDE_PATH LIBRARY_PATH

cat > "$PREFIX/lib/pkgconfig/zlib.pc" <<'EOF'
prefix=/usr
Name: zlib
Description: macOS system zlib
Version: 1.2.12
Libs: -lz
Cflags:
EOF
cat > "$PREFIX/lib/pkgconfig/libcurl.pc" <<'EOF'
prefix=/usr
Name: libcurl
Description: macOS system libcurl
Version: 8.7.1
Libs: -lcurl
Cflags:
EOF

untar() { tar -C "$ROOT/build" -xf "$ROOT/src/$1"; }
untar openssl-3.6.3.tar.gz
echo 'Building OpenSSL 3.6.3'
(
    cd "$ROOT/build/openssl-3.6.3"
    # SSLv3 for iPhone OS 1.x lockdownd (libimobiledevice-sslv3-ios1.patch picks it below 2.0 only; OpenSSL
    # still refuses it above security level 0, which only libimobiledevice's contexts set).
    ./Configure darwin64-arm64-cc no-shared no-tests no-docs enable-ssl3 enable-ssl3-method \
        --prefix="$PREFIX" --openssldir=/private/etc/ssl "$MIN" > "$LOG/openssl.configure.log" 2>&1
    make -j"$JOBS" > "$LOG/openssl.build.log" 2>&1
    make install_sw > "$LOG/openssl.install.log" 2>&1
)

autobuild() {
    local archive="$1" directory="$2"
    shift 2
    echo "Building $directory"
    untar "$archive"
    (
        cd "$ROOT/build/$directory"
        ./configure --prefix="$PREFIX" --disable-shared --enable-static "$@" \
            > "$LOG/$directory.configure.log" 2>&1
        make -j"$JOBS" > "$LOG/$directory.build.log" 2>&1
        make install > "$LOG/$directory.install.log" 2>&1
    )
}
autobuild libplist-2.7.0.tar.bz2 libplist-2.7.0 --without-cython
autobuild libimobiledevice-glue-1.3.2.tar.bz2 libimobiledevice-glue-1.3.2
autobuild libusbmuxd-2.1.1.tar.bz2 libusbmuxd-2.1.1
autobuild libtatsu-1.0.5.tar.bz2 libtatsu-1.0.5
autobuild libimobiledevice-1.4.0.tar.bz2 libimobiledevice-1.4.0 --without-cython
python3 - "$SRC" "$ROOT" <<'PY'
import hashlib, json, pathlib, subprocess, sys
source, root = map(pathlib.Path, sys.argv[1:])
record = {
    'schema_version': 1, 'static_deps': str(root / 'prefix'),
    'deployment_target': '14.0', 'architecture': 'arm64',
    'sources': json.loads((root / 'src/static-sources.json').read_text()),
    'recipe_sha256': hashlib.sha256((source / 'scripts/build-static-deps.sh').read_bytes()).hexdigest(),
    'xcode': subprocess.check_output(['xcodebuild', '-version'], text=True).strip(),
    'sdk': subprocess.check_output(['xcrun', '--sdk', 'macosx', '--show-sdk-version'], text=True).strip(),
}
(root / 'static-build.json').write_text(json.dumps(record, indent=2) + '\n')
PY
echo "Static dependencies ready: $PREFIX"
