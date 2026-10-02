#!/usr/bin/env python3
"""Actual shared session owner cancellation-resistant exit wait; helper hello only.

Requires explicit built --helper and --dylib. No .boot request, guest, USB
service, or QEMU build occurs. Import DeviceRuntime and its actual link /
reaper with HostRuntime, then verify cancellation, deadline boundaries, live
lease exclusion, and exactly-once owned helper reaping. CPU observations use a
wide host budget; they do not establish a portable performance percentage.
"""
import argparse
import ctypes
import hashlib
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'scripts'))
import device_runtime


class BSDInfo(ctypes.Structure):
    """Public macOS proc_bsdinfo layout; only used for failure cleanup identity."""
    _fields_ = [(name, ctypes.c_uint32) for name in (
        'flags', 'status', 'xstatus', 'pid', 'parent', 'uid', 'gid', 'ruid',
        'rgid', 'svuid', 'svgid', 'reserved')]
    _fields_ += [('comm', ctypes.c_char * 16), ('name', ctypes.c_char * 32)]
    _fields_ += [(name, ctypes.c_uint32) for name in (
        'nfiles', 'pgid', 'jobc', 'tty', 'ttygroup')]
    _fields_ += [('nice', ctypes.c_int32), ('started', ctypes.c_uint64),
                ('micros', ctypes.c_uint64)]


def identity(pid):
    proc = ctypes.CDLL('/usr/lib/libproc.dylib', use_errno=True)
    info = BSDInfo()
    proc.proc_pidinfo.argtypes = [ctypes.c_int, ctypes.c_int, ctypes.c_uint64,
                                 ctypes.c_void_p, ctypes.c_int]
    if proc.proc_pidinfo(pid, 3, 0, ctypes.byref(info), ctypes.sizeof(info)) != ctypes.sizeof(info):
        return None
    path = ctypes.create_string_buffer(4096)
    if proc.proc_pidpath(pid, path, len(path)) <= 0:
        return None
    return dict(pid=info.pid, parent=info.parent, uid=info.uid,
                started=info.started, micros=info.micros,
                path=os.fsdecode(path.value), status=info.status)


def events(log):
    result = []
    for line in log.read_text(errors='replace').splitlines():
        if line.startswith('{'):
            result.append(json.loads(line))
    return result


def cleanup_owned_helper(log, driver_pid):
    """Failure backstop: never signal a pathname lookup or an unrecorded PID."""
    for record in events(log):
        if record.get('event') != 'spawn':
            continue
        observed = identity(record['pid'])
        if not observed or observed['status'] == 5:  # absent or already a zombie
            continue
        # Reparenting after driver failure does not change the recorded birth identity.
        keys = ('pid', 'uid', 'started', 'micros', 'path')
        if record['parent'] != driver_pid or record['uid'] != os.getuid():
            raise RuntimeError(f'fixture recorded an unowned helper: {record}')
        if all(observed[key] == record[key] for key in keys):
            try:
                os.kill(record['pid'], signal.SIGKILL)
            except ProcessLookupError:
                pass


def build(out):
    command = ['xcrun', 'swiftc', *device_runtime.swift_flags(ROOT),
               '-parse-as-library', '-swift-version', '5',
               '-default-isolation', 'MainActor', '-module-cache-path', str(out / 'modules')]
    command += [str(ROOT / 'LightTouchMac' / name) for name in (
        'Library/StorageLocations.swift', 'Transport/NativeLogging.swift')]
    command += [str(ROOT / 'tests/fixtures/exit-wait.swift'), '-o', str(out / 'exit-wait')]
    inputs = [Path(arg) for arg in command if str(arg).endswith(('.swift', '.c'))]
    inputs += [ROOT / 'Shared/CLink/ltm_link.c', ROOT / 'Shared/CLink/ltm_link.h',
               ROOT / 'Shared/CLink/module.modulemap', ROOT / 'Shared/Package.swift',
               *sorted((ROOT / 'Shared').glob('Device*.swift')), ROOT / 'Shared/SharedStatus.swift',
               *sorted((ROOT / 'Packages/HostRuntime/Sources/HostRuntime').rglob('*.swift')),
               ROOT / 'Packages/HostRuntime/Package.swift', ROOT / 'scripts/device_runtime.py',
               ROOT / 'scripts/swift_package.py', Path(__file__).resolve()]
    library = Path(command[command.index('-L') + 1]) / 'libDeviceRuntime.a'
    (out / 'runtime-library.json').write_text(json.dumps(dict(path=str(library),
        sha256=hashlib.sha256(library.read_bytes()).hexdigest()), indent=2) + '\n')
    source_hashes = {str(path): hashlib.sha256(path.read_bytes()).hexdigest() for path in inputs}
    (out / 'compiled-source-hashes.json').write_text(json.dumps(source_hashes, indent=2) + '\n')
    (out / 'compile-command.json').write_text(json.dumps(command, indent=2) + '\n')
    with (out / 'compile.log').open('w') as log:
        subprocess.run(command, stdout=log, stderr=subprocess.STDOUT, check=True, timeout=120)
    return out / 'exit-wait'


def run_case(binary, args, out, mode, delay, timeout):
    label = f'{mode}-{delay}-{timeout}'
    work = out / (label + '-work')
    log = out / (label + '.log')
    command = [str(binary), str(args.helper), str(work), mode, str(delay), str(timeout)]
    if args.helper_requirement:
        command.append(args.helper_requirement)
    with log.open('w') as stream:
        driver = subprocess.Popen(command, stdout=stream, stderr=subprocess.STDOUT,
                                  stdin=subprocess.DEVNULL,
                                  env=dict(os.environ, LTM_QEMU_DYLIB=str(args.dylib)))
        try:
            driver.wait(timeout=20)
        except BaseException:
            # Keep the driver alive for its actual reaper/cleanup if possible.
            try:
                cleanup_owned_helper(log, driver.pid)
            finally:
                try:
                    driver.wait(timeout=6)
                except subprocess.TimeoutExpired:
                    driver.kill()
                    driver.wait(timeout=5)
            raise
    if mode == 'failure':
        cleanup = next(event for event in events(log) if event['event'] == 'failureCleanup')
        assert driver.returncode == 1 and cleanup['reaped'] and cleanup['exclusiveReap'], cleanup
        assert cleanup['remainingPID'] == 0 and cleanup['error'] == 'injected', cleanup
        print(json.dumps(cleanup, sort_keys=True), flush=True)
        return cleanup
    if driver.returncode:
        cleanup_owned_helper(log, driver.pid)
        raise RuntimeError(f'{label}: fixture exit {driver.returncode}; see {log}')
    observations = events(log)
    result = next(event for event in observations if event['event'] == 'result')
    expected_exit = timeout > delay / 1000
    assert result['wait'] == expected_exit, result
    assert result['deadAtReturn'] == expected_exit, result
    assert result['reaped'] and result['alreadyDead'] and result['deathCount'] == 1, result
    assert not result['guestStarted'], result
    assert 0 <= result['heartbeat'] < 1.5, result
    if timeout <= 0:
        assert result['returned'] < 0.5, result
    elif not expected_exit:
        assert timeout <= result['returned'] < timeout + 1, result
    print(json.dumps(result, sort_keys=True), flush=True)
    return result


def qualify(args, out):
    out.mkdir(parents=True, exist_ok=True)
    artifacts = {name: dict(path=str(getattr(args, name)),
                            sha256=hashlib.sha256(getattr(args, name).read_bytes()).hexdigest())
                 for name in ('helper', 'dylib')}
    (out / 'artifact-inputs.json').write_text(json.dumps(artifacts, indent=2) + '\n')
    binary = build(out)
    cases = [('normal', 1200, 1), ('cancelled', 1200, 1), ('during', 1200, 1),
             ('normal', 200, 2), ('cancelled', 200, 2),
             ('cancelled', 200, 0), ('cancelled', 200, -1), ('failure', 200, 1)]
    results = [run_case(binary, args, out, *case) for case in cases]
    # A broad native-host CPU budget detects the measured ~0.42s cancellation
    # error polling, without asserting a universal ratio or millisecond timing.
    for result in results[:3]:
        assert result['cpu'] < 0.15, result
    for name, receipt in artifacts.items():
        assert hashlib.sha256(getattr(args, name).read_bytes()).hexdigest() == receipt['sha256'], f'{name} changed during qualification'
    library = json.loads((out / 'runtime-library.json').read_text())
    assert hashlib.sha256(Path(library['path']).read_bytes()).hexdigest() == library['sha256'], 'runtime library changed during qualification'
    source_hashes = json.loads((out / 'compiled-source-hashes.json').read_text())
    assert all(hashlib.sha256(Path(path).read_bytes()).hexdigest() == digest for path, digest in source_hashes.items()), 'compiled source changed during qualification'
    (out / 'results.json').write_text(json.dumps(results, indent=2) + '\n')
    print('PASS: actual hello-only helper waits preserve cancellation cleanup, finite/zero/negative deadlines, live lease exclusion, and exclusive reaping')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--helper', type=Path, required=True)
    parser.add_argument('--dylib', type=Path, required=True)
    parser.add_argument('--helper-requirement')
    parser.add_argument('--out', type=Path, help='Retain text observations and private build outputs here')
    args = parser.parse_args()
    args.helper = args.helper.resolve()
    args.dylib = args.dylib.resolve()
    for name in ('helper', 'dylib'):
        path = getattr(args, name)
        if not path.is_file():
            parser.error(f'missing required {name}: {path}')
    if args.out:
        qualify(args, args.out.resolve())
    else:
        with tempfile.TemporaryDirectory(prefix='ltm-exit-wait-') as directory:
            qualify(args, Path(directory))


if __name__ == '__main__':
    main()
