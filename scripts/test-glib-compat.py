#!/usr/bin/env python3
"""Check GLib's macOS API selection without launching QEMU or any device.

The default check uses the active SDK and real Meson probes targeting macOS 14.
With --native-build, also inspect generated GLib/QEMU artifacts and exercise the
built static GLib's pipe fallback using private process-local descriptors.
"""
import argparse
import os
from pathlib import Path
import re
import shlex
import shutil
import subprocess
import tempfile


def run(command, **kwargs):
    result = subprocess.run(list(map(str, command)), capture_output=True, text=True, **kwargs)
    if result.returncode:
        raise RuntimeError(f"Command failed: {shlex.join(list(map(str, command)))}\n"
                           f"{result.stdout}{result.stderr}")
    return result.stdout


def reject_pipe2_import(path):
    symbols = run(['xcrun', 'nm', '-m', path])
    if any('(undefined)' in line and re.search(r'\b_pipe2\b', line)
           for line in symbols.splitlines()):
        raise RuntimeError(f'{path} imports pipe2, which is unavailable on macOS 14')


def check_probe(work, meson, cc):
    source = work / 'probe'
    source.mkdir()
    (source / 'meson.build').write_text("""project('glib-pipe-compatibility', 'c')
cc = meson.get_compiler('c')
# This declaration carries the SDK's macOS introduction version.
if cc.has_function('pipe2', prefix: '#include <unistd.h>')
  error('pipe2 must not be selected for the macOS 14 deployment target')
endif
assert(cc.has_function('pipe', prefix: '#include <unistd.h>'))
""")
    environment = dict(os.environ, CC=cc, CFLAGS='-O2 -mmacosx-version-min=14.0',
                       LDFLAGS='-mmacosx-version-min=14.0', MACOSX_DEPLOYMENT_TARGET='14.0')
    run([meson, 'setup', work / 'probe-build', source, '--wrap-mode=nodownload'], env=environment)
    print('PASS: real Meson/SDK probe rejects pipe2 and accepts pipe for macOS 14')


def check_native(work, native, cc, arch):
    config = native / 'build/glib-out/config.h'
    if re.search(r'^\s*#\s*define\s+HAVE_PIPE2\b', config.read_text(), re.MULTILINE):
        raise RuntimeError(f'{config} still defines HAVE_PIPE2 for the macOS 14 build')
    reject_pipe2_import(native / 'qemu-build/libqemu-arm.dylib')
    prefix = native / 'prefix'
    environment = dict(os.environ, PKG_CONFIG_PATH='',
                       PKG_CONFIG_LIBDIR=os.pathsep.join(map(str, [prefix / 'lib/pkgconfig',
                                                                  prefix / 'share/pkgconfig'])))
    flags = shlex.split(run(['pkg-config', '--static', '--cflags', '--libs', 'glib-2.0'],
                            env=environment))
    archive = prefix / 'lib/libglib-2.0.a'
    if not archive.is_file() or '-lglib-2.0' not in flags:
        raise RuntimeError(f'Missing static GLib library or pkg-config link flag: {archive}')
    flags = [str(archive) if flag == '-lglib-2.0' else flag for flag in flags]
    source = work / 'pipe-check.c'
    source.write_text(r'''#include <glib-unix.h>
#include <fcntl.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>

int main(void)
{
    int fds[2];
    GError *error = NULL;
    if (!g_unix_open_pipe(fds, O_CLOEXEC | O_NONBLOCK, &error)) {
        fprintf(stderr, "g_unix_open_pipe failed: %s\n", error ? error->message : "unknown");
        g_clear_error(&error);
        return 1;
    }
    int result = 0;
    for (int i = 0; i < 2; ++i) {
        int descriptor_flags = fcntl(fds[i], F_GETFD);
        int status_flags = fcntl(fds[i], F_GETFL);
        if (descriptor_flags < 0 || !(descriptor_flags & FD_CLOEXEC)
            || status_flags < 0 || !(status_flags & O_NONBLOCK))
            result = 2;
    }
    const char expected[] = "GLib pipe compatibility";
    char actual[sizeof expected] = {0};
    if (write(fds[1], expected, sizeof expected) != sizeof expected
        || read(fds[0], actual, sizeof actual) != sizeof actual
        || memcmp(expected, actual, sizeof expected))
        result = 3;
    int close_read = close(fds[0]);
    int close_write = close(fds[1]);
    if (close_read || close_write)
        result = 4;
    return result;
}
''')
    executable = work / 'pipe-check'
    run([cc, '-arch', arch, '-mmacosx-version-min=14.0', '-Wl,-no_weak_imports',
         source, '-o', executable, *flags])
    reject_pipe2_import(executable)
    run([executable], timeout=10)
    print('PASS: built GLib pipe fallback has working CLOEXEC/nonblocking descriptors and data flow')
    print('PASS: generated GLib config and QEMU contain no unsupported pipe2 import')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--native-build', type=Path, help='output of build-package-native.sh')
    parser.add_argument('--meson', default=os.environ.get('MESON') or shutil.which('meson') or 'meson')
    parser.add_argument('--cc', default='/usr/bin/clang')
    parser.add_argument('--arch', default='arm64')
    args = parser.parse_args()
    with tempfile.TemporaryDirectory(prefix='ltm-glib-compat-') as directory:
        work = Path(directory)
        check_probe(work, args.meson, args.cc)
        if args.native_build:
            check_native(work, args.native_build.resolve(), args.cc, args.arch)


if __name__ == '__main__':
    try:
        main()
    except (OSError, RuntimeError, subprocess.TimeoutExpired) as error:
        raise SystemExit(str(error))
