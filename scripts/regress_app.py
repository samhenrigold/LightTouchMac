#!/usr/bin/env python3
"""App-level regression checks for LightTouchMac.

Reuses the qemu-ios harness (tests/ipod/regress.py) for the boot/device
machinery and adds the checks that are specific to the app's stability work:
env parity with the harness, and the snapshot save/restore round trip that
Phase 4/5 depend on — including the negative case that a bad snapshot is
detectable rather than silently "working" (the app quarantines it; here we
prove the mechanism it keys on).

    scripts/regress_app.py                 # all checks
    scripts/regress_app.py --checks env    # just the fast, device-free ones

Needs the qemu-ios checkout and its images; run locally / pre-release, not per-PR.
"""
import os, sys, re, time, subprocess, argparse

QEMU_IOS = os.path.expanduser("~/Developer/qemu-ios")
APP = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(QEMU_IOS, "tests", "ipod"))
import regress as R
if not hasattr(R, "START"):
    R.START = time.time()

FAILURES = []


def check(name, ok, detail):
    print(f"  {name:<22} {'PASS' if ok else 'FAIL'}  {detail}")
    if not ok:
        FAILURES.append(name)
    return ok


# --------------------------------------------------------------------------
# 1. env parity — the cheapest, highest-value check
# --------------------------------------------------------------------------

def boot_env_keys(text):
    """The IT_* pairs the app's setBootEnv sets."""
    return dict(re.findall(r'"(IT_[A-Z_]+)":\s*"([^"]*)"', text))


def check_env_parity():
    app_src = open(os.path.join(APP, "LightTouchMac", "EmulatorController.swift")).read()
    app = boot_env_keys(app_src)
    harness_src = open(os.path.join(QEMU_IOS, "tests", "ipod", "regress.py")).read()
    m = re.search(r"def boot_env.*?return env", harness_src, re.S)
    harness = boot_env_keys(m.group(0)) if m else {}

    # The env 3.1.3 REQUIRES to boot — both must agree on these, or one side
    # boots a device the other cannot. (IT_DIRECT_IBOOT is path-derived on both
    # and IT_IMG3_SIG_ASIS is an app-only cosmetic, so neither is compared.)
    required = ["IT_LCD_BRIGHT", "IT_WDT_NORESET", "IT_TVOUT_READY", "IT_TVOUT_VBLANK",
                "IT_BOOT_ARGS", "IT_BOOT_ARGS_DELAY_MS", "IT_BOOT_ARGS_REPEAT",
                "IT_BOOT_ARGS_INTERVAL_MS"]
    drift = [k for k in required if app.get(k) != harness.get(k)]
    check("env-parity", not drift,
          "app and harness boot env agree" if not drift
          else f"DRIFT on {drift}: app={{k: app.get(k) for k in drift}} harness={{k: harness.get(k) for k in drift}}")


# --------------------------------------------------------------------------
# snapshot round trip (harness-level, validates the exact qmp mechanism)
# --------------------------------------------------------------------------

def make_cfg(out):
    class Cfg: pass
    c = Cfg()
    c.files = os.path.expanduser("~/Developer/qemu-ios-files")
    c.base_nand = os.path.join(c.files, "nand-ultimate")
    if not os.path.exists(c.base_nand):
        c.base_nand = os.path.join(c.files, "nand-appsync3")
    c.nor = os.path.join(c.files, "ios3", "nor_7E18.bin")
    c.qemu = os.path.join(QEMU_IOS, "build-min12b", "qemu-system-arm")
    c.cpu = None; c.mem = "128M"; c.out = out
    c.overlay = os.path.join(out, "overlay"); os.makedirs(c.overlay, exist_ok=True)
    c.usbmuxd = os.path.expanduser("~/Developer/usbmuxd-qemu/usbmuxd/src/usbmuxd")
    c.usbmuxd_ok = False   # snapshot checks don't need USB
    c.wifi = False
    c.usb_port = R.free_port(1541, 1549)
    c.mux_port = R.free_port(27341, 27349)
    c.qmp_port = R.free_port(28041, 28049)
    c.proxy_lo, c.proxy_hi = 28141, 28159
    return c


def boot(cfg, procs, tag, incoming=None):
    """Boot via the harness Device, optionally restoring from a snapshot.

    Device.start() has no -incoming hook, so for a restore we spawn qemu here
    with the same argv shape plus -incoming, and hand back a QMP client.
    """
    if incoming is None:
        dev = R.Device(cfg, procs, tag)
        dev.start()
        return dev
    # Restore path: same machine string as Device.start, plus -incoming.
    machine = ("iPod-Touch,bootrom=%s/bootrom_240_4,nand=%s,nor=%s,nandrw=%s"
               % (cfg.files, cfg.base_nand, cfg.nor, cfg.overlay))
    qmp_port = R.free_port(28041, 28049)
    serial = os.path.join(cfg.out, f"{tag}-serial.log")
    argv = [cfg.qemu, "-M", machine, "-m", cfg.mem, "-display", "none",
            "-audio", "driver=none", "-serial", "file:" + serial,
            "-qmp", "tcp:127.0.0.1:%d,server=on,wait=off" % qmp_port,
            "-incoming", "file:" + incoming]
    proc = procs.spawn(argv, os.path.join(cfg.out, f"{tag}-qemu.log"), env=R.boot_env(cfg))

    class Restored:
        def __init__(self):
            self.qmp = R.QMP(qmp_port, timeout=180)
            self.dir = cfg.out
            self.tag = tag
            self.proc = proc
        def alive(self): return proc.poll() is None
        def wait_for_home(self, timeout): return R.Device.wait_for_home(self, timeout)
    return Restored()


def check_snapshot_roundtrip():
    out = os.path.join("/tmp", "ltm-snap-%d" % os.getpid())
    os.makedirs(out, exist_ok=True)
    cfg = make_cfg(out)
    procs = R.Procs()
    snapshot = os.path.join(out, "snap.migrate")
    try:
        dev = boot(cfg, procs, "boot1")
        ok, detail, _ = dev.wait_for_home(900)
        if not check("snap-boot", ok, detail):
            return
        # Save exactly as the app's bottom half does: stop + migrate file:.
        dev.qmp.cmd("stop")
        dev.qmp.cmd("migrate", uri="file:" + snapshot)
        for _ in range(60):
            info = dev.qmp.cmd("query-migrate")
            if info.get("status") == "completed":
                break
            time.sleep(0.5)
        migrated = os.path.exists(snapshot) and os.path.getsize(snapshot) > 0
        check("snap-save", migrated, f"{os.path.getsize(snapshot) if migrated else 0} bytes")
        procs.stop(dev.proc if hasattr(dev, "proc") else dev.qemu)

        # Restore: -incoming, and assert it comes alive FAST (restored, not cold).
        t0 = time.time()
        r = boot(cfg, procs, "restore", incoming=snapshot)
        ok, detail, _ = r.wait_for_home(120)
        dt = time.time() - t0
        check("snap-restore", ok and dt < 60,
              f"home in {dt:.0f}s (restored)" if ok else f"restore failed: {detail}")

        # Negative: a truncated snapshot must be DETECTABLE — the app keys its
        # quarantine on exactly this, so a bad snapshot can never silently loop.
        # A bad -incoming makes qemu exit almost immediately (so QMP never even
        # accepts a connection); that early exit IS the detection. Spawn qemu
        # directly and assert it dies rather than reaching a live home screen.
        bad = os.path.join(out, "bad.migrate")
        with open(snapshot, "rb") as f, open(bad, "wb") as g:
            g.write(f.read(4096))   # header only — not a valid stream
        machine = ("iPod-Touch,bootrom=%s/bootrom_240_4,nand=%s,nor=%s,nandrw=%s"
                   % (cfg.files, cfg.base_nand, cfg.nor, cfg.overlay))
        argv = [cfg.qemu, "-M", machine, "-m", cfg.mem, "-display", "none",
                "-audio", "driver=none",
                "-serial", "file:" + os.path.join(out, "badrestore-serial.log"),
                "-incoming", "file:" + bad]
        bp = procs.spawn(argv, os.path.join(out, "badrestore-qemu.log"), env=R.boot_env(cfg))
        exited = False
        for _ in range(45):
            if bp.poll() is not None:
                exited = True
                break
            time.sleep(1)
        check("snap-bad-detected", exited,
              "truncated snapshot makes qemu exit (quarantinable — no silent loop)"
              if exited else "BAD: qemu stayed up on a truncated snapshot")
    finally:
        procs.stop_all()


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--checks", default="env,snapshot")
    args = ap.parse_args()
    selected = args.checks.split(",")
    print("LightTouchMac app regression")
    if "env" in selected:
        check_env_parity()
    if "snapshot" in selected:
        check_snapshot_roundtrip()
    print("=" * 50)
    if FAILURES:
        print("FAILED:", ", ".join(FAILURES))
        sys.exit(1)
    print("all app checks passed")


if __name__ == "__main__":
    main()
