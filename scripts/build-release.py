#!/usr/bin/env python3
"""Build a self-contained Light Touch app: the built-in iPod is a `firmwarekit create` of n72ap-7E18 packed as one blob."""
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
import time

ROOT = Path(__file__).resolve().parents[1]
SCRIPTS = ROOT / 'scripts'
sys.path.insert(0, str(SCRIPTS))
import sources as pins  # noqa: E402  (build-support/sources.json: the pinned qemu-ios and usbmuxd)

# The guest tools come from qemu-ios contrib/export-guest-artifacts.sh (build-guest-tools.sh calls it) with a
# manifest naming every staged file; these are the names the app and firmwarekit need to find in it, whatever
# else the export stages.
GUEST_PAYLOADS = frozenset(('MBXGLEngine', 'sbdlicon', 'ithalt', 'it_agent', 'it_typein.dylib',
                          'com.qemu.it-agent.plist', 'itstatus', 'itmedia', 'itphoto',
                          'itproxy', 'ittrust', 'itorient'))
# firmwarekit's --guest-tools set (SystemEdits.Helpers + it_keybag) and the n72/n45 recipes' inputs (N72Recipe,
# N45Recipe): one GL shim per arch (GLEngine, MBXGLEngine: the dispatch layout is read at load) and the name table
# they speak; the 2.x and 1.x GL front ends (OpenGLES-2x, OpenGLES-1x) and the export sets the recipes check the stock
# OpenGLES against (opengles-2x.exports, opengles-1x.exports).
IPAD_GUEST_PAYLOADS = frozenset(('it_pbd', 'it_ethlink', 'it_prefs', 'it_msmquiet.dylib', 'it_seal', 'it_keybag',
                                 'libappsync.dylib', 'com.qemu.it-pbd.plist', 'com.qemu.it-ethlink.plist',
                                 'com.qemu.it-prefs.plist', 'com.qemu.it-seal.plist', 'GLEngine', 'gles-names.h',
                                 'GLRendererFloatQEMU', 'armv6.itpack', 'armv7.itpack',
                                 'MBXGLEngine', 'sblaunch', 'sbdlicon', 'it_agent', 'it_typein.dylib',
                                 'com.qemu.it-agent.plist', 'it_keybag-armv6', 'it_prefs-armv6',
                                 'OpenGLES-2x', 'opengles-2x.exports', 'OpenGLES-1x', 'opengles-1x.exports'))
# The oldest guest package the bundle may carry: serial 7 is the first with the n45-ios1 family (1.x's OpenGLES
# front-end hook, no loader), which N45Board refuses to bake 1.x GL without (serial 5 brought n72-ios2's).
GUEST_PACKAGE_MIN_SERIAL = 8
CATALOG = ROOT / 'LightTouchMac/Resources/firmware-catalog.json'
SOURCE_EXCLUSIONS = {'.git', '.build', 'dist', '__pycache__', 'xcuserdata', '.DS_Store'}
NATIVE_RECIPES = frozenset(('scripts/build-package-native.sh', 'scripts/build-static-deps.sh',
                           'scripts/dependency-sources.py', 'build-support/dependencies.json',
                           'build-support/patches/glib-pipe2-availability.patch', 'build-support/patches/iBoot32Patcher-ltm.patch',
                           'build-support/patches/libimobiledevice-sslv3-ios1.patch',
                           'scripts/test-glib-compat.py', 'scripts/check-macho.py', 'scripts/build-iboot32patcher.sh'))
FFMPEG_PATCHES = ('h264-chunk-er.patch', 'h264-cavlc-pcm-offset.patch')
# Resumable pipeline (--stage); each step fits a 10-minute tool limit and skips when current.
STAGES = ('native', 'qemu', 'dylib', 'guest', 'app', 'package', 'notarize', 'staple', 'verify')
# The built-in iPod: this catalog entry, prepared by the built firmwarekit from --bundled-ipsw with the
# built guest tools, packed by scripts/pack-base.py (Resources/device/<entry>.itbase) during package.
BUNDLED_ENTRY = 'n72ap-7E18'
BUNDLED_IPSW = Path.home() / 'Developer/ipod2g-re/OldSDK/iPod2,1_3.1.3_7E18_Restore.ipsw'
# The SecureROMs under --assets that package.sh flattens into Resources/device (DeviceProfile.bootromName):
# the iPod touch 2G's, and the 1G's from devos50's n45ap set (qemu-ios docs/ipod1g).
BOOTROMS = ('bootrom_240_4', 'ipod1g/bootrom_s5l8900')
# The emulator and usbmuxd ship together (both pinned in build-support/sources.json). The staged native stage
# builds usbmuxd from the pinned commit of --usbmuxd-source through a temporary worktree, whatever that
# checkout's HEAD is; the one-step build takes the checkout's working tree.
USBMUXD_COMMIT = pins.commit('usbmuxd')
# iBoot32Patcher (firmwarekit's k48 real-iBoot recipe runs it) is pinned by commit, archive sha256 and license
# in build-support/dependencies.json ("tools" group; LukeZGD's fork, GPL-3.0). Both native paths build it with
# scripts/build-iboot32patcher.sh into build/iBoot32Patcher, and package.sh ships it in Contents/MacOS.
PATCHER = 'build/iBoot32Patcher/iBoot32Patcher'
# --universal: the slices of an Intel + Apple Silicon app. Each gets a complete native root (native/<arch>; staged,
# its own --qemu-build/<arch>), cross-compiled on the Apple Silicon build Mac with LTM_ARCH; scripts/merge-native.py
# lipos them into native-universal/, the one-step layout package.sh consumes, and iBoot32Patcher is built fat there.
UNIVERSAL_ARCHS = ('arm64', 'x86_64')
UNIVERSAL_ROOT = 'native-universal'
# QEMU's configure for a cross-compiled slice (the one-step recipe, build-package-native.sh, passes the same).
QEMU_CROSS = {'arm64': [], 'x86_64': ['--cross-prefix=', '--cpu=x86_64', '--cc=clang -arch x86_64',
                                      '--cxx=clang++ -arch x86_64', '--objcc=clang -arch x86_64']}


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


def manifest_hashes(entries, description):
    """The export manifest's {path: sha256} maps, checked."""
    return hashes([{'path': name, 'sha256': checksum} for name, checksum in (entries or {}).items()], description)


def validate_guest(args, guest):
    """The export's manifest is the record: every staged file at its hash, the required names present, and the
    sources it read (commit and input hashes) unchanged in the checkout."""
    manifest = read_record(guest.parent / 'manifest.json', 'schema')
    source = manifest.get('source', {})
    if Path(source.get('path', '')).resolve() != args.qemu_source:
        raise ValueError('Guest tools were built from a different QEMU checkout')
    serial = (manifest.get('guest_package') or {}).get('serial') or 0
    if serial < GUEST_PACKAGE_MIN_SERIAL:
        raise ValueError(f'Guest package serial {serial} predates {GUEST_PACKAGE_MIN_SERIAL} (the 1.x OpenGLES hook); rebuild guest tools')
    files = manifest_hashes(manifest.get('files'), 'guest artifact')
    for directory, required, description in ((guest, GUEST_PAYLOADS, 'Guest payload'),
                                             (guest.parent / 'ipad-guest-tools', IPAD_GUEST_PAYLOADS, 'iPad guest payload')):
        staged = {Path(name).name: checksum for name, checksum in files.items()
                  if Path(name).parent == Path(directory.name)}
        missing = required - set(staged)
        if missing:
            raise ValueError(f'{description}s missing from the export manifest: {", ".join(sorted(missing))}')
        require(directory, f'{description.lower()} directory', directory=True)
        if {path.name for path in directory.iterdir()} != set(staged):
            raise ValueError(f'{description} directory differs from the export manifest: {directory}')
        verify_hashes(directory, staged, description)
    if source.get('commit') != pins.head(args.qemu_source)[0]:
        raise ValueError(f'Guest tools were built from qemu-ios {source.get("commit")}, not the checkout\'s HEAD; rebuild guest tools')
    for name, checksum in manifest_hashes(manifest.get('inputs'), 'guest source').items():
        path = args.qemu_source / name
        if not path.is_file() or digest(path) != checksum:
            raise ValueError(f'Guest source inputs have changed ({name}); rebuild guest tools')
    return manifest


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


def validate_native(args, root, deps_only=False, arch='arm64'):
    """deps_only: reuse the prefix, static deps and usbmuxd; QEMU is built elsewhere."""
    native = read_record(root / 'native-build.json')
    if native.get('architecture') != arch:
        raise ValueError(f'Native build {root} is not an {arch} build')
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
    if native.get('usbmuxd_commit'):   # staged: a pinned commit, not the checkout's working tree
        if native['usbmuxd_commit'] != USBMUXD_COMMIT or previous.get('commit') != USBMUXD_COMMIT or previous.get('modified'):
            raise ValueError(f'Native build has usbmuxd {previous.get("commit")}, not {USBMUXD_COMMIT}; rebuild native')
    else:
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
                        (root / 'build/usbmuxd/src/usbmuxd', 'native usbmuxd'),
                        (root / PATCHER, 'native iBoot32Patcher')):
        require(path, label)
    return native


def slice_roots(args, base):
    """Native roots per architecture: base itself, or with --universal one complete root per slice under it."""
    if not args.universal:
        return {'arm64': base}
    return {arch: base / arch for arch in UNIVERSAL_ARCHS}


def slice_env(args, env, arch, root):
    """The environment for building one slice against root's prefix (the shared env itself when not universal)."""
    if not args.universal:
        return env
    return dict(env, LTM_ARCH=arch, PKG_CONFIG_LIBDIR=str(root / 'prefix/lib/pkgconfig'), PKG_CONFIG_PATH='')


def merge_universal(args, env, log, slices, output):
    """lipo the per-slice native roots into output (scripts/merge-native.py) and build iBoot32Patcher fat into it
    from the pinned archive the arm64 root fetched."""
    if output.exists():
        subprocess.run(['chmod', '-R', 'u+w', output], check=True)
        shutil.rmtree(output)
    run([sys.executable, SCRIPTS / 'merge-native.py', output, *slices.values()], env, log)
    run(['bash', SCRIPTS / 'build-iboot32patcher.sh', slices['arm64'] / 'src', (output / PATCHER).parent],
        dict(env, LTM_ARCH=' '.join(slices)), log)
    return output


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
    for name, source in (('native-build.json', native_record), ('guest-manifest.json', guest_record)):
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
    parser.add_argument('--qemu-source', '--qemu-ios', type=Path, default=pins.path('qemu-ios'),
                        help='The qemu-ios checkout (default: the pin, build-support/sources.json; QEMU_IOS_DIR overrides)')
    parser.add_argument('--usbmuxd-source', type=Path, default=pins.path('usbmuxd'),
                        help='The usbmuxd fork checkout (default: the pin; USBMUXD_SOURCE_DIR overrides)')
    parser.add_argument('--allow-unpinned', action='store_true',
                        help='Sign a build whose qemu-ios (or, one-step, usbmuxd) checkout is not at the pinned commit')
    parser.add_argument('--assets', type=Path, default=Path(os.environ.get('LTM_ASSETS', ROOT.parent / 'qemu-ios-files')))
    parser.add_argument('--bundled-ipsw', type=Path, default=BUNDLED_IPSW,
                        help=f'The {BUNDLED_ENTRY} IPSW the built firmwarekit prepares as the built-in iPod')
    parser.add_argument('--sdk', type=Path, default=Path(os.environ['ARMV6_SDK']) if 'ARMV6_SDK' in os.environ else None,
                        help='Locally installed iPhoneOS3.1.3.sdk used to build guest helpers')
    parser.add_argument('--native-build', type=Path, help='Reuse a native build root (with --universal, the directory holding '
                        'its arm64/ and x86_64/ roots); rebuild its QEMU before packaging')
    parser.add_argument('--universal', action='store_true',
                        help='Build an arm64 + x86_64 (Intel) app: every native dependency and QEMU a second time for x86_64')
    parser.add_argument('--static-deps', type=Path, help='Explicit compatible static prefix; otherwise build it from the pinned recipe')
    parser.add_argument('--guest-tools', type=Path, help='Reuse a guest-tools directory produced by build-guest-tools.sh')
    parser.add_argument('--source-packages', type=Path, help='Optional Xcode SourcePackages cache')
    parser.add_argument('--sign-id', default=os.environ.get('SIGN_ID', '-'), help='Signing identity; defaults to ad-hoc')
    parser.add_argument('--notary-profile', default=os.environ.get('NOTARY_PROFILE'), help='Optional notarytool keychain profile')
    parser.add_argument('--stage', action='append', choices=(*STAGES, 'all'),
                        help='Run the resumable staged build (repeatable, run in pipeline order; see "Multi-device release build" in docs/multi-device-plan.md). '
                             'Without it, the one-step build runs; --output may then not exist.')
    parser.add_argument('--native-deps', type=Path, help='Staged: native root whose prefix, static deps and usbmuxd are reused '
                        '(e.g. a previous release output\'s native/; with --universal, the directory holding arm64/ and x86_64/ roots)')
    parser.add_argument('--qemu-build', type=Path, help='Staged: private QEMU build directory (default <qemu-source>/build-release-native; '
                        'with --universal, <qemu-source>/build-release-universal, one subdirectory per slice)')
    parser.add_argument('--verify-ipsw', type=Path,
                        default=Path.home() / 'Downloads/ipad1-ios32-feasibility/iPad1,1_3.2.2_7B500_Restore.ipsw',
                        help=f'Staged verify: the {PREPARE_ENTRY} IPSW the bundled firmwarekit prepares (VERIFY_ENTRIES has the others)')
    parser.add_argument('--plan', action='store_true', help='Validate inputs and print selected paths without building or writing')
    args = parser.parse_args(argv)
    if args.output.expanduser().is_symlink():
        parser.error(f'Output must not be a symlink: {args.output}')
    for name in ('output', 'qemu_source', 'usbmuxd_source', 'assets', 'sdk', 'native_build', 'static_deps', 'guest_tools',
                 'source_packages', 'native_deps', 'qemu_build', 'verify_ipsw', 'bundled_ipsw'):
        value = getattr(args, name)
        if value is not None:
            setattr(args, name, value.expanduser().resolve())
    if args.stage:
        if not args.native_deps:
            parser.error('--stage requires --native-deps (a native root to reuse)')
        if args.native_build or args.guest_tools or args.static_deps:
            parser.error('--stage builds its own QEMU and guest tools; use --native-deps and --qemu-build')
        args.qemu_build = args.qemu_build or args.qemu_source / ('build-release-universal' if args.universal else 'build-release-native')
    elif args.output.exists():
        parser.error(f'Output already exists: {args.output}; choose a new directory')
    if args.universal and args.static_deps:
        parser.error('--static-deps names one architecture; omit it with --universal')
    if args.notary_profile and args.sign_id == '-':
        parser.error('--notary-profile requires a Developer ID --sign-id')
    return args


def pin_status(args):
    """Pinned vs actual commit of each source checkout (build-support/sources.json). A Developer ID build is a
    release: it must come from the pins (the staged native stage builds usbmuxd from its pin regardless, so
    only qemu-ios is checked there) unless --allow-unpinned. An ad-hoc build only records the difference."""
    status = pins.status({'qemu-ios': args.qemu_source, 'usbmuxd': args.usbmuxd_source})
    checked = ('qemu-ios',) if args.stage else ('qemu-ios', 'usbmuxd')
    off = [f'{name} pinned {status[name]["pinned"][:10]}, {status[name]["path"]} at '
           f'{(status[name]["actual"] or "no git")[:10]}{" (dirty)" if status[name]["dirty"] else ""}'
           for name in checked if not status[name]['matches']]
    if off and args.sign_id != '-' and not args.allow_unpinned:
        raise ValueError('Not built from the pin (build-support/sources.json): ' + '; '.join(off)
                         + '. Check out the pinned commits, bump the pin, or pass --allow-unpinned')
    return status


def validate(args):
    require(args.qemu_source / 'configure', 'QEMU checkout')
    require(args.usbmuxd_source / 'configure.ac', 'usbmuxd source checkout')
    pin_status(args)
    for name in BOOTROMS:
        require(args.assets / name, 'bundled firmware input')
    require(args.bundled_ipsw, f'{BUNDLED_ENTRY} IPSW for the built-in iPod (--bundled-ipsw)')
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
        for arch, root in slice_roots(args, args.native_build).items():
            validate_native(args, root, arch=arch)


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
    if args.universal:
        command[command.index('ARCHS=arm64')] = f'ARCHS={" ".join(UNIVERSAL_ARCHS)}'
        command.insert(-1, 'ONLY_ACTIVE_ARCH=NO')
    if args.source_packages:
        command[1:1] = ['-clonedSourcePackagesDirPath', args.source_packages]
    run(command, env, log)
    products = derived / 'Build/Products/Release'
    apps = [p for p in products.glob('*.app') if (p / 'Contents/Info.plist').is_file()]
    if len(apps) != 1:
        raise ValueError(f'Expected one Release app in {products}, found {len(apps)}')
    return apps[0]


def build_firmwarekit(args, log):
    """`swift build` of Packages/FirmwareKit into <output>/firmwarekit/release/firmwarekit (the built-in
    iPod and every in-app prepare need it)."""
    firmwarekit = args.output / 'firmwarekit/release/firmwarekit'
    archs = UNIVERSAL_ARCHS if args.universal else ('arm64',)
    swift = ['swift', 'build', '-c', 'release', *(flag for arch in archs for flag in ('--arch', arch)),
             '--package-path', ROOT / 'Packages/FirmwareKit',
             '--scratch-path', args.output / 'firmwarekit-build']
    run(swift, os.environ.copy(), log)
    built = Path(subprocess.check_output([*swift, '--show-bin-path'], text=True).strip()) / 'firmwarekit'
    firmwarekit.parent.mkdir(parents=True, exist_ok=True)
    shutil.copy2(built, firmwarekit)
    return firmwarekit


def write_build_record(args, sources, native_root, qemu_build, guest):
    provenance = copy_provenance(args.output, native_root / 'native-build.json', guest.parent / 'manifest.json')
    record = {
        'schema_version': 1, 'sources': sources,
        **({'host_architectures': list(UNIVERSAL_ARCHS)} if args.universal else {'host_architecture': 'arm64'}),
        'pin': pin_status(args),
        'firmware': {'bootroms_sha256': {Path(name).name: digest(args.assets / name) for name in BOOTROMS},
                     'bundled': json.loads((args.output / 'bundled/bundled.json').read_text())},
        'native_build_record_sha256': provenance['native-build.json'],
        'native_build_reused': bool(args.native_build or args.native_deps),
        'qemu_rebuilt_from_sources': sources['qemu'],
        'guest_build_record_sha256': provenance['guest-manifest.json'],
        'provenance_records': provenance,
        'qemu_build': str(qemu_build),
        'native_artifacts': {
            'prefix': inventory(native_root / 'prefix'),
            'qemu_library_sha256': digest(qemu_build / 'libqemu-arm.dylib'),
            'usbmuxd_sha256': digest(native_root / 'build/usbmuxd/src/usbmuxd'),
            'iboot32patcher': json.loads((native_root / PATCHER).with_name('build.json').read_text()),
        },
        'swift_packages': json.loads((ROOT / 'LightTouchMac.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved').read_text()),
        'xcode': subprocess.check_output(['xcodebuild', '-version'], text=True).strip(),
        'macos_sdk': subprocess.check_output(['xcrun', '--sdk', 'macosx', '--show-sdk-version'], text=True).strip(),
    }
    build_record = args.output / 'build-inputs.json'
    build_record.write_text(json.dumps(record, indent=2) + '\n')
    return build_record


def sources_now(args):
    usbmuxd = source_identity(args.usbmuxd_source)
    if args.stage:   # the pinned commit the native stage built, not the checkout's working tree
        staged = json.loads((slice_roots(args, args.output / 'native')['arm64'] / 'usbmuxd-source.json').read_text())
        usbmuxd = {'revision': staged['commit'], 'dirty': staged['modified'], 'files': len(staged['files']),
                   'source_sha256': hashlib.sha256(json.dumps(staged['files'], sort_keys=True).encode()).hexdigest(),
                   'submodules': {}}
    return {'app': source_identity(ROOT), 'qemu': source_identity(args.qemu_source), 'usbmuxd': usbmuxd}


def bundled_base(args, env, log, firmwarekit, guest, helper=None):
    """The built-in iPod: `firmwarekit create` of BUNDLED_ENTRY (the built firmwarekit, the built guest tools,
    --bundled-ipsw) packed by scripts/pack-base.py into <output>/bundled/<entry>.itbase, with bundled.json
    beside it (inputs, the lock's hashes). Skipped when its inputs are unchanged."""
    if not firmwarekit.is_file():
        raise ValueError('The built-in iPod needs firmwarekit; it did not build')
    bundled = args.output / 'bundled'
    blob, record = bundled / f'{BUNDLED_ENTRY}.itbase', bundled / 'bundled.json'
    tools = guest.parent / 'ipad-guest-tools'
    inputs = tree_stamp(firmwarekit, tools, args.bundled_ipsw, SCRIPTS / 'pack-base.py',
                        ROOT / 'LightTouchMac/Resources/firmware-catalog.json')
    if blob.is_file() and record.is_file() and json.loads(record.read_text()).get('inputs') == inputs:
        print('bundled: current')
        return blob
    catalog = json.loads((ROOT / 'LightTouchMac/Resources/firmware-catalog.json').read_text())
    entry = next(e for e in catalog['entries'] if e['id'] == BUNDLED_ENTRY)
    if entry.get('bundled') != f'device/{BUNDLED_ENTRY}.itbase':
        raise ValueError(f'The catalog entry {BUNDLED_ENTRY} does not name device/{BUNDLED_ENTRY}.itbase as bundled')
    if bundled.exists():
        subprocess.run(['chmod', '-R', 'u+w', bundled], check=True)
        shutil.rmtree(bundled)
    staging = bundled / 'staging'
    staging.mkdir(parents=True)
    (bundled / 'entry.json').write_text(json.dumps(entry))
    command = [firmwarekit, 'create', '--entry', bundled / 'entry.json', '--ipsw', args.bundled_ipsw, '--out', staging,
               '--cache', bundled / 'cache', '--guest-tools', tools]
    if helper and helper.is_file():
        command += ['--helper', helper]
    print(f'bundled: preparing {BUNDLED_ENTRY} with the built firmwarekit', flush=True)
    run(command, {k: v for k, v in env.items() if not k.startswith('LTM_')}, log)
    lock = json.loads((staging / 'device.lock.json').read_text())
    if str(tools.resolve()) not in json.dumps(lock):
        raise RuntimeError(f'The built-in iPod was not prepared with the built guest tools {tools}')
    run([sys.executable, SCRIPTS / 'pack-base.py', 'pack', staging, blob], env, log)
    record.write_text(json.dumps({
        'entry': BUNDLED_ENTRY, 'inputs': inputs, 'ipsw': str(args.bundled_ipsw), 'ipsw_sha1': entry['source']['sha1'],
        'firmwarekit_sha256': digest(firmwarekit), 'blob_sha256': digest(blob), 'bytes': blob.stat().st_size,
        'lock': {'tool': lock.get('tool'), 'outputs': lock.get('outputs'), 'guest_package': lock.get('guest_package')},
    }, indent=2) + '\n')
    subprocess.run(['chmod', '-R', 'u+w', staging], check=True)
    shutil.rmtree(staging)
    shutil.rmtree(bundled / 'cache', ignore_errors=True)
    return blob


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
# verify: each entry is prepared by the bundled firmwarekit, then booted headless through the bundled helper,
# dylib and usbmuxd (tests/sessions/check-sessions.py --single): lit, lockdown, AFC round trips past 16 KiB, an IPA
# install, a clean shutdown. One entry per run; rerun --stage verify until every entry is current.
VERIFY_ENTRIES = {
    'k48ap-7B500': ('ipad', None),   # --verify-ipsw
    'k48ap-8C148': ('ipad', Path.home() / 'Downloads/ipad1-ios32-feasibility/iPad1,1_4.2.1_8C148_Restore.ipsw'),
    'k48ap-7B367': ('ipad', Path.home() / 'Downloads/ipad1-ios32-feasibility/iPad1,1_3.2_7B367_Restore.ipsw'),
    'n72ap-7E18': ('ipod', Path.home() / 'Developer/ipod2g-re/OldSDK/iPod2,1_3.1.3_7E18_Restore.ipsw'),
    'n72ap-8C148': ('ipod', Path.home() / 'Downloads/ios4/iPod2,1_4.2.1_8C148_Restore.ipsw'),
}


def remove_tree(path, attempts=5):
    """Delete a verify work tree. A Finder window open on the output writes .DS_Store into directories as
    they empty, so rmtree can hit ENOTEMPTY (09-29 preflight); retry rather than fail a passing entry."""
    for attempt in range(attempts):
        if not path.exists():
            return
        subprocess.run(['chmod', '-R', 'u+w', path], check=True)
        try:
            return shutil.rmtree(path)
        except OSError:
            if attempt == attempts - 1:
                raise
            time.sleep(1)


def check_prepare(args, log, state, app):
    """Run the bundled firmwarekit as the app does (bundled --guest-tools default, bundled helper), then boot
    what it made through the bundle. Frames and events stay in verify-frames/<entry>/."""
    stamp = tree_stamp(app)
    done = state.setdefault('verify', {}).setdefault('devices', {})
    pending = [e for e in VERIFY_ENTRIES if done.get(e, {}).get('app') != stamp]
    for entry_id in VERIFY_ENTRIES:
        if entry_id not in pending:
            print(f'verify: {entry_id} current ({done[entry_id]["summary"]})')
    if not pending:
        return
    entry_id = pending[0]
    board, ipsw = VERIFY_ENTRIES[entry_id]
    ipsw = ipsw or args.verify_ipsw
    require(ipsw, f'{entry_id} IPSW for the in-bundle prepare check')
    catalog = json.loads((app / 'Contents/Resources/firmware-catalog.json').read_text())
    entry = next(e for e in catalog['entries'] if e['id'] == entry_id)
    work, frames = args.output / 'prepare-check', args.output / 'verify-frames' / entry_id

    def clean():
        remove_tree(work)
    clean()
    shutil.rmtree(frames, ignore_errors=True)
    (work / 'out').mkdir(parents=True)
    frames.mkdir(parents=True)
    clean_env = {k: v for k, v in os.environ.items() if not k.startswith('LTM_')}
    try:
        (work / 'entry.json').write_text(json.dumps(entry))
        command = [app / 'Contents/MacOS/firmwarekit', 'create', '--entry', work / 'entry.json', '--ipsw', ipsw,
                   '--out', work / 'out', '--cache', work / 'cache', '--helper', app / 'Contents/MacOS/LightTouchDevice']
        print('+ ' + shlex.join(map(str, command)), flush=True)
        started = time.monotonic()
        with log.open('ab') as output:
            result = subprocess.run(list(map(str, command)), stdout=subprocess.PIPE, stderr=output,
                                    env=clean_env, timeout=480)
        seconds = time.monotonic() - started
        events = [json.loads(line) for line in result.stdout.decode().splitlines() if line.strip()]
        with log.open('a') as output:
            output.write(''.join(json.dumps(e) + '\n' for e in events))
        for e in events:
            if e['event'] in ('step', 'warning', 'error', 'done'):
                print('  firmwarekit: ' + json.dumps(e), flush=True)
        if result.returncode or not events or events[-1]['event'] != 'done':
            raise RuntimeError(f'In-bundle prepare of {entry_id} failed ({result.returncode}); see {log}')
        lock = json.loads((work / 'out' / events[-1]['lock']).read_text())
        bundled = str((app / 'Contents/Resources/guest-tools').resolve())
        if bundled not in json.dumps(lock):
            raise RuntimeError(f'Prepare did not use the bundled guest tools {bundled}')
        prepared = int(subprocess.check_output(['du', '-sk', work / 'out'], text=True).split()[0]) * 1024
        boot = [sys.executable, ROOT / 'tests/sessions/check-sessions.py', '--single', work / 'out', '--board', board,
                '--helper', app / 'Contents/MacOS/LightTouchDevice', '--dylib', app / 'Contents/Frameworks/libqemu-arm.dylib',
                '--usbmuxd', app / 'Contents/MacOS/usbmuxd', '--frameworks', app / 'Contents/Frameworks',
                '--files', app / 'Contents/Resources/device', '--work', frames]
        print('+ ' + shlex.join(map(str, boot)), flush=True)
        checked = subprocess.run(list(map(str, boot)), stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True,
                                 env=clean_env, timeout=590)
        (frames / 'check.log').write_text(checked.stdout)
        print(checked.stdout, flush=True)
        if checked.returncode:
            raise RuntimeError(f'In-bundle boot of {entry_id} failed; see {frames}/check.log')
    finally:
        clean()
    passed = next((l for l in checked.stdout.splitlines() if ' passed; events ' in l), '').split(';')[0]
    done[entry_id] = {'app': stamp, 'summary': f'prepared in {seconds:.0f} s ({prepared} bytes), boot {passed}',
                      'prepare_seconds': round(seconds), 'prepared_bytes': prepared, 'frames': str(frames)}
    save_state(args, state)
    if len(pending) > 1:
        raise RuntimeError(f'verify: {entry_id} passed; rerun --stage verify for {", ".join(pending[1:])}')


def save_state(args, state):
    (args.output / 'stages.json').write_text(json.dumps(state, indent=2) + '\n')


def native_stage(args, env, log, deps, root, static, arch='arm64', qemu_build=None):
    """Reuse deps' prefix and static deps (they need over 10 minutes to build); rebuild usbmuxd
    from USBMUXD_COMMIT of the fork (a temporary worktree), as build-package-native.sh does, for arch."""
    record = read_record(deps / 'native-build.json')
    if (root / 'native-build.json').is_file():
        try:
            validate_native(args, root, deps_only=True, arch=arch)
            return print('native: current')
        except ValueError as error:
            print(f'native: rebuilding ({error})')
    shutil.rmtree(root, ignore_errors=True)
    (root / 'build').mkdir(parents=True)
    (root / 'prefix').symlink_to(deps / 'prefix')
    usb = root / 'build/usbmuxd'
    tree, git = args.output / 'usbmuxd-worktree', ['git', '-C', args.usbmuxd_source]
    subprocess.run([*git, 'worktree', 'remove', '--force', tree], capture_output=True)
    run([*git, 'worktree', 'add', '--detach', tree, USBMUXD_COMMIT], env, log)
    try:
        run([sys.executable, SCRIPTS / 'dependency-sources.py', 'stage-git', '--source', tree,
             '--destination', usb, '--record', root / 'usbmuxd-source.json'], env, log)
        (usb / '.tarball-version').write_text(subprocess.check_output(
            ['git', '-C', tree, 'describe', '--tags', '--always', '--dirty'], text=True))
    finally:
        run([*git, 'worktree', 'remove', '--force', tree], env, log)
    cross = '' if arch == 'arm64' else f'-arch {arch} '
    flags = cross + '-O2 -mmacosx-version-min=14.0'
    build_env = {key: value for key, value in env.items()
                 if key not in ('CPATH', 'C_INCLUDE_PATH', 'CPLUS_INCLUDE_PATH', 'LIBRARY_PATH')}
    build_env.update(MACOSX_DEPLOYMENT_TARGET='14.0', CFLAGS=flags, CXXFLAGS=flags, CC='/usr/bin/clang',
                     CXX='/usr/bin/clang++', lt_cv_sys_max_cmd_len='131072', PKG_CONFIG_PATH='',
                     PKG_CONFIG_LIBDIR=f'{deps / "prefix/lib/pkgconfig"}:{static / "lib/pkgconfig"}',
                     LDFLAGS=cross + '-mmacosx-version-min=14.0 -framework IOKit -framework CoreFoundation -framework Security')
    run(['sh', '-c', 'glibtoolize --copy --force && autoreconf -fi'], build_env, log, cwd=usb)
    host = [] if arch == 'arm64' else [f'--host={arch}-apple-darwin']
    run(['./configure', f'--prefix={deps / "prefix"}', *host, '--without-systemd'], build_env, log, cwd=usb)
    run(['make', f'-j{os.cpu_count()}'], build_env, log, cwd=usb)
    if 'HAVE_LIBSLIRP 1' not in (usb / 'config.h').read_text():
        raise RuntimeError('usbmuxd configured without libslirp; the iPad USB Ethernet bridge would be missing')
    run([sys.executable, SCRIPTS / 'check-macho.py', '--no-weak-imports', '--arch', arch, usb / 'src/usbmuxd'], env, log)
    # iBoot32Patcher from the manifest's pinned archive (deps' src/ is a cache when it is a one-step root).
    caches = [c for cache in (deps / 'src',) if cache.is_dir() for c in ('--cache', cache)]
    run([sys.executable, SCRIPTS / 'dependency-sources.py', 'fetch', '--group', 'tools', '--destination', root / 'src', *caches], env, log)
    run(['bash', SCRIPTS / 'build-iboot32patcher.sh', root / 'src', (root / PATCHER).parent], dict(env, LTM_ARCH=arch), log)
    record.update(usbmuxd=json.loads((root / 'usbmuxd-source.json').read_text()), usbmuxd_source=str(args.usbmuxd_source),
                  usbmuxd_commit=USBMUXD_COMMIT,
                  iboot32patcher=json.loads((root / PATCHER).with_name('build.json').read_text()),
                  usbmuxd_binary=str(usb / 'src/usbmuxd'), deps_prefix=str(root / 'prefix'),
                  qemu_source=str(args.qemu_source), qemu_build=str(qemu_build or args.qemu_build),
                  reused_native_deps=str(deps), usbmuxd_rebuilt_by='build-release.py --stage native')
    (root / 'native-build.json').write_text(json.dumps(record, indent=2) + '\n')
    validate_native(args, root, deps_only=True, arch=arch)


def staged(args, env, log):
    state_path = args.output / 'stages.json'
    state = json.loads(state_path.read_text()) if state_path.is_file() else {}
    selected = set(STAGES if 'all' in args.stage else args.stage)
    env.pop('NOTARY_PROFILE', None)  # notarize and staple are their own stages
    deps = args.native_deps
    deps_roots, roots = slice_roots(args, deps), slice_roots(args, args.output / 'native')
    builds = {arch: args.qemu_build / arch for arch in roots} if args.universal else {'arm64': args.qemu_build}
    statics = {arch: Path(read_record(root / 'native-build.json')['static_deps']).resolve() for arch, root in deps_roots.items()}
    if args.universal:   # what app and package read: the merged root (merge_universal)
        native_root = args.output / UNIVERSAL_ROOT
        build, static = native_root / 'qemu-build', native_root / 'static/prefix'
    else:
        native_root, build, static = roots['arm64'], builds['arm64'], statics['arm64']
    prefix = native_root / 'prefix'
    guest = args.output / 'guest/guest-tools'
    firmwarekit = args.output / 'firmwarekit/release/firmwarekit'
    env.update(QEMU_BUILD_DIR=str(build), LTM_DEPS_PREFIX=str(prefix), LTM_STATIC_DEPS=str(static),
               USBMUXD_BIN=str(native_root / 'build/usbmuxd/src/usbmuxd'), IBOOT32PATCHER_BIN=str(native_root / PATCHER),
               LTM_GUEST_TOOLS_DIR=str(guest),
               PKG_CONFIG_LIBDIR=str(prefix / 'lib/pkgconfig'), PKG_CONFIG_PATH='')
    products = args.output / 'DerivedData/Build/Products/Release'
    app = Path(state.get('package', {}).get('app', ''))

    def need(stage):
        if stage in selected:
            print(f'== {stage}', flush=True)
            return True
        return False

    if need('native'):
        for arch, root in roots.items():
            native_stage(args, env, log, deps_roots[arch], root, statics[arch], arch, builds[arch])
        state['native'] = {'deps': str(deps)}
        save_state(args, state)
    elif state.get('native', {}).get('deps') != str(deps):
        raise ValueError('Run --stage native for this --native-deps first')
    if need('qemu'):
        for arch, arch_build in builds.items():
            arch_env, arch_static = slice_env(args, env, arch, roots[arch]), statics[arch]
            configured = (arch_build / 'config.log').read_text(errors='replace') if (arch_build / 'config.log').is_file() else ''
            line = next((l for l in configured.splitlines() if l.startswith('# Configured with:')), '')
            if line and (str(args.qemu_source / 'configure') not in line or str(arch_static) not in line):
                raise ValueError(f'{arch_build} was configured for another source or static prefix; choose a new --qemu-build')
            if not (arch_build / 'build.ninja').is_file():
                arch_build.mkdir(parents=True, exist_ok=True)
                run([args.qemu_source / 'configure', *QEMU_CROSS[arch], '--target-list=arm-softmmu', '--without-default-features',
                     '--enable-cocoa', '--enable-coreaudio', '--enable-pixman', '--enable-slirp', '--disable-pie',
                     f'--python={os.environ.get("QEMU_PYTHON", "python3.12")}',
                     f'--extra-cflags=-I{arch_static}/include -mmacosx-version-min=14.0',
                     f'--extra-ldflags=-L{arch_static}/lib -lcrypto -mmacosx-version-min=14.0'], arch_env, log, cwd=arch_build)
            run(['ninja', '-C', arch_build, 'qemu-system-arm'], arch_env, log)  # ninja is its own up-to-date check
    if need('dylib'):
        for arch, arch_build in builds.items():
            arch_env = slice_env(args, env, arch, roots[arch])
            dylib, script = arch_build / 'libqemu-arm.dylib', args.qemu_source / 'contrib/macos-app/make-dylib-macos.sh'
            inputs = [arch_build / 'qemu-system-arm-unsigned', script, *(args.qemu_source / 'contrib' / name for name in (
                'ios-app/qemu-ios-entry.c', 'ios-app/qemu-ios-ui.c', 'macos-app/qemu-macos-extras.c'))]
            if dylib.is_file() and dylib.stat().st_mtime >= max(path.stat().st_mtime for path in inputs):
                print(f'dylib: current{f" ({arch})" if args.universal else ""}')
            else:
                run(['bash', script, arch_build], arch_env, log)
            run([sys.executable, SCRIPTS / 'check-macho.py', '--no-weak-imports',
                 *(('--arch', arch) if args.universal else ()), dylib], env, log)
    if args.universal and selected & {'dylib', 'app', 'package'}:
        # Remerge whenever a slice's native root, usbmuxd or dylib (or the merge recipe) changed.
        inputs = tree_stamp(*(path for arch, root in roots.items() for path in (
            root / 'native-build.json', root / 'build/usbmuxd/src/usbmuxd', root / PATCHER, builds[arch] / 'libqemu-arm.dylib')),
            SCRIPTS / 'merge-native.py', SCRIPTS / 'build-iboot32patcher.sh')
        if native_root.is_dir() and state.get('universal') == inputs:
            print(f'universal: current ({native_root})')
        else:
            for arch in roots:
                require(builds[arch] / 'libqemu-arm.dylib', f'{arch} QEMU library built by --stage dylib')
            merge_universal(args, env, log, roots, native_root)
            state['universal'] = inputs
            save_state(args, state)
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
        build_firmwarekit(args, log)
    if need('package'):
        apps = [path for path in products.glob('*.app') if (path / 'Contents/Info.plist').is_file()]
        if len(apps) != 1:
            raise ValueError(f'Expected one app built by --stage app in {products}, found {len(apps)}')
        product = apps[0]
        app = args.output / product.name
        require(build / 'libqemu-arm.dylib', 'QEMU library built by --stage dylib')
        validate_guest(args, guest)
        blob = bundled_base(args, env, log, firmwarekit, guest, product / 'Contents/MacOS/LightTouchDevice')
        inputs = tree_stamp(product, build / 'libqemu-arm.dylib', guest, guest.parent / 'ipad-guest-tools', firmwarekit, SCRIPTS / 'package.sh',
                            *(args.assets / name for name in BOOTROMS), blob) + args.sign_id
        if app.is_dir() and state.get('package', {}).get('inputs') == inputs:
            print('package: current')
        else:
            state.pop('package', None)
            shutil.rmtree(app, ignore_errors=True)
            run(['ditto', product, app], env, log)
            sources = sources_now(args)
            env['LTM_BUILD_RECORD'] = str(write_build_record(args, sources, native_root, build, guest))
            env['LTM_FIRMWAREKIT'] = str(firmwarekit)
            env['LTM_BASE_BLOB'] = str(blob)
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
        run([sys.executable, ROOT / 'tests/release/test-package.py', app], env, log)
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
        print(json.dumps({**{key: str(value) if isinstance(value, Path) else value
                             for key, value in vars(args).items() if key not in ('sign_id', 'notary_profile')},
                          'pin': pin_status(args)}, indent=2))
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
               LTM_ASSETS=str(args.assets), SIGN_ID=args.sign_id)
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
    slices = slice_roots(args, args.native_build or args.output / 'native')
    for arch, root in slices.items():
        arch_env = dict(env, LTM_ARCH=arch) if args.universal else env
        if args.native_build:
            run(['ninja', '-C', root / 'qemu-build', 'qemu-system-arm'], arch_env, log)
            arch_env['PKG_CONFIG_LIBDIR'] = str(root / 'prefix/lib/pkgconfig')
            arch_env['PKG_CONFIG_PATH'] = ''
            run(['bash', args.qemu_source / 'contrib/macos-app/make-dylib-macos.sh', root / 'qemu-build'], arch_env, log)
        else:
            run(['bash', SCRIPTS / 'build-package-native.sh', root], arch_env, log)
        native = validate_native(args, root, arch=arch)
    if args.universal:
        native_root = merge_universal(args, env, log, slices, args.output / UNIVERSAL_ROOT)
        native = read_record(native_root / 'native-build.json')
    else:
        native_root = slices['arm64']
    static = Path(native['static_deps']).resolve()
    env.update(QEMU_BUILD_DIR=str(native_root / 'qemu-build'), LTM_DEPS_PREFIX=str(native_root / 'prefix'),
               LTM_STATIC_DEPS=str(static), USBMUXD_BIN=str(native_root / 'build/usbmuxd/src/usbmuxd'),
               IBOOT32PATCHER_BIN=str(native_root / PATCHER))
    guest = args.guest_tools or args.output / 'guest/guest-tools'
    if not args.guest_tools:
        run(['bash', SCRIPTS / 'build-guest-tools.sh', guest.parent], env, log)
    validate_guest(args, guest)
    env['LTM_GUEST_TOOLS_DIR'] = str(guest)
    product = build_app(args, env, log, native_root / 'qemu-build')
    firmwarekit = build_firmwarekit(args, log)
    app = args.output / product.name
    run(['ditto', product, app], env, log)
    env['LTM_BASE_BLOB'] = str(bundled_base(args, env, log, firmwarekit, guest, product / 'Contents/MacOS/LightTouchDevice'))
    env['LTM_FIRMWAREKIT'] = str(firmwarekit)
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
