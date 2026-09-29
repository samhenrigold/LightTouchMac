#!/usr/bin/env python3
"""The pinned source checkouts (build-support/sources.json): one resolver for every script and check.

    scripts/sources.py qemu-ios | usbmuxd     the checkout path (QEMU_IOS_DIR / USBMUXD_SOURCE_DIR override it)
    scripts/sources.py qemu-build             the development QEMU build directory (QEMU_BUILD_DIR overrides it):
                                              <qemu-ios>/<build_dir>, where libqemu-arm.dylib is
    scripts/sources.py commit NAME            the pinned commit
    scripts/sources.py check                  pinned vs the checkouts' HEAD; exit 1 on a difference

From Python: sys.path.insert(0, '<repo>/scripts'); import sources; sources.path('qemu-ios'), sources.qemu_build(),
sources.commit('usbmuxd'), sources.status(). Configuration/Shared.xcconfig cannot run this: it repeats the qemu-ios
path and build_dir literally, and scripts/test-release.py checks that it agrees with the pin.
"""
import json
import os
from pathlib import Path
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]
PIN = ROOT / 'build-support/sources.json'
ENV = {'qemu-ios': 'QEMU_IOS_DIR', 'usbmuxd': 'USBMUXD_SOURCE_DIR'}


def pin():
    return json.loads(PIN.read_text())


def path(name):
    override = os.environ.get(ENV[name])
    return Path(override if override else pin()[name]['path']).expanduser().resolve()


def qemu_build():
    override = os.environ.get('QEMU_BUILD_DIR')
    return Path(override).expanduser().resolve() if override else path('qemu-ios') / pin()['qemu-ios']['build_dir']


def commit(name):
    return pin()[name]['commit']


def head(checkout):
    """(commit, dirty) of a checkout; (None, True) when it is not a Git checkout."""
    try:
        revision = subprocess.check_output(['git', '-C', str(checkout), 'rev-parse', 'HEAD'], text=True,
                                           stderr=subprocess.DEVNULL).strip()
        dirty = bool(subprocess.check_output(['git', '-C', str(checkout), 'status', '--porcelain'], text=True))
    except (subprocess.CalledProcessError, OSError):
        return None, True
    return revision, dirty


def status(checkouts=None):
    """Per name: pinned, actual, dirty, matches. checkouts overrides the resolved paths."""
    result = {}
    for name in ENV:
        checkout = (checkouts or {}).get(name) or path(name)
        actual, dirty = head(checkout)
        pinned = commit(name)
        result[name] = {'path': str(checkout), 'pinned': pinned, 'actual': actual, 'dirty': dirty,
                        'matches': actual == pinned and not dirty}
    return result


def main(argv):
    if argv[:1] == ['qemu-build']:
        print(qemu_build())
    elif argv[:1] in (['qemu-ios'], ['usbmuxd']):
        print(path(argv[0]))
    elif len(argv) == 2 and argv[0] == 'commit' and argv[1] in ENV:
        print(commit(argv[1]))
    elif argv == ['check']:
        off = 0
        for name, s in status().items():
            state = 'ok' if s['matches'] else 'DIFFERS'
            off += not s['matches']
            print(f"{state:8} {name}: pinned {s['pinned'][:10]}, {s['path']} at {(s['actual'] or 'no git')[:10]}"
                  f"{' (dirty)' if s['dirty'] else ''}")
        return 1 if off else 0
    else:
        sys.exit(__doc__)
    return 0


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
