#!/usr/bin/env python3
"""Real helper hello/lease, preparation rejection and reaping; no guest is booted.

Run against a built session-driver and LightTouchDevice. The helper only loads
libqemu for its hello; the driver never sends a .boot request. All storage and
usbmuxd state is temporary and owned by this test.
"""
import argparse
import json
import os
from pathlib import Path
import subprocess
import tempfile


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--driver', type=Path, required=True)
    parser.add_argument('--helper', type=Path, required=True)
    parser.add_argument('--dylib', type=Path, required=True)
    parser.add_argument('--usbmuxd', type=Path, required=True)
    parser.add_argument('--helper-requirement')
    args = parser.parse_args()
    with tempfile.TemporaryDirectory(prefix='ltm-preparation-failure-') as temp:
        work = Path(temp)
        cfg = dict(helper=str(args.helper.resolve()), requirement=args.helper_requirement,
                   usbmuxd=str(args.usbmuxd.resolve()), ipa='', bundleID='', work=temp,
                   files=temp, ipodNAND='', ipadBase='', preparationFailure=True, timeout=35)
        path = work / 'config.json'
        path.write_text(json.dumps(cfg))
        env = os.environ.copy()
        env['LTM_QEMU_DYLIB'] = str(args.dylib.resolve())
        result = subprocess.run([str(args.driver.resolve()), str(path)], env=env,
                                text=True, capture_output=True, timeout=45)
        print(result.stdout, end='')
        if result.stderr:
            print(result.stderr, end='')
        result.check_returncode()
        events = [json.loads(line) for line in result.stdout.splitlines() if line.startswith('{')]
        names = [e['event'] for e in events]
        assert names.index('hello') < names.index('configurationFailed') < names.index('bootFailed') < names.index('death')
        assert 'booted' not in names
        verified = next(e for e in events if e['event'] == 'preparationFailureVerified')
        diagnostic = next(e['error'] for e in events if e['event'] == 'configurationFailed')
        assert verified['reaped'] and verified['leaseReleased'] and not verified['guestStarted']
        assert verified['error'] == diagnostic != 'not booted'
        print('PASS: preparation follows real helper hello; original diagnostic, reaping, lease release and untouched storage verified')


if __name__ == '__main__':
    main()
