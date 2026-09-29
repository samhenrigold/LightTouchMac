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
            {'id': 'n72ap-7E18', 'bundled': 'device/n72ap-7E18.itbase', 'source': {'kind': 'ipsw', 'sha1': 'a' * 40},
             'recipe': {'name': 'n72'}}]}))
        self.put(self.usb / 'configure.ac')
        self.init_git(self.usb)
        self.put(self.assets / 'bootrom_240_4')
        self.put(self.assets / 'iPod2,1_3.1.3_7E18_Restore.ipsw')
        for name in ('usr/lib/libSystem.dylib', 'usr/include/stdio.h'):
            self.put(self.sdk / name)
        self.addCleanup(mock.patch.stopall)
        mock.patch.object(release, 'ROOT', self.product).start()
        mock.patch.object(release, 'SCRIPTS', self.product / 'scripts').start()
        mock.patch.object(release, 'CATALOG', self.product / 'LightTouchMac/Resources/firmware-catalog.json').start()
        self.argv = ['--output', str(self.root / 'output'), '--qemu-source', str(self.qemu),
                     '--usbmuxd-source', str(self.usb), '--assets', str(self.assets), '--sdk', str(self.sdk),
                     '--bundled-ipsw', str(self.assets / 'iPod2,1_3.1.3_7E18_Restore.ipsw')]
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

    def native_fixture(self):
        self.put(self.static / 'lib/libcrypto.a')
        for name in ('qemu-build/build.ninja', 'qemu-build/libqemu-arm.dylib',
                     'prefix/lib/libimobiledevice-1.0.dylib', 'prefix/lib/libplist-2.0.dylib',
                     'build/usbmuxd/src/usbmuxd', 'build/iBoot32Patcher/iBoot32Patcher'):
            self.put(self.native / name)
        for name in release.FFMPEG_PATCHES:
            self.put(self.qemu / 'contrib/ffmpeg' / name, 'patch ' + name)
            self.put(self.native / 'prefix/share/licenses/ffmpeg' / name, 'patch ' + name)
        record = {
            'schema_version': 1, 'qemu_source': str(self.qemu), 'usbmuxd_source': str(self.usb),
            'static_deps': str(self.static), 'usbmuxd': release.tracked_usbmuxd(self.usb),
            'recipes': {name: release.digest(self.product / name) for name in release.NATIVE_RECIPES},
            'static_inputs': [{'path': 'lib/libcrypto.a', 'sha256': release.digest(self.static / 'lib/libcrypto.a')}],
        }
        self.put(self.native / 'native-build.json', json.dumps(record))
        self.args.native_build = self.native
        return record

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
        self.put(self.assets / 'bootrom_240_4')
        (self.assets / 'iPod2,1_3.1.3_7E18_Restore.ipsw').unlink()
        with self.assertRaisesRegex(ValueError, 'built-in iPod'):
            release.validate(self.args)

    def test_bundled_base_is_prepared_packed_and_reused(self):
        """bundled_base runs the built firmwarekit (a fake here), packs its output, records it, and skips when current."""
        self.guest_fixture()
        self.args.output.mkdir()
        firmwarekit = self.root / 'fk/firmwarekit'
        firmwarekit.parent.mkdir()
        firmwarekit.write_text('#!/bin/sh\n'
                               'while [ $# -gt 0 ]; do case "$1" in --out) out=$2;; --guest-tools) tools=$2;; esac; shift; done\n'
                               'mkdir -p "$out/nand/cs0"; printf page > "$out/nand/cs0/1.page"; printf boot > "$out/iBoot.bin"\n'
                               'printf "{\\"tool\\": {\\"guest_tools\\": \\"$tools\\"}, \\"outputs\\": {}}" > "$out/device.lock.json"\n')
        firmwarekit.chmod(0o755)
        self.put(self.product / 'scripts/pack-base.py', (Path(__file__).resolve().parents[2] / 'scripts/pack-base.py').read_text())
        log = self.args.output / 'build.log'
        with contextlib.redirect_stdout(io.StringIO()) as out:
            blob = release.bundled_base(self.args, {'PATH': '/usr/bin:/bin'}, log, firmwarekit, self.guest)
        self.assertEqual(blob.read_bytes()[:8], b'ITPACK01')
        record = json.loads((blob.parent / 'bundled.json').read_text())
        self.assertEqual(record['entry'], 'n72ap-7E18')
        self.assertEqual(record['blob_sha256'], release.digest(blob))
        self.assertFalse((blob.parent / 'staging').exists())
        with contextlib.redirect_stdout(io.StringIO()) as out:
            release.bundled_base(self.args, {'PATH': '/usr/bin:/bin'}, log, firmwarekit, self.guest)
        self.assertIn('bundled: current', out.getvalue())
        with self.assertRaisesRegex(ValueError, 'needs firmwarekit'):
            release.bundled_base(self.args, {}, log, self.root / 'missing-firmwarekit', self.guest)

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
        for name in ('guest-tools/it_agent', 'ipad-guest-tools/GLEngine', 'ipad-guest-tools/MBXGLEngine',
                     'ipad-guest-tools/gles-names.h', 'ipad-guest-tools/OpenGLES-2x',
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


if __name__ == '__main__':
    unittest.main()
