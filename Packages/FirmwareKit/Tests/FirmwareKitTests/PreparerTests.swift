import Foundation
import Testing
@testable import FirmwareKit

/// The preparer contract's stream and cancel, through the built `firmwarekit` (skipped when it isn't built).
@Suite struct PreparerTests {
    static let cli = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().appendingPathComponent(".build/debug/firmwarekit")

    static func object(_ line: some StringProtocol) -> [String: Any]? {
        try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any]
    }

    @Test func eventLines() throws {
        let cases: [(PrepareEvent, [String: AnyHashable])] = [
            (.begin(steps: 7), ["event": "begin", "steps": 7]),
            (.begin(steps: 2, seconds: [1.5, 70]), ["event": "begin", "steps": 2, "seconds": [1.5, 70.0] as [Double]]),
            (.step(index: 3, name: "Building \"the\"/system\nvolume"), ["event": "step", "index": 3, "name": "Building \"the\"/system\nvolume"]),
            (.progress(0.42), ["event": "progress", "fraction": 0.42]),
            (.progress(0.5, detail: "Booting to seal the flash — 42 s"), ["event": "progress", "fraction": 0.5, "detail": "Booting to seal the flash — 42 s"]),
            (.warning("w"), ["event": "warning", "message": "w"]),
            (.done(lock: "device.lock.json"), ["event": "done", "lock": "device.lock.json"]),
            (.error(code: "activation_failed", message: "m"), ["event": "error", "code": "activation_failed", "message": "m"]),
        ]
        for (e, want) in cases {
            #expect(!e.json.contains("\n"))
            let got = try #require(Self.object(e.json))
            #expect(Set(got.keys) == Set(want.keys))
            for (k, v) in want { #expect((got[k] as? AnyHashable) == v, "\(k)") }
        }
    }

    /// A plan's time estimate: monotonic, held short of a milestone not yet seen, and never 1 by itself.
    @Test func planFraction() throws {
        let seal = StepPlan.plan("Sealing the NAND"), first = seal.milestones[0].at / seal.seconds
        let unseen = [Double?](repeating: nil, count: seal.milestones.count)
        let early = stride(from: 0.0, through: 600, by: 0.5).map { seal.fraction(elapsed: $0, seen: unseen) }
        #expect(zip(early, early.dropFirst()).allSatisfy { $0 <= $1 } && early.last! < first && early.last! > 0.9 * first)
        var seen = unseen
        seen[2] = 3   // launchd already up at 3 s (a fast 4.x boot): jumps to its milestone, then on by time
        #expect(abs(seal.fraction(elapsed: 3, seen: seen) - 19 / 72) < 1e-9 && seal.fraction(elapsed: 13, seen: seen) > 19 / 72)
        #expect(seal.fraction(elapsed: 1e6, seen: seen) < seal.milestones[3].at / seal.seconds)
        let lock = StepPlan.plan("Writing the lock")
        #expect(abs(lock.fraction(elapsed: 1e6, seen: []) - 0.95) < 1e-9 && StepPlan.plan("no such step").seconds > 0)
    }

    /// StepProgress's stream: every step's progress is monotonic, has a detail and ends with exactly one 1.0;
    /// a boot's milestones change the detail; nothing after stop().
    @Test func progressStream() throws {
        try Oracle.withTemp { work in
            final class Events: @unchecked Sendable { let lock = NSLock(); var all: [PrepareEvent] = [] }
            let events = Events()
            let p = StepProgress(work: work) { e in events.lock.withLock { events.all.append(e) } }
            let bytes = ByteCount(total: 100)
            p.next(index: 1, name: "Verifying the IPSW")
            p.measure = { bytes.fraction }
            for _ in 0..<3 { bytes.add(30); Thread.sleep(forTimeInterval: 0.6) }
            p.next(index: 2, name: "Sealing the NAND")
            try Data("iBoot version: iBoot-817.29\n[FTL:MSG] FTL_Open            [OK]\n".utf8).write(to: work.appendingPathComponent("seal.log"))
            Thread.sleep(forTimeInterval: 1.5)
            try Data("*** launchd[1] has started up. ***\n".utf8).write(to: work.appendingPathComponent("seal.log"))
            Thread.sleep(forTimeInterval: 1.5)
            p.finish()
            p.stop()
            let all = events.lock.withLock { events.all }
            Thread.sleep(forTimeInterval: 1.2)
            #expect(events.lock.withLock { events.all.count } == all.count, "no events after stop()")
            var steps: [[(Double, String)]] = []
            for e in all {
                switch e {
                case .step: steps.append([])
                case let .progress(f, detail): steps[steps.count - 1].append((f, try #require(detail)))
                default: Issue.record("\(e)")
                }
            }
            #expect(steps.count == 2)
            for s in steps {
                let f = s.map(\.0)
                #expect(zip(f, f.dropFirst()).allSatisfy { $0 <= $1 }, "monotonic: \(f)")
                #expect(f.last == 1 && f.dropLast().allSatisfy { $0 < 1 }, "one final 1.0: \(f)")
            }
            #expect(steps[0].dropLast().contains { $0.0 >= 0.6 }, "bytes measured: \(steps[0])")
            let details = steps[1].map(\.1)
            #expect(details.first == "Booting to seal the flash — 0 s")
            #expect(details.contains { $0.hasPrefix("Booting to seal the flash: opening the flash — ") })
            #expect(details.last!.hasPrefix("Booting to seal the flash: starting iOS — "), "\(details)")
        }
    }

    @Test func errorCodes() {
        func code(_ e: Error) -> String? { if case .error(let c, _) = Preparer.errorEvent(e) { return c }; return nil }
        #expect(code(FirmwareError(.activationFailed, "x")) == "activation_failed")
        #expect(code(ActivationFailure("x")) == "activation_failed")
        #expect(code(FirmwareError(.oneshotFailed, "x")) == "oneshot_failed")
        #expect(code(FirmwareError(.internal, "write: No space left on device")) == "disk_full")
        #expect(code(NSError(domain: NSPOSIXErrorDomain, code: Int(ENOSPC))) == "disk_full")
        #expect(code(CocoaError(.fileWriteOutOfSpace)) == "disk_full")
        #expect(code(CocoaError(.fileNoSuchFile)) == "internal")
    }

    /// Cancel's process sweep: a grandchild is found and stopped.
    @Test func terminatesDescendants() throws {
        let sh = Process()
        sh.executableURL = URL(fileURLWithPath: "/bin/sh")
        sh.arguments = ["-c", "sleep 60 & wait"]
        try sh.run()
        defer { if sh.isRunning { sh.terminate() } }
        var kids: [pid_t] = []
        for _ in 0..<100 where kids.isEmpty { usleep(20_000); kids = Preparer.descendants(of: sh.processIdentifier) }
        #expect(kids.count == 1)
        let t0 = Date()
        Preparer.terminateDescendants(of: sh.processIdentifier, grace: 1)
        sh.waitUntilExit()   // its `wait` returns once sleep is gone
        #expect(Date().timeIntervalSince(t0) < 2)
        #expect(kids.allSatisfy { kill($0, 0) != 0 })
    }

    struct Run { var lines: [[String: Any]]; var status: Int32; var staging: URL }

    /// Runs `firmwarekit create` on `ipsw` with the 7B500 entry; `whileRunning` gets the process after the first stdout bytes.
    static func create(_ dir: URL, ipsw: URL, extra: [String] = [], whileRunning: ((Process) -> Void)? = nil) throws -> Run {
        let entry = dir.appendingPathComponent("entry.json"), staging = dir.appendingPathComponent("staging")
        try JSONEncoder().encode(try Oracle.entry("k48ap-7B500")).write(to: entry)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        let p = Process(), out = Pipe()
        p.executableURL = cli
        p.arguments = ["create", "--entry", entry.path, "--ipsw", ipsw.path, "--out", staging.path, "--helper", "/bin/sh",
                       "--guest-tools", dir.path] + extra
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        try p.run()
        var data = Data()
        if let whileRunning {
            while !String(decoding: data, as: UTF8.self).contains("\"index\":1") {
                let d = out.fileHandleForReading.availableData
                if d.isEmpty { break }
                data += d
            }
            whileRunning(p)
        }
        data += out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        let text = String(decoding: data, as: UTF8.self)
        let lines = text.split(separator: "\n").map { Self.object($0) }
        #expect(lines.allSatisfy { $0 != nil }, "stdout is JSON Lines only: \(text)")
        return Run(lines: lines.compactMap { $0 }, status: p.terminationStatus, staging: staging)
    }

    @Test func streamOnError() throws {
        guard Oracle.exists(Self.cli) else { return }
        try Oracle.withTemp { dir in
            let ipsw = dir.appendingPathComponent("fake.ipsw")
            try Data("not the pinned IPSW".utf8).write(to: ipsw)
            let r = try Self.create(dir, ipsw: ipsw)
            #expect(r.status == 1)
            #expect(r.lines.map { $0["event"] as? String }.filter { $0 != "progress" } == ["begin", "step", "error"])
            #expect(r.lines.first?["steps"] as? Int == 7)
            #expect(r.lines[1]["index"] as? Int == 1 && r.lines.first?["seconds"] is [Double])
            #expect(r.lines.last?["code"] as? String == "sha_mismatch")

            // activation is built in: the old hook flag is an unknown argument
            try FileManager.default.removeItem(at: r.staging)
            let h = try Self.create(dir, ipsw: ipsw, extra: ["--activation-hook", "/bin/true"])
            #expect(h.status == 1)
            #expect(h.lines.map { $0["event"] as? String } == ["error"])
            #expect(h.lines.last?["code"] as? String == "internal")
        }
    }

    /// SIGTERM mid-step (hashing a sparse 8 GB "IPSW"): exits within 2 s, 143, staging left for the caller.
    @Test func cancelWithinTwoSeconds() throws {
        guard Oracle.exists(Self.cli) else { return }
        try Oracle.withTemp { dir in
            let ipsw = dir.appendingPathComponent("big.ipsw")
            FileManager.default.createFile(atPath: ipsw.path, contents: nil)
            #expect(truncate(ipsw.path, 8 << 30) == 0)
            var t0 = Date()
            let r = try Self.create(dir, ipsw: ipsw) { p in
                t0 = Date()
                p.terminate()
            }
            #expect(Date().timeIntervalSince(t0) < 2)
            #expect(r.status == 143)
            #expect(r.lines.map { $0["event"] as? String }.filter { $0 != "progress" } == ["begin", "step"])
            #expect(FileManager.default.fileExists(atPath: r.staging.path))
        }
    }
}
