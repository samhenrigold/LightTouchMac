#!/usr/bin/env python3
"""Exercise production storage boundaries without QEMU or real user state."""
from pathlib import Path
import os
import subprocess
import tempfile

root = Path(__file__).resolve().parents[2]



source = r'''
import Foundation
import Darwin
nonisolated func logEvent(_ format: String, _ arguments: CVarArg...) {}

@main struct Check {
    static func main() async throws {
        let fm = FileManager.default
        let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        func text(_ url: URL) throws -> String { try String(contentsOf: url, encoding: .utf8) }
        func put(_ value: String, _ url: URL) throws { try value.write(to: url, atomically: true, encoding: .utf8) }
        func exists(_ url: URL) -> Bool { fm.fileExists(atPath: url.path) }
        func children(_ url: URL) throws -> [URL] { try fm.contentsOfDirectory(at: url, includingPropertiesForKeys: nil) }
        let state = root.appendingPathComponent("state", isDirectory: true)
        let caches = root.appendingPathComponent("system caches", isDirectory: true)
        try fm.createDirectory(at: caches, withIntermediateDirectories: true)
        let cache = StorageLocations.appMetadataDirectory(state: state, caches: caches, isolated: true)
        precondition(cache == state.appendingPathComponent("Caches/AppMetadata", isDirectory: true) && exists(cache))
        precondition(try children(caches).isEmpty, "isolated run wrote global cache")
        let normal = root.appendingPathComponent("normal state", isDirectory: true)
        let normalCache = StorageLocations.appMetadataDirectory(state: normal, caches: caches, isolated: false)
        precondition(normalCache == caches.appendingPathComponent("gold.samhenri.LightTouchMac/AppMetadata", isDirectory: true) && exists(normalCache))
        // A running cache must recover after its directory is purged: the index
        // and the icon writer (AppMetadataCache.save and learn) both publish
        // through writeCacheData, without reinitializing.
        let metadataIndex = normalCache.appendingPathComponent("index.json")
        var entries = ["com.example.app": "original"]
        try StorageLocations.writeCacheData(JSONEncoder().encode(entries), to: metadataIndex)
        try fm.removeItem(at: normalCache)
        entries["com.example.new"] = "after purge"
        try StorageLocations.writeCacheData(JSONEncoder().encode(entries), to: metadataIndex)
        let recovered = try JSONDecoder().decode([String: String].self, from: Data(contentsOf: metadataIndex))
        precondition(recovered == entries)
        try fm.removeItem(at: normalCache)
        let icon = normalCache.appendingPathComponent("com.example.new.png")
        try StorageLocations.writeCacheData(Data("rebuilt icon".utf8), to: icon)
        precondition(try text(icon) == "rebuilt icon")
        try StorageLocations.writeCacheData(Data("replacement icon".utf8), to: icon)
        precondition(try text(icon) == "replacement icon")
        precondition(try children(normalCache).map(\.lastPathComponent) == ["com.example.new.png"])
        let scratch = root.appendingPathComponent("diagnostic temp", isDirectory: true)
        let exports = root.appendingPathComponent("exports", isDirectory: true)
        try fm.createDirectory(at: scratch, withIntermediateDirectories: true)
        try fm.createDirectory(at: exports, withIntermediateDirectories: true)
        let log = root.appendingPathComponent("app.log")
        try put("sample events", log)
        let success = exports.appendingPathComponent("success.zip")
        try await DiagnosticsExport.write(to: success, logs: [log], info: "real ditto archive", temporaryRoot: scratch)
        precondition(exists(success) && (try children(scratch)).isEmpty)
        let archiver = URL(fileURLWithPath: ProcessInfo.processInfo.environment["LTM_TEST_ARCHIVER"]!)
        let preserved = exports.appendingPathComponent("preserved.zip")
        try put("existing user archive", preserved)
        for (info, executable) in [("fail", archiver), ("empty", archiver), ("missing", root.appendingPathComponent("no-archiver"))] {
            do {
                try await DiagnosticsExport.write(to: preserved, logs: [log], info: info,
                    temporaryRoot: scratch, archiver: executable)
                preconditionFailure("failed export was reported as successful")
            } catch {}
            precondition(try text(preserved) == "existing user archive")
            precondition(try children(scratch).isEmpty)
            precondition(try children(exports).allSatisfy { !$0.lastPathComponent.hasPrefix(".LightTouch-") })
        }
        // Keep one archiver active while another export completes; neither may
        // delete the other's scratch. A ready marker makes the overlap explicit.
        let cancelled = Task {
            try await DiagnosticsExport.write(to: preserved, logs: [log], info: "cancel",
                temporaryRoot: scratch, archiver: archiver)
        }
        var ready: URL?
        let deadline = Date().addingTimeInterval(10)
        while ready == nil, Date() < deadline {
            ready = try children(scratch).map { $0.appendingPathComponent("LightTouchMac-diagnostics/ready") }
                .first { exists($0) }
            if ready == nil { try await Task.sleep(for: .milliseconds(10)) }
        }
        guard let ready else { cancelled.cancel(); fatalError("archiver did not start") }
        let pid = Int32(try text(ready).trimmingCharacters(in: .whitespacesAndNewlines))!
        let other = exports.appendingPathComponent("concurrent.zip")
        try await DiagnosticsExport.write(to: other, logs: [log], info: "concurrent real archive", temporaryRoot: scratch)
        precondition(exists(ready) && (try children(scratch)).count == 1)
        precondition(try text(ready.deletingLastPathComponent().appendingPathComponent("info.txt")) == "cancel")
        cancelled.cancel()
        do { try await cancelled.value; preconditionFailure("cancelled export succeeded") }
        catch is CancellationError {} catch { throw error }
        precondition(kill(pid, 0) != 0, "cancelled child still running")
        precondition(try text(preserved) == "existing user archive")
        precondition(try children(scratch).isEmpty)
        precondition(try children(exports).allSatisfy { !$0.lastPathComponent.hasPrefix(".LightTouch-") })
        precondition(try text(log) == "sample events")
        print("PASS: cache isolation/purge recovery, concurrent diagnostics, cancellation, and atomic export")
    }
}
'''
# Swift's precondition autoclosure cannot throw; evaluate these checks first.
source = source.replace("precondition(try ", "check(try ")
source = source.replace('precondition(exists(success) && (try children(scratch)).isEmpty)', 'check(try exists(success) && children(scratch).isEmpty)')
source = source.replace('precondition(exists(ready) && (try children(scratch)).count == 1)', 'check(try exists(ready) && children(scratch).count == 1)')
source = source.replace('func text(_ url:', 'func check(_ condition: Bool, _ message: String = "") { precondition(condition, message) }\n        func text(_ url:')

with tempfile.TemporaryDirectory(prefix="ltm-storage-check-") as directory:
    work = Path(directory)
    archiver = work / "archive-helper"
    archiver.write_text('''#!/bin/sh
case "$(cat "$5/info.txt")" in
    fail) printf incomplete > "$6"; exit 9 ;;
    empty) : > "$6"; exit 0 ;;
    cancel) printf '%s\\n' "$$" > "$5/ready"; exec /bin/sleep 60 ;;
esac
exit 1
''')
    archiver.chmod(0o700)
    check = work / "check.swift"
    check.write_text(source)
    executable = work / "check"
    subprocess.run(["xcrun", "swiftc", "-swift-version", "6", "-default-isolation", "MainActor",
                    "-parse-as-library", "-module-cache-path", str(work / "modules"),
                    str(root / "LightTouchMac/Library/StorageLocations.swift"),
                    str(root / "LightTouchMac/Features/DiagnosticsExport.swift"), str(check), "-o", str(executable)], check=True)
    subprocess.run([str(executable), str(work)], check=True, timeout=45,
                   env=dict(os.environ, LTM_TEST_ARCHIVER=str(archiver)))
    for name, info in [("success.zip", "real ditto archive"), ("concurrent.zip", "concurrent real archive")]:
        archive = work / "exports" / name
        subprocess.run(["/usr/bin/unzip", "-tq", str(archive)], check=True)
        actual = subprocess.check_output(["/usr/bin/unzip", "-p", str(archive), "LightTouchMac-diagnostics/info.txt"], text=True)
        assert actual == info
