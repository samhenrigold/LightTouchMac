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
            (.step(index: 3, name: "Building \"the\"/system\nvolume"), ["event": "step", "index": 3, "name": "Building \"the\"/system\nvolume"]),
            (.progress(0.42), ["event": "progress", "fraction": 0.42]),
            (.warning("w"), ["event": "warning", "message": "w"]),
            (.done(lock: "device.lock.json"), ["event": "done", "lock": "device.lock.json"]),
            (.error(code: "hook_failed", message: "m"), ["event": "error", "code": "hook_failed", "message": "m"]),
        ]
        for (e, want) in cases {
            #expect(!e.json.contains("\n"))
            let got = try #require(Self.object(e.json))
            #expect(Set(got.keys) == Set(want.keys))
            for (k, v) in want { #expect((got[k] as? AnyHashable) == v, "\(k)") }
        }
    }

    @Test func errorCodes() {
        func code(_ e: Error) -> String? { if case .error(let c, _) = Preparer.errorEvent(e) { return c }; return nil }
        #expect(code(FirmwareError(.hookFailed, "x")) == "hook_failed")
        #expect(code(HookFailure("x")) == "hook_failed")
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
            #expect(r.lines.map { $0["event"] as? String } == ["begin", "step", "error"])
            #expect(r.lines.first?["steps"] as? Int == 7)
            #expect(r.lines[1]["index"] as? Int == 1)
            #expect(r.lines.last?["code"] as? String == "sha_mismatch")

            let hook = dir.appendingPathComponent("hook.py")   // not executable: refused before anything runs
            try Data("print()".utf8).write(to: hook)
            try FileManager.default.removeItem(at: r.staging)
            let h = try Self.create(dir, ipsw: ipsw, extra: ["--activation-hook", hook.path])
            #expect(h.status == 1)
            #expect(h.lines.map { $0["event"] as? String } == ["error"])
            #expect(h.lines.last?["code"] as? String == "hook_failed")
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
            #expect(r.lines.map { $0["event"] as? String } == ["begin", "step"])
            #expect(FileManager.default.fileExists(atPath: r.staging.path))
        }
    }
}
