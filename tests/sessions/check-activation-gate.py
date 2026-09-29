#!/usr/bin/env python3
"""The app verifies activation once per boot and blocks commands, persistently, when it didn't happen.

Two halves. Offline (always): EmulatorController's first-answer check, sliced with a fake
lockdown, must ask ActivationState on the first answer of a boot, retry a failed or unactivated
answer twice before deciding, set the persistent DeviceConnectionIssue ("This iPod isn't
activated. Choose Erase All Content and Settings, then prepare it again."), drop reachability,
cancel the boot preparation, report the notice, and keep that issue over later transient
failures; a service that answers later clears it. The known activated states
(Activated, FactoryActivated, WildcardActivated) pass, and so does a lockdown whose
services answer whatever the string says (the built-in iPod reports Unactivated and works);
an activated guest asks nothing again until the next boot. lockdown -34 maps to the same issue; the sidebar row notes
"Prepared without activation" from the lock alone.

With --device (default: a hook-less device.py iPod 3.1.3 base), the session driver boots it
as the app does and asks the same question over its own usbmuxd: the state is not Activated,
the mapped issue is the persistent one, and the first service read (-34) maps to it too.
With --expect activated (and --device shipping for the app's built-in iPod image, nand-current)
the other half: whatever activated state lockdown reports maps to no issue, and the service read
(the inspector's first app list, what enables Install) succeeds.

    tests/sessions/check-activation-gate.py [--offline] [--device DIR|shipping --board ipod|ipad] [--expect activated]
                                            [--helper PATH] [--dylib PATH] [--work DIR]
"""
import argparse, importlib.util, json, os, signal, subprocess, sys, tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
HOME = Path.home()
sys.path.insert(0, str(ROOT / "scripts"))
import sources  # the pinned checkouts (build-support/sources.json)
DEFAULT_DEVICE = HOME / "Developer/qemu-ios-files/ipod-ipsw/devices/7E18-a"
TEXT = "This iPod isn’t activated. Choose Erase All Content and Settings, then prepare it again."


def offline():
    s = (ROOT / "LightTouchMac/Device/EmulatorController.swift").read_text()
    a = s.index("    func reportConnectionFailure(_ error: Error, operation: String) {")
    report = s[a:s.index("    private var connectionFailures =", a)]
    a = s.index("    // MARK: - Activation (prepared offline, completed and verified per boot")
    activation = s[a:s.index("    func launchApp(_ bundleID: String)", a)]
    instance = (ROOT / "LightTouchMac/Library/DeviceInstance.swift").read_text()
    a = instance.index("    static func lockLacksActivation(_ lock: URL) -> Bool {")
    lock = instance[a:instance.index("\n    }", a) + 6]
    source = r'''import Foundation
nonisolated func logEvent(_ message: String) {}
@MainActor final class Controller {
 let profile = DeviceProfile.iPodTouch2G
 var usbConnected = true, liveAgentStatus = 1, connectionFailures = 0
 var onStatusChange: (() -> Void)?
 var bootGeneration = 0
 var preparingDevice = true
 var readinessTask: Task<Void, Never>? = Task { try? await Task.sleep(for: .seconds(60)) }
 var notices: [String] = [], resolved: [String] = []
 enum NoticeOperation { case activation }
 func reportDeviceNotice(_ text: String, for operation: NoticeOperation) { notices.append(text) }
 func resolveDeviceNotice(for operation: NoticeOperation) { resolved.append("\(operation)") }
 var answers: [String?] = [], asked = 0
 func activationState() async -> String? { asked += 1; return answers.isEmpty ? nil : answers.removeFirst() }
 var finished = 0, completionFailures = 0
 func finishActivation() async throws {
  finished += 1
  if completionFailures > 0 { completionFailures -= 1; throw NSError(domain: "activation", code: 1) }
 }
 var servicesAnswer = false, probed = 0
 func installProxyReady() async -> Bool { probed += 1; return servicesAnswer }
 var services: Controller { get throws { self } }  // EmulatorController.services: lockdown's answers
 var connectionIssue: DeviceConnectionIssue?
 var deviceReachable: Bool? {
  didSet {
   // As EmulatorController.deviceReachable's didSet: a service answered, nothing blocks any more.
   if deviceReachable == true, let issue = connectionIssue {
    if issue.persistent { resolveDeviceNotice(for: .activation) }
    connectionIssue = nil
   }
   checkActivationIfNeeded()
  }
 }
 func considerConnectionRecovery() {}
''' + report + activation + r'''}
enum Lock {
''' + lock + r'''}
@main struct Check {
 @MainActor static func main() async throws {
  Controller.activationRetryDelay = .milliseconds(5)
  func settle() async { try? await Task.sleep(for: .milliseconds(80)); for _ in 0..<20 { await Task.yield() } }
  // The known activated states pass; unknown names do not.
  for state in ["Activated", "FactoryActivated", "WildcardActivated"] {
   precondition(DeviceConnectionIssue.activation(state: state, profile: .iPodTouch2G) == nil, state)
  }
  for state in ["Unactivated", "Pending", "", "SomeOtherActivated"] { precondition(DeviceConnectionIssue.activation(state: state, profile: .iPodTouch2G) != nil, state) }
  precondition(DeviceConnectionIssue.activation(state: nil, profile: .iPodTouch2G) == nil)
  // Unactivated three times: persistent issue, blocked, no retry, preparation cancelled, notice.
  let c = Controller(); c.answers = ["Unactivated", "Unactivated", "Unactivated"]
  c.deviceReachable = true; await settle()
  precondition(c.asked == 3 && c.connectionIssue?.summary == TEXT && c.connectionIssue?.persistent == true, "\(c.asked)")
  precondition(c.connectionIssue?.blocksCommands == true && c.connectionIssue?.reconnectManagement == false)
  precondition(c.deviceReachable == false && !c.preparingDevice && c.readinessTask!.isCancelled && c.notices == [TEXT])
  // Transient failures leave it; -34 maps to it.
  c.reportConnectionFailure(DeviceError.lockdown(-8), operation: "Refreshing apps")
  precondition(c.connectionIssue?.summary == TEXT)
  c.reportConnectionFailure(DeviceError.lockdown(-34), operation: "Refreshing apps")
  precondition(c.connectionIssue?.summary == TEXT && c.connectionIssue?.persistent == true)
  // A service that answers later (the inspector's list read) clears the stale issue: installs are no longer blocked.
  c.deviceReachable = true; await settle()
  precondition(c.asked == 3 && c.connectionIssue == nil && c.deviceReachable == true && c.resolved == ["activation"], "\(c.asked)")
  // The next boot asks again.
  c.bootGeneration += 1; c.answers = ["Activated"]
  c.deviceReachable = true; await settle()
  precondition(c.asked == 4 && c.connectionIssue == nil && c.resolved == ["activation", "activation"])
  // Services that answer win over the string: the built-in iPod reports Unactivated and works (Sam's screenshot 17).
  let works = Controller(); works.answers = ["Unactivated", "Unactivated", "Unactivated"]; works.servicesAnswer = true
  works.deviceReachable = true; await settle()
  precondition(works.asked == 3 && works.probed == 1 && works.connectionIssue == nil && works.deviceReachable == true && works.preparingDevice
               && works.notices.isEmpty && works.resolved == ["activation"], "\(works.asked) \(works.probed)")
  // A -34 issue standing when a service read later succeeds clears with it.
  works.reportConnectionFailure(DeviceError.lockdown(-34), operation: "Refreshing apps")
  precondition(works.connectionIssue?.persistent == true && works.deviceReachable == false)
  works.deviceReachable = true; await settle()
  precondition(works.connectionIssue == nil && works.resolved == ["activation", "activation"])
  // A transient failure never decides: one failed query, then an unactivated one, then activated -> no issue.
  let flaky = Controller(); flaky.answers = [nil, "Unactivated", "WildcardActivated"]
  flaky.deviceReachable = true; await settle(); precondition(flaky.asked == 3 && flaky.connectionIssue == nil && flaky.preparingDevice)
  // Activated: asked once; three unanswered questions are asked again on the next answer.
  let ok = Controller(); ok.answers = [nil, nil, nil, "Activated"]
  ok.deviceReachable = true; await settle(); precondition(ok.asked == 3 && ok.connectionIssue == nil)
  ok.deviceReachable = true; await settle(); precondition(ok.asked == 4 && ok.connectionIssue == nil && ok.preparingDevice)
  ok.deviceReachable = true; await settle(); precondition(ok.asked == 4)
  precondition(ok.finished == 1)
  let retry = Controller(); retry.answers = Array(repeating: "Activated", count: 4); retry.completionFailures = 3
  retry.deviceReachable = true; await settle(); precondition(retry.finished == 3)
  retry.deviceReachable = true; await settle(); precondition(retry.finished == 4)
  retry.deviceReachable = true; await settle(); precondition(retry.finished == 4)
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
  print("PASS: activation verified per boot with retries; known activated states pass, completion retries, services that answer win; unactivated is a persistent issue that a later service answer clears; -34 maps to it; the lock's note")
 }
}
'''.replace("TEXT", json.dumps(TEXT, ensure_ascii=False))
    with tempfile.TemporaryDirectory(prefix="ltm-activation-") as d:
        p = Path(d) / "check.swift"
        p.write_text(source)
        subprocess.run(["swiftc", "-parse-as-library", "-module-cache-path", d + "/modules", str(ROOT / "LightTouchMac/Device/DeviceProfile.swift"),
                        str(ROOT / "LightTouchMac/Device/DeviceConnectionIssue.swift"), str(ROOT / "LightTouchMac/Transport/DeviceExecution.swift"), str(p), "-o", d + "/check"], check=True)
        subprocess.run([d + "/check"], check=True, timeout=60)


def live(args):
    spec = importlib.util.spec_from_file_location("check_sessions", ROOT / "tests/sessions/check-sessions.py")
    sessions = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(sessions)
    work = args.work or Path(tempfile.mkdtemp(prefix="ltm-activation-"))
    work.mkdir(parents=True, exist_ok=True)
    print(f"work: {work}", flush=True)
    helper = sessions.build(args, work)
    shipping = str(args.device) == "shipping"
    nand_current = args.files / "nand-current"
    cfg = {"helper": str(helper), "requirement": sessions.TEAM_REQ, "usbmuxd": args.usbmuxd, "ipa": "", "bundleID": "",
           "work": str(work), "files": str(args.files),
           "ipodNAND": str(args.files / os.readlink(nand_current)) if shipping and nand_current.is_symlink() else "",
           "ipadBase": str(args.device if args.board == "ipad" else ""),
           "activation": {"board": args.board, "base": "" if shipping else str(args.device)}}
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
    check(one("lit"), f"lit in {one('lit').get('seconds', -1):.1f} s")
    check(one("usb").get("productType"), f"lockdown answered over its usbmuxd: {one('usb').get('productType')}")
    act = one("activation")
    svc = one("service")
    if args.expect == "activated":
        # What lockdown says is reported, not judged: the built-in iPod reports Unactivated and works.
        print(f"  note: ActivationState {act.get('state')!r} (issue from the string alone: {act.get('summary') or 'none'!r})")
        check(not svc.get("error") and svc.get("apps", -1) >= 0, f"the service read succeeds: {svc.get('apps')} apps listed (installs enabled)"
              + (f": {svc.get('error')}" if svc.get("error") else ""))
    else:
        check(one("lock").get("lacksActivation"), "the lock records no activation: the row says \"Prepared without activation\"")
        check(act.get("state") and (act.get("state") == "Unactivated" or "Activated" not in act.get("state")), f"ActivationState {act.get('state')!r}")
        check(act.get("summary") == text and act.get("persistent") and act.get("blocks") and not act.get("retries"),
              f"the issue: persistent, blocks commands, no retry: {act.get('summary')!r}")
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
    ap.add_argument("--device", type=Path, default=DEFAULT_DEVICE, help="a prepared base whose lock has no activation; "
                    "`shipping`: the app's built-in iPod image (qemu-ios-files/nand-current)")
    ap.add_argument("--board", choices=("ipod", "ipad"), default="ipod")
    ap.add_argument("--expect", choices=("unactivated", "activated"), default="unactivated")
    ap.add_argument("--helper")
    ap.add_argument("--dylib", default=os.environ.get("LTM_QEMU_DYLIB", str(sources.qemu_build() / "libqemu-arm.dylib")))
    ap.add_argument("--files", type=Path, default=HOME / "Developer/qemu-ios-files")
    ap.add_argument("--usbmuxd", default=str(sources.path("usbmuxd") / "src/usbmuxd"))
    ap.add_argument("--frameworks")
    ap.add_argument("--work", type=Path)
    args = ap.parse_args()
    offline()
    if args.offline:
        return 0
    if str(args.device) != "shipping" and not args.device.is_dir():
        print(f"no device at {args.device}: offline half only")
        return 0
    return 0 if live(args) else 1


if __name__ == "__main__":
    sys.exit(main())
