#!/usr/bin/env python3
"""Actual helper hello-only lease checks: regular/external admission and busy/pending/symlink refusal.

Uses built production helper/session-driver and loads the supplied dylib for
hello only. No BootConfig is returned, so no .boot request or native guest runs.
"""
import argparse
import json
import os
from pathlib import Path
import subprocess
import tempfile


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--driver', type=Path, required=True)
    p.add_argument('--helper', type=Path, required=True)
    p.add_argument('--dylib', type=Path, required=True)
    p.add_argument('--helper-requirement')
    args = p.parse_args()
    with tempfile.TemporaryDirectory(prefix='ltm-helper-lease-') as temp:
        root = Path(temp)
        work = root / 'managed-work'
        work.mkdir()
        cfg = dict(helper=str(args.helper.resolve()), requirement=args.helper_requirement,
                   usbmuxd='', ipa='', bundleID='', work=str(work), files=temp,
                   ipodNAND='', ipadBase='', leaseAdmission=True, timeout=65)
        config = root / 'config.json'
        config.write_text(json.dumps(cfg))
        result = subprocess.run([str(args.driver.resolve()), str(config)],
                                env=dict(os.environ, LTM_QEMU_DYLIB=str(args.dylib.resolve())),
                                text=True, capture_output=True, timeout=75)
        print(result.stdout, end='')
        if result.stderr:
            print(result.stderr, end='')
        result.check_returncode()
        events = [json.loads(line) for line in result.stdout.splitlines() if line.startswith('{')]
        verified = [e for e in events if e['event'] == 'leaseAdmissionVerified']
        assert [(e['case'], e['admitted']) for e in verified] == [('ordinary', True), ('external', True), ('busy', False), ('pending', False), ('symlink', False)]
        assert all(e['reaped'] and e['targetUnchanged'] and not e['guestStarted'] for e in verified)
        assert (root / 'external-lease/target').read_bytes() == b'lease-target-must-stay-unchanged'
        assert (work / 'alias/lease').is_symlink()
        print('PASS: actual helper admits regular/external caller leases, refuses busy/pending/symlink before hello, reaps all owned processes')


if __name__ == '__main__':
    main()
