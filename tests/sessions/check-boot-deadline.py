#!/usr/bin/env python3
"""A boot that never lights ends as a named error with the helper halted, never "Booting…" forever.

Offline (always): EmulatorController's boot watch, sliced with a fake helper. No uiReady within the
board's budget halts the helper and the session dies with the deadline reason; iBoot's "Entering
recovery mode" on the serial log does the same with the recovery reason, at once; a boot whose UI
came up in time is left alone; a base missing iBoot.bin fails before boot with a reason naming
the file. The serial watch itself (NativeLogging.LogPipeReader) is fed the marker split across
two writes and must report it exactly once.

With --recovery-device (default: the stale device.py iPod 4.2.1 base, which iBoot leaves in
recovery mode), the session driver boots it with the app's serial watch and must see the marker
long before the budget, then halt the helper.

    tests/sessions/check-boot-deadline.py [--offline] [--recovery-device DIR --board ipod|ipad] [--helper PATH] [--dylib PATH] [--work DIR]
"""
import argparse, importlib.util, json, os, signal, subprocess, sys, tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
HOME = Path.home()
sys.path.insert(0, str(ROOT / "scripts"))
import sources  # the pinned checkouts (build-support/sources.json)
DEFAULT_DEVICE = HOME / "Developer/qemu-ios-files/ipod-ipsw/devices/8C148-b"


def offline():
    s = (ROOT / "LightTouchMac/Device/EmulatorController.swift").read_text()
    a = s.index("    // MARK: - Boot deadline")
    deadline = s[a:s.index("    /// The guestfwd for itwebproxy", a)]
    deadline = deadline.replace("try? await Task.sleep(for: .seconds(self?.profile.bootBudget ?? 0))",
                                "try? await Task.sleep(for: .milliseconds(Int((self?.profile.bootBudget ?? 0) * 1000)))")
    a = s.index("    private func helperDied(_ reason: String) {")
    died = s[a:s.index("    // MARK: - Liveness", a)]
    source = r'''import Foundation
nonisolated func logEvent(_ message: String) {}
enum DeviceProfile { case iPodTouch2G, iPad1
 var shortName: String { self == .iPad1 ? "iPad" : "iPod" }
 var bootBudget: TimeInterval { 0.3 }
}
@MainActor final class FakeProcess {
 var terms = 0, kills = 0, isDead = false, hung = false
 var onDeath: ((String) -> Void)?
 func terminate() { terms += 1; if hung { return }; Task { try? await Task.sleep(for: .milliseconds(20)); self.isDead = true; self.onDeath?("The emulator stopped.") } }
 func kill() { kills += 1; isDead = true }
 func waitForExit(timeout: TimeInterval) async -> Bool {
  let deadline = Date().addingTimeInterval(timeout)
  while !isDead, Date() < deadline { try? await Task.sleep(for: .milliseconds(5)) }
  return isDead
 }
}
struct Status { var uiReady = true }
struct Mux { var session: Int? = 1; func stop() {} }
struct Serial { func finish() {} }
@MainActor final class Controller {
 enum State: Equatable { case notStarted, booting, running, poweredOff; case dead(exitCode: Int32?) }
 enum NoticeOperation { case storage }
 static let haltBudget: TimeInterval = 0.2
 let profile: DeviceProfile
 var state = State.booting
 var isDead: Bool { if case .dead = state { return true } else { return false } }
 var isPoweredOff: Bool { state == .poweredOff }
 var shuttingDown = false, halting = false
 var bootGeneration = 0
 var status: Status? = Status()
 var deviceReachable: Bool?
 var process: FakeProcess? = FakeProcess()
 var deathReason: String?
 var notices: [String] = []
 func reportDeviceNotice(_ text: String, for operation: NoticeOperation) { notices.append(text) }
 var usbmux = Mux()
 var fileWatch: Int?
 var statusTimer: Timer?, readinessTask: Task<Void, Never>?, foregroundTask: Task<Void, Never>?, orientationTask: Task<Void, Never>?
 var audioSink: ((Int) -> Void)?
 var serialCapture: Serial? = Serial()
 init(_ profile: DeviceProfile) {
  self.profile = profile
  process!.onDeath = { [weak self] reason in self?.helperDied(reason) }
 }
''' + deadline.replace("private func", "func").replace("private var", "var") + died.replace("audioSink?(.audioEnded(generation: 0, failed: true))", "audioSink?(0)") + r'''}
@main struct Check {
 @MainActor static func main() async throws {
  func settle(_ ms: Int) async { try? await Task.sleep(for: .milliseconds(ms)) }
  // No uiReady within the budget: halted, dead with the deadline reason.
  let late = Controller(.iPodTouch2G)
  late.startBootWatch(); await settle(600)
  precondition(late.process!.terms == 1 && late.isDead && late.deathReason == Controller.deadlineReason(.iPodTouch2G))
  precondition(late.deathReason!.hasPrefix("The iPod didn’t start within"))
  // lockdown answered in time (QEMU's uiReady alone is iBoot's display, not iOS): nothing happens.
  let lit = Controller(.iPad1); lit.deviceReachable = true
  lit.startBootWatch(); await settle(600)
  precondition(lit.process!.terms == 0 && !lit.isDead && lit.deathReason == nil)
  let quiet = Controller(.iPad1); quiet.status!.uiReady = true
  quiet.startBootWatch(); await settle(600)
  precondition(quiet.isDead, "a lit display without lockdown is not a finished boot")
  let noUSB = Controller(.iPodTouch2G); noUSB.usbmux.session = nil; noUSB.state = .running
  noUSB.startBootWatch(); await settle(600)
  precondition(!noUSB.isDead, "without a USB bridge, painting has to do")
  // Recovery mode on serial: at once, with the recovery reason; the helper's own exit keeps it.
  let recovery = Controller(.iPad1)
  recovery.startBootWatch()
  recovery.abortBoot(Controller.recoveryReason(.iPad1)); await settle(100)
  precondition(recovery.process!.terms == 1 && recovery.isDead && recovery.deathReason == Controller.recoveryReason(.iPad1))
  precondition(recovery.deathReason!.contains("recovery mode") && recovery.deathReason!.contains("iPad"))
  recovery.abortBoot("again"); precondition(recovery.process!.terms == 1, "a dead session isn't aborted twice")
  // A helper that ignores SIGTERM is killed after the halt budget.
  let stuck = Controller(.iPodTouch2G)
  stuck.process!.hung = true
  let stubborn = stuck.process!
  stuck.abortBoot("stuck"); await settle(400)
  precondition(stubborn.terms == 1 && stubborn.kills == 1)
  // Stop/powered-off sessions are left to their own paths.
  let stopping = Controller(.iPodTouch2G); stopping.shuttingDown = true
  stopping.abortBoot("late"); precondition(stopping.process!.terms == 0 && !stopping.isDead)
  // A base without its boot file: named before anything boots.
  let missing = CocoaError(.fileNoSuchFile, userInfo: [NSFilePathErrorKey: "/state/Devices/x/base/iBoot.bin"])
  let reason = Controller.bootFilesReason(missing, profile: .iPodTouch2G)
  precondition(reason == "This iPod’s system files are incomplete: iBoot.bin is missing. Delete it and prepare it again.")
  let other = Controller.bootFilesReason(CocoaError(.fileReadCorruptFile), profile: .iPad1)
  precondition(other.hasPrefix("Couldn’t prepare the iPad’s storage: "))
  let failing = Controller(.iPodTouch2G)
  failing.failBoot(missing)
  precondition(failing.isDead && failing.deathReason == reason && failing.notices == [reason])
  print("PASS: boot deadline and recovery mode end the session as named errors with the helper halted; missing boot files are named before boot")
 }
}
'''
    watch = r'''import Foundation
@main struct Check {
 static func main() throws {
  var fds: [Int32] = [-1, -1]
  precondition(pipe(&fds) == 0)
  let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ltm-serial-watch-\(UUID().uuidString)")
  try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: dir) }
  let matches = Matches()
  let reader = try LogPipeReader(descriptor: fds[0], log: RotatingLog(url: dir.appendingPathComponent("serial.log")),
                                 watch: .init(phrases: ["Entering recovery mode", "root filesystem mount failed"]) { matches.add($0) })
  func write(_ text: String) { _ = text.withCString { Darwin.write(fds[1], $0, strlen($0)) }; usleep(50_000) }
  write("iBoot-636.66\nroot filesystem mou")
  write("nt failed\nEntering reco")
  precondition(matches.all == ["root filesystem mount failed"], "\(matches.all)")
  write("very mode\n")
  write("Entering recovery mode\n")   // once only
  reader.flush()
  precondition(matches.all == ["root filesystem mount failed", "Entering recovery mode"], "\(matches.all)")
  let logged = try String(contentsOf: dir.appendingPathComponent("serial.log"), encoding: .utf8)
  precondition(logged.contains("iBoot-636.66\nroot filesystem mount failed\n"))
  Darwin.close(fds[1])
  reader.finish()
  print("PASS: the serial watch reports each phrase once, across write boundaries, and the log keeps every byte")
 }
}
final class Matches: @unchecked Sendable {
 private let lock = NSLock(); private var seen: [String] = []
 func add(_ phrase: String) { lock.withLock { seen.append(phrase) } }
 var all: [String] { lock.withLock { seen } }
}
'''
    with tempfile.TemporaryDirectory(prefix="ltm-deadline-") as d:
        p = Path(d) / "check.swift"
        p.write_text(source)
        if os.environ.get("LTM_DUMP"):
            Path(os.environ["LTM_DUMP"]).write_text(source)
        subprocess.run(["swiftc", "-parse-as-library", "-module-cache-path", d + "/modules", str(p), "-o", d + "/check"], check=True)
        subprocess.run([d + "/check"], check=True, timeout=20)
        w = Path(d) / "watch.swift"
        w.write_text(watch)
        subprocess.run(["swiftc", "-parse-as-library", "-module-cache-path", d + "/modules", *[str(ROOT / "LightTouchMac" / f)
                        for f in ("Transport/NativeLogging.swift", "Library/StorageLocations.swift", "Library/Bundled.swift", "Transport/AppEventLog.swift")],
                        str(w), "-o", d + "/watch"], check=True)
        subprocess.run([d + "/watch"], check=True, timeout=20, env=dict(os.environ, LTM_STATE_DIR=d + "/state"))


def live(args):
    spec = importlib.util.spec_from_file_location("check_sessions", ROOT / "tests/sessions/check-sessions.py")
    sessions = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(sessions)
    work = args.work or Path(tempfile.mkdtemp(prefix="ltm-deadline-"))
    work.mkdir(parents=True, exist_ok=True)
    print(f"work: {work}", flush=True)
    helper = sessions.build(args, work)
    cfg = {"helper": str(helper), "requirement": sessions.TEAM_REQ, "usbmuxd": args.usbmuxd, "ipa": "", "bundleID": "",
           "work": str(work), "files": str(args.files), "ipodNAND": "",
           "ipadBase": str(args.recovery_device if args.board == "ipad" else ""),
           "deadline": {"board": args.board, "base": str(args.recovery_device), "budget": args.budget}}
    (work / "config.json").write_text(json.dumps(cfg, indent=1))
    driver = subprocess.Popen([work / "session-driver", work / "config.json"], stdout=open(work / "driver.jsonl", "w"),
                              stderr=subprocess.STDOUT, stdin=subprocess.DEVNULL, env=dict(os.environ, LTM_QEMU_DYLIB=args.dylib))
    events = []
    try:
        try:
            driver.wait(timeout=args.budget + 90)
        except subprocess.TimeoutExpired:
            driver.kill()
            driver.wait()
    finally:
        for line in (work / "driver.jsonl").read_text(errors="replace").splitlines():
            try:
                events.append(json.loads(line))
            except ValueError:
                events.append({"event": "text", "text": line})
        pids = {e["pid"] for e in events if e.get("event") in ("hello", "booted", "usbmuxd") and e.get("pid")}
        if (work / "pids").exists():
            pids |= {int(x) for x in (work / "pids").read_text().split()}
        for pid in pids:
            try:
                os.kill(pid, signal.SIGKILL)
                print(f"  (killed leftover {pid})")
            except (ProcessLookupError, PermissionError):
                pass
    one = lambda name: ([e for e in events if e.get("event") == name] or [{}])[0]
    results = []

    def check(ok, what):
        results.append(bool(ok))
        print(f"  {'ok ' if ok else 'FAIL'} {what}", flush=True)

    out = one("outcome")
    check(out.get("outcome") == "recovery", f"the serial watch saw \"Entering recovery mode\" after {one('recovery').get('seconds', -1):.1f} s "
          f"(outcome {out.get('outcome')!r} at {out.get('seconds', -1):.1f} s of a {out.get('budget', 0):.0f} s budget)")
    check(one("quit").get("exited"), f"the helper halted in {one('quit').get('seconds', -1):.1f} s: {one('quit').get('reason')!r}")
    check(one("done") and driver.returncode == 0, f"driver finished (exit {driver.returncode})")
    fails = [e for e in events if e.get("event") == "fail"]
    if fails:
        print("  driver: " + fails[0]["why"])
    print(f"\n{sum(results)}/{len(results)} passed; events {work}/driver.jsonl")
    return all(results)


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--offline", action="store_true", help="only the sliced controller and serial-watch checks")
    ap.add_argument("--recovery-device", type=Path, default=DEFAULT_DEVICE, help="a base iBoot leaves in recovery mode")
    ap.add_argument("--board", choices=("ipod", "ipad"), default="ipod")
    ap.add_argument("--budget", type=float, default=120, help="seconds to allow the marker (the app's budget is the board's)")
    ap.add_argument("--helper")
    ap.add_argument("--dylib", default=os.environ.get("LTM_QEMU_DYLIB", str(sources.qemu_build() / "libqemu-arm.dylib")))
    ap.add_argument("--files", type=Path, default=HOME / "Developer/qemu-ios-files")
    ap.add_argument("--usbmuxd", default=str(sources.path("usbmuxd") / "src/usbmuxd"))
    ap.add_argument("--work", type=Path)
    args = ap.parse_args()
    offline()
    if args.offline:
        return 0
    if not args.recovery_device.is_dir():
        print(f"no recovery base at {args.recovery_device}: offline half only")
        return 0
    return 0 if live(args) else 1


if __name__ == "__main__":
    sys.exit(main())
