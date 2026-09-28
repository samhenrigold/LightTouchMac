#!/usr/bin/env python3
"""The app verifies activation once per boot and blocks commands, persistently, when it didn't happen.

Two halves. Offline (always): EmulatorController's first-answer check, sliced with a fake
lockdown, must ask ActivationState once per boot, set the persistent DeviceConnectionIssue
("This iPod isn't activated. Choose Erase All Content and Settings, then prepare it again."),
drop reachability, cancel the boot preparation, report the notice, and keep that issue over
later transient failures; an activated guest clears the notice and asks nothing again until
the next boot. lockdown -34 maps to the same issue; the sidebar row notes "Prepared without
activation" from the lock alone.

With --device (default: a hook-less device.py iPod 3.1.3 base), the session driver boots it
as the app does and asks the same question over its own usbmuxd: the state is not Activated,
the mapped issue is the persistent one, and the first service read (-34) maps to it too.

    tests/check-activation-gate.py [--offline] [--device DIR --board ipod|ipad] [--helper PATH] [--dylib PATH] [--work DIR]
"""
import argparse, importlib.util, json, os, signal, subprocess, sys, tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
HOME = Path.home()
DEFAULT_DEVICE = HOME / "Developer/qemu-ios-files/ipod-ipsw/devices/7E18-a"
TEXT = "This iPod isn’t activated. Choose Erase All Content and Settings, then prepare it again."


def offline():
    s = (ROOT / "LightTouchMac/EmulatorController.swift").read_text()
    a = s.index("    func reportConnectionFailure(_ error: Error, operation: String) {")
    report = s[a:s.index("    private var connectionFailures =", a)]
    a = s.index("    // MARK: - Activation (verified once per boot")
    activation = s[a:s.index("    func uninstall(_ bundleID: String)", a)]
    instance = (ROOT / "LightTouchMac/DeviceInstance.swift").read_text()
    a = instance.index("    static func lockLacksActivation(_ lock: URL) -> Bool {")
    lock = instance[a:instance.index("\n    }", a) + 6]
    source = r'''import Foundation
nonisolated func logEvent(_ message: String) {}
nonisolated enum AbandonedWork { static let count = 0 }
@MainActor final class Controller {
 let profile = DeviceProfile.iPodTouch2G
 var usbConnected = true, liveAgentStatus = 1, connectionFailures = 0
 var onStatusChange: (() -> Void)?
 var bootGeneration = 0
 var preparingMedia = true
 var mediaPreparationTask: Task<Void, Never>? = Task { try? await Task.sleep(for: .seconds(60)) }
 var notices: [String] = [], resolved: [String] = []
 enum NoticeOperation { case activation }
 func reportDeviceNotice(_ text: String, for operation: NoticeOperation) { notices.append(text) }
 func resolveDeviceNotice(for operation: NoticeOperation) { resolved.append("\(operation)") }
 var answers: [String?] = [], asked = 0
 func activationState() async -> String? { asked += 1; return answers.isEmpty ? nil : answers.removeFirst() }
 var connectionIssue: DeviceConnectionIssue?
 var deviceReachable: Bool? {
  didSet {
   if deviceReachable == true, connectionIssue?.persistent != true { connectionIssue = nil }
   checkActivationIfNeeded()
  }
 }
 func considerConnectionRecovery() {}
''' + report + activation + r'''}
enum Lock {
''' + lock + r'''}
@main struct Check {
 @MainActor static func main() async throws {
  func settle() async { for _ in 0..<20 { await Task.yield() } }
  // Unactivated: asked once, persistent issue, blocked, no retry, preparation cancelled, notice.
  let c = Controller(); c.answers = ["Unactivated"]
  c.deviceReachable = true; await settle()
  precondition(c.asked == 1 && c.connectionIssue?.summary == TEXT && c.connectionIssue?.persistent == true)
  precondition(c.connectionIssue?.blocksCommands == true && c.connectionIssue?.reconnectManagement == false)
  precondition(c.deviceReachable == false && !c.preparingMedia && c.mediaPreparationTask!.isCancelled && c.notices == [TEXT])
  // Later answers and transient failures leave it; -34 maps to it.
  c.deviceReachable = true; await settle(); precondition(c.asked == 1 && c.connectionIssue?.persistent == true)
  c.reportConnectionFailure(DeviceError.lockdown(-8), operation: "Refreshing apps")
  precondition(c.connectionIssue?.summary == TEXT)
  c.reportConnectionFailure(DeviceError.lockdown(-34), operation: "Refreshing apps")
  precondition(c.connectionIssue?.summary == TEXT && c.connectionIssue?.persistent == true)
  // The next boot asks again.
  c.bootGeneration += 1; c.connectionIssue = nil; c.answers = ["Activated"]
  c.deviceReachable = true; await settle()
  precondition(c.asked == 2 && c.connectionIssue == nil && c.resolved == ["activation"])
  // Activated: nothing asked twice; an unanswered question is asked again on the next answer.
  let ok = Controller(); ok.answers = [nil, "Activated"]
  ok.deviceReachable = true; await settle(); precondition(ok.asked == 1 && ok.connectionIssue == nil)
  ok.deviceReachable = true; await settle(); precondition(ok.asked == 2 && ok.connectionIssue == nil && ok.preparingMedia)
  ok.deviceReachable = true; await settle(); precondition(ok.asked == 2)
  // A fresh -34 with no prior issue is the same persistent issue.
  let refused = Controller()
  refused.reportConnectionFailure(DeviceError.lockdown(-34), operation: "Refreshing apps")
  precondition(refused.connectionIssue?.summary == TEXT && refused.connectionIssue?.persistent == true)
  // The lock: null or absent activation is "prepared without activation"; a recorded one isn't.
  let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ltm-activation-\(UUID().uuidString)")
  try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: dir) }
  func lock(_ text: String) -> Bool {
   let url = dir.appendingPathComponent("device.lock.json")
   try! Data(text.utf8).write(to: url)
   return Lock.lockLacksActivation(url)
  }
  precondition(lock(#"{"inputs": {"ipsw": {}, "activation": null}}"#))
  precondition(lock(#"{"inputs": {"ipsw": {}, "activation_hook": null}}"#))
  precondition(!lock(#"{"inputs": {"activation": {"input_sha256": "a", "output_sha256": "b"}}}"#))
  precondition(!lock("not json") && !Lock.lockLacksActivation(dir.appendingPathComponent("missing")))
  print("PASS: activation asked once per boot; unactivated is a persistent, non-retrying issue with the notice; -34 maps to it; the lock's note")
 }
}
'''.replace("TEXT", json.dumps(TEXT, ensure_ascii=False))
    with tempfile.TemporaryDirectory(prefix="ltm-activation-") as d:
        p = Path(d) / "check.swift"
        p.write_text(source)
        services = (ROOT / "LightTouchMac/DeviceServices.swift").read_text()
        errors = services[services.index("nonisolated enum DeviceError:"):services.index("// MARK: - Timeouts")]
        (Path(d) / "errors.swift").write_text("import Foundation\n" + errors)
        subprocess.run(["swiftc", "-parse-as-library", "-module-cache-path", d + "/modules", str(ROOT / "LightTouchMac/DeviceProfile.swift"),
                        str(ROOT / "LightTouchMac/DeviceConnectionIssue.swift"), d + "/errors.swift", str(p), "-o", d + "/check"], check=True)
        subprocess.run([d + "/check"], check=True, timeout=20)


def live(args):
    spec = importlib.util.spec_from_file_location("check_sessions", ROOT / "tests/check-sessions.py")
    sessions = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(sessions)
    work = args.work or Path(tempfile.mkdtemp(prefix="ltm-activation-"))
    work.mkdir(parents=True, exist_ok=True)
    print(f"work: {work}", flush=True)
    helper = sessions.build(args, work)
    cfg = {"helper": str(helper), "requirement": sessions.TEAM_REQ, "usbmuxd": args.usbmuxd, "ipa": "", "bundleID": "",
           "work": str(work), "files": str(args.files), "ipodNAND": "", "ipadBase": str(args.device if args.board == "ipad" else ""),
           "activation": {"board": args.board, "base": str(args.device)}}
    if args.frameworks:
        cfg["frameworks"] = args.frameworks
    (work / "config.json").write_text(json.dumps(cfg, indent=1))
    driver = subprocess.Popen([work / "session-driver", work / "config.json"], stdout=open(work / "driver.jsonl", "w"),
                              stderr=subprocess.STDOUT, stdin=subprocess.DEVNULL, env=dict(os.environ, LTM_QEMU_DYLIB=args.dylib))
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

    text = TEXT.replace("iPod", "iPad") if args.board == "ipad" else TEXT
    check(one("lock").get("lacksActivation"), "the lock records no activation: the row says \"Prepared without activation\"")
    check(one("lit"), f"lit in {one('lit').get('seconds', -1):.1f} s")
    check(one("usb").get("productType"), f"lockdown answered over its usbmuxd: {one('usb').get('productType')}")
    act = one("activation")
    check(act.get("state") and act.get("state") not in ("Activated", "FactoryActivated"), f"ActivationState {act.get('state')!r}")
    check(act.get("summary") == text and act.get("persistent") and act.get("blocks") and not act.get("retries"),
          f"the issue: persistent, blocks commands, no retry: {act.get('summary')!r}")
    svc = one("service")
    if "-34" in svc.get("error", "") or "prohibited" in svc.get("error", "").lower():
        check(svc.get("summary") == text and svc.get("persistent"), "the first service read (-34) maps to the same issue")
    else:
        print(f"  note: the service read did not fail with -34 ({svc.get('error') or 'succeeded'}); no mapping to check")
    check(one("quit").get("exited"), f"helper halted in {one('quit').get('seconds', -1):.1f} s")
    check(one("done") and driver.returncode == 0, f"driver finished (exit {driver.returncode})")
    fails = [e for e in events if e.get("event") == "fail"]
    if fails:
        print("  driver: " + fails[0]["why"])
    print(f"\n{sum(results)}/{len(results)} passed; events {work}/driver.jsonl")
    return all(results)


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--offline", action="store_true", help="only the sliced controller check")
    ap.add_argument("--device", type=Path, default=DEFAULT_DEVICE, help="a prepared base whose lock has no activation")
    ap.add_argument("--board", choices=("ipod", "ipad"), default="ipod")
    ap.add_argument("--helper")
    ap.add_argument("--dylib", default=os.environ.get("LTM_QEMU_DYLIB", str(HOME / "Developer/qemu-ios-ipad1/build-w1-native/libqemu-arm.dylib")))
    ap.add_argument("--files", type=Path, default=HOME / "Developer/qemu-ios-files")
    ap.add_argument("--usbmuxd", default=str(HOME / "Developer/usbmuxd-qemu/usbmuxd/src/usbmuxd"))
    ap.add_argument("--frameworks")
    ap.add_argument("--work", type=Path)
    args = ap.parse_args()
    offline()
    if args.offline:
        return 0
    if not args.device.is_dir():
        print(f"no device at {args.device}: offline half only")
        return 0
    return 0 if live(args) else 1


if __name__ == "__main__":
    sys.exit(main())
