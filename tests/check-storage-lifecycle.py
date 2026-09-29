#!/usr/bin/env python3
"""Exercise production storage boundaries without QEMU or real user state."""
from pathlib import Path
import os
import subprocess
import sys
import tempfile

root = Path(__file__).resolve().parents[1]


def section(file, start, end):
    text = (root / "LightTouchMac" / file).read_text()
    return text[text.index(start):text.index(end, text.index(start))]


metadata = section("AppMetadataCache.swift", "    nonisolated static func prepareDirectory", "    #if DEBUG")
metadata_save = section("AppMetadataCache.swift", "    private func save()", "    // MARK: - .ipa reading")
diagnostics = section("MainWindowController.swift", "nonisolated enum DiagnosticsExport", "// MARK: - Toolbar item validation")

source = r'''
import Foundation
import Darwin
nonisolated func logEvent(_ format: String, _ arguments: CVarArg...) {}
struct Metadata {
    var entries: [String: String] = [:]
    let dir: URL
    var indexURL: URL { dir.appendingPathComponent("index.json") }
''' + metadata + metadata_save.replace("private func", "func") + "}\n" + diagnostics + r'''

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
        let cache = Metadata.prepareDirectory(state: state, caches: caches, isolated: true)
        precondition(cache == state.appendingPathComponent("Caches/AppMetadata", isDirectory: true) && exists(cache))
        precondition(try children(caches).isEmpty, "isolated run wrote global cache")
        let normal = root.appendingPathComponent("normal state", isDirectory: true)
        let normalCache = Metadata.prepareDirectory(state: normal, caches: caches, isolated: false)
        precondition(normalCache == caches.appendingPathComponent("gold.samhenri.LightTouchMac/AppMetadata", isDirectory: true) && exists(normalCache))
        // A running cache must recover after its directory is purged. Exercise
        // production save() as well as the icon writer, without reinitializing.
        var running = Metadata(dir: normalCache)
        running.entries["com.example.app"] = "original"
        running.save()
        try fm.removeItem(at: normalCache)
        running.entries["com.example.new"] = "after purge"
        running.save()
        let recovered = try JSONDecoder().decode([String: String].self,
            from: Data(contentsOf: running.indexURL))
        precondition(recovered == running.entries)
        try fm.removeItem(at: normalCache)
        let icon = normalCache.appendingPathComponent("com.example.new.png")
        try Metadata.writeCacheData(Data("rebuilt icon".utf8), to: icon)
        precondition(try text(icon) == "rebuilt icon")
        try Metadata.writeCacheData(Data("replacement icon".utf8), to: icon)
        precondition(try text(icon) == "replacement icon")
        precondition(try children(normalCache).map(\.lastPathComponent) == ["com.example.new.png"])
        // The built-in device's blob (scripts/pack-base.py's format): unpacked as a stream, modes
        // kept; a truncated stream, extra bytes and an escaping name are refused.
        let blob = URL(fileURLWithPath: CommandLine.arguments[2])
        let image = root.appendingPathComponent("device/image")
        var fractions: [Double] = []
        try BundledBase.unpack(blob, into: image) { fractions.append($0) }
        precondition(try text(image.appendingPathComponent("nand/cs0/1.page")) == "page one" && fractions.last == 1 && fractions == fractions.sorted())
        precondition(try text(image.appendingPathComponent("nor.bin")) == String(repeating: "n", count: 70000) && exists(image.appendingPathComponent("empty")))
        precondition(try fm.attributesOfItem(atPath: image.appendingPathComponent("nor.bin").path)[.posixPermissions] as! NSNumber == 0o444)
        precondition(try fm.attributesOfItem(atPath: image.appendingPathComponent("identity.json").path)[.posixPermissions] as! NSNumber == 0o600)
        let bytes = try Data(contentsOf: blob)
        let truncated = root.appendingPathComponent("truncated.itbase")
        try bytes.prefix(bytes.count - 40).write(to: truncated)
        do { try BundledBase.unpack(truncated, into: root.appendingPathComponent("device/truncated")); preconditionFailure("truncated blob accepted") } catch {}
        let escaping = root.appendingPathComponent("escaping.itbase")
        let index = Data(#"{"entries":[{"name":"../outside","size":0}]}"#.utf8)
        try (Data("ITPACK01".utf8) + Data([UInt8(index.count), 0, 0, 0]) + index + Data([0x78, 0x9c, 3, 0, 0, 0, 0, 1])).write(to: escaping)
        do { try BundledBase.unpack(escaping, into: root.appendingPathComponent("device/escaping")); preconditionFailure("escaping name accepted") } catch {}
        precondition(!exists(root.appendingPathComponent("outside")) && !exists(root.appendingPathComponent("device/escaping")))

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
        print("PASS: cache isolation/purge recovery, the built-in base unpacked and refused when torn, concurrent diagnostics, cancellation, and atomic export")
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
    base = work / "base"
    (base / "nand/cs0").mkdir(parents=True)
    (base / "nand/cs0/1.page").write_text("page one")
    (base / "nor.bin").write_text("n" * 70000)
    (base / "nor.bin").chmod(0o444)
    (base / "identity.json").write_text("{}")
    (base / "identity.json").chmod(0o600)
    (base / "empty").write_text("")
    blob = work / "base.itbase"
    subprocess.run([sys.executable, str(root / "scripts/pack-base.py"), "pack", str(base), str(blob)], check=True, stdout=subprocess.DEVNULL)
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
                    str(root / "LightTouchMac/BundledBase.swift"), str(check), "-o", str(executable)], check=True)
    subprocess.run([str(executable), str(work), str(blob)], check=True, timeout=45,
                   env=dict(os.environ, LTM_TEST_ARCHIVER=str(archiver)))
    for name, info in [("success.zip", "real ditto archive"), ("concurrent.zip", "concurrent real archive")]:
        archive = work / "exports" / name
        subprocess.run(["/usr/bin/unzip", "-tq", str(archive)], check=True)
        actual = subprocess.check_output(["/usr/bin/unzip", "-p", str(archive), "LightTouchMac-diagnostics/info.txt"], text=True)
        assert actual == info
