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

def computed_boot_args(text):
    # Resolve the known Swift expression, excluding the two optional app flags.
    # Unknown expressions fail parity instead of silently using a guessed base.
    base = re.search(
        r'static var bootArgs: String\s*\{\s*var args = "([^"]*)"\s*'
        r'if verboseBoot \{ args \+= " -v" \}\s*'
        r'if kernelConsole \{ args \+= " serial=3 debug=0x8" \}\s*'
        r'return args\s*\}', text)
    return base.group(1) if base else None


def boot_env_keys(text):
    """Literal IT_* pairs, including the former computed app boot-args value."""
    values = dict(re.findall(r'"(IT_[A-Z_]+)":\s*"([^"]*)"', text))
    if re.search(r'"IT_BOOT_ARGS":\s*Self\.bootArgs\b', text):
        base = computed_boot_args(text)
        if base is not None:
            values["IT_BOOT_ARGS"] = base
    return values


def boot_config_keys(text):
    """Compare effective startup values regardless of property/alias spelling."""
    values = boot_env_keys(text)
    for prop, alias in (("boot-args-delay-ms", "IT_BOOT_ARGS_DELAY_MS"),
                        ("boot-args-repeat", "IT_BOOT_ARGS_REPEAT"),
                        ("boot-args-interval-ms", "IT_BOOT_ARGS_INTERVAL_MS")):
        if "," + prop + "=" in text:
            # Explicit properties override aliases, even if the checker cannot
            # evaluate them. Missing values must remain a parity failure.
            values.pop(alias, None)
            match = re.search(r"," + prop + r"=(\d+)(?=,|\")", text)
            if match:
                values[alias] = match.group(1)
    if ",boot-args=" in text:
        values.pop("IT_BOOT_ARGS", None)
        expression = r',boot-args=\(Self.bootArgs.replacingOccurrences(of: ",", with: ",,"))'
        if expression in text:
            base = computed_boot_args(text)
            if base is not None:
                values["IT_BOOT_ARGS"] = base
    return values


def env_drift(app, harness, required):
    return {key: (app.get(key), harness.get(key)) for key in required
            if key not in app or key not in harness or app[key] != harness[key]}


def self_test():
    source = '''
    static var bootArgs: String {
        var args = "test=1"
        if verboseBoot { args += " -v" }
        if kernelConsole { args += " serial=3 debug=0x8" }
        return args
    }
    "IT_BOOT_ARGS": Self.bootArgs,
    "IT_WDT_NORESET": "1"
    '''
    app = boot_env_keys(source)
    assert app == {"IT_BOOT_ARGS": "test=1", "IT_WDT_NORESET": "1"}
    assert not env_drift(app, dict(app), app)
    assert env_drift({}, {}, ["missing"]) == {"missing": (None, None)}
    assert env_drift(app, {}, ["IT_BOOT_ARGS"]) == {"IT_BOOT_ARGS": ("test=1", None)}
    assert env_drift({"key": "1"}, {"key": "2"}, ["key"]) == {"key": ("1", "2")}
    assert "IT_BOOT_ARGS" not in boot_env_keys(source.replace("return args", "return other"))
    properties = source + r' ",boot-args=\(Self.bootArgs.replacingOccurrences(of: ",", with: ",,"))"'
    properties += '\n",boot-args-delay-ms=1500,boot-args-repeat=200,boot-args-interval-ms=250"'
    effective = boot_config_keys(properties)
    expected = {**app, "IT_BOOT_ARGS_DELAY_MS":"1500", "IT_BOOT_ARGS_REPEAT":"200",
                "IT_BOOT_ARGS_INTERVAL_MS":"250"}
    assert not env_drift(effective, expected, expected)
    assert "IT_BOOT_ARGS" not in boot_config_keys(properties.replace("return args", "return other"))
    assert "IT_BOOT_ARGS" not in boot_config_keys(properties.replace('with: ",,"', 'with: ","'))
    assert "IT_BOOT_ARGS_REPEAT" not in boot_config_keys(properties.replace("repeat=200", "repeat=unknown"))
    assert env_drift(boot_config_keys(properties.replace("repeat=200", "repeat=201")),
                     expected, expected) == {"IT_BOOT_ARGS_REPEAT": ("201", "200")}
    aliases = properties + '\n"IT_BOOT_ARGS_REPEAT": "999"'
    assert boot_config_keys(aliases)["IT_BOOT_ARGS_REPEAT"] == "200"
    assert boot_config_keys(properties.replace('test=1', 'test=1,more=2'))["IT_BOOT_ARGS"] == "test=1,more=2"
    print("env parity self-test passed")


def check_env_parity():
    app_src = open(os.path.join(APP, "LightTouchMac", "EmulatorController.swift")).read()
    app = boot_config_keys(app_src)
    harness_src = open(os.path.join(QEMU_IOS, "tests", "ipod", "regress.py")).read()
    m = re.search(r"def boot_env.*?return env", harness_src, re.S)
    harness = boot_config_keys(m.group(0)) if m else {}

    # Required effective boot configuration must agree, or one side
    # boots a device the other cannot. (Direct iBoot is now a machine property,
    # and IT_LCD_BRIGHT is a harness-only knob — its lit-pixel checks need full exposure, while the app
    # must show the real backlight or Lock looks dead — so none are compared.)
    required = ["IT_TVOUT_READY",
                "IT_BOOT_ARGS", "IT_BOOT_ARGS_DELAY_MS", "IT_BOOT_ARGS_REPEAT",
                "IT_BOOT_ARGS_INTERVAL_MS"]
    check("obsolete-env-absent", all(key not in app and key not in harness
          for key in ("IT_TVOUT_VBLANK", "IT_IMG3_SIG_ASIS")),
          "removed behavior switches stay absent")
    check("guest-reset-enabled", "IT_WDT_NORESET" not in app and
          "IT_WDT_NORESET" not in harness,
          "neither launcher suppresses guest watchdog reset commands")
    check("direct-boot-property", ",direct-iboot=" in app_src and ",direct-llb=" in app_src
          and '"IT_DIRECT_IBOOT":' not in app_src,
          "app selects direct boot explicitly without a process-wide environment mutation")
    check("boot-properties", all(
          "," + prop + "=" in app_src and '"' + alias + '":' not in app_src
          for prop, alias in (("boot-args", "IT_BOOT_ARGS"),
                              ("boot-args-delay-ms", "IT_BOOT_ARGS_DELAY_MS"),
                              ("boot-args-repeat", "IT_BOOT_ARGS_REPEAT"),
                              ("boot-args-interval-ms", "IT_BOOT_ARGS_INTERVAL_MS"))),
          "app sets boot configuration through startup properties")
    drift = env_drift(app, harness, required)
    check("env-parity", not drift,
          "app and harness effective boot configuration agree" if not drift
          else f"DRIFT (app, harness): {drift}")


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
    c.qemu = os.environ.get("QEMU", os.path.join(QEMU_IOS, "build-min12b", "qemu-system-arm"))
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
        migrated = (info.get("status") == "completed" and
                    os.path.exists(snapshot) and os.path.getsize(snapshot) > 0)
        if not check("snap-save", migrated,
                     f"status={info.get('status')}, {os.path.getsize(snapshot) if migrated else 0} bytes"):
            return
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
    ap.add_argument("--self-test", action="store_true")
    args = ap.parse_args()
    if args.self_test:
        self_test()
        return
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
