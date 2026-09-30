#!/usr/bin/env python3
"""Changed inputs and damaged evidence cannot suppress a matrix run."""
import tempfile
import json
import sys
import subprocess
from unittest.mock import patch
import unittest
from pathlib import Path
import matrix_provenance as p

class ProvenanceTests(unittest.TestCase):
    def test_content_identity_survives_relocation_but_not_same_size_edit(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            a, b = root / 'a', root / 'b'
            a.write_bytes(b'abcd'); b.write_bytes(b'abcd')
            self.assertEqual(p.artifact(a), p.artifact(b))
            before = p.identity({'id': 'x'}, {'tool': p.artifact(a)}, {})
            a.write_bytes(b'abce')
            self.assertNotEqual(before, p.identity({'id': 'x'}, {'tool': p.artifact(a)}, {}))
            self.assertNotEqual(before, p.identity({'id': 'x', 'recipe': {'boot': 'iboot'}}, {'tool': p.artifact(b)}, {}))
            self.assertNotEqual(before, p.identity({'id': 'x'}, {'tool': p.artifact(b)}, {'restore': True}))

    def test_immutable_runs_and_verified_reuse(self):
        with tempfile.TemporaryDirectory() as tmp:
            expected = p.identity({'id': 'x'}, {}, {})
            first = p.run_directory(tmp, 'x', expected['sha256'])
            second = p.run_directory(tmp, 'x', expected['sha256'])
            self.assertNotEqual(first, second)
            (first / 'serial.log').write_text('good')
            record = {'provenance': expected, 'complete': True, 'artifacts': str(first), 'evidence': p.artifact(first)}
            p.atomic_json(first / 'record.json', record)
            self.assertTrue(p.reusable(record, expected))
            p.preserve_previous(tmp, 'x', record)
            p.preserve_previous(tmp, 'x', record)
            self.assertEqual(len(list((Path(tmp) / 'x/history').glob('*.json'))), 1)
            for key in ('runner_error', 'first_failure', 'skipped'):
                self.assertFalse(p.reusable({**record, key: 'bad'}, expected))
            self.assertFalse(p.reusable({}, expected))  # old skip-by-ID record
            (first / 'serial.log').write_text('evil')
            self.assertFalse(p.reusable(record, expected))
            self.assertEqual((first / 'record.json').exists(), True)

    def test_bytecode_does_not_invalidate_source_contract(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            (root / 'judge.py').write_text('judge')
            before = p.artifact(root)
            (root / '__pycache__').mkdir()
            (root / '__pycache__/judge.pyc').write_bytes(b'compiled')
            self.assertEqual(before, p.artifact(root))

class ConcurrentIndexTests(unittest.TestCase):
    def test_two_processes_with_distinct_scratch_merge_index(self):
        # Both workers repeatedly read-modify-write the shared index. An induced
        # delay after reading makes an unprotected last-writer implementation
        # lose entries rather than accidentally passing this check.
        worker = r"""
import sys, time
from pathlib import Path
sys.path.insert(0, sys.argv[1])
import matrix_provenance as p
index, label = Path(sys.argv[2]), sys.argv[3]
for i in range(20):
    def merge(current):
        time.sleep(0.002)
        current[label + str(i)] = {"scratch": str(Path.cwd())}
        return current
    p.update_index(index, merge, lambda current: p.atomic_json(index.with_suffix('.summary'), {"count": len(current)}))
"""
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            index = root / 'results.json'
            processes = []
            for label in ('a', 'b'):
                scratch = root / label
                scratch.mkdir()
                processes.append(subprocess.Popen([sys.executable, '-c', worker, str(Path(__file__).parent), str(index), label], cwd=scratch))
            for process in processes:
                self.assertEqual(process.wait(timeout=20), 0)
            values = json.loads(index.read_text())
            self.assertEqual(len(values), 40)
            self.assertEqual({v['scratch'] for v in values.values()}, {str((root / 'a').resolve()), str((root / 'b').resolve())})
            self.assertEqual(json.loads(index.with_suffix('.summary').read_text())['count'], 40)

class RunnerTests(unittest.TestCase):
    def test_runner_preserves_runs_and_reruns_changed_bytes(self):
        import matrix
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            for name in ('tests/sessions', 'tests/drivers/session-driver', 'guest', 'frameworks'):
                (root / name).mkdir(parents=True)
            binaries = {}
            for name in ('firmwarekit', 'helper', 'dylib', 'usbmuxd', 'patcher', 'ipa', 'ipsw'):
                binaries[name] = root / name
                binaries[name].write_bytes(name.encode())
            entry = {'id': 'k48ap-test', 'board': 'k48ap', 'version': '3.2.2', 'status': 'experimental',
                     'product_type': 'iPad1,1', 'source': {'sha1': 'abc'}, 'recipe': {'boot': 'iboot'}}
            catalog = root / 'catalog.json'
            catalog.write_text(json.dumps({'entries': [entry]}))
            result = root / 'results.json'
            def build(args, tools):
                (tools / 'session-driver').write_bytes(b'driver')
                return binaries['helper']
            def tz(tools, frameworks):
                path = tools / 'lockdown-tz'
                path.write_bytes(b'tz')
                return path
            def prepare(entry, entry_file, ipsw, base, a, helper, env):
                base.mkdir()
                return {'ok': True, 'seconds': 0, 'error': None}, root / 'fk.log'
            def boot(entry, base, a, helper, drive, env, app):
                (drive / 'driver.jsonl').write_text('events')
                return [], 0, root / 'serial', drive, {}
            args = ['matrix', '--guest-tools', str(root / 'guest'), '--frameworks', str(root / 'frameworks'),
                    '--dylib', str(binaries['dylib']), '--firmwarekit', str(binaries['firmwarekit']),
                    '--helper', str(binaries['helper']), '--usbmuxd', str(binaries['usbmuxd']),
                    '--patcher', str(binaries['patcher']), '--qemu-ios', str(root),
                    '--results-dir', str(root / 'runs'), '--scratch', str(root / 'scratch')]
            with patch.object(matrix, 'ROOT', root), patch.object(matrix, 'CATALOG', catalog), \
                 patch.object(matrix, 'RESULTS_JSON', result), patch.object(matrix, 'write_md'), \
                 patch.object(matrix.check_sessions, 'build', side_effect=build), \
                 patch.object(matrix.check_sessions, 'build_lockdown_tz', side_effect=tz), \
                 patch.object(matrix.check_sessions, 'tree', return_value={}), \
                 patch.object(matrix, 'test_app', return_value={'ipa': str(binaries['ipa']), 'bundle_id': 'test', 'min_os': '3.0', 'source': 'fixture'}), \
                 patch.object(matrix, 'fetch_ipsw', return_value=(binaries['ipsw'], None)), \
                 patch.object(matrix, 'verify_keys', return_value={'ok': 1, 'total': 1, 'bad': []}), \
                 patch.object(matrix, 'prepare', side_effect=prepare) as producer, \
                 patch.object(matrix, 'boot', side_effect=boot), \
                 patch.object(matrix, 'judge', return_value=({'driver_exit': 0, 'base_unchanged': True}, {}, None)), \
                 patch.object(sys, 'argv', args):
                matrix.main()
                first = json.loads(result.read_text())[entry['id']]
                matrix.main()
                self.assertEqual(producer.call_count, 1)
                self.assertEqual(json.loads(result.read_text())[entry['id']], first)
                binaries['dylib'].write_bytes(b'changed')
                matrix.main()
                second = json.loads(result.read_text())[entry['id']]
                self.assertEqual(producer.call_count, 2)
                self.assertNotEqual(first['artifacts'], second['artifacts'])
                self.assertTrue((Path(first['artifacts']) / 'record.json').exists())
                self.assertTrue((Path(second['artifacts']) / 'record.json').exists())
                self.assertEqual(len(list((root / 'runs' / entry['id'] / 'history').glob('*.json'))), 1)

if __name__ == '__main__':
    unittest.main()
