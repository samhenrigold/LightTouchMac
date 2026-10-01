#!/usr/bin/env python3
"""What a shipped bundle may not contain, and what it must carry for what it ships.

    tests/release/test-bundle-hygiene.py [PACKAGED.app]

Fails when:
  - a Mach-O in the bundle is not attributed to a component below (a new binary needs its licenses first);
  - a component a shipped binary contains has no license text in Contents/Resources/licenses/<dir>/;
  - a GPL or LGPL component (and libslirp) has no SOURCE.txt naming where its source is;
  - a Swift package either Package.resolved pins has no licenses/swift/<package>/ text;
  - Help.txt does not name every component;
  - any file names a local path (/Users/ or this Mac's home);
  - a host Mach-O still carries a debug map (it was not stripped) or a .dSYM ships;
  - the same Mach-O ships twice.
Without an app it runs the same checks on fixture bundles, each broken one way.
"""
import fnmatch
import hashlib
import json
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[2]
# component: (licenses/<dir>, the name Help.txt uses, needs SOURCE.txt)
COMPONENTS = {
    'qemu': ('qemu', 'QEMU', True),
    'usbmuxd': ('usbmuxd', 'usbmuxd', True),
    'inetcat': ('inetcat', 'inetcat', True),
    'libimobiledevice': ('libimobiledevice', 'libimobiledevice', True),
    'libimobiledevice-glue': ('libimobiledevice-glue', 'libimobiledevice-glue', True),
    'libusbmuxd': ('libusbmuxd', 'libusbmuxd', True),
    'libtatsu': ('libtatsu', 'libtatsu', True),
    'libplist': ('libplist', 'libplist', True),
    'glib': ('glib', 'GLib', True),
    'proxy-libintl': ('proxy-libintl', 'proxy-libintl', True),
    'ffmpeg': ('ffmpeg', 'FFmpeg', True),
    'iBoot32Patcher': ('iBoot32Patcher', 'iBoot32Patcher', True),
    'libslirp': ('libslirp', 'libslirp', True),
    'openssl': ('openssl', 'OpenSSL', False),
    'pcre2': ('pcre2', 'PCRE2', False),
    'pixman': ('pixman', 'pixman', False),
}
# Where each shipped Mach-O comes from (bundle-relative glob: the components linked into it). Light Touch's own
# binaries list only what they link in; their Swift packages are checked against the Package.resolved files.
BINARIES = {
    'Contents/MacOS/Light Touch': (),
    'Contents/MacOS/LightTouchDevice': (),
    'Contents/MacOS/LightTouchServices': (),
    'Contents/MacOS/inetcat': ('inetcat', 'libusbmuxd', 'libimobiledevice-glue', 'libplist'),
    'Contents/MacOS/firmwarekit': (),
    'Contents/MacOS/lockdown-tz': (),
    'Contents/MacOS/lockdown-mcinstall': (),
    'Contents/MacOS/ipod-helper': ('qemu',),
    'Contents/MacOS/usbmuxd': ('usbmuxd', 'glib', 'proxy-libintl', 'pcre2', 'libslirp', 'libimobiledevice-glue'),
    'Contents/MacOS/iBoot32Patcher': ('iBoot32Patcher',),
    'Contents/Frameworks/libqemu-arm.dylib': ('qemu', 'glib', 'proxy-libintl', 'pcre2', 'pixman', 'libslirp', 'openssl'),
    'Contents/Frameworks/libavcodec*.dylib': ('ffmpeg',),
    'Contents/Frameworks/libavutil*.dylib': ('ffmpeg',),
    'Contents/Frameworks/libimobiledevice-1.0*.dylib': ('libimobiledevice', 'openssl', 'libimobiledevice-glue', 'libusbmuxd', 'libtatsu'),
    'Contents/Frameworks/libplist-2.0*.dylib': ('libplist',),
    'Contents/Resources/guest-tools/*': ('qemu',),   # the guest tools: qemu-ios contrib, built for the guest
    'Contents/Resources/tools/*': ('qemu',),
}
LICENSE_TEXTS = ('LICENSE*', 'LICENCE*', 'COPYING*', 'COPYRIGHT*')
RESOLVED = (ROOT / 'LightTouchMac.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved',
            ROOT / 'Packages/FirmwareKit/Package.resolved')


def macho(path):
    with path.open('rb') as stream:
        return stream.read(4) in (b'\xcf\xfa\xed\xfe', b'\xce\xfa\xed\xfe', b'\xca\xfe\xba\xbe', b'\xbe\xba\xfe\xca')


def has_license(directory):
    return directory.is_dir() and any(p.is_file() and p.stat().st_size and any(fnmatch.fnmatch(p.name, g) for g in LICENSE_TEXTS)
                                      for p in directory.iterdir())


def swift_packages():
    return sorted({pin['identity'] for resolved in RESOLVED for pin in json.loads(resolved.read_text())['pins']})


def problems(app, packages):
    app = Path(app)
    licenses = app / 'Contents/Resources/licenses'
    found, needed, seen = [], set(), {}
    local = (b'/Users/', str(Path.home()).encode())
    for path in sorted(app.rglob('*')):
        name = str(path.relative_to(app))
        if path.is_dir() and path.suffix == '.dSYM':
            found.append(f'a dSYM ships: {name}')
        if path.is_symlink() or not path.is_file():
            continue
        data = path.read_bytes()
        if any(marker in data for marker in local):
            found.append(f'names a local path: {name}')
        if not macho(path):
            continue
        owners = [components for pattern, components in BINARIES.items() if fnmatch.fnmatch(name, pattern)]
        if not owners:
            found.append(f'unattributed Mach-O (add it to BINARIES with its licenses): {name}')
        needed.update(c for components in owners for c in components)
        digest = hashlib.sha256(data).hexdigest()
        if digest in seen:
            found.append(f'ships twice: {seen[digest]} and {name}')
        seen.setdefault(digest, name)
        if not name.startswith('Contents/Resources/'):   # host binaries; the guest tools are the guest's
            symbols = subprocess.run(['nm', '-ap', path], capture_output=True, text=True).stdout
            if ' OSO ' in symbols:
                found.append(f'not stripped (has a debug map): {name}')
    for component in sorted(needed):
        directory, _, copyleft = COMPONENTS[component]
        if not has_license(licenses / directory):
            found.append(f'no license text for {component} in licenses/{directory}/')
        source = licenses / directory / 'SOURCE.txt'
        if copyleft and not (source.is_file() and 'https://' in source.read_text()):
            found.append(f'no SOURCE.txt naming the source of {component} (licenses/{directory}/SOURCE.txt)')
    shipped = {p.name.lower(): p for p in (licenses / 'swift').iterdir()} if (licenses / 'swift').is_dir() else {}
    for package in packages:
        if not has_license(shipped.get(package.lower(), licenses / 'swift' / package)):
            found.append(f'no license text for the Swift package {package} (licenses/swift/{package}/)')
    help_text = (app / 'Contents/Resources/Help.txt').read_text() if (app / 'Contents/Resources/Help.txt').is_file() else ''
    for component in sorted(needed):
        if COMPONENTS[component][1] not in help_text:
            found.append(f'Help.txt does not name {COMPONENTS[component][1]}')
    return found


def self_test():
    with tempfile.TemporaryDirectory(prefix='ltm-hygiene-') as tmp:
        tmp = Path(tmp)
        (tmp / 'main.c').write_text('int main(void) { return 0; }\n')
        subprocess.run(['cc', '-g', '-c', tmp / 'main.c', '-o', tmp / 'main.o'], check=True)
        subprocess.run(['cc', tmp / 'main.o', '-o', tmp / 'debug'], check=True)
        shutil.copy(tmp / 'debug', tmp / 'stripped')
        subprocess.run(['strip', '-S', '-x', tmp / 'stripped'], check=True)
        stripped = (tmp / 'stripped').read_bytes()

        def bundle(label):
            app = tmp / f'{label}.app'
            for name, salt in (('Contents/MacOS/usbmuxd', b'u'), ('Contents/Frameworks/libplist-2.0.4.dylib', b'p'),
                               ('Contents/Resources/guest-tools/it_agent', b'a'), ('Contents/MacOS/inetcat', b'i'),
                               ('Contents/MacOS/LightTouchServices', b'w')):
                (app / name).parent.mkdir(parents=True, exist_ok=True)
                (app / name).write_bytes(stripped + salt)   # distinct contents, still a Mach-O
            licenses = app / 'Contents/Resources/licenses'
            for directory in ('usbmuxd', 'glib', 'proxy-libintl', 'pcre2', 'libslirp', 'libimobiledevice-glue', 'libplist', 'qemu', 'inetcat', 'libusbmuxd'):
                (licenses / directory).mkdir(parents=True)
                (licenses / directory / 'COPYING').write_text('license text')
                (licenses / directory / 'SOURCE.txt').write_text(f'{directory}: https://example.invalid/{directory}.tar.gz')
            (licenses / 'swift/Example').mkdir(parents=True)
            (licenses / 'swift/Example/LICENSE.txt').write_text('MIT')
            (app / 'Contents/Resources/Help.txt').write_text('Licenses: usbmuxd, GLib, proxy-libintl, PCRE2, libslirp, '
                                                             'libimobiledevice-glue, libplist, QEMU, inetcat, libusbmuxd')
            return app

        def expect(app, text):
            found = problems(app, ['example'])
            assert any(text in line for line in found), f'{app.name}: expected “{text}”, got {found}'
            return found

        good = bundle('good')
        assert problems(good, ['example']) == [], problems(good, ['example'])
        broken = bundle('no-license')
        (broken / 'Contents/Resources/licenses/libslirp/COPYING').unlink()
        expect(broken, 'no license text for libslirp')
        broken = bundle('no-source')
        (broken / 'Contents/Resources/licenses/glib/SOURCE.txt').unlink()
        expect(broken, 'no SOURCE.txt naming the source of glib')
        broken = bundle('local-path')
        (broken / 'Contents/Resources/build-inputs.json').write_text('{"path": "/Users/someone/Developer/qemu-ios"}')
        expect(broken, 'names a local path: Contents/Resources/build-inputs.json')
        broken = bundle('unattributed')
        (broken / 'Contents/MacOS/newtool').write_bytes(stripped + b'n')
        expect(broken, 'unattributed Mach-O (add it to BINARIES with its licenses): Contents/MacOS/newtool')
        broken = bundle('unstripped')
        shutil.copy(tmp / 'debug', broken / 'Contents/MacOS/usbmuxd')
        expect(broken, 'not stripped (has a debug map): Contents/MacOS/usbmuxd')
        broken = bundle('dsym')
        (broken / 'Contents/Resources/usbmuxd.dSYM/Contents').mkdir(parents=True)
        expect(broken, 'a dSYM ships')
        broken = bundle('twice')
        (broken / 'Contents/Resources/tools').mkdir(parents=True)
        shutil.copy(broken / 'Contents/Resources/guest-tools/it_agent', broken / 'Contents/Resources/tools/it_agent')
        expect(broken, 'ships twice: Contents/Resources/guest-tools/it_agent and Contents/Resources/tools/it_agent')
        broken = bundle('swift')
        shutil.rmtree(broken / 'Contents/Resources/licenses/swift/Example')
        expect(broken, 'no license text for the Swift package example')
        broken = bundle('help')
        (broken / 'Contents/Resources/Help.txt').write_text('Licenses: usbmuxd')
        expect(broken, 'Help.txt does not name GLib')
    print('PASS: fixture bundles: complete passes; missing license, SOURCE.txt, Swift package license, Help entry, '
          'local path, unattributed binary, unstripped binary, dSYM and duplicate each fail')


if __name__ == '__main__':
    if len(sys.argv) > 1:
        found = problems(sys.argv[1], swift_packages())
        for line in found:
            print('FAIL:', line)
        if found:
            sys.exit(1)
        print(f'PASS: {sys.argv[1]}: every shipped binary attributed and licensed, sources named, no local paths, stripped, no duplicates')
    else:
        self_test()
