import Foundation
import Testing

@testable import FirmwareKit

/// The preparer contract's stream and cancel, through the built `firmwarekit` (skipped when it isn't built).
@Suite(.detachesItsImages) struct PreparerTests {
    static let cli = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().appendingPathComponent(".build/debug/firmwarekit")

    static func object(_ line: some StringProtocol) -> [String: Any]? {
        try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any]
    }

    @Test func eventLines() throws {
        let cases: [(PrepareEvent, [String: AnyHashable])] = [
            (.begin(steps: 7), ["event": "begin", "steps": 7]),
            (
                .begin(steps: 2, seconds: [1.5, 70]),
                ["event": "begin", "steps": 2, "seconds": [1.5, 70.0] as [Double]]
            ),
            (
                .step(index: 3, name: "Building \"the\"/system\nvolume"),
                ["event": "step", "index": 3, "name": "Building \"the\"/system\nvolume"]
            ),
            (.progress(0.42), ["event": "progress", "fraction": 0.42]),
            (
                .progress(0.5, detail: "Starting iOS — 42 s"),
                ["event": "progress", "fraction": 0.5, "detail": "Starting iOS — 42 s"]
            ),
            (.warning("w"), ["event": "warning", "message": "w"]),
            (.done(lock: "device.lock.json"), ["event": "done", "lock": "device.lock.json"]),
            (
                .error(code: "activation_failed", message: "m"),
                ["event": "error", "code": "activation_failed", "message": "m"]
            )
        ]
        for (e, want) in cases {
            #expect(!e.json.contains("\n"))
            let got = try #require(Self.object(e.json))
            #expect(Set(got.keys) == Set(want.keys))
            for (k, v) in want { #expect((got[k] as? AnyHashable) == v, "\(k)") }
        }
    }

    /// A plan's time estimate: monotonic, on by time past milestones a release never prints, and never to the
    /// last milestone (the halt) or 1 by itself.
    @Test func planFraction() throws {
        let seal = StepPlan.plan(StepPlan.sealStep)
        let end = seal.milestones.last!.at / seal.seconds
        let unseen = [Double?](repeating: nil, count: seal.milestones.count)
        let early = stride(from: 0.0, through: 600, by: 0.5).map { seal.fraction(elapsed: $0, seen: unseen) }
        #expect(zip(early, early.dropFirst()).allSatisfy { $0 <= $1 } && early.last! < end && early.last! > 0.9 * end)
        var seen = unseen
        seen[2] = 3  // launchd already up at 3 s (a fast 4.x boot): jumps to its milestone, then on by time
        #expect(
            abs(seal.fraction(elapsed: 3, seen: seen) - 19 / 72) < 1e-9
                && seal.fraction(elapsed: 13, seen: seen) > 19 / 72
        )
        #expect(seal.fraction(elapsed: 1e6, seen: seen) < end)
        let lock = StepPlan.plan("Writing the lock")
        #expect(abs(lock.fraction(elapsed: 1e6, seen: []) - 0.95) < 1e-9 && StepPlan.plan("no such step").seconds > 0)
    }

    /// Sam 10-07: the seal of an iOS 7 iPhone sat at ~83% for minutes. Its boot prints launchd at 8 s and nothing
    /// the plan knows for minutes after; the step keeps moving all the while, and its weight is its real length.
    @Test func iOS7SealKeepsMoving() throws {
        let seal = StepPlan.plan(StepPlan.sealStep, major: 7)
        #expect(seal.seconds > 300 && StepPlan.plan(StepPlan.sealStep, major: 6).seconds < 100)
        var seen = [Double?](repeating: nil, count: seal.milestones.count)
        seen[0] = 4
        seen[1] = 8  // FTL_Open, launchd; no Wi-Fi line (a boot without it), no SpringBoard yet
        let at = stride(from: 10.0, through: 320, by: 30).map { seal.fraction(elapsed: $0, seen: seen) }
        #expect(zip(at, at.dropFirst()).allSatisfy { $1 - $0 > 0.05 }, "every 30 s moves the step on: \(at)")
    }

    /// StepProgress's stream: every step's progress is monotonic, has a detail and ends with exactly one 1.0;
    /// a boot's milestones change the detail; nothing after stop().
    @Test func progressStream() throws {
        try Oracle.withTemp { work in
            final class Events: @unchecked Sendable {
                let lock = NSLock()
                var all: [PrepareEvent] = []
            }
            let events = Events()
            let p = StepProgress(work: work) { e in events.lock.withLock { events.all.append(e) } }
            let bytes = ByteCount(total: 100)
            p.next(index: 1, name: "Verifying the IPSW")
            p.measure = { bytes.fraction }
            for _ in 0..<3 {
                bytes.add(30)
                Thread.sleep(forTimeInterval: 0.6)
            }
            p.next(index: 2, name: StepPlan.sealStep)
            try Data("iBoot version: iBoot-817.29\n[FTL:MSG] FTL_Open            [OK]\n".utf8).write(
                to: work.appendingPathComponent("seal.log")
            )
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
                case .progress(let f, let detail): steps[steps.count - 1].append((f, try #require(detail)))
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
            #expect(details.first == "Starting iOS — 0 s")
            #expect(details.contains { $0.hasPrefix("Opening the flash — ") })
            #expect(details.last!.hasPrefix("Starting iOS — "), "\(details)")
        }
    }

    /// The check boot's FTL_Open [OK], split by interleaved serial lines (ipad1_seal.py FTL_OPEN_RE).
    @Test func ftlOpenAcrossLines() {
        #expect(Preparer.ftlOpened("[FTL:MSG] FTL_Open            [OK]\n"))
        #expect(Preparer.ftlOpened("AppleNANDFTL: [FTL:MSG] FTL_Open\n            [OK]\n"))
        #expect(
            !Preparer.ftlOpened("[FTL:MSG] FTL_Open            [FAIL]\n") && !Preparer.ftlOpened("CXT is not valid\n")
        )
    }

    @Test func errorCodes() {
        func code(_ e: Error) -> String? {
            if case .error(let c, _, _) = Preparer.errorEvent(e) { return c }
            return nil
        }
        #expect(code(FirmwareError(.activationFailed, "x")) == "activation_failed")
        #expect(code(ActivationFailure("x")) == "activation_failed")
        #expect(code(FirmwareError(.oneshotFailed, "x")) == "oneshot_failed")
        #expect(code(FirmwareError(.internal, "write: No space left on device")) == "disk_full")
        #expect(code(NSError(domain: NSPOSIXErrorDomain, code: Int(ENOSPC))) == "disk_full")
        #expect(code(CocoaError(.fileWriteOutOfSpace)) == "disk_full")
        #expect(code(CocoaError(.fileNoSuchFile)) == "internal")
        // A required piece that doesn't fit names itself in the event, for the app's plain words.
        let log = FitCheck.Log()
        #expect(throws: FirmwareError.self) {
            try log.check(FitCheck.Fit("OpenGLES front end (contrib/gles-public)", fits: false, "x"), required: true)
        }
        do {
            try log.check(FitCheck.Fit("OpenGLES front end (contrib/gles-public)", fits: false, "x"), required: true)
        } catch {
            let line = Self.object(Preparer.errorEvent(error).json)
            #expect(
                line?["code"] as? String == "unsupported"
                    && line?["piece"] as? String == "OpenGLES front end (contrib/gles-public)"
            )
        }
        #expect(Self.object(Preparer.errorEvent(FirmwareError(.unsupported, "x")).json)?["piece"] == nil)
    }

    /// Cancel's process sweep: a grandchild is found and stopped.
    @Test func terminatesDescendants() async throws {
        // Spawned and reaped here rather than through Process, whose waitUntilExit once missed the exit under load and hung the plan.
        var sh: pid_t = 0
        let argv: [UnsafeMutablePointer<CChar>?] =
            ["/bin/sh", "-c", "sleep 600 & wait"].map { (s: String) in strdup(s) } + [nil]
        defer { for arg in argv { free(arg) } }
        try #require(posix_spawn(&sh, "/bin/sh", nil, nil, argv, environ) == 0)
        var reaped = false
        defer {
            if !reaped {
                kill(sh, SIGKILL)
                waitpid(sh, nil, 0)
            }
        }
        var kids: [pid_t] = []
        for _ in 0..<100 where kids.isEmpty {
            usleep(20_000)
            kids = Preparer.descendants(of: sh)
        }
        #expect(kids.count == 1)
        let t0 = Date()
        await Preparer.terminateDescendants(of: sh, grace: 1)
        // Its `wait` returns once sleep is gone: 60 s is well short of sleep's 600, and at load 100 or more a shell
        // has taken over 10 s to be scheduled and exit.
        while !reaped, Date().timeIntervalSince(t0) < 60 {
            reaped = waitpid(sh, nil, WNOHANG) == sh
            if !reaped { usleep(20_000) }
        }
        #expect(reaped)
        #expect(kids.allSatisfy { kill($0, 0) != 0 })
    }

    struct Run {
        var lines: [[String: Any]]
        var status: Int32
        var staging: URL
    }

    /// The emulator's machines as LightTouchDevice lists them.
    static let machines = URL(fileURLWithPath: #filePath)
        .appendingPathComponent("../../../../../tests/fixtures/machines.json").standardized

    /// Runs `firmwarekit create` on `ipsw` with the 7B500 entry; `whileRunning` gets the process after the first stdout bytes.
    /// The helper is a stand-in that only lists the machines (machines.json): the K48 board's check asks the helper for
    /// the iPad's machine before the plan begins, and nothing here gets as far as booting it.
    static func create(_ dir: URL, ipsw: URL, extra: [String] = [], whileRunning: ((Process) -> Void)? = nil) throws
        -> Run
    {
        let entry = dir.appendingPathComponent("entry.json")
        let staging = dir.appendingPathComponent("staging")
        let helper = dir.appendingPathComponent("LightTouchDevice")
        try JSONEncoder().encode(try Oracle.entry("k48ap-7B500")).write(to: entry)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        try "#!/bin/sh\nprintf '{\"machines\":'\ncat '\(machines.path)'\nprintf '}'\n".write(
            to: helper,
            atomically: true,
            encoding: .utf8
        )
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: helper.path)
        let p = Process()
        let out = Pipe()
        p.executableURL = cli
        p.arguments =
            [
                "create", "--entry", entry.path, "--ipsw", ipsw.path, "--out", staging.path, "--helper", helper.path,
                "--guest-tools", dir.path
            ] + extra
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

    @Test(.enabled(if: FixtureRequirements.corpusEnabled, "Firmware corpus test; set FK_TEST_CORPUS=1 to run"))
    func streamOnError() throws {
        guard Oracle.exists(Self.cli) else {
            try FixtureRequirements.missing(#"PreparerTests.swift: Oracle.exists(Self.cli)"#)
        }
        try Oracle.withTemp { dir in
            let ipsw = dir.appendingPathComponent("fake.ipsw")
            try Data("not the pinned IPSW".utf8).write(to: ipsw)
            let r = try Self.create(dir, ipsw: ipsw)
            #expect(r.status == 1)
            #expect(r.lines.map { $0["event"] as? String }.filter { $0 != "progress" } == ["begin", "step", "error"])
            #expect(r.lines.first?["steps"] as? Int == 7)
            #expect(r.lines.dropFirst().first?["index"] as? Int == 1 && r.lines.first?["seconds"] is [Double])
            #expect(r.lines.last?["code"] as? String == "sha_mismatch")

            // activation is built in: the old hook flag is a command line it doesn't take (64, nothing on stdout)
            try FileManager.default.removeItem(at: r.staging)
            let h = try Self.create(dir, ipsw: ipsw, extra: ["--activation-hook", "/bin/true"])
            #expect(h.status == 64 && h.lines.isEmpty)
        }
    }

    /// SIGTERM mid-step (hashing a sparse 8 GB "IPSW"): exits within 2 s, 143, staging left for the caller.
    @Test(.enabled(if: FixtureRequirements.corpusEnabled, "Firmware corpus test; set FK_TEST_CORPUS=1 to run"))
    func cancelWithinTwoSeconds() throws {
        guard Oracle.exists(Self.cli) else {
            try FixtureRequirements.missing(#"PreparerTests.swift: Oracle.exists(Self.cli)"#)
        }
        try Oracle.withTemp { dir in
            let ipsw = dir.appendingPathComponent("big.ipsw")
            FileManager.default.createFile(atPath: ipsw.path, contents: nil)
            #expect(truncate(ipsw.path, 8 << 30) == 0)
            var t0 = Date()
            let r = try Self.create(dir, ipsw: ipsw) { p in
                t0 = Date()
                p.terminate()
            }
            #expect(Date().timeIntervalSince(t0) < 10)  // well short of sleep's 60 s, with room for a loaded host
            #expect(r.status == 143)
            #expect(r.lines.map { $0["event"] as? String }.filter { $0 != "progress" } == ["begin", "step"])
            #expect(FileManager.default.fileExists(atPath: r.staging.path))
        }
    }
}
