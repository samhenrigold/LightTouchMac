#!/usr/bin/env python3
"""Exercise deployment-target and relocation checks against real Mach-O files.

    tests/release/test-package.py [PACKAGED.app]

With an app (package.sh output), also check its device helper: present in
Contents/MacOS, hardened runtime with the QEMU entitlements, its load closure and
the dlopened Frameworks/libqemu-arm.dylib resolved inside the bundle, and a
--probe that actually loads the bundled emulator library.
"""
import json
import os
import pathlib
import re
import shutil
import subprocess
import sys
import tempfile
import uuid

CHECK = pathlib.Path(__file__).resolve().parents[2] / 'scripts/check-macho.py'


def run(*args):
    return subprocess.run(list(map(str, args)), check=True, capture_output=True, text=True)


def verify(*paths, bundle=None, error=None, no_weak_imports=False):
    cmd = [sys.executable, CHECK, '--minos', '14.0']
    if bundle:
        cmd += ['--bundle', bundle]
    if no_weak_imports:
        cmd += ['--no-weak-imports']
    result = subprocess.run(list(map(str, cmd + list(paths))), capture_output=True, text=True)
    if error:
        assert result.returncode != 0 and error in result.stderr, result
    else:
        assert result.returncode == 0, result.stderr


with tempfile.TemporaryDirectory() as directory:
    root = pathlib.Path(directory)
    libsrc, mainsrc = root / 'lib.c', root / 'main.c'
    libsrc.write_text('int value(void) { return 0; }\n')
    mainsrc.write_text('extern int value(void); int main(void) { return value(); }\n')
    libs = []
    for minimum in ('14.0', '26.0'):
        lib = root / f'lib{minimum}.dylib'
        run('cc', '-arch', 'arm64', f'-mmacosx-version-min={minimum}', '-dynamiclib',
            libsrc, '-install_name', lib, '-o', lib)
        exe = root / f'exe{minimum}'
        run('cc', '-arch', 'arm64', '-mmacosx-version-min=14.0', mainsrc, lib, '-o', exe)
        libs.append(lib)
        verify(exe, error='requires macOS 26.0' if minimum == '26.0' else None)
    app = root / 'Test.app'
    frameworks, macos = app / 'Contents/Frameworks', app / 'Contents/MacOS'
    frameworks.mkdir(parents=True)
    macos.mkdir()
    executable = macos / 'Test'
    shutil.copy(root / 'exe14.0', executable)
    verify(executable, bundle=app, error='escapes relocatable bundle')
    shutil.copy(libs[0], frameworks / libs[0].name)
    run('install_name_tool', '-change', libs[0], '@rpath/' + libs[0].name, executable)
    verify(executable, bundle=app, error='unresolved dependency')
    run('install_name_tool', '-add_rpath', '@executable_path/../Frameworks', executable)
    verify(executable, bundle=app)
    tools = app / 'Contents/Resources/tools'
    tools.mkdir(parents=True)
    tool = tools / 'tool'
    shutil.copy(executable, tool)
    verify(tool, bundle=app, error='unresolved dependency')
    run('install_name_tool', '-delete_rpath', '@executable_path/../Frameworks',
        '-add_rpath', '@executable_path/../../Frameworks', tool)
    verify(tool, bundle=app)
    (frameworks / libs[0].name).unlink()
    verify(executable, bundle=app, error='unresolved dependency')
    libs[0].unlink()
    verify(root / 'exe14.0', error='unresolved dependency')
    weaksrc = root / 'weak.c'
    weaksrc.write_text('extern int optional_api(void) __attribute__((weak_import));\n'
                       'int value(void) { return optional_api ? optional_api() : 0; }\n')
    weaklib = root / 'weak.dylib'
    run('cc', '-arch', 'arm64', '-mmacosx-version-min=14.0', '-dynamiclib',
        '-undefined', 'dynamic_lookup', weaksrc, '-o', weaklib)
    verify(weaklib)  # A low LC_BUILD_VERSION alone cannot establish runtime compatibility.
    verify(weaklib, no_weak_imports=True, error='unexpected weak imports')
    verify(root / 'lib26.0.dylib', no_weak_imports=True, error='requires macOS 26.0')
    # A universal binary (build-release.py --universal) needs every slice of every dependency.
    both = root / 'both.dylib'
    run('cc', '-arch', 'arm64', '-arch', 'x86_64', '-mmacosx-version-min=14.0', '-dynamiclib',
        libsrc, '-install_name', both, '-o', both)
    fat = root / 'fat'
    run('cc', '-arch', 'arm64', '-arch', 'x86_64', '-mmacosx-version-min=14.0', mainsrc, both, '-o', fat)
    verify(fat)
    run('lipo', both, '-thin', 'arm64', '-output', both)
    verify(fat, error='missing x86_64 slice')
    # package.sh's --arch per app slice: a thin tool in a universal app is refused.
    (root / 'plain.c').write_text('int main(void) { return 0; }\n')
    run('cc', '-arch', 'arm64', '-mmacosx-version-min=14.0', root / 'plain.c', '-o', root / 'thin')
    thin = subprocess.run([sys.executable, CHECK, '--arch', 'arm64', '--arch', 'x86_64', root / 'thin'],
                          capture_output=True, text=True)
    assert thin.returncode != 0 and 'missing x86_64 slice' in thin.stderr, thin
print('PASS: compatible closure, newer transitive library, external path, bundle relocation, missing dependency, weak imports, universal slices')


def check_helper(app):
    app = pathlib.Path(app)
    helper = app / 'Contents/MacOS/LightTouchDevice'
    assert helper.is_file() and helper.stat().st_mode & 0o111, f'missing executable {helper}'
    details = subprocess.run(['codesign', '-dvv', '--entitlements', ':-', helper], capture_output=True, text=True)
    assert details.returncode == 0, details.stderr
    for key in ('com.apple.security.cs.allow-jit', 'com.apple.security.cs.allow-unsigned-executable-memory',
                'com.apple.security.cs.disable-library-validation'):
        assert key in details.stdout, f'helper lacks entitlement {key}'
    flags = re.search(r'flags=0x([0-9a-fA-F]+)', details.stderr)
    assert flags and int(flags[1], 16) & 0x10000, 'helper lacks hardened runtime'
    assert 'Identifier=gold.samhenri.LightTouchMac.LightTouchDevice' in details.stderr, details.stderr
    subprocess.run(['codesign', '--verify', '--strict', helper], check=True)
    info = subprocess.run(['/usr/libexec/PlistBuddy', '-c', 'Print :LSMinimumSystemVersion', app / 'Contents/Info.plist'],
                          capture_output=True, text=True, check=True).stdout.strip()
    worker = app / 'Contents/MacOS/LightTouchServices'
    assert worker.is_file() and os.access(worker, os.X_OK), f'missing service worker {worker}'
    subprocess.run(['codesign', '--verify', '--strict', worker], check=True)
    worker_deps = subprocess.run(['otool', '-L', worker], capture_output=True, text=True, check=True).stdout
    assert 'libqemu' not in worker_deps, 'service worker must not load the emulator: ' + worker_deps
    # No request is sent: this proves the packaged process can launch/reap
    # without probing a real device or loading QEMU.
    socket = '127.0.0.1:1'
    empty = subprocess.run([worker, '--socket', socket, '--udid', '', '--session', str(uuid.uuid4())],
        input='', capture_output=True, text=True, timeout=10,
        env={**os.environ, 'USBMUXD_SOCKET_ADDRESS': socket})
    assert empty.returncode == 0 and not empty.stdout, empty
    inetcat = app / 'Contents/MacOS/inetcat'
    assert inetcat.is_file() and os.access(inetcat, os.X_OK), f'missing stock USB bridge {inetcat}'
    assert run(inetcat, '--version').returncode == 0
    dylib = app / 'Contents/Frameworks/libqemu-arm.dylib'
    closure = subprocess.run([sys.executable, CHECK, '--minos', info, '--bundle', app, helper, worker, inetcat, dylib],
                             capture_output=True, text=True)
    assert closure.returncode == 0, closure.stderr
    probe = subprocess.run([helper, '--probe', 'ipad1'], capture_output=True, text=True, timeout=60,
                           env={k: v for k, v in os.environ.items() if k != 'LTM_QEMU_DYLIB'})
    assert probe.returncode == 0, probe.stderr
    loaded = json.loads(probe.stdout)['dylibPath']
    assert pathlib.Path(loaded).resolve() == dylib.resolve(), f'helper loaded {loaded}, not the bundled {dylib}'
    # iPhone OS 1.x lockdownd is SSLv3 only: the bundled OpenSSL must be built enable-ssl3 enable-ssl3-method
    # (build-static-deps.sh); without it libimobiledevice-sslv3-ios1.patch asks for a protocol the library lacks.
    imd = app / 'Contents/Frameworks/libimobiledevice-1.0.dylib'
    assert '_SSLv3_client_method' in run('nm', '-gU', imd).stdout, f'{imd.name} links an OpenSSL without SSLv3'
    device = app / 'Contents/Resources/device'
    assets = ('bootrom_240_4', 'bootrom_s5l8900')  # the 2G's and 1G's SecureROMs; no prepared device ships
    assert all((device / name).is_file() for name in assets), f'missing device assets under {device}'
    stray = [p for p in device.rglob('*') if p.is_file() and p.name not in assets]
    assert not stray, f'unexpected device assets (a packed device, raw pages, iBoot?): {stray[:5]}'
    catalog = json.loads((app / 'Contents/Resources/firmware-catalog.json').read_text())
    first = next(e for e in catalog['entries'] if e['id'] == catalog['first_run'])
    assert first['status'] == 'available' and first['source']['url'].startswith('https://secure-appldnld.apple.com/'), first['id']
    print(f'PASS: {helper.name} signed (runtime, QEMU entitlements, minos {info}), closure in-bundle, loads {dylib.name} from Frameworks; SSLv3 in {imd.name}; SecureROMs only, first run {first["id"]} from Apple')

if len(sys.argv) > 1:
    check_helper(sys.argv[1])
