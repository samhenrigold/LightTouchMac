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

spec = importlib.util.spec_from_file_location('release', Path(__file__).with_name('build-release.py'))
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
        for component in release.GUEST_COMPONENTS:
            self.put(self.qemu / 'contrib' / component / 'source.c', component)
        self.put(self.usb / 'configure.ac')
        self.init_git(self.usb)
        for name in ('bootrom_240_4', 'ios3/iBoot.bin', 'ios3/nor_7E18.bin'):
            self.put(self.assets / name)
        (self.assets / 'nand-agent-v4').mkdir()
        (self.assets / 'nand-current').symlink_to('nand-agent-v4')
        for name in ('usr/lib/libSystem.dylib', 'usr/include/stdio.h'):
            self.put(self.sdk / name)
        self.addCleanup(mock.patch.stopall)
        mock.patch.object(release, 'ROOT', self.product).start()
        mock.patch.object(release, 'SCRIPTS', self.product / 'scripts').start()
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
        for name in release.GUEST_PAYLOADS:
            self.put(self.guest / name, 'payload ' + name)
        record = {
            'schema': 1, 'qemu_source': str(self.qemu),
            'builder': {'sha256': release.digest(self.product / 'scripts/build-guest-tools.sh')},
            'source_inputs': [{'path': name, 'sha256': checksum}
                              for name, checksum in release.guest_source_hashes(self.qemu).items()],
            'outputs': [{'path': name, 'sha256': release.digest(self.guest / name)}
                        for name in sorted(release.GUEST_PAYLOADS)],
        }
        self.put(self.guest.parent / 'guest-tools.json', json.dumps(record))
        self.args.guest_tools = self.guest
        return record

    def native_fixture(self):
        self.put(self.static / 'lib/libcrypto.a')
        for name in ('qemu-build/build.ninja', 'qemu-build/libqemu-arm.dylib',
                     'prefix/lib/libimobiledevice-1.0.dylib', 'prefix/lib/libplist-2.0.dylib',
                     'build/usbmuxd/src/usbmuxd'):
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
        (self.assets / 'ios3/iBoot.bin').unlink()
        with self.assertRaisesRegex(ValueError, 'bundled firmware input'):
            release.validate(self.args)

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

    def test_guest_exact_payloads_are_required(self):
        record = self.guest_fixture()
        release.validate_guest(self.args, self.guest)
        record['outputs'].pop()
        self.put(self.guest.parent / 'guest-tools.json', json.dumps(record))
        with self.assertRaisesRegex(ValueError, 'exactly the 12'):
            release.validate_guest(self.args, self.guest)

    def test_extra_guest_payload_is_rejected(self):
        self.guest_fixture()
        self.put(self.guest / 'old-helper')
        with self.assertRaisesRegex(ValueError, 'exactly the 12'):
            release.validate_guest(self.args, self.guest)

    def test_tampered_guest_payload_is_rejected(self):
        self.guest_fixture()
        self.put(self.guest / 'it_agent', 'tampered')
        with self.assertRaisesRegex(ValueError, 'Guest payload differs'):
            release.validate_guest(self.args, self.guest)

    def test_stale_guest_source_is_rejected(self):
        self.guest_fixture()
        self.put(self.qemu / 'contrib/it-agent/source.c', 'new source')
        with self.assertRaisesRegex(ValueError, 'source inputs have changed'):
            release.validate_guest(self.args, self.guest)

    def test_stale_guest_recipe_is_rejected(self):
        self.guest_fixture()
        self.put(self.product / 'scripts/build-guest-tools.sh', 'new recipe')
        with self.assertRaisesRegex(ValueError, 'recipe has changed'):
            release.validate_guest(self.args, self.guest)

    def test_stale_usbmuxd_is_rejected(self):
        self.native_fixture()
        release.validate_native(self.args, self.native)
        self.put(self.usb / 'configure.ac', 'new configure source')
        with self.assertRaisesRegex(ValueError, 'usbmuxd source has changed'):
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
        guest = self.guest.parent / 'guest-tools.json'
        records = release.copy_provenance(output, source, guest)
        self.assertEqual((output / source.name).read_bytes(), source.read_bytes())
        self.assertEqual((output / guest.name).read_bytes(), guest.read_bytes())
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
