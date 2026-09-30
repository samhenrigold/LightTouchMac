#!/usr/bin/env python3
"""Boot a disposable N72 edit candidate and read its offline-added plist twice.

Create it with StoppedEditSpikeTests first. This is research acceptance, not an
in-place editor or a publication command. All runtime writes use regress.py's
private overlay. Pass normal regress.py flags after --qemu-root and --expected.
"""
import argparse
import importlib.util
from pathlib import Path
import sys
import time

parser = argparse.ArgumentParser(add_help=False, allow_abbrev=False)
parser.add_argument("--qemu-root", required=True)
parser.add_argument("--expected", required=True)
options, forwarded = parser.parse_known_args()
root = Path(options.qemu_root).resolve()
sys.path.insert(0, str(root / "tests/ipod"))
spec = importlib.util.spec_from_file_location("regress", root / "tests/ipod/regress.py")
regress = importlib.util.module_from_spec(spec)
spec.loader.exec_module(regress)
expected = Path(options.expected).read_bytes()
remote = "/ltm-stopped-edit.plist"
reads = []


def read_probe(cfg, label):
    destination = Path(cfg.out) / ("edit-probe-" + label + ".plist")
    # Lockdown attachment can precede AFC readiness; retry only the read.
    deadline = time.monotonic() + 25
    while True:
        result = regress.afc(cfg, ["get -f %s %s" % (remote, destination)], timeout=15)
        if destination.exists() and destination.read_bytes() == expected:
            reads.append(label)
            regress.log("stopped edit probe byte-identical on " + label)
            return True, "offline-added plist matches"
        if time.monotonic() >= deadline:
            return False, (result.stdout + result.stderr)[-400:]
        time.sleep(1)


original_wait = regress.wait_for_device


def wait_with_probe(cfg, *args, **kwargs):
    udid, detail = original_wait(cfg, *args, **kwargs)
    if udid and not reads:
        ok, probe = read_probe(cfg, "first-boot")
        if not ok:
            return None, "stopped edit probe read failed: " + probe
    return udid, detail


original_persist = regress.check_persist


def persist_with_probe(cfg, dev, marker, remote_marker, result, *args, **kwargs):
    original_persist(cfg, dev, marker, remote_marker, result, *args, **kwargs)
    ok, detail = read_probe(cfg, "second-boot")
    if not ok:
        result.set(False, "offline edit missing or changed after cold reboot: " + detail)


regress.wait_for_device = wait_with_probe
regress.check_persist = persist_with_probe
sys.argv = [str(root / "tests/ipod/regress.py")] + forwarded
status = regress.main()
if status == 0 and set(reads) != {"first-boot", "second-boot"}:
    print("FAIL: acceptance did not read the offline edit on both boots")
    status = 1
raise SystemExit(status)
