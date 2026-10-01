#!/usr/bin/env python3
"""The app's test runner: one tier per invocation, one line per check, a summary, exit 1 on any FAIL.

    tests/run.py offline  [--only NAME ...] [-j N]     no emulator: tests/offline/check-*.py (swiftc on the app's
                                                        sources plus temp fixtures), run-catalog-checks.py, and the
                                                        --offline halves of check-activation-gate / check-boot-deadline
    tests/run.py release  [--only NAME ...] [-j N] [--network]
                                                        packaging and build checks: tests/release/*.py and
                                                        scripts/test-glib-compat.py; test-dependency-sources.py (the
                                                        one that fetches) only with --network
    tests/run.py sessions [--only NAME ...]             helper + emulator, one at a time, every boot headless with
                                                        -audio driver=none: check-helper-boot, check-sessions
                                                        (--ipad-device, then --guest), check-guest-package,
                                                        check-activation-gate, check-boot-deadline, check-files-native,
                                                        check-media-native, check-proxy-trust

--only matches a substring of the check's name (repeatable). Offline and release run -j at a time (default 4)
through one shared Swift module cache: the runner puts a swiftc/xcrun shim on PATH that rewrites every
-module-cache-path to $LTM_MODULE_CACHE (default ~/Library/Caches/LightTouchMac-tests/modules), so the checks
keep pinning their own path and still share the warm cache. Logs land under --out (default a mktemp dir).

Inputs for the sessions tier, resolved here once (the checks' own flags otherwise):
  QEMU_IOS_DIR     the qemu-ios checkout (default: the pin, scripts/sources.py qemu-ios)
  LTM_QEMU_DYLIB   the helper's dylib (default $(scripts/sources.py qemu-build)/libqemu-arm.dylib)
  LTM_IPAD_DEVICE  a device.py iPad (default ~/Developer/qemu-ios-files/ipad1/repro/default-iboot)
  LTM_IPOD_DEVICE  --guest: a fresh device.py 7E18 iPod with a baked seed package (no default)
  LTM_ITPACK       --guest: the armv6 package (default $QEMU_IOS_DIR/build/guest-package/armv6.itpack)
A check whose input is missing is SKIP with the path it wanted. A check listed in XFAIL below fails on today's
code for the reason given: it runs and reports XFAIL (XPASS once it passes again) and neither fails the run.
"""
import argparse
import os
import shutil
import subprocess
import sys
import tempfile
import time
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
TESTS = ROOT / 'tests'
HOME = Path.home()
sys.path.insert(0, str(ROOT / 'scripts'))
import sources  # noqa: E402  the pinned checkouts (build-support/sources.json)

# Failing on today's code, each for a known reason. Delete the line when the check is fixed.
XFAIL = {}

TIMEOUT = 1800


def name_of(argv):
    """'offline/check-x' or 'sessions/check-sessions --guest': the check's path under tests/ plus its flags (not their values)."""
    path = Path(argv[0])
    rel = path.relative_to(TESTS) if TESTS in path.parents else Path('scripts') / path.name
    return ' '.join([str(rel), *[a for a in argv[1:] if str(a).startswith('--')]])


def display_asleep():
    """True when the main display is asleep: the Metal and ScreenCaptureKit checks cannot present or capture then."""
    import ctypes
    cg = ctypes.CDLL('/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics')
    cg.CGMainDisplayID.restype = ctypes.c_uint32
    cg.CGDisplayIsAsleep.argtypes = [ctypes.c_uint32]
    return bool(cg.CGDisplayIsAsleep(cg.CGMainDisplayID()))


# Put windows on screen. check-model and check-model-startup render headless and run their windowed
# halves only with LTM_DISPLAY_CHECKS=1 themselves.
NEEDS_DISPLAY = ('check-canvas-capture.py', 'check-log-view.py')   # put a window on screen: LTM_DISPLAY_CHECKS=1


def module_cache_shims(out):
    """A swiftc and an xcrun on PATH that route every -module-cache-path to the shared cache."""
    cache = Path(os.environ.get('LTM_MODULE_CACHE', HOME / 'Library/Caches/LightTouchMac-tests/modules'))
    cache.mkdir(parents=True, exist_ok=True)
    shim = f'''#!/usr/bin/env python3
import os, sys
args = sys.argv[1:]
if os.path.basename(sys.argv[0]) == 'xcrun':
    if args[:1] != ['swiftc']:
        os.execv('/usr/bin/xcrun', ['/usr/bin/xcrun', *args])
    args = args[1:]
if '-module-cache-path' in args:
    args[args.index('-module-cache-path') + 1] = {str(cache)!r}
else:
    args += ['-module-cache-path', {str(cache)!r}]
os.execv('/usr/bin/xcrun', ['/usr/bin/xcrun', 'swiftc', *args])   # the toolchain's swiftc, with its SDK
'''
    bin_dir = out / 'bin'
    bin_dir.mkdir(exist_ok=True)
    for tool in ('swiftc', 'xcrun'):
        (bin_dir / tool).write_text(shim)
        (bin_dir / tool).chmod(0o755)
    return bin_dir


def run_one(argv, out, env):
    name = name_of(argv)
    log = out / (name.replace('/', '_').replace(' ', '_') + '.log')
    t0 = time.monotonic()
    with open(log, 'w') as stream:
        try:
            ok = subprocess.run([sys.executable, *map(str, argv)], stdout=stream, stderr=subprocess.STDOUT,
                                cwd=ROOT, env=env, timeout=TIMEOUT).returncode == 0
        except subprocess.TimeoutExpired:
            stream.write(f'\nTIMEOUT after {TIMEOUT}s\n')
            ok = False
    why = XFAIL.get(name)
    state = 'PASS' if ok else 'FAIL'
    if why:
        state = 'XPASS' if ok else 'XFAIL'
    return state, int(time.monotonic() - t0), name, why


def offline_checks():
    checks = [[p] for p in sorted((TESTS / 'offline').glob('check-*.py'))]
    checks.append([TESTS / 'offline/run-catalog-checks.py'])
    checks.append([TESTS / 'sessions/check-activation-gate.py', '--offline'])
    checks.append([TESTS / 'sessions/check-boot-deadline.py', '--offline'])
    checks.append([TESTS / 'sessions/test-matrix-provenance.py'])   # immutable input identity and retained evidence
    checks.append([TESTS / 'sessions/test-matrix-judge.py'])   # the matrix's verdicts on fabricated event streams
    checks.append([TESTS / 'sessions/check-setup-walk.py'])   # the 5.x Setup walk's tap-retry core, fake taps
    checks.append([TESTS / 'sessions/test-proxy-trust-judge.py'])   # check-proxy-trust's home-screen verdict
    skips = []
    # Opt-in (Sam, 09-29): nothing on screen by default. LTM_DISPLAY_CHECKS=1 runs them.
    if os.environ.get('LTM_DISPLAY_CHECKS') != '1':
        skips = [(f'offline/{c}', 'opens windows on screen; LTM_DISPLAY_CHECKS=1 runs it') for c in NEEDS_DISPLAY]
        checks = [c for c in checks if c[0].name not in NEEDS_DISPLAY]
    elif display_asleep():
        skips = [(f'offline/{c}', 'the main display is asleep; Metal presents and ScreenCaptureKit capture nothing') for c in NEEDS_DISPLAY]
        checks = [c for c in checks if c[0].name not in NEEDS_DISPLAY]
    return checks, skips


def release_checks(network):
    checks = [[p] for p in sorted((TESTS / 'release').glob('*.py'))
              if network or p.name != 'test-dependency-sources.py']
    checks.append([ROOT / 'scripts/test-glib-compat.py'])   # stays in scripts/: a native-recipe input (build-release.py)
    skips = [] if network else [('release/test-dependency-sources.py', 'fetches every dependency; --network runs it')]
    return checks, skips


def session_checks():
    """The emulator-backed checks with their inputs, and the SKIPs for inputs that are missing."""
    qemu_ios = sources.path('qemu-ios')
    dylib = Path(os.environ.get('LTM_QEMU_DYLIB', sources.qemu_build() / 'libqemu-arm.dylib'))
    ipad = Path(os.environ.get('LTM_IPAD_DEVICE', HOME / 'Developer/qemu-ios-files/ipad1/repro/default-iboot'))
    ipod = os.environ.get('LTM_IPOD_DEVICE')
    itpack = Path(os.environ.get('LTM_ITPACK', qemu_ios / 'build/guest-package/armv6.itpack'))
    files = HOME / 'Developer/qemu-ios-files'
    S = TESTS / 'sessions'
    checks, skips = [], []

    def want(name, path, what):
        if Path(path).exists():
            return True
        skips.append((name, f'no {what} at {path}'))
        return False

    # Hello-only host gate: an explicitly supplied built helper, no guest.
    exit_wait = 'sessions/check-exit-wait.py'
    helper = os.environ.get('LTM_DEVICE_HELPER')
    if not helper:
        skips.append((exit_wait, 'manual host gate: supply LTM_DEVICE_HELPER and LTM_QEMU_DYLIB'))
    elif want(exit_wait, helper, 'built helper (LTM_DEVICE_HELPER)') and want(exit_wait, dylib, 'dylib (LTM_QEMU_DYLIB)'):
        checks.append([S / 'check-exit-wait.py', '--helper', Path(helper), '--dylib', dylib])

    if want('sessions/check-helper-boot.py', dylib, 'emulator dylib (LTM_QEMU_DYLIB)'):
        # The check's own iPad recipe is the direct-kernel bring-up (kboot.bin + nand/); an iBoot device has no
        # kboot.bin, so its iPad cases run only for a kboot device and are otherwise skipped by the check itself.
        ipad_flags = ['--ipad-device', ipad] if (ipad / 'kboot.bin').exists() else []
        checks.append([S / 'check-helper-boot.py', *ipad_flags, '--dylib', dylib])
        if want('sessions/check-sessions.py --ipad-device', ipad, 'iPad device (LTM_IPAD_DEVICE)'):
            checks.append([S / 'check-sessions.py', '--ipad-device', ipad, '--dylib', dylib])
        # The shipping image has no loader, so --guest upgrades its components from the checkout's own builds.
        guest = 'sessions/check-sessions.py --guest'
        missing = next((t for t in ('it-agent/it_agent', 'it-agent/it_typein.dylib', 'it-media/itphoto')
                        if not (qemu_ios / 'contrib' / t).exists()), None)
        if not ipod:
            skips.append((guest, 'LTM_IPOD_DEVICE unset: a fresh device.py 7E18 iPod'))
        elif missing:
            skips.append((guest, f'no {qemu_ios}/contrib/{missing}: build it with its build.sh'))
        elif want(guest, itpack, 'armv6 package (LTM_ITPACK)'):
            checks.append([S / 'check-sessions.py', '--guest', '--ipod-device', ipod, '--itpack', itpack,
                           '--contrib', qemu_ios / 'contrib', '--dylib', dylib])
        for check in ('check-activation-gate.py', 'check-boot-deadline.py'):
            checks.append([S / check, '--dylib', dylib])
    else:
        for c in ('check-sessions.py --ipad-device', 'check-sessions.py --guest', 'check-activation-gate.py', 'check-boot-deadline.py'):
            skips.append((f'sessions/{c}', f'no emulator dylib at {dylib} (LTM_QEMU_DYLIB)'))
    if want('sessions/check-guest-package.py', qemu_ios / 'contrib/guest-package/mkpkg.py', 'mkpkg.py (QEMU_IOS_DIR)'):
        checks.append([S / 'check-guest-package.py', '--qemu-ios', qemu_ios])
    for check in ('check-files-native.py', 'check-media-native.py'):
        if want(f'sessions/{check}', sources.qemu_build() / 'qemu-system-arm', 'qemu-system-arm (QEMU_BUILD_DIR)') \
                and want(f'sessions/{check}', files / 'nand-current', 'shipping image'):
            checks.append([S / check])
    # The web proxy's CA trusted through the guest agent on the shipping image: the helper's proxy, the armv6
    # package from the checkout, httpget (contrib/it-proxy/build.sh) for the guest-side fetch proof.
    trust = 'sessions/check-proxy-trust.py'
    if dylib.exists() and want(trust, files / 'nand-current', 'shipping image') \
            and want(trust, itpack, 'armv6 package (LTM_ITPACK)') \
            and want(trust, qemu_ios / 'contrib/it-proxy/httpget', 'httpget (contrib/it-proxy/build.sh)'):
        checks.append([S / 'check-proxy-trust.py', '--board', 'ipod', '--itpack', itpack, '--httpget', qemu_ios / 'contrib/it-proxy/httpget', '--dylib', dylib])
    return checks, skips


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('tier', choices=('offline', 'sessions', 'release'))
    ap.add_argument('--only', action='append', default=[], help='run the checks whose name contains this (repeatable)')
    ap.add_argument('-j', type=int, default=int(os.environ.get('JOBS', 4)))
    ap.add_argument('--require-inputs', action='store_true', help='fail if any selected check lacks prerequisites')
    ap.add_argument('--network', action='store_true', help='release: also test-dependency-sources.py')
    ap.add_argument('--out', type=Path, default=Path(os.environ.get('OUT') or tempfile.mkdtemp(prefix=f'ltm-{sys.argv[1] if len(sys.argv) > 1 else "run"}.')))
    args = ap.parse_args()
    args.out.mkdir(parents=True, exist_ok=True)

    if args.tier == 'offline':
        checks, skips = offline_checks()
    elif args.tier == 'release':
        checks, skips = release_checks(args.network)
    else:
        checks, skips = session_checks()
    if args.only:
        checks = [c for c in checks if any(o in name_of(c) for o in args.only)]
        skips = [s for s in skips if any(o in s[0] for o in args.only)]

    if not checks and not skips:
        ap.error('no checks match the selection')

    env = dict(os.environ)
    env['QEMU_IOS_DIR'] = str(sources.path('qemu-ios'))
    env['PATH'] = f"{module_cache_shims(args.out)}:{env['PATH']}"
    if display_asleep():
        env.pop('LTM_DISPLAY_CHECKS', None)   # windowed halves would wait forever for a frame
    jobs = 1 if args.tier == 'sessions' else args.j   # one emulator at a time
    results = []
    with ThreadPoolExecutor(jobs) as pool:
        for state, seconds, name, why in pool.map(lambda c: run_one(c, args.out, env), checks):
            print(f'{state:5} {seconds:5d}s  {name}{f"  ({why})" if why else ""}', flush=True)
            results.append(state)
    for name, why in skips:
        print(f'SKIP      -  {name}  ({why})')
    counts = {s: results.count(s) for s in ('PASS', 'FAIL', 'XFAIL', 'XPASS')}
    print(f"== {args.tier}: {counts['PASS']} passed, {counts['FAIL']} failed, {len(skips)} skipped, "
          f"{counts['XFAIL']} known failing, {counts['XPASS']} passing again; logs in {args.out}")
    return 1 if counts['FAIL'] or (args.require_inputs and skips) else 0


if __name__ == '__main__':
    sys.exit(main())
