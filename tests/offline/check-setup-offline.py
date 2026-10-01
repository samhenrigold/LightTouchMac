#!/usr/bin/env python3
"""5.x Setup runs offline, then networking opens in place (smoke #54), outside the app.

Compiles BootRecipe.swift and Shared/DeviceLinkProtocol.swift with a fixture and checks what the
app's iPadBoot / foreground watch decide:
  - which firmware boots slirp restrict=on (5.x only), and the wifi0 netdev both ways: the proxy
    guestfwd kept, unrestricted byte-identical to the pre-#54 string;
  - SetupNetworkGate over it_agent frontmost sequences. The agent answers
    "com.apple.springboard / Lock Screen" when locked (contrib/it-agent/agent-sbs.h), and a fresh 5.x
    shows exactly that before Setup, so the lift must wait for an unlocked non-Setup screen (twice).
    The 9B206 sequence is the one the net-restrict-live gate recorded;
  - the .setup-done overlay mark (next boot unrestricted; Erase deletes the overlay with it);
  - LinkCommand.netRestrict survives the app<->helper wire (JSON Codable).
Temp dir only; deleted at the end.
"""
import sys
from pathlib import Path
sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "scripts"))
import host_runtime
from pathlib import Path
import subprocess, sys, tempfile

ROOT = Path(__file__).resolve().parents[2]
APP = ROOT / 'LightTouchMac'

CHECK = r'''
import Foundation

var failures = 0
func expect(_ ok: Bool, _ what: @autoclosure () -> String, line: Int = #line) {
    if !ok { print("FAIL line \(line): \(what())"); failures += 1 }
}

// Which firmware runs Setup offline.
for v in ["5.0", "5.0.1", "5.1", "5.1.1"] { expect(BootRecipe.setupPhonesHome(iosVersion: v), "\(v) should boot restricted") }
for v in ["3.2", "3.2.2", "4.2.1", "4.3", "4.3.5", "3.1.3"] { expect(!BootRecipe.setupPhonesHome(iosVersion: v), "\(v) should boot unrestricted") }

// The wifi0 netdev: guestfwd kept both ways; unrestricted is the pre-#54 string.
let fwd = ",guestfwd=tcp:10.0.2.100:3128-cmd:/usr/bin/nc -U /tmp/p.sock"
expect(BootRecipe.wifiNetdev(guestForward: fwd, restricted: false) == "user,id=wifi0" + fwd, "unrestricted netdev changed")
let r = BootRecipe.wifiNetdev(guestForward: fwd, restricted: true)
expect(r.hasPrefix("user,id=wifi0" + fwd) && r.hasSuffix(",restrict=on"), "restricted netdev: \(r)")
// The helper reads the same argv to start its web proxy offline (DeviceHost; the PAC routes public hosts
// through it, and slirp's restrict lets guestfwd traffic by).
func argv(_ netdev: String?) -> BootConfig { BootConfig(argv: ["LightTouchMac", "-M", "ipad1"] + (netdev.map { ["-netdev", $0] } ?? []), machine: "ipad1") }
expect(argv(r).wifiRestricted, "helper doesn't see the restricted netdev")
expect(!argv(BootRecipe.wifiNetdev(guestForward: fwd, restricted: false)).wifiRestricted, "helper sees an unrestricted netdev as restricted")
expect(!argv(nil).wifiRestricted, "no netdev read as restricted")
expect(!argv("user,id=wifi0,guestfwd=tcp:10.0.2.100:3128-cmd:/usr/bin/nc -U /tmp/restrict=on").wifiRestricted, "a path containing restrict=on")

// The gate over frontmost sequences: (bundleID, name) per 3 s poll; nil = agent not up yet.
typealias Poll = (String?, String?)
func lifts(_ seq: [Poll]) -> Int? {
    var gate = BootRecipe.SetupNetworkGate()
    for (i, p) in seq.enumerated() where gate.observe(bundleID: p.0, name: p.1) { return i }
    return nil
}
let SB = "com.apple.springboard", PB = "com.apple.purplebuddy"
// Fresh 5.x: agent coming up, Setup's lock screen, the walk, home.
let fresh: [Poll] = [(nil, nil), (nil, nil), (SB, "Lock Screen"), (SB, "Lock Screen"), (SB, "Lock Screen"),
                     (PB, "Setup"), (PB, "Setup"), (PB, "Setup"), (SB, "Home Screen"), (SB, "Home Screen")]
expect(lifts(fresh) == 9, "fresh 5.x lifted at \(String(describing: lifts(fresh))), want 9 (second home poll)")
// Locked forever (a device left on Setup's lock screen) never lifts.
expect(lifts(Array(repeating: (SB, "Lock Screen"), count: 20)) == nil, "lifted on the lock screen")
expect(lifts(Array(repeating: (PB, "Setup"), count: 20)) == nil, "lifted during Setup")
// One stray unlocked poll while the slide hands over to purplebuddy doesn't lift.
let blip: [Poll] = [(SB, "Lock Screen"), (SB, "Home Screen"), (PB, "Setup"), (PB, "Setup")]
expect(lifts(blip) == nil, "a single unlocked poll lifted it")
// A failed poll (agent error) breaks the streak.
let broken: [Poll] = [(PB, "Setup"), (SB, "Home Screen"), (nil, nil), (SB, "Home Screen")]
expect(lifts(broken) == nil, "a failed poll between two homes still lifted")
// A past-Setup device with no mark (predates it): lifts at the first unlocked screen, app or home.
let reused: [Poll] = [(SB, "Lock Screen"), (SB, "Lock Screen"), ("com.apple.mobilesafari", "Safari"), ("com.apple.mobilesafari", "Safari")]
expect(lifts(reused) == 3, "reused device lifted at \(String(describing: lifts(reused)))")
// Answers true once.
var once = BootRecipe.SetupNetworkGate()
_ = once.observe(bundleID: SB, name: "Home Screen"); let first = once.observe(bundleID: SB, name: "Home Screen")
expect(first && !once.observe(bundleID: SB, name: "Home Screen") && once.lifted, "gate fired more than once")

// RECORDED (net-restrict-live gate, 9B206): see sequence file passed as argv[1], one "bundle\tname" per poll.
if CommandLine.arguments.count > 1, let text = try? String(contentsOfFile: CommandLine.arguments[1], encoding: .utf8) {
    let seq: [Poll] = text.split(separator: "\n").map {
        let f = $0.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
        return (f[0].isEmpty ? nil : f[0], f.count > 1 && !f[1].isEmpty ? f[1] : nil)
    }
    let firstHome = seq.firstIndex { $0.0 == SB && $0.1 == "Home Screen" }
    let lastSetup = seq.lastIndex { $0.0 == PB }
    let at = lifts(seq)
    expect(lastSetup != nil, "recorded sequence never shows purplebuddy")
    expect(at != nil && lastSetup != nil && at! > lastSetup!, "recorded: lifted at \(String(describing: at)), last Setup poll \(String(describing: lastSetup))")
    expect(at != nil && firstHome != nil && at! == firstHome! + 1, "recorded: lifted at \(String(describing: at)), first home \(String(describing: firstHome))")
    print("recorded 9B206 sequence: \(seq.count) polls, last Setup \(lastSetup ?? -1), lift at \(at ?? -1)")
}

// The overlay mark.
let tmp = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("setup-offline-\(UUID().uuidString)")
try! FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
let mark = BootRecipe.setupDoneMark(overlay: tmp)
expect(mark.deletingLastPathComponent().resolvingSymlinksInPath().path == tmp.resolvingSymlinksInPath().path, "mark outside the overlay: \(mark.path)")
expect(mark.lastPathComponent.hasPrefix("."), "mark is not a dot-file (pinOverlay reads the overlay's contents)")
try? FileManager.default.removeItem(at: tmp)

// The wire.
let data = try! JSONEncoder().encode(AppMessage.command(.netRestrict(false)))
if case .command(.netRestrict(let on))? = try? JSONDecoder().decode(AppMessage.self, from: data) { expect(on == false, "decoded \(on)") }
else { expect(false, "netRestrict didn't round-trip: \(String(decoding: data, as: UTF8.self))") }

if failures > 0 { exit(1) }
print("PASS: 5.x-only restrict, netdev both ways, gate sequences (lock screen, Setup, blip, failed poll, reuse, once), overlay mark, wire")
'''


def main():
    with tempfile.TemporaryDirectory(prefix='check-setup-offline.') as t:
        tmp = Path(t)
        (tmp / 'main.swift').write_text(CHECK)
        subprocess.run(['xcrun', 'swiftc', *host_runtime.swift_flags(Path(__file__).resolve().parents[2]), '-O', '-suppress-warnings', '-swift-version', '5', '-module-cache-path', str(tmp / 'modules'), str(ROOT / 'Shared/DeviceLinkProtocol.swift'), str(tmp / 'main.swift'),
                        '-o', str(tmp / 'check')], check=True)
        seq = ROOT / 'tests/fixtures/frontmost-9B206-setup.tsv'
        return subprocess.run([str(tmp / 'check')] + ([str(seq)] if seq.exists() else [])).returncode


if __name__ == '__main__':
    sys.exit(main())
