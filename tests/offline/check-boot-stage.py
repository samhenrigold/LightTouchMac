#!/usr/bin/env python3
"""The boot toast's stage comes from the device's own signals, never a timer.

Compiles Device/BootStage.swift whole with the app's serial watch (Transport/NativeLogging.swift) and feeds
the watch a recorded iPad 4.2.1 serial log (tests/fixtures/serial-k48ap-8C148.log, kernel console on), in
small writes, with the app's marker list; then the recorded boot's other two events (the guest tools
reporting in, USB attaching). The stages must come out in order with their words, move only forward, and
not move at all for lines that prove nothing. The readiness rule for a boot whose USB never answers is
here too: a picture from a running iOS keeps the device running; no picture, or only iBoot's, stops it.
"""
from pathlib import Path
import os, subprocess, tempfile

ROOT = Path(__file__).resolve().parents[2]
APP = ROOT / 'LightTouchMac'

check = r'''
import Foundation
final class Seen: @unchecked Sendable {
    private let lock = NSLock(); private var all: [String] = []
    func add(_ s: String) { lock.withLock { all.append(s) } }
    var phrases: [String] { lock.withLock { all } }
}
@main struct Check {
    static func main() throws {
        // The recorded log through the real watch, 64 bytes at a time (markers split across writes).
        var fds: [Int32] = [-1, -1]
        precondition(pipe(&fds) == 0)
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ltm-boot-stage-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let seen = Seen()
        let reader = try LogPipeReader(descriptor: fds[0], log: RotatingLog(url: dir.appendingPathComponent("serial.log")),
                                       watch: .init(phrases: Array(BootStage.serialMarkers.keys)) { seen.add($0) })
        let log = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))
        for start in stride(from: 0, to: log.count, by: 64) {
            let chunk = log[start..<min(start + 64, log.count)]
            _ = chunk.withUnsafeBytes { Darwin.write(fds[1], $0.baseAddress, chunk.count) }
            usleep(2_000)
        }
        usleep(100_000)
        reader.flush()
        Darwin.close(fds[1])
        reader.finish()
        // Each once; one read can carry several, reported in the watch's list order, so compare as a set
        // (stages only move forward, so the order within a read can't take the toast back).
        let recorded = [":: iBoot for", "Loading kernel cache", "iBoot version: ", "launchd[1] has started up"]
        precondition(seen.phrases.count == 4 && Set(seen.phrases) == Set(recorded), "\(seen.phrases)")
        precondition(seen.phrases.map(BootStage.Event.serial).reduce(BootStage.poweringOn) { $0.after($1) } == .system)

        // The recorded boot, event by event in the log's order: what the toast says after each.
        let text = String(decoding: log, as: UTF8.self)
        precondition(recorded == recorded.sorted { text.range(of: $0)!.lowerBound < text.range(of: $1)!.lowerBound })
        let events = recorded.map(BootStage.Event.serial) + [.guestTools, .usbAttached]
        var stage = BootStage.poweringOn
        var said = [stage.text]
        for event in events {
            let next = stage.after(event)
            if next != stage { said.append(next.text) }
            stage = next
        }
        precondition(said == ["Powering on", "Loading iOS", "Starting the system", "Connecting over USB", "Waiting for the Home screen"], "\(said)")
        precondition(stage == .usb)

        // Only forward: a late marker (a reset reprinting iBoot, the loader reporting after USB) changes nothing.
        precondition(BootStage.usb.after(.serial(":: iBoot for")) == .usb && BootStage.usb.after(.guestTools) == .usb)
        precondition(BootStage.kernel.after(.serial("no such phrase")) == .kernel)
        // Without the kernel console (the default), iBoot's lines, then the guest tools, then USB.
        precondition(BootStage.poweringOn.after(.serial("Loading kernel cache")).after(.guestTools) == .system)
        // The iPod touch (1st generation): iBoot-204 prints no banner; the kernel's line is the first sign.
        precondition(BootStage.poweringOn.after(.serial("Darwin Kernel Version")) == .kernel)

        // The readiness deadline: iOS on screen without USB keeps running; no picture, or iBoot's logo alone, stops.
        precondition(ReadinessDeadline.verdict(painted: true, stage: .system) == .keepRunning, "slide to set up, no USB: keep it")
        precondition(ReadinessDeadline.verdict(painted: true, stage: .usb) == .keepRunning)
        precondition(ReadinessDeadline.verdict(painted: false, stage: .system) == .stop, "iOS runs but never shows a picture")
        precondition(ReadinessDeadline.verdict(painted: false, stage: .poweringOn) == .stop, "nothing at all")
        precondition(ReadinessDeadline.verdict(painted: true, stage: .loading) == .stop && ReadinessDeadline.verdict(painted: true, stage: .kernel) == .stop,
                     "iBoot lights the display too: its logo alone is not iOS")
        precondition(stage == .usb && ReadinessDeadline.verdict(painted: true, stage: recorded.prefix(4).map(BootStage.Event.serial)
            .reduce(.poweringOn) { $0.after($1) }) == .keepRunning, "the recorded boot, had USB never come: kept")
        let notice = ReadinessDeadline.notice(shortName: "iPad")
        precondition(notice.hasPrefix("The iPad is running, but it isn’t connected over USB yet.") && notice.contains("Installing apps and transferring files"))
        print("PASS: the recorded boot's serial lines, guest tools and USB give the toast's stages in order, only forward; iOS on screen without USB keeps running, no picture stops")
    }
}
'''

with tempfile.TemporaryDirectory(prefix='ltm-boot-stage-') as d:
    main = Path(d) / 'main.swift'
    main.write_text(check)
    subprocess.run(['xcrun', 'swiftc', '-parse-as-library', '-module-cache-path', d + '/modules',
                    *[str(APP / f) for f in ('Device/BootStage.swift', 'Transport/NativeLogging.swift', 'Library/StorageLocations.swift',
                                             'Library/Bundled.swift', 'Transport/AppEventLog.swift')],
                    str(main), '-o', d + '/check'], check=True)
    subprocess.run([d + '/check', str(ROOT / 'tests/fixtures/serial-k48ap-8C148.log')], check=True, timeout=30,
                   env=dict(os.environ, LTM_STATE_DIR=d + '/state'))
