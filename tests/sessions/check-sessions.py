#!/usr/bin/env python3
"""Two devices at once, each in its own LightTouchDevice, through the app's session code.

tests/drivers/session-driver stands in for the app. It compiles the app's own DeviceProcess and
BootRecipe, DeviceServices,
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
  guest      (--ipad-itpack) the iPad booted with the app's offer: the loader's report, then the
             agent through GuestServices: foreground app, lock state, launch Safari
  kill       kill -9 of the iPad helper: it is noticed as dead, the iPod keeps running
  restart    a fresh iPad helper and usbmuxd on the same overlay lights and answers USB
  quit       both halted in parallel (SIGTERM: pause, flush, quit QEMU), helpers exit 0 within 5 s
  base       the prepared iPad base is byte- and mode-identical afterwards

    tests/sessions/check-sessions.py --ipad-device DIR [--ipad-itpack ARMV7.itpack] [--helper PATH] [--dylib PATH] [--ipa PATH] [--work DIR]
    tests/sessions/check-sessions.py --guest --ipod-device DIR --itpack ARMV6.itpack [...]
    tests/sessions/check-sessions.py --single DIR --board ipod|ipad [--frameworks DIR] [...]

--single --afc-race N (smoke.md #5) instead boots the base N times, lists the Media root over AFC the moment lockdown
first answers (polled every 100 ms), and Stops; --afc-race-dirty adds an IPA install, an upload and the agent halt,
stopping 20-45 s into the shutdown.

--single boots one prepared base (firmwarekit create output) as the app does: lit, lockdown over its own
usbmuxd, AFC upload + download round trips of 16384, 16385, 65536 and 1048583 bytes (no restore), an IPA
install, and a clean shutdown; screenshots lock/home/installed in --work/<board>/. build-release.py's verify
runs it with the bundle's helper, dylib, usbmuxd, Frameworks and Resources/device.

--guest runs the no-shell guest-services scenario (tests/drivers/session-driver/guest.swift) on two
iPods at once: the shipping image (nand-current) and a fresh device.py 7E18 (--ipod-device),
each through the app's GuestServices/GuestAgent, DeviceServices, lockdown-tz and GuestPackage:

  offer      the boot's guest-package offer from --itpack, passed as guest-package=
  agent      capabilities from the agent's ping (a v1 agent falls back to its exec)
  report     the loader's report and the verdict: the fresh device installs the bundled
             package and judges it good; the shipping image has no loader (legacy tools)
  install    an IPA through installation_proxy, then launch it through the agent
  respring   launchd restarts SpringBoard (a new pid) and it answers again
  timezone   lockdown SetValue through the lockdown-tz child process
  media      a photo staged over AFC and committed with itphoto
  rollback   (fresh) the package judged bad: after a clean halt and a fresh helper the loader reverts
  halt       the agent's halt, confirmed power-off, helper exit 0; the base is unchanged

--ipad-device is a fresh device from the qemu-ios device tool, e.g.
  python3 $(scripts/sources.py qemu-ios)/imgtools/device.py create manifests/ipad1-7B500.json OUT \\
      --activation-hook ~/Developer/qemu-ios-files/ipad1/offline-activation/patch_lockdownd.py
--helper defaults to building the LightTouchDevice target (Debug). Boots use -audio driver=none.
Run in the foreground; every process it starts is gone when it returns. Screenshots land in
--work/<device>/*.png.
"""
import argparse, json, os, signal, subprocess, sys, tempfile, time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
HOME = Path.home()
sys.path.insert(0, str(ROOT / "scripts"))
import sources  # the pinned checkouts (build-support/sources.json)
TEAM_REQ = 'anchor apple generic and certificate leaf[subject.OU] = "SM75355Y6R"'
APP_SOURCES = ["Services/DeviceServices", "Device/DeviceProcess", "Transport/DeviceExecution", "Device/BootRecipe", "Services/AFC", "Services/InstallationProxy", "Services/LockdownTools", "Transport/IMobileDevice", "Device/DeviceProfile", "Device/DeviceProfile+Display",
               "Transport/NativeLogging", "Library/StorageLocations", "Library/DeviceStateStorage", "Guest/GuestServices", "Guest/GuestAgent", "Guest/GuestPackage",
               "Library/DeviceInstance", "Library/FirmwareCatalog", "Features/MediaPhoto", "Features/MediaIdentity", "Device/DeviceConnectionIssue",
               "Device/WebProxyConfiguration", "Services/SpringBoardServices"]


def tree(root):
    """Every path under a base with its size, mode and mtime: the base must not change."""
    out = {}
    for dirpath, dirs, files in os.walk(root):
        for name in dirs + files:
            p = os.path.join(dirpath, name)
            st = os.lstat(p)
            out[os.path.relpath(p, root)] = (st.st_size, st.st_mode, st.st_mtime_ns)
    return out


def guest_checks(find, check, events):
    one = lambda name, device, **m: (find(name, device=device, **m) or [{}])[0]
    for d in ("shipping", "fresh"):
        offer = one("offer", d)
        check(offer.get("serial", -1) > 0 and offer.get("text", "").startswith("ltpkg 1\nbuild 7E18\nserial "),
              f"{d}: offer serial {offer.get('serial')} composed and passed as guest-package=")
        check(one("supported", d).get("guestPackage"), f"{d}: the helper's dylib serves guest-package offers")
        caps = one("capabilities", d)
        check(caps.get("version", 0) >= 1, f"{d}: agent v{caps.get('version')} ({len(caps.get('ops', []))} ops)")
        comp = one("agent", d)
        check(comp.get("version", 0) >= 2, f"{d}: agent v{comp.get('version')} (packaged {comp.get('packaged')})")
        check(one("unlocked", d).get("locked") is False, f"{d}: unlocked")
        inst = one("installed", d)
        check(inst.get("has"), f"{d}: IPA installed ({inst.get('seconds', 0):.0f} s)")
        check(one("launched", d).get("frontmost") == "com.qemuios.harness", f"{d}: launched through the agent: frontmost {one('launched', d).get('frontmost')}")
        rs = one("respring", d)
        check(rs.get("after", -1) > 0 and rs.get("after") != rs.get("before"), f"{d}: respring, SpringBoard pid {rs.get('before')} -> {rs.get('after')}")
        check(one("timezone", d).get("zone") == "Asia/Tokyo", f"{d}: time zone now {one('timezone', d).get('zone')} (lockdown-tz)")
        media = one("media", d)
        check(media.get("imported") and media.get("receipt", "").startswith("done\n"), f"{d}: photo imported (itphoto, receipt {media.get('receipt')!r})")
        for n, halt in enumerate(find("halted", device=d) or [{}]):
            check(halt.get("submitted") and halt.get("confirmed", -1) >= 0 and halt.get("exited") and str(halt.get("reason")).endswith(" stopped."),
                  f"{d}: clean halt {n + 1}, power-off confirmed in {halt.get('confirmed', -1):.1f} s, helper exited")
    ship = one("verdict", "shipping", label="boot")
    check(ship.get("serial") == -1 and ship.get("verdict") == "legacy", f"shipping: no report, legacy baked tools ({ship.get('verdict')})")
    fresh = one("verdict", "fresh", label="boot")
    # A bundled serial newer than the seed is installed (1) or switched to (2); the seed itself stays (0).
    check(fresh.get("serial") == one("offer", "fresh").get("bundled") and fresh.get("result") in (0, 1, 2) and fresh.get("verdict", "").startswith("good"),
          f"fresh: the loader runs the bundled serial {fresh.get('serial')} (result {fresh.get('result')}), judged {fresh.get('verdict')}")
    check(one("agent", "fresh").get("packaged"), "fresh: a packaged image, the loader's")
    if fresh.get("result") == 0:
        print("  note: the bundled package is the seed; no rollback to test (use an itpack with a newer serial)")
    else:
        back = one("verdict", "fresh", label="rollback")
        check(back.get("result") == 3 and back.get("serial") == 1, f"fresh: after verdict bad the loader reverted to serial {back.get('serial')} (result {back.get('result')})")
        offers = find("offer", device="fresh")
        check(len(offers) == 2 and "verdict bad" in offers[-1].get("text", ""), "fresh: the rollback offer carries the bad verdict")


def build_lockdown_tz(out, frameworks=None):
    """out/lockdown-tz; the app's Debug build compiles the same source (LockdownTools: DeviceServices.developmentHelper).
    With `frameworks` (a prefix's lib/), linked against that libimobiledevice as package.sh links the bundled one."""
    tz = out / "lockdown-tz"
    flags = (f'-I{Path(frameworks).parent}/include -L{frameworks} -Wl,-rpath,{frameworks} -limobiledevice-1.0 -lplist-2.0'
             if frameworks else '$(pkg-config --cflags --libs libimobiledevice-1.0 libplist-2.0)')
    r = subprocess.run(["/bin/sh", "-c", 'PATH=/opt/homebrew/bin:/usr/local/bin:$PATH; cc -O2 -o "$1" "$2" ' + flags,
                        "sh", str(tz), str(ROOT / "scripts/lockdown-tz.c")])
    if r.returncode:
        sys.exit("FAIL: building lockdown-tz")
    return tz


def build(args, out):
    subprocess.run(["clang", "-O", "-c", ROOT / "Shared/CLink/ltm_link.c", "-o", out / "ltm_link.o"], check=True)
    subprocess.run(["xcrun", "swiftc", "-swift-version", "5", "-default-isolation", "MainActor", "-module-cache-path", out / "modules",
                    "-I", ROOT / "Shared/CLink", out / "ltm_link.o", *sorted((ROOT / "Shared").glob("*.swift")),
                    ROOT / "LightTouchDevice/FrameTools.swift", *[ROOT / f"LightTouchMac/{n}.swift" for n in APP_SOURCES],
                    ROOT / "tests/drivers/session-driver/main.swift", ROOT / "tests/drivers/session-driver/guest.swift",
                    ROOT / "tests/drivers/session-driver/single.swift", ROOT / "tests/drivers/session-driver/activation.swift",
                    ROOT / "tests/drivers/session-driver/deadline.swift", ROOT / "tests/drivers/session-driver/proxy.swift",
                    "-o", out / "session-driver"],
                   check=True, stdout=open(out / "swiftc.log", "w"), stderr=subprocess.STDOUT)
    if args.helper:
        return Path(args.helper)
    qemu = sources.path("qemu-ios")
    r = subprocess.run(["xcodebuild", "-project", ROOT / "LightTouchMac.xcodeproj", "-target", "LightTouchDevice",
                        "-configuration", "Debug", f"SYMROOT={out}/xcode", f"QEMU_IOS_DIR={qemu}", "build"],
                       stdout=open(out / "xcodebuild.log", "w"), stderr=subprocess.STDOUT)
    if r.returncode:
        sys.exit(f"FAIL: building LightTouchDevice; see {out}/xcodebuild.log")
    return out / "xcode/Debug/LightTouchDevice"


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--ipad-device", type=Path)
    ap.add_argument("--guest", action="store_true", help="the no-shell guest-services scenario on two iPods")
    ap.add_argument("--ipod-device", type=Path, help="--guest: a fresh device.py iPod (nand/, nor.bin, iBoot.bin, gid-blobs.bin)")
    ap.add_argument("--itpack", type=Path, default=sources.path("qemu-ios") / "build/guest-package/armv6.itpack")
    ap.add_argument("--guest-tools", type=Path, help="--guest: a flat build-guest-tools.sh guest-tools directory "
                    "(it_agent, it_typein.dylib, itphoto); default: the qemu-ios checkout's contrib binaries")
    ap.add_argument("--contrib", type=Path, default=sources.path("qemu-ios") / "contrib")
    ap.add_argument("--time-zone", default="Asia/Tokyo")
    ap.add_argument("--helper")
    ap.add_argument("--helper-requirement", default=TEAM_REQ, help="explicit signing requirement for a supplied test helper (default: project team)")
    ap.add_argument("--dylib", default=os.environ.get("LTM_QEMU_DYLIB", str(sources.qemu_build() / "libqemu-arm.dylib")))
    ap.add_argument("--files", type=Path, default=HOME / "Developer/qemu-ios-files")
    ap.add_argument("--usbmuxd", default=str(sources.path("usbmuxd") / "src/usbmuxd"))
    ap.add_argument("--ipa", type=Path, default=sources.path("qemu-ios") / "contrib/it-harness/build/Harness.ipa")
    ap.add_argument("--bundle-id", default="com.qemuios.harness")
    ap.add_argument("--work", type=Path)
    ap.add_argument("--single", type=Path, help="one prepared base (firmwarekit create output)")
    ap.add_argument("--board", choices=("ipod", "ipad"), help="--single: the base's board")
    ap.add_argument("--afc-race", type=int, metavar="N", help="--single: N boots, AFC at lockdown's first answer, then Stop (smoke.md #5)")
    ap.add_argument("--afc-race-dirty", action="store_true", help="--afc-race: install, upload and halt first, stopping mid-shutdown")
    ap.add_argument("--frameworks", help="where libimobiledevice is loaded from (default Homebrew's)")
    ap.add_argument("--ipad-itpack", type=Path, help="boot the iPad with the app's offer from this armv7.itpack and check "
                    "the loader's report and the agent (foreground app, lock state, launch)")
    args = ap.parse_args()
    if args.helper_requirement != TEAM_REQ and not args.helper:
        ap.error("--helper-requirement needs an explicitly supplied --helper")
    if args.helper and not os.access(args.helper, os.X_OK):
        ap.error("test helper is not executable: " + args.helper)
    if not Path(args.dylib).is_file():
        ap.error("emulator dylib is missing: " + args.dylib)
    if not args.ipa.is_file():
        ap.error("test IPA is missing: " + str(args.ipa))
    if args.single and not args.board:
        ap.error("--single needs --board")
    if not args.guest and not args.ipad_device and not args.single:
        ap.error("--ipad-device is required (or --guest, --single)")
    if args.guest and not args.ipod_device:
        ap.error("--guest needs --ipod-device")
    work = args.work or Path(tempfile.mkdtemp(prefix="ltm-sessions-"))
    work.mkdir(parents=True, exist_ok=True)
    print(f"work: {work}", flush=True)
    helper = build(args, work)
    base_dir = args.single or (args.ipod_device if args.guest else args.ipad_device)
    base_before = tree(base_dir)
    nand_current = args.files / "nand-current"
    cfg = {"helper": str(helper), "requirement": args.helper_requirement, "usbmuxd": args.usbmuxd, "ipa": str(args.ipa),
           "bundleID": args.bundle_id, "work": str(work), "files": str(args.files),
           "ipodNAND": str(args.files / os.readlink(nand_current)) if nand_current.is_symlink() else "",
           "ipadBase": str(args.single if args.board == "ipad" else args.ipad_device or "")}
    if args.frameworks:
        cfg["frameworks"] = args.frameworks
    if args.single:
        cfg["single"] = {"board": args.board, "base": str(args.single)}
        if args.afc_race:
            cfg["single"] |= {"raceBoots": args.afc_race, "raceDirty": args.afc_race_dirty}
            cfg["timeout"] = 200 * args.afc_race
    if args.ipad_itpack:
        cfg["ipadItpack"] = str(args.ipad_itpack)
    if args.guest:
        tz = build_lockdown_tz(work, args.frameworks)
        dev = args.ipod_device
        c, g = args.contrib, args.guest_tools
        tools = {n: str(g / n if g else c / sub / n) for n, sub in (("it_agent", "it-agent"), ("it_typein.dylib", "it-agent"),
                                                                   ("itphoto", "it-media"))}
        cfg["guest"] = {"itpack": str(args.itpack), "lockdownTZ": str(tz), "tools": tools, "timeZone": args.time_zone,
                        "devices": [{"name": "shipping", "nand": cfg["ipodNAND"], "nor": str(args.files / "ios3/nor_7E18.bin"),
                                     "iBoot": str(args.files / "ios3/iBoot.bin")},
                                    {"name": "fresh", "nand": str(dev / "nand"), "nor": str(dev / "nor.bin"), "iBoot": str(dev / "iBoot.bin"),
                                     "gidBlobs": str(dev / "gid-blobs.bin"), "lock": str(dev / "device.lock.json"), "rollback": True}]}
    (work / "config.json").write_text(json.dumps(cfg, indent=1))
    env = dict(os.environ, LTM_QEMU_DYLIB=args.dylib)
    driver = subprocess.Popen([work / "session-driver", work / "config.json"], stdout=open(work / "driver.jsonl", "w"),
                              stderr=subprocess.STDOUT, stdin=subprocess.DEVNULL, env=env)
    events = []
    try:
        try:
            driver.wait(timeout=cfg.get("timeout", 560) + 10)
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

    if args.afc_race:
        d = args.board
        for r in find("race", device=d):
            check("error" not in r, f"{d} boot {r['generation']}: AFC {r.get('seconds', 0):.1f} s after lockdown's first answer "
                  f"({r['lockdown']:.1f} s after power-on): " + (r.get("error") or f"{r['entries']} entries"))
        for r in find("raceStop", device=d):
            check("uploadError" not in r, f"{d} boot {r['generation']}: installed, uploaded, Stop {r['afterHalt']:.0f} s into the halt "
                  f"(power-off {'confirmed' if r['confirmed'] else 'not yet confirmed'})" + (f": {r['uploadError']}" if "uploadError" in r else ""))
        check(len(find("race", device=d)) == args.afc_race and find("done"), f"{d}: {len(find('race', device=d))}/{args.afc_race} boots ran")
        print(f"\n{sum(results)}/{len(results)} passed; events {work}/driver.jsonl")
        sys.exit(0 if all(results) else 1)
    if args.single:
        d = args.board
        lit = (find("lit", device=d) or [{}])[0]
        check(lit, f"{d}: lit in {lit.get('seconds', -1):.1f} s")
        usb = (find("usb", device=d) or [{}])[0]
        check(usb.get("productType") == ("iPad1,1" if d == "ipad" else "iPod2,1"), f"{d}: lockdown over its usbmuxd: {usb.get('productType')}")
        for a in find("afc", device=d):
            check(a.get("same") and a.get("listed") == a["bytes"], f"{d}: AFC round trip of {a['bytes']} bytes"
                  + (f" ({a.get('seconds', 0):.1f} s)" if a.get("same") else f": {a.get('error', 'content differs')}"))
        check(len(find("afc", device=d)) >= 4, f"{d}: AFC checks ran")
        inst = (find("installed", device=d) or [{}])[0]
        check(inst.get("has"), f"{d}: IPA installed ({inst.get('seconds', 0):.0f} s, attempt {inst.get('attempt')})")
        q = (find("quit", device=d) or [{}])[0]
        check(q.get("confirmed", -1) >= 0 and q.get("exited") and str(q.get("reason")).endswith(" stopped."),
              f"{d}: clean shutdown, power-off confirmed in {q.get('confirmed', -1):.1f} s, helper exited")
        check(tree(base_dir) == base_before, f"{d}: the prepared base is unchanged")
        check(find("done") and driver.returncode == 0, f"driver finished (exit {driver.returncode})")
        fails = find("fail")
        if fails:
            print("  driver: " + fails[0]["why"])
        for e in find("screenshot"):
            print(f"   {e['path']}  ({e['width']}x{e['height']}, brightness {e['brightness']:.2f})")
        print(f"\n{sum(results)}/{len(results)} passed; events {work}/driver.jsonl")
        sys.exit(0 if all(results) else 1)
    if args.guest:
        guest_checks(find, check, events)
        check(tree(base_dir) == base_before, "the fresh device's base is unchanged (paths, sizes, modes, mtimes)")
        check(find("done") and driver.returncode == 0, f"driver finished (exit {driver.returncode})")
        fails = find("fail")
        if fails:
            print("  driver: " + fails[0]["why"])
        print(f"\n{sum(results)}/{len(results)} passed; events {work}/driver.jsonl")
        sys.exit(0 if all(results) else 1)

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
    if args.ipad_itpack:
        offer, rep = (find("offer", device="ipad") or [{}])[0], (find("ipadReport") or [{}])[0]
        check(offer.get("serial", -1) > 0 and rep.get("serial") == offer.get("serial") and rep.get("result", -99) >= 0,
              f"iPad guest package: offered serial {offer.get('serial')} (seed {offer.get('seed')}), "
              f"loader reports serial {rep.get('serial')} result {rep.get('result')}")
        ag = (find("ipadAgent") or [{}])[0]
        check(ag.get("alive") and ag.get("home") == "Home Screen" and ag.get("locked") == 0 and ag.get("launched") == "Safari",
              f"iPad agent through GuestServices: foreground {ag.get('home')!r}, locked {ag.get('locked')}, "
              f"launch -> {ag.get('launched')!r}")
    killed = (find("killed") or [{}])[0]
    # The user sees "stopped unexpectedly"; the signal goes to the log (DeviceSession.terminated, ee84c89).
    signaled = any(f"helper {killed.get('pid')}: signaled(9)" in e.get("message", "") for e in find("log"))
    check(killed.get("noticed") and killed.get("seconds", 9) < 1 and signaled
          and "stopped unexpectedly" in killed.get("reason", ""),
          f"kill -9 iPad: noticed in {killed.get('seconds', -1) * 1000:.0f} ms, signaled(9) logged: {killed.get('reason')}")
    surv = (find("survivor") or [{}])[0]
    check(not surv.get("dead", True) and surv.get("heartbeat", 0) > 20 and surv.get("frames", 0) > 0 and surv.get("productType") == "iPod2,1",
          f"the iPod kept running: +{surv.get('heartbeat')} heartbeats, +{surv.get('frames')} frames, USB {surv.get('productType')}")
    check(len(find("booted", device="ipad")) == 2 and len([e for e in find("lit") if e["device"] == "ipad"]) == 2
          and len(find("usb", device="ipad")) == 2, "restart: a fresh iPad helper lit and answered USB on the same overlay")
    # Not a check: a kill -9 right after an install, with no guest sync, can lose it (powerdown-fixed.md).
    print(f"  note: after the kill -9 the installed app is {'still there' if (find('restartedApps') or [{}])[0].get('has') else 'gone (no guest sync before the kill)'}")
    quit_ = (find("quit") or [{}])[0]
    check(quit_.get("ipodExited") and quit_.get("ipadExited") and quit_.get("seconds", 99) < 5
          and quit_.get("ipodReason") == "The iPod stopped." and quit_.get("ipadReason") == "The iPad stopped.",
          f"Stop halts both at once (SIGTERM: pause, flush, quit; no guest shutdown) in {quit_.get('seconds', -1):.1f} s: {quit_}")
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
