#!/usr/bin/env python3
"""LightTouchDevice, headless: both devices boot through DeviceLink and the IOSurface ring.

tests/drivers/helper-driver stands in for the app (spawn, Mach rendezvous + validation,
status block, frame ring, framed link). Cases:

  reject     an ad-hoc re-signed helper is refused by the Team requirement
  lease      two helpers on one device's work/lease (temp state dir): the second is refused
             ("in use by another copy of Light Touch"), another device's lease is not; after the
             holder's parent dies and its helper exits, the lease is taken again. No boot.
  ipod       iPod nand-current: lit, unlock drag, battery request, agent RPC, then the
             parent is SIGKILLed: the helper hard-halts (pause, flush, quit) and exits
  ipad       iPad 3.2.2: lit, unlock, snapshot, resume, snapshot, quit -> qemuExited(0)
  restore    -incoming the second snapshot: lit, tap Settings, Home; then SIGKILL the
             helper: the client notices (invalidated + terminated)
  ipad-orphan  fresh overlay, lit, parent SIGKILLed: hard halt (NAND synced), helper exits
  meddle     iPod, lit, the app's DeviceFileWatch on its overlay; the overlay's NOR is unlinked
             under the running helper: the watch reports it (the app's notice), then SIGTERM
             halts the helper, which exits (the flush lands in the dead inode, harmlessly)
  oneshot    --oneshot: an iPad boot stopped at FTL_Open [OK] (stopPattern, newlines removed)
  headless   --headless: an iPod boot to a lit lock screen, dump, quit

    tests/sessions/check-helper-boot.py --ipad-device DIR [--helper PATH] [--dylib PATH] [--work DIR] [--only a,b]

--ipad-device is a device made by qemu-ios imgtools/ipad1_device.py create (kboot.bin + nand/);
without it the iPad cases are skipped. --helper defaults to building the LightTouchDevice
target (Debug). Bases are read-only; overlays, snapshots, logs and PNG dumps go to --work.
Every boot uses -audio driver=none: no test plays sound through the Mac.
Run in the foreground; every process it starts is gone when it returns.
"""
import argparse, json, os, shutil, signal, subprocess, sys, tempfile, time, uuid
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
HOME = Path.home()
sys.path.insert(0, str(ROOT / "scripts"))
import sources  # the pinned checkouts (build-support/sources.json)
TEAM_REQ = 'anchor apple generic and certificate leaf[subject.OU] = "SM75355Y6R"'
SIGN_ID = "Developer ID Application: Sam Gold (SM75355Y6R)"
IPOD_UNLOCK = "drag 0.18 0.9 0.92 0.9"              # the lock screen slider, 320x480 portrait
IPAD_UNLOCK = "drag 0.9365 0.621 0.9365 0.0612"     # tests/ipad1/boot-smoke.py over 1024x768
IPAD_SETTINGS = "tap 0.4375 0.846"
FTL_OPEN = r"FTL_Open\s*\[OK\]"   # Preparer.ftlOpen
esc = lambda p: str(p).replace(",", ",,")
started = []        # every pid this script started, reaped in finally


def alive(pid):
    try:
        os.kill(pid, 0)
        return True
    except ProcessLookupError:
        return False


def wait_gone(pid, seconds):
    t0 = time.time()
    while time.time() - t0 < seconds:
        if not alive(pid):
            return time.time() - t0
        time.sleep(0.1)
    return None


def build(args, out):
    """helper-driver (swiftc) and, unless given, the LightTouchDevice target (xcodebuild)."""
    subprocess.run(["clang", "-O", "-c", ROOT / "Shared/CLink/ltm_link.c", "-o", out / "ltm_link.o"], check=True)
    subprocess.run(["swiftc", "-O", "-swift-version", "5", "-I", ROOT / "Shared/CLink", out / "ltm_link.o",
                    *sorted((ROOT / "Shared").glob("*.swift")), ROOT / "LightTouchDevice/FrameTools.swift",
                    ROOT / "LightTouchMac/Device/DeviceFileWatch.swift",
                    ROOT / "tests/drivers/helper-driver/main.swift", "-o", out / "helper-driver"], check=True)
    if args.helper:
        return Path(args.helper)
    qemu = sources.path("qemu-ios")
    r = subprocess.run(["xcodebuild", "-project", ROOT / "LightTouchMac.xcodeproj", "-target", "LightTouchDevice",
                        "-configuration", "Debug", f"SYMROOT={out}/xcode", f"QEMU_IOS_DIR={qemu}", "build"],
                       stdout=open(out / "xcodebuild.log", "w"), stderr=subprocess.STDOUT)
    if r.returncode:
        sys.exit(f"FAIL: building LightTouchDevice; see {out}/xcodebuild.log")
    return out / "xcode/Debug/LightTouchDevice"


class Driver:
    def __init__(self, args, bin_dir, helper, work, name, scenario, extra=()):
        self.name, self.dir = name, work / name
        self.dir.mkdir(parents=True, exist_ok=True)
        scenario.setdefault("dylib", args.dylib)
        (self.dir / "scenario.json").write_text(json.dumps({k: v for k, v in scenario.items() if v is not None}, indent=1))
        self.out = self.dir / "driver.jsonl"
        self.log = self.dir / "native.log"
        self.p = subprocess.Popen([bin_dir / "helper-driver", "--helper", helper, "--scenario", self.dir / "scenario.json",
                                   "--dump", self.dir, "--log", self.log, "--requirement", TEAM_REQ, *extra],
                                  stdout=open(self.out, "w"), stderr=subprocess.STDOUT, stdin=subprocess.DEVNULL)
        started.append(self.p.pid)

    def events(self):
        out = []
        for line in self.out.read_text(errors="replace").splitlines():
            try:
                out.append(json.loads(line))
            except ValueError:
                out.append({"event": "text", "text": line})
        return out

    def find(self, name):
        return [e for e in self.events() if e.get("event") == name]

    def helper_pid(self):
        c = self.find("connected")
        return c[0]["pid"] if c else None

    def wait(self, seconds):
        try:
            return self.p.wait(timeout=seconds)
        except subprocess.TimeoutExpired:
            self.p.kill()
            self.p.wait()
            return None

    def wait_event(self, name, seconds):
        t0 = time.time()
        while time.time() - t0 < seconds and self.p.poll() is None:
            if self.find(name):
                return self.find(name)[0]
            time.sleep(0.2)
        return self.find(name)[0] if self.find(name) else None

    def tail(self):
        return "\n".join(json.dumps(e) for e in self.events()[-12:])


def check(ok, what, case, results):
    results.append((case, what, bool(ok)))
    print(f"  {'ok ' if ok else 'FAIL'} {what}", flush=True)
    return ok


def ipod_boot(files, ovl):
    ovl.mkdir(parents=True, exist_ok=True)
    nor = ovl / "nor.bin"
    shutil.copy(files / "ios3/nor_7E18.bin", nor)       # DeviceStateStorage.writableNOR
    nor.chmod(0o600)
    boot_args = "amfi_allow_any_signature=1 cs_enforcement_disable=1"
    machine = ("iPod-Touch,h264-decode=on,scaler-decode=on,mpvd-decode=on,amc-mode=decode,lcd-planes=on"
               f",boot-args={esc(boot_args)},boot-args-delay-ms=1500,boot-args-repeat=200,boot-args-interval-ms=250"
               f",direct-iboot={esc(files / 'ios3/iBoot.bin')},direct-llb=,bootrom={files}/bootrom_240_4"
               f",nand={files / os.readlink(files / 'nand-current')},nor={files}/ios3/nor_7E18.bin"
               f",nor-rw={nor},nandrw={ovl},wifi=on")
    return {"machine": "iPod-Touch", "environment": {"IT_TVOUT_READY": "1"},
            "argv": ["LightTouchDevice", "-M", machine, "-m", "128M", "-display", "none", "-no-shutdown",
                     "-audio", "driver=none", "-serial", f"file:{ovl.parent}/serial.log",
                     "-netdev", "user,id=wifi0"]}


def ipad_boot(device, ovl, serial, restore=None, shutdown=True):
    ovl.mkdir(parents=True, exist_ok=True)
    machine = f"ipad1,kboot={esc(device / 'kboot.bin')},nand={esc(device / 'nand')},nand-overlay={esc(ovl)}"
    argv = ["LightTouchDevice", "-M", machine, "-display", "none", "-audio", "driver=none", *(["-no-shutdown"] if shutdown else []),
            "-serial", f"file:{serial}", "-device", "usb-kbd,bus=usb-bus.0,max-power=20"]
    if restore:
        argv += ["-incoming", f"file:{restore}"]
    return {"machine": "ipad1", "argv": argv}


def parent_kill(d, case, results, budget):
    """SIGKILL the driver (the 'app') once it holds; the helper must halt (no guest shutdown) and exit."""
    hold = d.wait_event("hold", 400)
    if not check(hold, "reached hold", case, results):
        print(d.tail()); return
    helper = hold["helperPid"]
    started.append(helper)
    os.kill(d.p.pid, signal.SIGKILL)
    d.p.wait()
    gone = wait_gone(helper, budget)
    check(gone is not None, f"helper exited {gone:.1f} s after the parent died" if gone else "helper exited", case, results)
    log = d.log.read_text(errors="replace")
    check("halt: parent exited" in log or "halt: link closed" in log, "helper noticed the parent's death", case, results)
    lines = [l for l in log.splitlines() if "halt:" in l or "NAND synced" in l]
    print("   " + "\n   ".join(l.split("] ", 1)[-1] for l in lines))
    check("did not return" not in log and "powerdown" not in log, "hard halt: paused (storage flushed), QEMU quit, no guest shutdown", case, results)

def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--ipad-device", type=Path)
    ap.add_argument("--helper")
    ap.add_argument("--dylib", default=os.environ.get("LTM_QEMU_DYLIB"))
    ap.add_argument("--files", type=Path, default=HOME / "Developer/qemu-ios-files")
    ap.add_argument("--work", type=Path)
    ap.add_argument("--only")
    args = ap.parse_args()
    cases = ["reject", "lease", "ipod", "ipad", "restore", "ipad-orphan", "oneshot", "headless", "meddle"]
    if args.only:
        cases = [c for c in cases if c in args.only.split(",")]
    if not args.ipad_device:
        cases = [c for c in cases if not c.startswith(("ipad", "restore", "oneshot"))]
        print("no --ipad-device: skipping the iPad cases")
    work = args.work or Path(tempfile.mkdtemp(prefix="ltm-helper-boot-"))
    work.mkdir(parents=True, exist_ok=True)
    bin_dir = work / "bin"
    bin_dir.mkdir(exist_ok=True)
    helper = build(args, bin_dir)
    print(f"helper {helper}\nwork   {work}", flush=True)
    results = []
    files, dev = args.files, args.ipad_device
    try:
        if "reject" in cases:
            print("reject", flush=True)
            impostor = bin_dir / "LightTouchDevice-adhoc"
            shutil.copy(helper, impostor)
            ent = sources.path("qemu-ios") / "contrib/macos-app/entitlements.plist"
            subprocess.run(["codesign", "-f", "-o", "runtime", "-s", "-", "--entitlements", ent, impostor],
                           check=True, capture_output=True)
            # It must get as far as the rendezvous: give it a dylib it can load outside the bundle.
            bundled = Path(helper).resolve().parent.parent / "Frameworks/libqemu-arm.dylib"
            d = Driver(args, bin_dir, impostor, work, "reject",
                       {"dylib": args.dylib or (str(bundled) if bundled.exists() else None), "steps": []}, ["--expect-reject", "1"])
            check(d.wait(30) == 0 and "requirement failed" in d.out.read_text(), "ad-hoc impostor rejected", "reject", results)

        if "lease" in cases:
            print("lease", flush=True)
            state = work / "lease-state"
            lease = state / f"Devices/{uuid.uuid4()}/work/lease"
            other = state / f"Devices/{uuid.uuid4()}/work/lease"
            a = Driver(args, bin_dir, helper, work, "lease-a", {"steps": ["hold"]}, ["--lease", lease])
            check(a.wait_event("hold", 30), "first helper takes the lease and connects", "lease", results) or print(a.tail())
            b = Driver(args, bin_dir, helper, work, "lease-b", {"steps": []},
                       ["--lease", lease, "--expect-failure", "in use by another copy of Light Touch"])
            check(b.wait(30) == 0, "second helper on the same device is refused", "lease", results) or print(b.tail())
            o = Driver(args, bin_dir, helper, work, "lease-other", {"steps": []}, ["--lease", other])
            check(o.wait(30) == 0 and o.find("connected"), "another device's helper connects meanwhile", "lease", results)
            holder = a.helper_pid()
            if a.p.poll() is None:
                os.kill(a.p.pid, signal.SIGKILL)
            a.p.wait()
            check(holder and wait_gone(holder, 60) is not None, "the holder exits after its parent dies", "lease", results)
            c = Driver(args, bin_dir, helper, work, "lease-c", {"steps": []}, ["--lease", lease])
            check(c.wait(30) == 0 and c.find("connected"), "the lease is taken again once released", "lease", results)

        if "ipod" in cases:
            print("ipod", flush=True)
            d = Driver(args, bin_dir, helper, work, "ipod", {"machine": "iPod-Touch", "boot": ipod_boot(files, work / "ipod/overlay"),
                       "steps": ["boot", "lit 0.03 240", "dump lock", IPOD_UNLOCK, "wait 4", "dump home", "battery 50 0",
                                 "wait 20", "agent echo agent-ok", "status", "hold"]})
            parent_kill(d, "ipod", results, 10)
            ev = {e["event"]: e for e in d.events()}
            check("lit" in ev, f"lit through the ring after {ev.get('lit', {}).get('seconds', 0):.1f} s", "ipod", results)
            dumps = {e["name"]: e for e in d.find("dump")}
            check(dumps.get("home", {}).get("ok") and dumps.get("lock", {}).get("ok"), "lock + home dumps", "ipod", results)
            check(any("ok(true)" in e.get("reply", "") for e in d.find("reply")), "battery request -> ok(true)", "ipod", results)
            check(any("agent-ok" in e.get("output", "") for e in d.find("agent")), "agent RPC round trip", "ipod", results)

        if "ipad" in cases:
            print("ipad", flush=True)
            ovl = work / "ipad/overlay"
            d = Driver(args, bin_dir, helper, work, "ipad", {"machine": "ipad1", "boot": ipad_boot(dev, ovl, work / "ipad/serial.log"),
                       "steps": ["boot", "lit 0.2 240", "dump lock", IPAD_UNLOCK, "wait 5", "dump home",
                                 f"snapshot {work}/ipad/snap1", "resume", "wait 4", "dump after-resume",
                                 f"snapshot {work}/ipad/snap2", "quit", "expectExit 30"]})
            rc = d.wait(300)
            check(rc == 0, "scenario completed", "ipad", results) or print(d.tail())
            snaps = d.find("snapshot")
            check(len(snaps) == 2 and all(s["status"] == 2 for s in snaps),
                  "two snapshots DONE (" + ", ".join(f"{s['seconds']:.2f} s, {s['bytes'] >> 20} MB, {s['glesContexts']} GL" for s in snaps) + ")",
                  "ipad", results)
            check(d.find("qemuExited") and d.find("qemuExited")[0]["code"] == 0, "qemuExited(0) after quit", "ipad", results)
            check(any("exited(0)" in e["termination"] for e in d.find("terminated")), "termination exited(0)", "ipad", results)

        if "restore" in cases:
            print("restore", flush=True)
            ovl = work / "ipad/overlay"
            d = Driver(args, bin_dir, helper, work, "restore", {"machine": "ipad1",
                       "boot": ipad_boot(dev, ovl, work / "restore-serial.log", restore=work / "ipad/snap2"),
                       "steps": ["boot", "lit 0.1 60", "dump restored", IPAD_SETTINGS, "wait 5", "dump settings",
                                 "button 0", "wait 4", "dump after-home", "killHelper"]})
            rc = d.wait(120)
            lit = d.find("lit")
            check(lit and lit[0]["seconds"] < 10, f"restored and lit after {lit[0]['seconds']:.1f} s" if lit else "restored and lit", "restore", results)
            n = d.find("noticed")
            check(rc == 0 and n, f"client noticed the helper's SIGKILL (invalidated {n[0]['invalidatedMs']:.1f} ms, terminated {n[0]['terminatedMs']:.1f} ms)"
                  if n else "client noticed the helper's SIGKILL", "restore", results) or print(d.tail())
            check(any("signaled(9)" in e["termination"] for e in d.find("terminated")), "termination signaled(9)", "restore", results)

        if "ipad-orphan" in cases:
            print("ipad-orphan", flush=True)
            d = Driver(args, bin_dir, helper, work, "ipad-orphan", {"machine": "ipad1",
                       "boot": ipad_boot(dev, work / "ipad-orphan/overlay", work / "ipad-orphan/serial.log"),
                       "steps": ["boot", "lit 0.2 240", "dump lock", "wait 3", "hold"]})
            parent_kill(d, "ipad-orphan", results, 10)

        if "oneshot" in cases:
            print("oneshot", flush=True)
            o = work / "oneshot"
            o.mkdir(exist_ok=True)
            config = {"dylib": args.dylib, "boot": ipad_boot(dev, o / "overlay", o / "serial.log", shutdown=False),
                      "serialLog": str(o / "serial.log"), "stopPattern": FTL_OPEN, "timeout": 120}
            (o / "config.json").write_text(json.dumps({k: v for k, v in config.items() if v is not None}))
            p = subprocess.Popen([helper, "--oneshot", o / "config.json"], stdout=subprocess.PIPE,
                                 stderr=open(o / "native.log", "w"), stdin=subprocess.DEVNULL, text=True)
            started.append(p.pid)
            out, _ = p.communicate(timeout=150)
            result = json.loads(out.strip().splitlines()[-1]) if out.strip() else {}
            check(p.returncode == 0 and result.get("marker"), f"stopped at the serial marker after {result.get('seconds', 0):.1f} s", "oneshot", results)

        if "meddle" in cases:
            print("meddle", flush=True)
            ovl = work / "meddle/overlay"
            d = Driver(args, bin_dir, helper, work, "meddle", {"machine": "iPod-Touch", "boot": ipod_boot(files, ovl),
                       "steps": ["boot", "lit 0.03 240", "wait 3", f"watch {ovl}", "hold"]})
            hold = d.wait_event("hold", 400)
            if check(hold, "lit and holding with the overlay watched", "meddle", results):
                helper = hold["helperPid"]
                started.append(helper)
                check((d.find("watching") or [{}])[0].get("count", 0) >= 2, "the watch covers the overlay and its files", "meddle", results)
                (ovl / "nor.bin").unlink()   # the writable NOR QEMU has open
                m = d.wait_event("meddled", 5)
                check(m and m["path"].endswith("nor.bin") and m["notice"] == "Files of this iPod were changed while it was running. Stop and start it again; unsaved changes may be lost.",
                      f"the watch reported {m and m['path']} with the app's notice", "meddle", results)
                check(alive(helper) and d.p.poll() is None, "the helper and guest kept running on the unlinked inode", "meddle", results)
                os.kill(helper, signal.SIGTERM)
                gone = wait_gone(helper, 15)
                check(gone is not None, f"SIGTERM: the helper exited {gone:.1f} s later" if gone else "SIGTERM: the helper exited", "meddle", results)
                check("halt:" in d.log.read_text(errors="replace"), "the helper logged its halt", "meddle", results)
                os.kill(d.p.pid, signal.SIGKILL)
                d.p.wait()
            else:
                print(d.tail())

        if "headless" in cases:
            print("headless", flush=True)
            h = work / "headless"
            h.mkdir(exist_ok=True)
            config = {"dylib": args.dylib, "boot": ipod_boot(files, h / "overlay"), "dumpDir": str(h),
                      "litFraction": 0.03, "maxSeconds": 240, "actions": ["dump lock", "quit"]}
            (h / "config.json").write_text(json.dumps({k: v for k, v in config.items() if v is not None}))
            p = subprocess.Popen([helper, "--headless", h / "config.json"], stdout=open(h / "status.jsonl", "w"),
                                 stderr=open(h / "native.log", "w"), stdin=subprocess.DEVNULL)
            started.append(p.pid)
            rc = p.wait(timeout=300)
            events = [json.loads(l) for l in (h / "status.jsonl").read_text().splitlines() if l.startswith("{")]
            kinds = {e["event"] for e in events}
            check(rc == 0 and {"ring", "lit", "dump", "exit"} <= kinds and any(e["event"] == "status" for e in events),
                  "headless: ring, lit, dump, status lines, exit 0", "headless", results)
    finally:
        for pid in started:
            if alive(pid):
                os.kill(pid, signal.SIGKILL)
    failed = [r for r in results if not r[2]]
    print(f"\n{'PASS' if not failed else 'FAIL'}: {len(results) - len(failed)}/{len(results)} checks; dumps and logs in {work}")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
