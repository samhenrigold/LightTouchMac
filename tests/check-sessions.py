#!/usr/bin/env python3
"""Two devices at once, each in its own LightTouchDevice, through the app's session code.

tests/session-driver stands in for the app. It compiles the app's own DeviceProcess and
BootRecipe (the "Helper process" section of DeviceSession.swift), DeviceServices,
IMobileDevice and the one app-wide DeviceGate, NativeLogging's log and serial captures,
DeviceStateStorage.writableNOR, and W1's DeviceLink, and runs:

  prepared   a prepared base's first-boot files: kboot/nand from base, overlay created,
             writable NOR cloned (cp -c) and made u+w, kept on the next boot, base untouched
  concurrent the iPod (nand-current, private overlay) and a fresh iPad 3.2.2 (a prepared
             base, its die id) boot at once, each with its own usbmuxd; both light
  input      each lock-screen slider is dragged; both reach their home screens
  screenshot one from each, read from its ring surface under a use count
  usb        lockdown ProductType through each device's own usbmuxd (no cross-talk)
  install    one IPA into each at once, through the gate; each lists it
  kill       kill -9 of the iPad helper: it is noticed as dead, the iPod keeps running
  restart    a fresh iPad helper and usbmuxd on the same overlay lights and answers USB
  quit       both shut down cleanly in parallel (power-off confirmed), helpers exit 0
  base       the prepared iPad base is byte- and mode-identical afterwards

    tests/check-sessions.py --ipad-device DIR [--helper PATH] [--dylib PATH] [--ipa PATH] [--work DIR]

--ipad-device is a fresh device from the qemu-ios device tool, e.g.
  python3 ~/Developer/qemu-ios-ipad1/imgtools/device.py create manifests/ipad1-7B500.json OUT \\
      --activation-hook ~/Developer/qemu-ios-files/ipad1/offline-activation/patch_lockdownd.py
--helper defaults to building the LightTouchDevice target (Debug). Boots use -audio driver=none.
Run in the foreground; every process it starts is gone when it returns. Screenshots land in
--work/<device>/*.png.
"""
import argparse, json, os, signal, subprocess, sys, tempfile, time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
HOME = Path.home()
TEAM_REQ = 'anchor apple generic and certificate leaf[subject.OU] = "SM75355Y6R"'
APP_SOURCES = ["DeviceServices", "DeviceFiles", "IMobileDevice", "DeviceProfile", "DeviceProfile+Display",
               "NativeLogging", "StorageLocations", "DeviceStateStorage"]


def tree(root):
    """Every path under a base with its size, mode and mtime: the base must not change."""
    out = {}
    for dirpath, dirs, files in os.walk(root):
        for name in dirs + files:
            p = os.path.join(dirpath, name)
            st = os.lstat(p)
            out[os.path.relpath(p, root)] = (st.st_size, st.st_mode, st.st_mtime_ns)
    return out


def build(args, out):
    source = (ROOT / "LightTouchMac/DeviceSession.swift").read_text()
    section = source[source.index("// MARK: - Helper process"):source.index("// MARK: - Sessions")]
    (out / "DeviceProcess.swift").write_text("import Foundation\nimport IOSurface\n" + section)
    subprocess.run(["clang", "-O", "-c", ROOT / "Shared/CLink/ltm_link.c", "-o", out / "ltm_link.o"], check=True)
    subprocess.run(["xcrun", "swiftc", "-swift-version", "5", "-default-isolation", "MainActor", "-module-cache-path", out / "modules",
                    "-I", ROOT / "Shared/CLink", out / "ltm_link.o", *sorted((ROOT / "Shared").glob("*.swift")),
                    ROOT / "LightTouchDevice/FrameTools.swift", *[ROOT / f"LightTouchMac/{n}.swift" for n in APP_SOURCES],
                    out / "DeviceProcess.swift", ROOT / "tests/session-driver/main.swift", "-o", out / "session-driver"],
                   check=True, stdout=open(out / "swiftc.log", "w"), stderr=subprocess.STDOUT)
    if args.helper:
        return Path(args.helper)
    qemu = os.environ.get("QEMU_IOS_DIR", str(HOME / "Developer/qemu-ios-ipad1"))
    r = subprocess.run(["xcodebuild", "-project", ROOT / "LightTouchMac.xcodeproj", "-target", "LightTouchDevice",
                        "-configuration", "Debug", f"SYMROOT={out}/xcode", f"QEMU_IOS_DIR={qemu}", "build"],
                       stdout=open(out / "xcodebuild.log", "w"), stderr=subprocess.STDOUT)
    if r.returncode:
        sys.exit(f"FAIL: building LightTouchDevice; see {out}/xcodebuild.log")
    return out / "xcode/Debug/LightTouchDevice"


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--ipad-device", type=Path, required=True)
    ap.add_argument("--helper")
    ap.add_argument("--dylib", default=os.environ.get("LTM_QEMU_DYLIB",
                                                      str(HOME / "Developer/qemu-ios-ipad1/build-w1-native/libqemu-arm.dylib")))
    ap.add_argument("--files", type=Path, default=HOME / "Developer/qemu-ios-files")
    ap.add_argument("--usbmuxd", default=str(HOME / "Developer/usbmuxd-qemu/usbmuxd/src/usbmuxd"))
    ap.add_argument("--ipa", type=Path, default=HOME / "Developer/qemu-ios-ipad1/contrib/it-harness/build/Harness.ipa")
    ap.add_argument("--bundle-id", default="com.qemuios.harness")
    ap.add_argument("--work", type=Path)
    args = ap.parse_args()
    work = args.work or Path(tempfile.mkdtemp(prefix="ltm-sessions-"))
    work.mkdir(parents=True, exist_ok=True)
    print(f"work: {work}", flush=True)
    helper = build(args, work)
    base_before = tree(args.ipad_device)
    cfg = {"helper": str(helper), "requirement": TEAM_REQ, "usbmuxd": args.usbmuxd, "ipa": str(args.ipa),
           "bundleID": args.bundle_id, "work": str(work), "files": str(args.files),
           "ipodNAND": str(args.files / os.readlink(args.files / "nand-current")), "ipadBase": str(args.ipad_device)}
    (work / "config.json").write_text(json.dumps(cfg, indent=1))
    env = dict(os.environ, LTM_QEMU_DYLIB=args.dylib)
    driver = subprocess.Popen([work / "session-driver", work / "config.json"], stdout=open(work / "driver.jsonl", "w"),
                              stderr=subprocess.STDOUT, stdin=subprocess.DEVNULL, env=env)
    events = []
    try:
        try:
            driver.wait(timeout=570)
        except subprocess.TimeoutExpired:
            driver.kill()
            driver.wait()
    finally:
        for line in (work / "driver.jsonl").read_text(errors="replace").splitlines():
            try:
                events.append(json.loads(line))
            except ValueError:
                events.append({"event": "text", "text": line})
        # Everything the driver started: its helpers and usbmuxds. Nothing else is touched.
        pids = {e["pid"] for e in events if e.get("event") in ("hello", "booted", "usbmuxd") and e.get("pid")}
        if (work / "pids").exists():
            pids |= {int(x) for x in (work / "pids").read_text().split()}
        for pid in pids:
            try:
                os.kill(pid, signal.SIGKILL)
                print(f"  (killed leftover {pid})")
            except (ProcessLookupError, PermissionError):
                pass

    def find(name, **match):
        return [e for e in events if e.get("event") == name and all(e.get(k) == v for k, v in match.items())]

    results = []

    def check(ok, what):
        results.append(bool(ok))
        print(f"  {'ok ' if ok else 'FAIL'} {what}", flush=True)

    prep = (find("preparedFiles") or [{}])[0]
    check(prep.get("kboot") and prep.get("nand") and prep.get("overlay") and prep.get("missingThrows"),
          "prepared: kboot.bin and nand/ from base, overlay created, a base without them refused")
    check(prep.get("cloneMatches") and prep.get("cloneMode", 0) & 0o200 and prep.get("secondBootKeeps") and prep.get("baseUntouched"),
          f"prepared: NOR cloned, mode {oct(prep.get('cloneMode', 0))} (u+w), kept on the next boot, base unchanged")
    hellos = find("hello")
    check(len({e["pid"] for e in hellos}) >= 3 and all(e.get("dylib") for e in hellos),
          f"one helper per device (+ the restart): pids {[e['pid'] for e in hellos]}")
    geometry = {e["device"]: (e["width"], e["height"]) for e in hellos}
    check(geometry.get("ipod") == (320, 480) and geometry.get("ipad") == (1024, 768)
          and not [e for e in events if e.get("event") == "log" and "display:" in e.get("message", "")],
          f"hello device info matches DeviceProfile, no mismatch logged: {geometry}")
    lit = {e["device"]: e for e in find("lit")}
    check("ipod" in lit and "ipad" in lit, "concurrent: both lit " + ", ".join(f"{k} {v['seconds']:.1f} s" for k, v in lit.items()))
    conc = (find("concurrent") or [{}])[0]
    check(conc.get("ipodPID") and conc.get("ipadPID") and conc["ipodPID"] != conc["ipadPID"]
          and conc.get("ipodHeartbeat", 0) > 0 and conc.get("ipadHeartbeat", 0) > 0, "both helpers alive at once, heartbeats advancing")
    shots = {e["path"].rsplit("/", 1)[-1]: e for e in find("screenshot")}
    for d in ("ipod", "ipad"):
        lock, home = shots.get(f"{d}-lock.png"), shots.get(f"{d}-home.png")
        check(lock and home and home["serial"] > lock["serial"], f"input + screenshot {d}: {lock and lock['path']} -> {home and home['path']}")
    usb = {e["device"]: e["productType"] for e in find("usb")}
    check(usb.get("ipod") == "iPod2,1" and usb.get("ipad") == "iPad1,1", f"each usbmuxd reaches its own device: {usb}")
    inst = {e["device"]: e for e in find("installed")}
    check(all(inst.get(d, {}).get("has") for d in ("ipod", "ipad")),
          "IPA installed into each through the gate: " + ", ".join(f"{k} {v['seconds']:.0f} s (attempt {v['attempt']})" for k, v in inst.items()))
    killed = (find("killed") or [{}])[0]
    check(killed.get("noticed") and killed.get("seconds", 9) < 1 and "signal 9" in killed.get("reason", ""),
          f"kill -9 iPad: noticed in {killed.get('seconds', -1) * 1000:.0f} ms: {killed.get('reason')}")
    surv = (find("survivor") or [{}])[0]
    check(not surv.get("dead", True) and surv.get("heartbeat", 0) > 20 and surv.get("frames", 0) > 0 and surv.get("productType") == "iPod2,1",
          f"the iPod kept running: +{surv.get('heartbeat')} heartbeats, +{surv.get('frames')} frames, USB {surv.get('productType')}")
    check(len(find("booted", device="ipad")) == 2 and len([e for e in find("lit") if e["device"] == "ipad"]) == 2
          and len(find("usb", device="ipad")) == 2, "restart: a fresh iPad helper lit and answered USB on the same overlay")
    # Not a check: a kill -9 right after an install, with no guest sync, can lose it (powerdown-fixed.md).
    print(f"  note: after the kill -9 the installed app is {'still there' if (find('restartedApps') or [{}])[0].get('has') else 'gone (no guest sync before the kill)'}")
    conf = (find("confirmed") or [{}])[0]
    quit_ = (find("quit") or [{}])[0]
    check(conf.get("ipod", -1) >= 0 and conf.get("ipad", -1) >= 0,
          f"clean quit in parallel: power-off confirmed, iPod {conf.get('ipod', -1):.1f} s, iPad {conf.get('ipad', -1):.1f} s")
    check(quit_.get("ipodExited") and quit_.get("ipadExited") and quit_.get("ipodReason") == "The emulator stopped."
          and quit_.get("ipadReason") == "The emulator stopped.", f"both helpers exited cleanly after SIGTERM: {quit_}")
    check(tree(args.ipad_device) == base_before, "the prepared base is unchanged (paths, sizes, modes, mtimes)")
    check(find("done") and driver.returncode == 0, f"driver finished (exit {driver.returncode})")
    fails = find("fail")
    if fails:
        print("  driver: " + fails[0]["why"])
    print(f"\n{sum(results)}/{len(results)} passed; events {work}/driver.jsonl")
    for e in find("screenshot"):
        print(f"   {e['path']}  ({e['width']}x{e['height']}, brightness {e['brightness']:.2f})")
    sys.exit(0 if all(results) else 1)


if __name__ == "__main__":
    main()
