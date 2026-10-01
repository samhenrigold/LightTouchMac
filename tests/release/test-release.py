#!/usr/bin/env python3
"""Exercise release preflight/provenance with real temporary sources, without compilers."""
import contextlib
import importlib.util
import io
import json
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest
from unittest import mock

spec = importlib.util.spec_from_file_location('release', Path(__file__).resolve().parents[2] / 'scripts/build-release.py')
release = importlib.util.module_from_spec(spec)
spec.loader.exec_module(release)


class ReleaseTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name).resolve()
        self.product = self.root / 'product'
        self.qemu = self.root / 'qemu'
        self.usb = self.root / 'usb'
        self.assets = self.root / 'assets'
        self.sdk = self.root / 'SDK'
        self.native = self.root / 'native'
        self.static = self.root / 'static'
        self.guest = self.root / 'guest-build/guest-tools'
        for name in release.NATIVE_RECIPES | {'scripts/build-guest-tools.sh'}:
            self.put(self.product / name, 'recipe: ' + name)
        self.put(self.qemu / 'configure')
        self.put(self.qemu / 'contrib/it-agent/it_agent.c', 'agent')
        self.put(self.qemu / 'contrib/export-guest-artifacts.sh', 'export')
        self.put(self.product / 'LightTouchMac/Resources/firmware-catalog.json', json.dumps({'format': 1, 'entries': [
            {'id': 'n72ap-7E18', 'source': {'kind': 'ipsw', 'sha1': 'a' * 40},
             'recipe': {'name': 'n72'}}]}))
        self.put(self.usb / 'configure.ac')
        self.init_git(self.usb)
        for name in release.BOOTROMS:
            self.put(self.assets / name)
        for name in ('usr/lib/libSystem.dylib', 'usr/include/stdio.h'):
            self.put(self.sdk / name)
        self.addCleanup(mock.patch.stopall)
        mock.patch.object(release, 'ROOT', self.product).start()
        mock.patch.object(release, 'SCRIPTS', self.product / 'scripts').start()
        mock.patch.object(release, 'CATALOG', self.product / 'LightTouchMac/Resources/firmware-catalog.json').start()
        self.argv = ['--output', str(self.root / 'output'), '--qemu-source', str(self.qemu),
                     '--usbmuxd-source', str(self.usb), '--assets', str(self.assets), '--sdk', str(self.sdk)]
        self.args = release.parse(self.argv)

    def put(self, path, content='fixture'):
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(content)

    def git(self, root, *args):
        return subprocess.check_output(['git', '-C', str(root), *args], stderr=subprocess.DEVNULL)

    def init_git(self, root):
        root.mkdir(parents=True, exist_ok=True)
        self.git(root, 'init', '-q')
        self.git(root, 'add', '.')
        self.git(root, '-c', 'user.name=Test', '-c', 'user.email=test@example.invalid',
                 '-c', 'commit.gpgsign=false', 'commit', '-qm', 'fixture')

    def guest_fixture(self):
        """An export tree as qemu-ios contrib/export-guest-artifacts.sh stages it, with its manifest."""
        files = {}
        for directory, names in (('guest-tools', release.GUEST_PAYLOADS),
                                 ('ipad-guest-tools', release.IPAD_GUEST_PAYLOADS | {'extra-file'})):
            for name in names:
                self.put(self.guest.parent / directory / name, 'payload ' + name)
                files[f'{directory}/{name}'] = release.digest(self.guest.parent / directory / name)
        self.put(self.guest.parent / 'macos-app/entitlements.plist', 'entitlements')
        files['macos-app/entitlements.plist'] = release.digest(self.guest.parent / 'macos-app/entitlements.plist')
        manifest = {
            'schema': 1, 'source': {'path': str(self.qemu), 'commit': None, 'branch': None, 'dirty': True},
            'inputs': {name: release.digest(self.qemu / name)
                       for name in ('contrib/it-agent/it_agent.c', 'contrib/export-guest-artifacts.sh')},
            'files': files,
            'guest_package': {'serial': release.GUEST_PACKAGE_MIN_SERIAL, 'version': '1.1.5'},
        }
        self.put(self.guest.parent / 'manifest.json', json.dumps(manifest))
        self.args.guest_tools = self.guest
        return manifest

    def native_fixture(self, native=None, arch='arm64'):
        native = native or self.native
        static = self.static if native == self.native else native / 'static/prefix'
        self.put(static / 'lib/libcrypto.a')
        for name in ('qemu-build/build.ninja', 'qemu-build/libqemu-arm.dylib',
                     'prefix/lib/libimobiledevice-1.0.dylib', 'prefix/lib/libplist-2.0.dylib',
                     'build/usbmuxd/src/usbmuxd', 'build/iBoot32Patcher/iBoot32Patcher'):
            self.put(native / name)
        for name in release.FFMPEG_PATCHES:
            self.put(self.qemu / 'contrib/ffmpeg' / name, 'patch ' + name)
            self.put(native / 'prefix/share/licenses/ffmpeg' / name, 'patch ' + name)
        record = {
            'schema_version': 1, 'architecture': arch, 'qemu_source': str(self.qemu), 'usbmuxd_source': str(self.usb),
            'static_deps': str(static), 'usbmuxd': release.tracked_usbmuxd(self.usb),
            'recipes': {name: release.digest(self.product / name) for name in release.NATIVE_RECIPES},
            'static_inputs': [{'path': 'lib/libcrypto.a', 'sha256': release.digest(static / 'lib/libcrypto.a')}],
        }
        self.put(native / 'native-build.json', json.dumps(record))
        self.args.native_build = self.native
        return record

    def test_native_slice_architecture_must_match(self):
        self.guest_fixture()
        record = self.native_fixture()
        record['architecture'] = 'x86_64'
        self.put(self.native / 'native-build.json', json.dumps(record))
        with self.assertRaisesRegex(ValueError, 'not an arm64 build'):
            release.validate(self.args)

    def test_universal_reuses_one_native_root_per_slice(self):
        """--universal --native-build names a directory of arm64/ and x86_64/ roots, each filed under its own arch."""
        self.guest_fixture()
        for arch in release.UNIVERSAL_ARCHS:
            self.native_fixture(self.native / arch, arch)
        args = release.parse(self.argv + ['--universal', '--native-build', str(self.native)])
        args.guest_tools = self.guest
        self.assertEqual(release.slice_roots(args, self.native),
                         {'arm64': self.native / 'arm64', 'x86_64': self.native / 'x86_64'})
        release.validate(args)
        self.assertEqual(release.slice_roots(self.args, self.native), {'arm64': self.native})
        swapped = json.loads((self.native / 'x86_64/native-build.json').read_text())
        swapped['architecture'] = 'arm64'
        self.put(self.native / 'x86_64/native-build.json', json.dumps(swapped))
        with self.assertRaisesRegex(ValueError, 'not an x86_64 build'):
            release.validate(args)
        with contextlib.redirect_stderr(io.StringIO()), self.assertRaises(SystemExit):
            release.parse(self.argv + ['--universal', '--static-deps', str(self.static)])

    def test_universal_staged_build_keeps_a_root_and_qemu_build_per_slice(self):
        self.args.output.mkdir()
        for arch in release.UNIVERSAL_ARCHS:
            self.native_fixture(self.native / arch, arch)
        args = release.parse(self.argv + ['--universal', '--stage', 'qemu', '--native-deps', str(self.native)])
        self.assertEqual(args.qemu_build, self.qemu / 'build-release-universal')
        plain = release.parse(self.argv + ['--stage', 'qemu', '--native-deps', str(self.native / 'arm64')])
        self.assertEqual(plain.qemu_build, self.qemu / 'build-release-native')
        for arch, root in release.slice_roots(args, self.native).items():
            release.validate_native(args, root, deps_only=True, arch=arch)
        env = {'PATH': '/usr/bin:/bin'}
        self.assertIs(release.slice_env(plain, env, 'arm64', self.native), env)
        x86 = release.slice_env(args, env, 'x86_64', self.native / 'x86_64')
        self.assertEqual((x86['LTM_ARCH'], x86['PKG_CONFIG_LIBDIR']), ('x86_64', str(self.native / 'x86_64/prefix/lib/pkgconfig')))
        self.assertEqual(release.QEMU_CROSS['arm64'], [])
        self.assertIn('--cpu=x86_64', release.QEMU_CROSS['x86_64'])

    def test_universal_builds_every_host_binary_for_both_slices(self):
        """xcodebuild (the app and LightTouchDevice) and swift build (firmwarekit) get both arches only with --universal."""
        commands = []
        def fake_run(command, env, log, cwd=None):
            commands.append(list(map(str, command)))
            products = self.args.output / 'DerivedData/Build/Products/Release/Light Touch.app/Contents'
            products.mkdir(parents=True, exist_ok=True)
            (products / 'Info.plist').write_text('plist')
        universal = release.parse(self.argv + ['--universal'])
        self.args.output.mkdir()
        bin_path = self.root / 'fk-bin'
        self.put(bin_path / 'firmwarekit', 'binary')
        with mock.patch.object(release, 'run', fake_run), \
                mock.patch.object(release.subprocess, 'check_output', return_value=str(bin_path) + '\n'):
            for args in (self.args, universal):
                release.build_app(args, {}, None, self.root / 'qemu-build')
                release.build_firmwarekit(args, None)
        plain_app, plain_fk, universal_app, universal_fk = commands
        self.assertIn('ARCHS=arm64', plain_app)
        self.assertNotIn('ONLY_ACTIVE_ARCH=NO', plain_app)
        self.assertEqual(universal_app[-1], 'build')
        self.assertIn('ARCHS=arm64 x86_64', universal_app)
        self.assertIn('ONLY_ACTIVE_ARCH=NO', universal_app)
        self.assertEqual([plain_fk[i + 1] for i, a in enumerate(plain_fk) if a == '--arch'], ['arm64'])
        self.assertEqual([universal_fk[i + 1] for i, a in enumerate(universal_fk) if a == '--arch'], ['arm64', 'x86_64'])

    def test_plan_validates_without_creating_output(self):
        with contextlib.redirect_stdout(io.StringIO()):
            self.assertEqual(release.main(self.argv + ['--plan']), 0)
        self.assertFalse(self.args.output.exists())

    def test_staged_build_resumes_in_existing_output_and_reuses_deps_only(self):
        with contextlib.redirect_stderr(io.StringIO()), self.assertRaises(SystemExit):
            release.parse(self.argv + ['--stage', 'native'])  # needs --native-deps
        self.native_fixture()
        self.args.output.mkdir()
        args = release.parse(self.argv + ['--stage', 'qemu', '--native-deps', str(self.native)])
        release.validate_output(args)
        self.assertEqual(args.qemu_build, self.qemu / 'build-release-native')
        (self.native / 'qemu-build/libqemu-arm.dylib').unlink()
        release.validate_native(args, self.native, deps_only=True)
        with self.assertRaisesRegex(ValueError, 'QEMU library'):
            release.validate_native(args, self.native)

    def test_missing_firmware_is_rejected(self):
        (self.assets / 'bootrom_240_4').unlink()
        with self.assertRaisesRegex(ValueError, 'bundled firmware input'):
            release.validate(self.args)

    def test_every_board_bootrom_is_required_and_packaged(self):
        """Each DeviceProfile.bootromName is a release input, and package.sh copies the same list flat into Resources/device."""
        repo = Path(__file__).resolve().parents[2]
        profile = (repo / 'LightTouchMac/Device/DeviceProfile.swift').read_text()
        self.assertEqual({Path(name).name for name in release.BOOTROMS}, {'bootrom_240_4', 'bootrom_s5l8900'})
        for name in release.BOOTROMS:
            self.assertIn(f'"{Path(name).name}"', profile)
        package = (repo / 'scripts/package.sh').read_text()
        self.assertIn('BOOTROMS=(' + ' '.join(release.BOOTROMS) + ')', package)
        self.assertIn('for rom in "${BOOTROMS[@]}"; do cp "$FILES/$rom" "$DEVICE/"; done', package)
        (self.assets / 'ipod1g/bootrom_s5l8900').unlink()
        with self.assertRaisesRegex(ValueError, 'bundled firmware input'):
            release.validate(self.args)

    def test_build_record_names_no_local_path(self):
        """build-inputs.json ships in the bundle: the checkouts' and binaries' absolute paths stay out of it, and a
        local path anything else brings in stops the build."""
        self.native_fixture()
        self.guest_fixture()
        self.args.output.mkdir()
        self.put(self.native / 'build/iBoot32Patcher/build.json', json.dumps(
            {'commit': 'c' * 40, 'sha256': 'd' * 64, 'binary': str(self.native / 'build/iBoot32Patcher/iBoot32Patcher')}))
        self.put(self.product / 'LightTouchMac.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved', '{"pins": []}')
        sources = {name: {'revision': None, 'dirty': True, 'source_sha256': '0' * 64, 'files': 1, 'submodules': {}}
                   for name in ('app', 'qemu', 'usbmuxd')}
        record = release.write_build_record(self.args, sources, self.native, self.native / 'qemu-build', self.guest)
        text = record.read_text()
        self.assertNotIn(str(self.root), text)
        self.assertEqual(json.loads(text)['native_artifacts']['iboot32patcher'], {'commit': 'c' * 40, 'sha256': 'd' * 64})
        self.assertEqual(set(json.loads(text)['pin']['qemu-ios']), {'pinned', 'actual', 'dirty', 'matches'})
        # A source-only revision change must refresh the shipped receipt even
        # when the compiled payload and source bytes have not changed.
        sources['qemu']['revision'] = 'e' * 40
        changed = release.write_build_record(self.args, sources, self.native, self.native / 'qemu-build', self.guest).read_text()
        self.assertNotEqual(text, changed)
        self.assertEqual(json.loads(changed)['sources']['qemu']['revision'], 'e' * 40)
        self.put(self.native / 'build/iBoot32Patcher/build.json', json.dumps({'commit': 'c' * 40, 'source': str(Path.home() / 'src')}))
        with self.assertRaisesRegex(ValueError, 'local path'):
            release.write_build_record(self.args, sources, self.native, self.native / 'qemu-build', self.guest)

    def test_existing_and_symlink_outputs_are_rejected(self):
        self.args.output.mkdir()
        with self.assertRaises(ValueError):
            release.validate_output(self.args)
        self.args.output.rmdir()
        self.args.output.symlink_to(self.root / 'does-not-exist')
        with contextlib.redirect_stderr(io.StringIO()), self.assertRaises(SystemExit):
            release.parse(self.argv)

    def test_output_cannot_pollute_sources_or_inputs(self):
        self.args.output = self.product / 'release-artifacts'
        with self.assertRaisesRegex(ValueError, 'Git-ignored'):
            release.validate_output(self.args)
        self.args.output = self.assets / 'release-artifacts'
        with self.assertRaisesRegex(ValueError, 'outside'):
            release.validate_output(self.args)

    def test_ignored_output_does_not_change_source_identity(self):
        self.put(self.product / '.gitignore', 'custom-output/\n')
        self.init_git(self.product)
        self.args.output = self.product / 'custom-output'
        release.validate_output(self.args)
        before = release.source_identity(self.product)
        self.put(self.args.output / 'new-binary')
        self.assertEqual(before, release.source_identity(self.product))

    def test_guest_required_payloads_are_required(self):
        manifest = self.guest_fixture()
        release.validate_guest(self.args, self.guest)
        for name in ('guest-tools/it_agent', 'ipad-guest-tools/OpenGLES',
                     'ipad-guest-tools/gles-names.h',
                     'ipad-guest-tools/OpenGLES-1x', 'ipad-guest-tools/opengles-1x.exports'):
            missing = dict(manifest, files={k: v for k, v in manifest['files'].items() if k != name})
            self.put(self.guest.parent / 'manifest.json', json.dumps(missing))
            with self.assertRaisesRegex(ValueError, 'missing from the export manifest: ' + Path(name).name):
                release.validate_guest(self.args, self.guest)
        self.put(self.guest.parent / 'manifest.json', json.dumps(dict(manifest, guest_package={'serial': 6})))
        with self.assertRaisesRegex(ValueError, f'serial 6 predates {release.GUEST_PACKAGE_MIN_SERIAL}'):
            release.validate_guest(self.args, self.guest)

    def test_guest_directory_must_match_manifest(self):
        self.guest_fixture()
        self.put(self.guest / 'old-helper')
        with self.assertRaisesRegex(ValueError, 'differs from the export manifest'):
            release.validate_guest(self.args, self.guest)
        (self.guest / 'old-helper').unlink()
        (self.guest.parent / 'ipad-guest-tools/extra-file').unlink()
        with self.assertRaisesRegex(ValueError, 'differs from the export manifest'):
            release.validate_guest(self.args, self.guest)

    def test_tampered_guest_payload_is_rejected(self):
        self.guest_fixture()
        self.put(self.guest / 'it_agent', 'tampered')
        with self.assertRaisesRegex(ValueError, 'Guest payload differs'):
            release.validate_guest(self.args, self.guest)

    def test_stale_guest_source_is_rejected(self):
        self.guest_fixture()
        self.put(self.qemu / 'contrib/it-agent/it_agent.c', 'new source')
        with self.assertRaisesRegex(ValueError, 'source inputs have changed'):
            release.validate_guest(self.args, self.guest)

    def test_stale_guest_recipe_is_rejected(self):
        self.guest_fixture()
        self.put(self.qemu / 'contrib/export-guest-artifacts.sh', 'new recipe')
        with self.assertRaisesRegex(ValueError, 'source inputs have changed'):
            release.validate_guest(self.args, self.guest)

    def test_guest_tools_from_another_commit_are_rejected(self):
        manifest = self.guest_fixture()
        self.put(self.guest.parent / 'manifest.json', json.dumps(dict(manifest, source=dict(manifest['source'], commit='0' * 40))))
        with self.assertRaisesRegex(ValueError, 'not the checkout'):
            release.validate_guest(self.args, self.guest)

    def test_guest_cache_reuses_identical_inputs_across_unrelated_commits(self):
        manifest = self.guest_fixture()
        manifest['source']['commit'] = 'old-commit'
        manifest['build_context'] = {'sdk': 'fixture', 'tools': 'fixture'}
        self.put(self.guest.parent / 'manifest.json', json.dumps(manifest))
        snapshot = {key: manifest[key] for key in ('inputs', 'build_context')}
        with mock.patch.object(release, 'guest_inputs_now', return_value=snapshot):
            self.assertEqual(release.validate_guest(self.args, self.guest)['source']['commit'], 'old-commit')
        for key, message in (('inputs', 'inventory'), ('build_context', 'SDK or toolchain')):
            with self.subTest(key=key):
                changed = dict(snapshot, **{key: dict(snapshot[key], new='changed')})
                with mock.patch.object(release, 'guest_inputs_now', return_value=changed):
                    with self.assertRaisesRegex(ValueError, message):
                        release.validate_guest(self.args, self.guest)

    def test_guest_snapshot_failures_require_a_rebuild(self):
        for manifest in ({'build_context': {}}, {'build_context': {'sdk': {
                'armv6': {'path': str(self.sdk)}, 'ipad': {'path': str(self.sdk)}}}}):
            with self.subTest(manifest=manifest):
                # The second case reaches the missing inventory helper in the fixture checkout.
                with self.assertRaisesRegex(ValueError, 'Cannot verify guest build inputs'):
                    release.guest_inputs_now(self.args, manifest)

    def test_signed_build_must_come_from_the_pin(self):
        """Ad-hoc builds record the difference; a Developer ID build from another commit needs --allow-unpinned."""
        status = release.pin_status(self.args)
        self.assertEqual({name: s['matches'] for name, s in status.items()}, {'qemu-ios': False, 'usbmuxd': False})
        signed = release.parse(self.argv + ['--sign-id', 'Developer ID Application: Test'])
        with self.assertRaisesRegex(ValueError, 'Not built from the pin.*qemu-ios pinned'):
            release.validate(signed)
        release.validate(release.parse(self.argv + ['--sign-id', 'Developer ID Application: Test', '--allow-unpinned']))
        pinned = dict(release.pins.pin())
        for name in ('qemu-ios', 'usbmuxd'):
            pinned[name] = dict(pinned[name], commit=release.pins.head(self.usb)[0])
        with mock.patch.object(release.pins, 'pin', return_value=pinned):
            self.assertTrue(release.pin_status(release.parse(self.argv + ['--qemu-source', str(self.usb)]))['qemu-ios']['matches'])

    def test_xcconfig_repeats_the_pin(self):
        """Configuration/Shared.xcconfig cannot run sources.py: its two lines must say what the pin says."""
        pin = release.pins.pin()['qemu-ios']
        settings = dict(line.split(' = ', 1) for line in (Path(__file__).parents[2] / 'Configuration/Shared.xcconfig')
                        .read_text().splitlines() if ' = ' in line and not line.startswith('//'))
        self.assertEqual(settings['QEMU_IOS_DIR'], pin['path'].replace('~', '$(HOME)', 1))
        self.assertEqual(settings['QEMU_BUILD_DIR'], '$(QEMU_IOS_DIR)/' + pin['build_dir'])
        self.assertEqual(len(pin['commit']), 40)
        self.assertEqual(len(release.USBMUXD_COMMIT), 40)

    def test_stale_usbmuxd_is_rejected(self):
        self.native_fixture()
        release.validate_native(self.args, self.native)
        self.put(self.usb / 'configure.ac', 'new configure source')
        with self.assertRaisesRegex(ValueError, 'usbmuxd source has changed'):
            release.validate_native(self.args, self.native)

    def test_missing_iboot32patcher_is_rejected(self):
        self.native_fixture()
        release.validate_native(self.args, self.native)
        (self.native / 'build/iBoot32Patcher/iBoot32Patcher').unlink()
        with self.assertRaisesRegex(ValueError, 'iBoot32Patcher'):
            release.validate_native(self.args, self.native)

    def test_static_override_must_match_configured_prefix(self):
        self.native_fixture()
        self.args.static_deps = self.root / 'different-static'
        with self.assertRaisesRegex(ValueError, 'differs from the prefix'):
            release.validate_native(self.args, self.native)

    def test_changed_ffmpeg_patch_invalidates_native_reuse(self):
        self.native_fixture()
        self.put(self.qemu / 'contrib/ffmpeg/h264-chunk-er.patch', 'updated patch')
        with self.assertRaisesRegex(ValueError, 'FFmpeg patch has changed'):
            release.validate_native(self.args, self.native)

    def test_tampered_static_archive_is_rejected(self):
        self.native_fixture()
        self.put(self.static / 'lib/libcrypto.a', 'tampered archive')
        with self.assertRaisesRegex(ValueError, 'Static input differs'):
            release.validate_native(self.args, self.native)

    def test_unrecorded_static_library_is_rejected(self):
        self.native_fixture()
        self.put(self.static / 'lib/libcrypto.dylib')
        with self.assertRaisesRegex(ValueError, 'file inventory differs'):
            release.validate_native(self.args, self.native)

    def test_recipe_changes_invalidate_native_reuse(self):
        self.native_fixture()
        self.put(self.product / 'scripts/build-package-native.sh', 'changed recipe')
        with self.assertRaisesRegex(ValueError, 'Native recipe differs'):
            release.validate_native(self.args, self.native)

    def test_full_provenance_is_copied_verbatim(self):
        self.native_fixture()
        self.guest_fixture()
        output = self.root / 'receipt-output'
        output.mkdir()
        source = self.native / 'native-build.json'
        guest = self.guest.parent / 'manifest.json'
        records = release.copy_provenance(output, source, guest)
        self.assertEqual((output / source.name).read_bytes(), source.read_bytes())
        self.assertEqual((output / 'guest-manifest.json').read_bytes(), guest.read_bytes())
        self.assertEqual(records[source.name], release.digest(source))

    def test_inventory_records_links_without_following_them(self):
        app = self.root / 'Test.app'
        self.put(app / 'regular-file', 'contents')
        (app / 'link').symlink_to('regular-file')
        records = {item['path']: item for item in release.inventory(app)}
        self.assertEqual(records['link'], {'path': 'link', 'symlink': 'regular-file'})
        self.assertEqual(records['regular-file']['sha256'], release.digest(app / 'regular-file'))

    def test_already_dirty_submodule_content_is_identified(self):
        module = self.product / 'module'
        self.put(self.product / 'main.c')
        self.init_git(self.product)
        self.put(module / 'source.c', 'initial')
        self.init_git(module)
        revision = self.git(module, 'rev-parse', 'HEAD').decode().strip()
        self.git(self.product, 'update-index', '--add', '--cacheinfo', f'160000,{revision},module')
        self.put(module / 'source.c', 'first modification')
        before = release.source_identity(self.product)
        self.put(module / 'source.c', 'second modification')
        after = release.source_identity(self.product)
        self.assertTrue(before['dirty'])
        self.assertTrue(after['dirty'])
        self.assertNotEqual(before['source_sha256'], after['source_sha256'])
        self.assertEqual(after['submodules']['module']['recorded_revision'], revision)
        shutil.rmtree(module)
        self.assertFalse(release.source_identity(self.product)['submodules']['module']['initialized'])


class RemoveTreeTests(unittest.TestCase):
    def test_locked_base_takes_no_new_files_and_still_removes(self):
        """verify boots a base locked as the app locks one: a Finder .DS_Store can't land in it, and clean() removes it."""
        with tempfile.TemporaryDirectory() as temporary:
            base = Path(temporary) / 'prepare-check/out'
            (base / 'nand/cs0').mkdir(parents=True)
            (base / 'nand/cs0/1.page').write_bytes(b'x')
            release.lock_base(base)
            for directory in (base, base / 'nand', base / 'nand/cs0'):
                with self.assertRaises(PermissionError):
                    (directory / '.DS_Store').write_bytes(b'')
            release.remove_tree(base.parent)
            self.assertFalse(base.parent.exists())

    def test_retries_when_finder_refills_a_directory(self):
        with tempfile.TemporaryDirectory() as temporary:
            work = Path(temporary) / 'prepare-check'
            (work / 'out/nand').mkdir(parents=True)
            (work / 'out/nand/nand.bin').write_bytes(b'x')
            real, calls = shutil.rmtree, []

            def finder_rmtree(path, *args, **kwargs):   # Finder writes .DS_Store as the tree empties
                calls.append(path)
                if len(calls) == 1:
                    (work / 'out/nand/nand.bin').unlink()
                    (work / 'out/nand/.DS_Store').write_bytes(b'')
                    raise OSError(66, 'Directory not empty', str(work / 'out/nand'))
                return real(path, *args, **kwargs)
            with mock.patch.object(release.shutil, 'rmtree', finder_rmtree), mock.patch.object(release.time, 'sleep'):
                release.remove_tree(work)
            self.assertFalse(work.exists())
            self.assertEqual(len(calls), 2)


if __name__ == '__main__':
    unittest.main()
