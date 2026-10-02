#!/usr/bin/env python3
"""Kill an actual helper before hello: no guest boot, exactly-once completion and reap."""
import argparse
import json
import os
from pathlib import Path
import subprocess
import tempfile


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ('driver', 'helper', 'dylib'):
        parser.add_argument('--' + name, type=Path, required=True)
    parser.add_argument('--helper-requirement')
    args = parser.parse_args()
    with tempfile.TemporaryDirectory(prefix='ltm-kill-before-boot-') as temp:
        work = Path(temp)
        config = dict(helper=str(args.helper.resolve()), requirement=args.helper_requirement,
                      usbmuxd='', ipa='', bundleID='', work=temp, files=temp,
                      ipodNAND='', ipadBase='', killBeforeBoot=True, timeout=35)
        path = work / 'config.json'
        path.write_text(json.dumps(config))
        env = os.environ.copy()
        env['LTM_QEMU_DYLIB'] = str(args.dylib.resolve())
        result = subprocess.run([str(args.driver.resolve()), str(path)], env=env,
                                text=True, capture_output=True, timeout=45)
        print(result.stdout, end='')
        if result.stderr:
            print(result.stderr, end='')
        result.check_returncode()
        events = [json.loads(line) for line in result.stdout.splitlines() if line.startswith('{')]
        verified = [e for e in events if e.get('event') == 'killBeforeBootVerified']
        assert len(verified) == 1
        receipt = verified[0]
        assert receipt['reaped'] and not receipt['configured'] and not receipt['guestStarted']
        assert receipt['completions'] == receipt['deaths'] == 1
        assert not any(e.get('event') in ('hello', 'booted', 'configurationFailed') for e in events)
        print('PASS: actual helper killed before boot; one completion/death, reaped and lease released')


if __name__ == '__main__':
    main()
