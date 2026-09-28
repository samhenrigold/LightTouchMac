#!/usr/bin/env python3
"""Build a self-contained Light Touch app with the existing bundled firmware."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import shlex
import shutil
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]
SCRIPTS = ROOT / 'scripts'
GUEST_PAYLOADS = frozenset(('MBXGLEngine', 'sbdlicon', 'ithalt', 'it_agent', 'it_typein.dylib',
                          'com.qemu.it-agent.plist', 'itstatus', 'itmedia', 'itphoto',
                          'itproxy', 'ittrust', 'itorient'))
GUEST_COMPONENTS = ('armv6-toolchain', 'it-gles', 'it-instprogress', 'it-halt', 'it-agent',
                    'it-status', 'it-media', 'it-proxy', 'it-orientation')
# firmwarekit's --guest-tools set (SystemEdits.Helpers + it_keybag), from checkouts with the iPad helpers.
IPAD_GUEST_PAYLOADS = frozenset(('it_pbd', 'it_ethlink', 'it_prefs', 'it_msmquiet.dylib', 'it_seal', 'it_keybag',
                                 'libappsync.dylib', 'com.qemu.it-pbd.plist', 'com.qemu.it-ethlink.plist',
                                 'com.qemu.it-prefs.plist', 'com.qemu.it-seal.plist', 'GLEngine-7B500',
                                 'gli-dispatch-7B500.tsv', 'GLEngine-8C148', 'gli-dispatch-8C148.tsv',
                                 'GLRendererFloatQEMU', 'armv6.itpack', 'armv7.itpack',
                                 # the n72 recipe's (N72Recipe)
                                 'MBXGLEngine', 'sblaunch', 'sbdlicon', 'it_agent', 'it_typein.dylib',
                                 'com.qemu.it-agent.plist', 'gli-dispatch-7E18.tsv'))
IPAD_GUEST_COMPONENTS = ('ipad1-guest', 'appsync', 'ipad1-gles', 'it-pasteboard', 'it-ethlink', 'it-seal', 'it-prefs',
                         'it-keybag', 'it-heading', 'it-cctest', 'it-gltest', 'it-msmquiet', 'it-boot', 'guest-package')
SOURCE_EXCLUSIONS = {'.git', '.build', 'dist', '__pycache__', 'xcuserdata', '.DS_Store'}
NATIVE_RECIPES = frozenset(('scripts/build-package-native.sh', 'scripts/build-static-deps.sh',
                           'scripts/dependency-sources.py', 'build-support/dependencies.json',
                           'build-support/patches/glib-pipe2-availability.patch',
                           'scripts/test-glib-compat.py', 'scripts/check-macho.py'))
FFMPEG_PATCHES = ('h264-chunk-er.patch', 'h264-cavlc-pcm-offset.patch')
# Resumable pipeline (--stage); each step fits a 10-minute tool limit and skips when current.
STAGES = ('native', 'qemu', 'dylib', 'guest', 'app', 'package', 'notarize', 'staple', 'verify')


def digest(path):
    value = hashlib.sha256()
    with Path(path).open('rb') as source:
        for chunk in iter(lambda: source.read(1024 * 1024), b''):
            value.update(chunk)
    return value.hexdigest()


def source_identity(root):
    """Identify working sources too: local uncommitted work is never hidden."""
    root = Path(root)
    probe = subprocess.run(['git', '-C', str(root), 'rev-parse', '--show-toplevel'],
                           capture_output=True, text=True)
    revision = None
    gitlinks = {}
    submodules = {}
    if probe.returncode == 0 and Path(probe.stdout.strip()).resolve() == root.resolve():
        revision = subprocess.check_output(['git', '-C', str(root), 'rev-parse', 'HEAD'], text=True).strip()
        names = subprocess.check_output(['git', '-C', str(root), 'ls-files', '-z',
                                         '--cached', '--others', '--exclude-standard']).decode().split('\0')
        dirty = bool(subprocess.check_output(['git', '-C', str(root), 'status', '--porcelain']))
        staged = subprocess.check_output(['git', '-C', str(root), 'ls-files', '--stage', '-z']).decode()
        for entry in staged.split('\0'):
            if not entry:
                continue
            metadata, name = entry.split('\t', 1)
            mode, commit, stage = metadata.split()
            if mode == '160000':
                gitlinks[name] = {'mode': mode, 'recorded_revision': commit}
    else:
        # Supports reviewing a source-only staging tree; never report it clean.
        names = [str(p.relative_to(root)) for p in root.rglob('*') if p.is_file()]
        dirty = True
    aggregate = hashlib.sha256()
    count = 0
    for name in sorted(set(names)):
        if not name or any(part in SOURCE_EXCLUSIONS
                           for part in Path(name).parts):
            continue
        path = root / name
        if name in gitlinks:
            module = {**gitlinks[name], 'initialized': (path / '.git').exists()}
            if module['initialized']:
                module['source'] = source_identity(path)
            submodules[name] = module
            content = hashlib.sha256(json.dumps(module, sort_keys=True).encode()).hexdigest()
        elif path.is_symlink():
            content = hashlib.sha256(os.readlink(path).encode()).hexdigest()
        elif path.is_file():
            content = digest(path)
        else:
            continue
        mode = str(path.stat().st_mode & 0o111) if path.exists() else 'missing'
        aggregate.update(name.encode() + b'\0' + content.encode() + b'\0' + mode.encode() + b'\0')
        count += 1
    return {'revision': revision, 'dirty': dirty, 'source_sha256': aggregate.hexdigest(),
            'files': count, 'submodules': submodules}


def read_record(path, schema_key='schema_version'):
    require(path, 'build provenance record')
    try:
        value = json.loads(path.read_text())
    except (json.JSONDecodeError, UnicodeError) as error:
        raise ValueError(f'Invalid build record: {path}: {error}') from error
    if not isinstance(value, dict) or value.get(schema_key) != 1:
        raise ValueError(f'Unsupported build record: {path}')
    return value


def hashes(entries, description):
    result = {}
    if not isinstance(entries, list) or not entries:
        raise ValueError(f'Missing {description} inventory')
    for entry in entries:
        if not isinstance(entry, dict):
            raise ValueError(f'Invalid {description} entry: {entry}')
        name, checksum = entry.get('path'), entry.get('sha256')
        if (not isinstance(name, str) or not name or Path(name).is_absolute()
                or '..' in Path(name).parts or name in result
                or not isinstance(checksum, str) or not re.fullmatch('[0-9a-f]{64}', checksum)):
            raise ValueError(f'Invalid or duplicate {description} entry: {entry}')
        result[name] = checksum
    return result


def verify_hashes(root, expected, description):
    for name, checksum in expected.items():
        path = root / name
        require(path, description)
        if digest(path) != checksum:
            raise ValueError(f'{description} differs from its build record: {path}')


def has_ipad_guest(qemu):
    return (qemu / 'contrib/ipad1-guest/build.sh').is_file()


def guest_source_hashes(qemu):
    selected = {}
    ipad = IPAD_GUEST_COMPONENTS if has_ipad_guest(qemu) else ()
    for component in (*GUEST_COMPONENTS, *ipad):
        directory = qemu / 'contrib' / component
        require(directory, f'guest source component {component}', directory=True)
        for path in directory.iterdir():
            if (path.is_file() and path.name not in ('gles_stubs.h', 'gli_fwd.h')
                    and path.suffix in ('.c', '.h', '.sh', '.py', '.xml', '.plist', '.entitlements', '.txt')):
                selected[str(path.relative_to(qemu))] = digest(path)
    if ipad:
        for path in (qemu / 'docs/ipad1').glob('gli-dispatch-*.tsv'):
            selected[str(path.relative_to(qemu))] = digest(path)
    return selected


def validate_guest(args, guest):
    record = read_record(guest.parent / 'guest-tools.json', 'schema')
    if record.get('builder', {}).get('sha256') != digest(SCRIPTS / 'build-guest-tools.sh'):
        raise ValueError('Guest build recipe has changed; rebuild guest tools')
    if Path(record.get('qemu_source', '')).resolve() != args.qemu_source:
        raise ValueError('Guest tools were built from a different QEMU checkout')
    expected = hashes(record.get('outputs'), 'guest payload')
    if set(expected) != GUEST_PAYLOADS:
        raise ValueError('Guest build record must declare exactly the 12 required payloads')
    require(guest, 'guest tools directory', directory=True)
    if {path.name for path in guest.iterdir()} != GUEST_PAYLOADS:
        raise ValueError('Guest tools directory must contain exactly the 12 required payloads')
    verify_hashes(guest, expected, 'Guest payload')
    ipad = guest.parent / 'ipad-guest-tools'
    if has_ipad_guest(args.qemu_source):
        expected = hashes(record.get('ipad_outputs'), 'iPad guest payload')
        require(ipad, 'iPad guest tools directory', directory=True)
        if set(expected) != IPAD_GUEST_PAYLOADS or {path.name for path in ipad.iterdir()} != IPAD_GUEST_PAYLOADS:
            raise ValueError(f'iPad guest tools must be exactly: {", ".join(sorted(IPAD_GUEST_PAYLOADS))}')
        verify_hashes(ipad, expected, 'iPad guest payload')
    elif ipad.exists():
        raise ValueError('iPad guest tools built from a checkout without contrib/ipad1-guest')
    if hashes(record.get('source_inputs'), 'guest source') != guest_source_hashes(args.qemu_source):
        raise ValueError('Guest source inputs have changed; rebuild guest tools')
    return record


def tracked_usbmuxd(source):
    def git(*args):
        return subprocess.check_output(['git', '-C', str(source), *args])
    untracked = git('ls-files', '--others', '--exclude-standard', '-z').decode().split('\0')
    if any(name and Path(name).name != '.DS_Store' for name in untracked):
        raise ValueError('usbmuxd has untracked source files; add them to Git and rebuild native dependencies')
    files = []
    for name in sorted(set(git('ls-files', '-z').decode().split('\0'))):
        if not name or Path(name).name == '.DS_Store':
            continue
        path = source / name
        if path.is_file():
            files.append({'path': name, 'sha256': digest(path), 'executable': bool(path.stat().st_mode & 0o111)})
    return {
        'commit': git('rev-parse', 'HEAD').decode().strip(),
        'tracked_diff_sha256': hashlib.sha256(git('diff', '--binary', 'HEAD', '--', '.', ':(exclude).DS_Store')).hexdigest(),
        'files': files,
    }


def validate_native(args, root, deps_only=False):
    """deps_only: reuse the prefix, static deps and usbmuxd; QEMU is built elsewhere."""
    native = read_record(root / 'native-build.json')
    if not deps_only and Path(native.get('qemu_source', '')).resolve() != args.qemu_source:
        raise ValueError('Native build was configured for a different QEMU checkout')
    if Path(native.get('usbmuxd_source', '')).resolve() != args.usbmuxd_source:
        raise ValueError('Native build used a different usbmuxd checkout')
    static = Path(native.get('static_deps', '')).resolve()
    if args.static_deps and args.static_deps != static:
        raise ValueError('--static-deps differs from the prefix configured into the native build')
    if set(native.get('recipes', {})) != NATIVE_RECIPES:
        raise ValueError('Native build has incomplete recipe provenance; rebuild native dependencies')
    verify_hashes(ROOT, hashes([{'path': name, 'sha256': checksum}
                               for name, checksum in native['recipes'].items()], 'native recipe'), 'Native recipe')
    previous = native.get('usbmuxd', {})
    current = tracked_usbmuxd(args.usbmuxd_source)
    if any(previous.get(name) != value for name, value in current.items()):
        raise ValueError('usbmuxd source has changed since the native build; rebuild native dependencies')
    static_inputs = hashes(native.get('static_inputs'), 'static input')
    if {str(path.relative_to(static)) for path in static.rglob('*') if path.is_file()} != set(static_inputs):
        raise ValueError('Static prefix file inventory differs from its native build record')
    verify_hashes(static, static_inputs, 'Static input')
    for name in FFMPEG_PATCHES:
        current_patch = args.qemu_source / 'contrib/ffmpeg' / name
        built_patch = root / 'prefix/share/licenses/ffmpeg' / name
        require(current_patch, 'current FFmpeg patch')
        require(built_patch, 'preserved FFmpeg build patch')
        if digest(current_patch) != digest(built_patch):
            raise ValueError(f'FFmpeg patch has changed since the native build: {name}; rebuild native dependencies')
    qemu_outputs = () if deps_only else ((root / 'qemu-build/build.ninja', 'configured native QEMU build'),
                                         (root / 'qemu-build/libqemu-arm.dylib', 'QEMU library'))
    for path, label in (*qemu_outputs,
                        (root / 'prefix/lib/libimobiledevice-1.0.dylib', 'native device library'),
                        (root / 'prefix/lib/libplist-2.0.dylib', 'native plist library'),
                        (root / 'build/usbmuxd/src/usbmuxd', 'native usbmuxd')):
        require(path, label)
    return native


def validate_output(args):
    if not args.stage and (args.output.exists() or args.output.is_symlink()):
        raise ValueError(f'Output already exists: {args.output}; choose a new directory')
    for source in (ROOT, args.qemu_source, args.usbmuxd_source):
        source = source.resolve()
        if not args.output.is_relative_to(source):
            continue
        relative = args.output.relative_to(source)
        if '.git' in relative.parts:
            raise ValueError('Output must not be inside Git metadata')
        ignored = subprocess.run(['git', '-C', str(source), 'check-ignore', '--quiet', '--no-index',
                                  '--', str(relative) + '/'], capture_output=True).returncode == 0
        if not ignored and not any(part in SOURCE_EXCLUSIONS - {'.git', '.DS_Store'} for part in relative.parts):
            raise ValueError(f'Output inside source checkout must be Git-ignored: {args.output}')
    for name in ('assets', 'sdk', 'native_build', 'static_deps', 'guest_tools', 'source_packages', 'native_deps'):
        selected = getattr(args, name)
        if selected and args.output.is_relative_to(selected):
            raise ValueError(f'Output must be outside the {name.replace("_", " ")} input: {args.output}')


def copy_provenance(output, native_record, guest_record):
    copies = {}
    for name, source in (('native-build.json', native_record), ('guest-tools.json', guest_record)):
        destination = output / name
        shutil.copyfile(source, destination)
        copies[name] = digest(destination)
    return copies


def run(command, env, log, cwd=None):
    command = list(map(str, command))
    print('+ ' + shlex.join(command), flush=True)
    with log.open('ab') as output:
        output.write(('\n+ ' + shlex.join(command) + '\n').encode())
        output.flush()
        result = subprocess.run(command, env=env, stdout=output, stderr=subprocess.STDOUT, cwd=cwd)
    if result.returncode:
        raise RuntimeError(f'Command failed ({result.returncode}); see {log}')


def require(path, description, directory=False):
    if not (path.is_dir() if directory else path.is_file()):
        raise ValueError(f'Missing {description}: {path}')


def parse(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', required=True, type=Path, help='New output directory; existing directories are never overwritten')
    parser.add_argument('--qemu-source', '--qemu-ios', type=Path, default=Path(os.environ.get('QEMU_IOS_DIR', ROOT.parent / 'qemu-ios')))
    parser.add_argument('--usbmuxd-source', type=Path, default=Path(os.environ.get('USBMUXD_SOURCE_DIR', ROOT.parent / 'usbmuxd-qemu/usbmuxd')))
    parser.add_argument('--assets', type=Path, default=Path(os.environ.get('LTM_ASSETS', ROOT.parent / 'qemu-ios-files')))
    parser.add_argument('--nand', default=os.environ.get('LTM_NAND'), help='Exact local NAND directory name (default: the target of <assets>/nand-current)')
    parser.add_argument('--sdk', type=Path, default=Path(os.environ['ARMV6_SDK']) if 'ARMV6_SDK' in os.environ else None,
                        help='Locally installed iPhoneOS3.1.3.sdk used to build guest helpers')
    parser.add_argument('--native-build', type=Path, help='Reuse a native build root; rebuild its QEMU before packaging')
    parser.add_argument('--static-deps', type=Path, help='Explicit compatible static prefix; otherwise build it from the pinned recipe')
    parser.add_argument('--guest-tools', type=Path, help='Reuse a guest-tools directory produced by build-guest-tools.sh')
    parser.add_argument('--source-packages', type=Path, help='Optional Xcode SourcePackages cache')
    parser.add_argument('--sign-id', default=os.environ.get('SIGN_ID', '-'), help='Signing identity; defaults to ad-hoc')
    parser.add_argument('--notary-profile', default=os.environ.get('NOTARY_PROFILE'), help='Optional notarytool keychain profile')
    parser.add_argument('--stage', action='append', choices=(*STAGES, 'all'),
                        help='Run the resumable staged build (repeatable, run in pipeline order; see "Multi-device release build" in docs/multi-device-plan.md). '
                             'Without it, the one-step build runs; --output may then not exist.')
    parser.add_argument('--native-deps', type=Path, help='Staged: native root whose prefix, static deps and usbmuxd are reused '
                        '(e.g. a previous release output\'s native/)')
    parser.add_argument('--qemu-build', type=Path, help='Staged: private QEMU build directory (default <qemu-source>/build-release-native)')
    parser.add_argument('--verify-ipsw', type=Path,
                        default=Path.home() / 'Downloads/ipad1-ios32-feasibility/iPad1,1_3.2.2_7B500_Restore.ipsw',
                        help=f'Staged verify: the {PREPARE_ENTRY} IPSW the bundled firmwarekit prepares')
    parser.add_argument('--plan', action='store_true', help='Validate inputs and print selected paths without building or writing')
    args = parser.parse_args(argv)
    if args.output.expanduser().is_symlink():
        parser.error(f'Output must not be a symlink: {args.output}')
    for name in ('output', 'qemu_source', 'usbmuxd_source', 'assets', 'sdk', 'native_build', 'static_deps', 'guest_tools',
                 'source_packages', 'native_deps', 'qemu_build', 'verify_ipsw'):
        value = getattr(args, name)
        if value is not None:
            setattr(args, name, value.expanduser().resolve())
    if args.stage:
        if not args.native_deps:
            parser.error('--stage requires --native-deps (a native root to reuse)')
        if args.native_build or args.guest_tools or args.static_deps:
            parser.error('--stage builds its own QEMU and guest tools; use --native-deps and --qemu-build')
        args.qemu_build = args.qemu_build or args.qemu_source / 'build-release-native'
    elif args.output.exists():
        parser.error(f'Output already exists: {args.output}; choose a new directory')
    if not args.nand and (args.assets / 'nand-current').is_symlink():
        args.nand = Path(os.readlink(args.assets / 'nand-current')).name
    if not args.nand or Path(args.nand).name != args.nand or args.nand in ('.', '..'):
        parser.error('--nand must be a directory name within --assets')
    if args.notary_profile and args.sign_id == '-':
        parser.error('--notary-profile requires a Developer ID --sign-id')
    return args


def validate(args):
    require(args.qemu_source / 'configure', 'QEMU checkout')
    require(args.usbmuxd_source / 'configure.ac', 'usbmuxd source checkout')
    for name in ('bootrom_240_4', 'ios3/iBoot.bin', 'ios3/nor_7E18.bin'):
        require(args.assets / name, 'bundled firmware input')
    require(args.assets / args.nand, 'selected NAND', directory=True)
    validate_output(args)
    if args.guest_tools:
        validate_guest(args, args.guest_tools)
    elif args.sdk is None:
        raise ValueError('Pass --sdk /path/to/iPhoneOS3.1.3.sdk (or ARMV6_SDK) to build guest helpers')
    else:
        for name in ('usr/lib/libSystem.dylib', 'usr/include/stdio.h'):
            require(args.sdk / name, 'legacy SDK input')
    if args.static_deps:
        require(args.static_deps / 'lib/libcrypto.a', 'static OpenSSL')
    if args.native_build:
        validate_native(args, args.native_build)


def inventory(app):
    result = []
    for path in sorted(app.rglob('*')):
        name = str(path.relative_to(app))
        if path.is_symlink():
            result.append({'path': name, 'symlink': os.readlink(path)})
        elif path.is_file():
            result.append({'path': name, 'bytes': path.stat().st_size, 'sha256': digest(path)})
    return result


def build_app(args, env, log, qemu_build):
    derived = args.output / 'DerivedData'
    command = ['xcodebuild', '-project', ROOT / 'LightTouchMac.xcodeproj', '-scheme', 'LightTouchMac',
               '-configuration', 'Release', '-derivedDataPath', derived, '-disableAutomaticPackageResolution',
               '-onlyUsePackageVersionsFromResolvedFile', 'CODE_SIGNING_ALLOWED=NO', 'ARCHS=arm64',
               f'QEMU_IOS_DIR={args.qemu_source}', f'QEMU_BUILD_DIR={qemu_build}', 'build']
    if args.source_packages:
        command[1:1] = ['-clonedSourcePackagesDirPath', args.source_packages]
    run(command, env, log)
    products = derived / 'Build/Products/Release'
    apps = [p for p in products.glob('*.app') if (p / 'Contents/Info.plist').is_file()]
    if len(apps) != 1:
        raise ValueError(f'Expected one Release app in {products}, found {len(apps)}')
    return apps[0]


def write_build_record(args, sources, native_root, qemu_build, guest):
    provenance = copy_provenance(args.output, native_root / 'native-build.json', guest.parent / 'guest-tools.json')
    record = {
        'schema_version': 1, 'sources': sources, 'host_architecture': 'arm64',
        'firmware': {'nand_name': args.nand, 'components': {
            name: digest(args.assets / name) for name in ('bootrom_240_4', 'ios3/iBoot.bin', 'ios3/nor_7E18.bin')}},
        'native_build_record_sha256': provenance['native-build.json'],
        'native_build_reused': bool(args.native_build or args.native_deps),
        'qemu_rebuilt_from_sources': sources['qemu'],
        'guest_build_record_sha256': provenance['guest-tools.json'],
        'provenance_records': provenance,
        'qemu_build': str(qemu_build),
        'native_artifacts': {
            'prefix': inventory(native_root / 'prefix'),
            'qemu_library_sha256': digest(qemu_build / 'libqemu-arm.dylib'),
            'usbmuxd_sha256': digest(native_root / 'build/usbmuxd/src/usbmuxd'),
        },
        'swift_packages': json.loads((ROOT / 'LightTouchMac.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved').read_text()),
        'xcode': subprocess.check_output(['xcodebuild', '-version'], text=True).strip(),
        'macos_sdk': subprocess.check_output(['xcrun', '--sdk', 'macosx', '--show-sdk-version'], text=True).strip(),
    }
    build_record = args.output / 'build-inputs.json'
    build_record.write_text(json.dumps(record, indent=2) + '\n')
    return build_record


def sources_now(args):
    return {'app': source_identity(ROOT), 'qemu': source_identity(args.qemu_source),
            'usbmuxd': source_identity(args.usbmuxd_source)}


def tree_stamp(*paths):
    """Cheap change detector (path, size, mtime) for stage outputs; not provenance."""
    value = hashlib.sha256()
    for root in paths:
        root = Path(root)
        for path in sorted([root, *root.rglob('*')] if root.is_dir() else [root]):
            if path.is_file() and not path.is_symlink():
                stat = path.stat()
                value.update(f'{path}\0{stat.st_size}\0{stat.st_mtime_ns}\0'.encode())
    return value.hexdigest()


def notarize(args, env, log, state, app):
    stamp = tree_stamp(app)
    record = state.get('notarize', {})
    if record.get('app') == stamp and record.get('status') == 'Accepted':
        return print(f'notarize: current (submission {record["id"]} Accepted)')
    if record.get('app') != stamp:
        archive = args.output / 'notarize.zip'
        run(['ditto', '-c', '-k', '--keepParent', app, archive], env, log)
        submitted = json.loads(subprocess.check_output(
            ['xcrun', 'notarytool', 'submit', archive, '--keychain-profile', args.notary_profile,
             '--output-format', 'json'], text=True))
        record = state['notarize'] = {'app': stamp, 'id': submitted['id'], 'status': 'In Progress'}
        save_state(args, state)
        print(f'notarize: submitted {record["id"]}', flush=True)
    # Waits at most 9 minutes; rerun the stage to keep waiting on the same submission.
    subprocess.run(['xcrun', 'notarytool', 'wait', record['id'], '--keychain-profile', args.notary_profile,
                    '--timeout', '9m'], stdout=subprocess.DEVNULL)
    info = json.loads(subprocess.check_output(['xcrun', 'notarytool', 'info', record['id'], '--keychain-profile',
                                               args.notary_profile, '--output-format', 'json'], text=True))
    record['status'] = info['status']
    save_state(args, state)
    print(f'notarize: {record["id"]} {record["status"]}', flush=True)
    if record['status'] == 'In Progress':
        raise RuntimeError('Notarization still in progress; rerun --stage notarize')
    if record['status'] != 'Accepted':
        with (args.output / 'notary-log.json').open('w') as output:
            subprocess.run(['xcrun', 'notarytool', 'log', record['id'], '--keychain-profile', args.notary_profile],
                           stdout=output)
        raise RuntimeError(f'Notarization {record["status"]}; see {args.output / "notary-log.json"}')
    (args.output / 'notarize.zip').unlink(missing_ok=True)


PREPARE_ENTRY = 'k48ap-7B500'


def check_prepare(args, log, state, app):
    """Run the bundled firmwarekit as the app does: bundled --guest-tools default, bundled helper."""
    stamp = tree_stamp(app)
    if state.get('verify', {}).get('prepare') == stamp:
        return print(f'verify: in-bundle prepare of {PREPARE_ENTRY} current')
    require(args.verify_ipsw, f'{PREPARE_ENTRY} IPSW for the in-bundle prepare check (--verify-ipsw)')
    catalog = json.loads((app / 'Contents/Resources/firmware-catalog.json').read_text())
    entry = next(e for e in catalog['entries'] if e['id'] == PREPARE_ENTRY)
    work = args.output / 'prepare-check'

    def clean():
        if work.exists():
            subprocess.run(['chmod', '-R', 'u+w', work], check=True)
            shutil.rmtree(work)
    clean()
    (work / 'out').mkdir(parents=True)
    try:
        (work / 'entry.json').write_text(json.dumps(entry))
        command = [app / 'Contents/MacOS/firmwarekit', 'create', '--entry', work / 'entry.json', '--ipsw', args.verify_ipsw,
                   '--out', work / 'out', '--cache', work / 'cache', '--helper', app / 'Contents/MacOS/LightTouchDevice']
        print('+ ' + shlex.join(map(str, command)), flush=True)
        clean_env = {k: v for k, v in os.environ.items() if not k.startswith('LTM_')}
        with log.open('ab') as output:
            result = subprocess.run(list(map(str, command)), stdout=subprocess.PIPE, stderr=output,
                                    env=clean_env, timeout=480)
        events = [json.loads(line) for line in result.stdout.decode().splitlines() if line.strip()]
        with log.open('a') as output:
            output.write(''.join(json.dumps(e) + '\n' for e in events))
        for e in events:
            if e['event'] in ('step', 'warning', 'error', 'done'):
                print('  firmwarekit: ' + json.dumps(e), flush=True)
        if result.returncode or not events or events[-1]['event'] != 'done':
            raise RuntimeError(f'In-bundle prepare of {PREPARE_ENTRY} failed ({result.returncode}); see {log}')
        lock = json.loads((work / 'out' / events[-1]['lock']).read_text())
        bundled = str((app / 'Contents/Resources/guest-tools').resolve())
        if bundled not in json.dumps(lock):
            raise RuntimeError(f'Prepare did not use the bundled guest tools {bundled}')
    finally:
        clean()
    state.setdefault('verify', {})['prepare'] = stamp
    save_state(args, state)


def save_state(args, state):
    (args.output / 'stages.json').write_text(json.dumps(state, indent=2) + '\n')


def native_stage(args, env, log, deps, root, static):
    """Reuse deps' prefix and static deps (they need over 10 minutes to build); rebuild usbmuxd
    from the current fork, as build-package-native.sh does, whenever its source changed."""
    record = read_record(deps / 'native-build.json')
    current = tracked_usbmuxd(args.usbmuxd_source)
    if (root / 'native-build.json').is_file():
        try:
            validate_native(args, root, deps_only=True)
            return print('native: current')
        except ValueError as error:
            print(f'native: rebuilding ({error})')
    shutil.rmtree(root, ignore_errors=True)
    (root / 'build').mkdir(parents=True)
    (root / 'prefix').symlink_to(deps / 'prefix')
    usb = root / 'build/usbmuxd'
    run([sys.executable, SCRIPTS / 'dependency-sources.py', 'stage-git', '--source', args.usbmuxd_source,
         '--destination', usb, '--record', root / 'usbmuxd-source.json'], env, log)
    (usb / '.tarball-version').write_text(subprocess.check_output(
        ['git', '-C', args.usbmuxd_source, 'describe', '--tags', '--always', '--dirty'], text=True))
    flags = '-O2 -mmacosx-version-min=14.0'
    build_env = {key: value for key, value in env.items()
                 if key not in ('CPATH', 'C_INCLUDE_PATH', 'CPLUS_INCLUDE_PATH', 'LIBRARY_PATH')}
    build_env.update(MACOSX_DEPLOYMENT_TARGET='14.0', CFLAGS=flags, CXXFLAGS=flags, CC='/usr/bin/clang',
                     CXX='/usr/bin/clang++', lt_cv_sys_max_cmd_len='131072', PKG_CONFIG_PATH='',
                     PKG_CONFIG_LIBDIR=f'{deps / "prefix/lib/pkgconfig"}:{static / "lib/pkgconfig"}',
                     LDFLAGS='-mmacosx-version-min=14.0 -framework IOKit -framework CoreFoundation -framework Security')
    run(['sh', '-c', 'glibtoolize --copy --force && autoreconf -fi'], build_env, log, cwd=usb)
    run(['./configure', f'--prefix={deps / "prefix"}', '--without-systemd'], build_env, log, cwd=usb)
    run(['make', f'-j{os.cpu_count()}'], build_env, log, cwd=usb)
    if 'HAVE_LIBSLIRP 1' not in (usb / 'config.h').read_text():
        raise RuntimeError('usbmuxd configured without libslirp; the iPad USB Ethernet bridge would be missing')
    run([sys.executable, SCRIPTS / 'check-macho.py', '--no-weak-imports', usb / 'src/usbmuxd'], env, log)
    record.update(usbmuxd=json.loads((root / 'usbmuxd-source.json').read_text()), usbmuxd_source=str(args.usbmuxd_source),
                  usbmuxd_binary=str(usb / 'src/usbmuxd'), deps_prefix=str(root / 'prefix'),
                  qemu_source=str(args.qemu_source), qemu_build=str(args.qemu_build),
                  reused_native_deps=str(deps), usbmuxd_rebuilt_by='build-release.py --stage native')
    (root / 'native-build.json').write_text(json.dumps(record, indent=2) + '\n')
    validate_native(args, root, deps_only=True)
    assert current == tracked_usbmuxd(args.usbmuxd_source), 'usbmuxd source changed during the build'


def staged(args, env, log):
    state_path = args.output / 'stages.json'
    state = json.loads(state_path.read_text()) if state_path.is_file() else {}
    selected = set(STAGES if 'all' in args.stage else args.stage)
    env.pop('NOTARY_PROFILE', None)  # notarize and staple are their own stages
    deps, build, native_root = args.native_deps, args.qemu_build, args.output / 'native'
    static = Path(read_record(deps / 'native-build.json')['static_deps']).resolve()
    prefix = native_root / 'prefix'
    guest = args.output / 'guest/guest-tools'
    firmwarekit = args.output / 'firmwarekit/release/firmwarekit'
    env.update(QEMU_BUILD_DIR=str(build), LTM_DEPS_PREFIX=str(prefix), LTM_STATIC_DEPS=str(static),
               USBMUXD_BIN=str(native_root / 'build/usbmuxd/src/usbmuxd'), LTM_GUEST_TOOLS_DIR=str(guest),
               PKG_CONFIG_LIBDIR=str(prefix / 'lib/pkgconfig'), PKG_CONFIG_PATH='')
    products = args.output / 'DerivedData/Build/Products/Release'
    app = Path(state.get('package', {}).get('app', ''))

    def need(stage):
        if stage in selected:
            print(f'== {stage}', flush=True)
            return True
        return False

    if need('native'):
        native_stage(args, env, log, deps, native_root, static)
        state['native'] = {'deps': str(deps)}
        save_state(args, state)
    elif state.get('native', {}).get('deps') != str(deps):
        raise ValueError('Run --stage native for this --native-deps first')
    if need('qemu'):
        configured = (build / 'config.log').read_text(errors='replace') if (build / 'config.log').is_file() else ''
        line = next((l for l in configured.splitlines() if l.startswith('# Configured with:')), '')
        if line and (str(args.qemu_source / 'configure') not in line or str(static) not in line):
            raise ValueError(f'{build} was configured for another source or static prefix; choose a new --qemu-build')
        if not (build / 'build.ninja').is_file():
            build.mkdir(parents=True, exist_ok=True)
            run([args.qemu_source / 'configure', '--target-list=arm-softmmu', '--without-default-features',
                 '--enable-cocoa', '--enable-coreaudio', '--enable-pixman', '--enable-slirp', '--disable-pie',
                 f'--python={os.environ.get("QEMU_PYTHON", "python3.12")}',
                 f'--extra-cflags=-I{static}/include -mmacosx-version-min=14.0',
                 f'--extra-ldflags=-L{static}/lib -lcrypto -mmacosx-version-min=14.0'], env, log, cwd=build)
        run(['ninja', '-C', build, 'qemu-system-arm'], env, log)  # ninja is its own up-to-date check
    if need('dylib'):
        dylib, script = build / 'libqemu-arm.dylib', args.qemu_source / 'contrib/macos-app/make-dylib-macos.sh'
        inputs = [build / 'qemu-system-arm-unsigned', script, *(args.qemu_source / 'contrib' / name for name in (
            'ios-app/qemu-ios-entry.c', 'ios-app/qemu-ios-ui.c', 'macos-app/qemu-macos-extras.c'))]
        if dylib.is_file() and dylib.stat().st_mtime >= max(path.stat().st_mtime for path in inputs):
            print('dylib: current')
        else:
            run(['bash', script, build], env, log)
        run([sys.executable, SCRIPTS / 'check-macho.py', '--no-weak-imports', dylib], env, log)
    if need('guest'):
        try:
            validate_guest(args, guest)
            print('guest: current')
        except ValueError:
            shutil.rmtree(guest.parent, ignore_errors=True)
            run(['bash', SCRIPTS / 'build-guest-tools.sh', guest.parent], env, log)
            validate_guest(args, guest)
    if need('app'):
        build_app(args, env, log, build)  # xcodebuild is incremental
        # firmwarekit is optional until its CLI is complete; the app builds without it.
        swift = ['swift', 'build', '-c', 'release', '--arch', 'arm64', '--package-path', ROOT / 'Packages/FirmwareKit',
                 '--scratch-path', args.output / 'firmwarekit-build']
        with log.open('ab') as output:
            result = subprocess.run(swift, stdout=output, stderr=subprocess.STDOUT)
        built = Path(subprocess.check_output([*swift, '--show-bin-path'], text=True).strip()) / 'firmwarekit'
        if result.returncode == 0 and built.is_file():
            firmwarekit.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(built, firmwarekit)
        else:
            firmwarekit.unlink(missing_ok=True)
            print(f'app: firmwarekit did not build ({result.returncode}); packaging without it (see {log})')
    if need('package'):
        apps = [path for path in products.glob('*.app') if (path / 'Contents/Info.plist').is_file()]
        if len(apps) != 1:
            raise ValueError(f'Expected one app built by --stage app in {products}, found {len(apps)}')
        product = apps[0]
        app = args.output / product.name
        require(build / 'libqemu-arm.dylib', 'QEMU library built by --stage dylib')
        validate_guest(args, guest)
        inputs = tree_stamp(product, build / 'libqemu-arm.dylib', guest, guest.parent / 'ipad-guest-tools', firmwarekit, SCRIPTS / 'package.sh',
                            args.assets / args.nand) + args.sign_id
        if app.is_dir() and state.get('package', {}).get('inputs') == inputs:
            print('package: current')
        else:
            state.pop('package', None)
            shutil.rmtree(app, ignore_errors=True)
            run(['ditto', product, app], env, log)
            sources = sources_now(args)
            env['LTM_BUILD_RECORD'] = str(write_build_record(args, sources, native_root, build, guest))
            if firmwarekit.is_file():
                env['LTM_FIRMWAREKIT'] = str(firmwarekit)
            run(['bash', SCRIPTS / 'package.sh', app], env, log)
            state['package'] = {'app': str(app), 'inputs': inputs, 'firmwarekit': firmwarekit.is_file(),
                                'sources': {name: value['source_sha256'] for name, value in sources.items()}}
            save_state(args, state)
    if 'package' not in state and selected & {'notarize', 'staple', 'verify'}:
        raise ValueError('Run --stage package first')
    if need('notarize'):
        if not args.notary_profile or args.sign_id == '-':
            raise ValueError('--stage notarize needs --sign-id "Developer ID Application: ..." and --notary-profile')
        if subprocess.run(['xcrun', 'stapler', 'validate', app], capture_output=True).returncode == 0:
            print('notarize: already stapled')
        else:
            notarize(args, env, log, state, app)
    if need('staple'):
        if subprocess.run(['xcrun', 'stapler', 'validate', app], capture_output=True).returncode == 0:
            print('staple: current')
        else:
            run(['xcrun', 'stapler', 'staple', app], env, log)
    if need('verify'):
        now = {name: value['source_sha256'] for name, value in sources_now(args).items()}
        if now != state['package']['sources']:
            raise RuntimeError('Source files changed since --stage package; rerun from package')
        require(app / 'Contents/Resources/firmware-catalog.json', 'bundled firmware catalog')
        require(app / 'Contents/MacOS/firmwarekit', 'bundled firmwarekit')
        run([sys.executable, SCRIPTS / 'test-package.py', app], env, log)
        run(['codesign', '--verify', '--deep', '--strict', app], env, log)
        if args.notary_profile:
            run(['xcrun', 'stapler', 'validate', app], env, log)
            assessment = subprocess.run(['spctl', '-a', '-vv', '-t', 'exec', app], capture_output=True, text=True)
            with log.open('a') as output:
                output.write(assessment.stderr)
            if assessment.returncode or 'Notarized Developer ID' not in assessment.stderr:
                raise RuntimeError(f'spctl rejected the app: {assessment.stderr.strip()}')
        check_prepare(args, log, state, app)
        entries = inventory(app)
        (args.output / 'bundle-inventory.json').write_text(json.dumps(entries, indent=2) + '\n')
        archive = args.output / 'LightTouchMac.zip'
        archive.unlink(missing_ok=True)
        run(['ditto', '-c', '-k', '--keepParent', app, archive], env, log)
        (args.output / 'SHA256SUMS').write_text(f'{digest(archive)}  {archive.name}\n')
        print(f'Verified {app}\nArchive: {archive}', flush=True)
    return 0


def main(argv=None):
    args = parse(argv)
    validate(args)
    if args.plan:
        print(json.dumps({key: str(value) if isinstance(value, Path) else value
                          for key, value in vars(args).items() if key not in ('sign_id', 'notary_profile')}, indent=2))
        return 0
    if sys.platform != 'darwin':
        raise ValueError('The product build requires macOS and Xcode')
    for tool in ('xcodebuild', 'xcrun', 'ninja', 'pkg-config', 'cc', 'codesign', 'ditto'):
        if shutil.which(tool) is None:
            raise ValueError(f'Missing build tool: {tool}')
    validate_output(args)
    args.output.mkdir(parents=True, exist_ok=bool(args.stage))
    log = args.output / 'build.log'
    env = os.environ.copy()
    env.update(QEMU_IOS_DIR=str(args.qemu_source), USBMUXD_SOURCE_DIR=str(args.usbmuxd_source),
               LTM_ASSETS=str(args.assets), LTM_NAND=args.nand, SIGN_ID=args.sign_id)
    if args.static_deps:
        env['LTM_STATIC_DEPS'] = str(args.static_deps)
    else:
        env.pop('LTM_STATIC_DEPS', None)
    if args.sdk:
        env['ARMV6_SDK'] = str(args.sdk)
    if args.notary_profile:
        env['NOTARY_PROFILE'] = args.notary_profile
    else:
        env.pop('NOTARY_PROFILE', None)
    if args.stage:
        return staged(args, env, log)
    sources = {'app': source_identity(ROOT), 'qemu': source_identity(args.qemu_source),
               'usbmuxd': source_identity(args.usbmuxd_source)}
    native_root = args.native_build or args.output / 'native'
    if args.native_build:
        run(['ninja', '-C', native_root / 'qemu-build', 'qemu-system-arm'], env, log)
        env['PKG_CONFIG_LIBDIR'] = str(native_root / 'prefix/lib/pkgconfig')
        env['PKG_CONFIG_PATH'] = ''
        run(['bash', args.qemu_source / 'contrib/macos-app/make-dylib-macos.sh', native_root / 'qemu-build'], env, log)
    else:
        run(['bash', SCRIPTS / 'build-package-native.sh', native_root], env, log)
    native = validate_native(args, native_root)
    static = Path(native['static_deps']).resolve()
    env.update(QEMU_BUILD_DIR=str(native_root / 'qemu-build'), LTM_DEPS_PREFIX=str(native_root / 'prefix'),
               LTM_STATIC_DEPS=str(static), USBMUXD_BIN=str(native_root / 'build/usbmuxd/src/usbmuxd'))
    guest = args.guest_tools or args.output / 'guest/guest-tools'
    if not args.guest_tools:
        run(['bash', SCRIPTS / 'build-guest-tools.sh', guest.parent], env, log)
    validate_guest(args, guest)
    env['LTM_GUEST_TOOLS_DIR'] = str(guest)
    product = build_app(args, env, log, native_root / 'qemu-build')
    app = args.output / product.name
    run(['ditto', product, app], env, log)
    build_record = write_build_record(args, sources, native_root, native_root / 'qemu-build', guest)
    env['LTM_BUILD_RECORD'] = str(build_record)
    run(['bash', SCRIPTS / 'package.sh', app], env, log)
    after = {'app': source_identity(ROOT), 'qemu': source_identity(args.qemu_source),
             'usbmuxd': source_identity(args.usbmuxd_source)}
    if after != sources:
        raise RuntimeError('Source files changed during the build; no release archive produced')
    entries = inventory(app)
    (args.output / 'bundle-inventory.json').write_text(json.dumps(entries, indent=2) + '\n')
    archive = args.output / 'LightTouchMac.zip'
    run(['ditto', '-c', '-k', '--keepParent', app, archive], env, log)
    (args.output / 'SHA256SUMS').write_text(f'{digest(archive)}  {archive.name}\n')
    print(f'Built {app}\nArchive: {archive}\nInputs and inventory: {args.output}', flush=True)
    return 0


if __name__ == '__main__':
    try:
        sys.exit(main())
    except (OSError, ValueError, RuntimeError, subprocess.CalledProcessError) as error:
        sys.exit(str(error))
