#!/usr/bin/env python3
"""scripts/merge-native.py on real Mach-O slices: a one-step arm64 root and a staged-layout x86_64 root (prefix a
symlink into its --native-deps, QEMU built elsewhere) merge into one universal root with build paths relocated."""
import json
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile

MERGE = Path(__file__).resolve().parents[2] / 'scripts/merge-native.py'


def run(*args):
    return subprocess.run(list(map(str, args)), check=True, capture_output=True, text=True).stdout


def slice_root(work, arch, staged):
    root = work / arch
    deps = work / f'deps-{arch}' if staged else root
    prefix, static = deps / 'prefix', deps / 'static/prefix'
    qemu = work / f'qemu-{arch}' if staged else root / 'qemu-build'
    for directory in (prefix / 'lib/pkgconfig', prefix / 'include', prefix / 'share', static / 'lib', qemu,
                      root / 'build/usbmuxd/src'):
        directory.mkdir(parents=True, exist_ok=True)
    if staged:
        (root / 'prefix').symlink_to(prefix)
    (work / 'lib.c').write_text('int value(void) { return 1; }\n')
    (work / 'main.c').write_text('extern int value(void); int main(void) { return value(); }\n')
    lib = prefix / 'lib/libvalue.dylib'
    cc = ('cc', '-arch', arch, '-mmacosx-version-min=14.0')
    run(*cc, '-dynamiclib', work / 'lib.c', '-install_name', lib, '-o', lib)
    run(*cc, '-c', work / 'lib.c', '-o', work / f'{arch}.o')
    run('ar', 'rcs', static / 'lib/libvalue.a', work / f'{arch}.o')
    run(*cc, '-dynamiclib', work / 'lib.c', '-install_name', '@rpath/libqemu-arm.dylib', '-o', qemu / 'libqemu-arm.dylib')
    usbmuxd = root / 'build/usbmuxd/src/usbmuxd'
    run(*cc, work / 'main.c', lib, '-Wl,-rpath,' + str(prefix / 'lib'), '-o', usbmuxd)
    (prefix / 'include/value.h').write_text('int value(void);\n')
    (prefix / 'share/where.txt').write_text(f'built in {prefix}\n')
    (prefix / 'lib/pkgconfig/value.pc').write_text(f'arch={arch}\n')   # per-slice build metadata: not merged
    (prefix / 'lib/libvalue.1.dylib').symlink_to('libvalue.dylib')
    gdb = prefix / 'share/gdb/auto-load' / str(prefix.resolve()).lstrip('/') / 'lib/libvalue-gdb.py'   # as glib installs it
    gdb.parent.mkdir(parents=True)
    gdb.write_text('# gdb helper\n')
    record = {'schema_version': 1, 'architecture': arch, 'deps_prefix': str(root / 'prefix'), 'static_deps': str(static),
              'qemu_build': str(qemu), 'usbmuxd_binary': str(usbmuxd)}
    if staged:
        record['reused_native_deps'] = str(deps)
    (root / 'native-build.json').write_text(json.dumps(record))
    return root


def merge(output, *roots):
    return subprocess.run([sys.executable, MERGE, output, *roots], capture_output=True, text=True)


with tempfile.TemporaryDirectory() as directory:
    work = Path(directory).resolve()
    arm, intel = slice_root(work, 'arm64', staged=False), slice_root(work, 'x86_64', staged=True)
    out = work / 'universal'
    result = merge(out, arm, intel)
    assert result.returncode == 0, result.stderr
    for name in ('prefix/lib/libvalue.dylib', 'static/prefix/lib/libvalue.a', 'qemu-build/libqemu-arm.dylib',
                 'build/usbmuxd/src/usbmuxd'):
        assert set(run('lipo', '-archs', out / name).split()) == {'arm64', 'x86_64'}, name
    assert (out / 'prefix/lib/libvalue.1.dylib').readlink() == Path('libvalue.dylib')
    assert (out / 'prefix/share/gdb/auto-load' / str(out / 'prefix').lstrip('/') / 'lib/libvalue-gdb.py').is_file()
    assert not (out / 'prefix/lib/pkgconfig').exists(), 'per-slice pkg-config metadata was merged'
    assert (out / 'prefix/share/where.txt').read_text() == f'built in {out / "prefix"}\n'
    for arch in ('arm64', 'x86_64'):
        loads = run('otool', '-arch', arch, '-l', out / 'build/usbmuxd/src/usbmuxd')
        assert f'name {out / "prefix/lib/libvalue.dylib"} ' in loads, loads
        assert f'path {out / "prefix/lib"} ' in loads, loads
        assert str(work / arch) not in loads and 'deps-' not in loads, loads
        assert run('otool', '-arch', arch, '-D', out / 'prefix/lib/libvalue.dylib').splitlines()[1] == \
            str(out / 'prefix/lib/libvalue.dylib')
    record = json.loads((out / 'native-build.json').read_text())
    assert record['architectures'] == ['arm64', 'x86_64'] and record['static_deps'] == str(out / 'static/prefix')
    assert merge(out, arm, intel).returncode != 0, 'merged over an existing output'
    shutil.rmtree(out)
    (work / 'deps-x86_64/prefix/include/value.h').write_text('int value(long);\n')
    result = merge(out, arm, intel)
    assert result.returncode != 0 and 'differs between architectures' in result.stderr, result
    assert not out.exists(), 'a failed merge left its output'
    result = merge(out, arm, arm)
    assert result.returncode != 0 and 'Two native roots for arm64' in result.stderr, result
print('PASS: merge-native lipos one-step and staged slices, relocates build paths, skips pkg-config, rejects differing files')
