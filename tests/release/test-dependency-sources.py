#!/usr/bin/env python3
"""Check cache integrity and source staging without network or dependency compilation."""
import argparse
import hashlib
import importlib.util
import json
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest import mock

spec = importlib.util.spec_from_file_location('dependency_sources', Path(__file__).resolve().parents[2] / 'scripts/dependency-sources.py')
sources = importlib.util.module_from_spec(spec)
spec.loader.exec_module(sources)


class SourceTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name).resolve()
        self.cache = self.root / 'archive cache'
        self.cache.mkdir()
        self.content = b'fixed source archive contents'
        self.manifest = self.root / 'dependencies.json'
        self.manifest.write_text(json.dumps({'schema_version': 1, 'packages': [{
            'name': 'example', 'groups': ['native'], 'archive': 'example-1.tar.gz',
            'cache_aliases': ['example.tar.gz'], 'url': 'https://example.invalid/source.tar.gz',
            'sha256': hashlib.sha256(self.content).hexdigest(),
        }]}))
        self.args = argparse.Namespace(manifest=self.manifest, group='native',
                                       destination=self.root / 'sources', cache=[self.cache], offline=True)

    def test_legacy_cache_alias_is_verified_and_recorded(self):
        (self.cache / 'example.tar.gz').write_bytes(self.content)
        sources.fetch(self.args)
        self.assertEqual((self.args.destination / 'example-1.tar.gz').read_bytes(), self.content)
        record = json.loads((self.args.destination / 'native-sources.json').read_text())
        self.assertEqual(record['packages'][0]['obtained_from'], str(self.cache / 'example.tar.gz'))

    def test_bad_cache_never_falls_back_to_network(self):
        (self.cache / 'example.tar.gz').write_bytes(b'corrupted cached bytes')
        self.args.offline = False
        with mock.patch.object(sources.subprocess, 'run') as network:
            with self.assertRaisesRegex(ValueError, 'SHA-256 mismatch'):
                sources.fetch(self.args)
            network.assert_not_called()
        self.assertFalse((self.args.destination / 'example-1.tar.gz').exists())

    def test_existing_destination_is_reverified(self):
        (self.cache / 'example.tar.gz').write_bytes(self.content)
        sources.fetch(self.args)
        (self.args.destination / 'example-1.tar.gz').write_bytes(b'modified since last fetch')
        with self.assertRaisesRegex(ValueError, 'SHA-256 mismatch'):
            sources.fetch(self.args)

    def test_offline_missing_archive_fails(self):
        with self.assertRaisesRegex(ValueError, 'offline source missing'):
            sources.fetch(self.args)

    def test_bad_download_is_removed(self):
        self.args.offline = False
        def download(command, **kwargs):
            Path(command[command.index('--output') + 1]).write_bytes(b'wrong download')
        with mock.patch.object(sources.subprocess, 'run', side_effect=download):
            with self.assertRaisesRegex(ValueError, 'SHA-256 mismatch'):
                sources.fetch(self.args)
        self.assertEqual(list(self.args.destination.iterdir()), [])

    def git(self, *args):
        return subprocess.check_output(['git', '-C', str(self.repository), *args], stderr=subprocess.DEVNULL)

    def repository_fixture(self):
        self.repository = self.root / 'repository'
        self.repository.mkdir()
        self.git('init', '-q')
        (self.repository / '.gitignore').write_text('*.o\nbuild/\n')
        (self.repository / 'main.c').write_text('original source\n')
        (self.repository / '.DS_Store').write_bytes(b'metadata')
        self.git('add', '.')
        self.git('-c', 'user.name=Source test', '-c', 'user.email=test@example.invalid',
                 '-c', 'commit.gpgsign=false', 'commit', '-qm', 'fixture')
        return argparse.Namespace(source=self.repository, destination=self.root / 'staged',
                                  record=self.root / 'staged.json')

    def test_staging_preserves_edits_and_omits_build_outputs(self):
        args = self.repository_fixture()
        (self.repository / 'main.c').write_text('current edited source\n')
        (self.repository / 'main.o').write_bytes(b'stale build product')
        sources.stage_git(args)
        self.assertEqual((args.destination / 'main.c').read_text(), 'current edited source\n')
        self.assertFalse((args.destination / 'main.o').exists())
        self.assertFalse((args.destination / '.git').exists())
        self.assertFalse((args.destination / '.DS_Store').exists())
        record = json.loads(args.record.read_text())
        self.assertTrue(record['modified'])
        self.assertEqual(record['commit'], self.git('rev-parse', 'HEAD').decode().strip())

    def test_untracked_source_cannot_silently_disappear(self):
        args = self.repository_fixture()
        (self.repository / 'new-feature.c').write_text('untracked source\n')
        with self.assertRaisesRegex(ValueError, 'new-feature.c'):
            sources.stage_git(args)
        self.assertFalse(args.destination.exists())


if __name__ == '__main__':
    unittest.main()
