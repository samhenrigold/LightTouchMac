// Created by Sam on 2026-08-05.
//
// Host-side app management over USB, reusing the existing qemu-ios scripts
// (which carry fixes the raw ideviceinstaller path lacks: the 0644 exec-bit
// repair, the GL-engine swap, cryptid/OpenGLES warnings). Listing and
// uninstalling go straight to ideviceinstaller; installs and the SSH terminal
// go through the scripts. All external processes run via swift-subprocess.

import Foundation
import Subprocess
import System

struct InstalledApp: Identifiable, Sendable {
    let id: String        // CFBundleIdentifier
    let name: String
    let version: String
}

enum DeviceToolsError: LocalizedError {
    case toolMissing(String)
    case failed(String)
    var errorDescription: String? {
        switch self {
        case .toolMissing(let t): return "\(t) not found. Install libimobiledevice (brew install libimobiledevice)."
        case .failed(let msg): return msg
        }
    }
}

/// Talks to one running device, identified by its usbmuxd client socket.
struct DeviceTools: Sendable {
    let clientSocket: String
    let filesRoot: String
    
    // The app's own tools first, then Homebrew's — without assuming any PATH.
    private static let searchPaths = Bundled.binarySearchPaths
    
    private static func toolPath(_ name: String) -> String? {
        for dir in searchPaths {
            let p = "\(dir)/\(name)"
            if FileManager.default.isExecutableFile(atPath: p) { return p }
        }
        return nil
    }
    
    private var toolEnvironment: Environment {
        var environment: [Environment.Key: String?] = [
            // SOCK is what apps/install-app.sh keys on; USBMUXD_SOCKET_ADDRESS is
            // what it-ssh-terminal.sh and the raw libimobiledevice tools use.
            // Passing both means neither needs the session.env file to exist.
            "SOCK": clientSocket,
            "USBMUXD_SOCKET_ADDRESS": clientSocket,
            "IPOD_FILES": filesRoot,
            "PATH": (Self.searchPaths + ["/bin", "/usr/sbin", "/sbin"]).joined(separator: ":"),
        ]
        // The scripts look these up themselves and fall back to a source
        // checkout when they are unset. Pointing them at the bundle is what
        // makes an install work on a Mac that has neither the checkout nor
        // Homebrew: install-ipa.sh carries the exec-bit repair and the GL
        // engine, ipod-helper stands in for the python3 a clean Mac lacks, and
        // the guest tools are the binaries it copies onto the device.
        for (key, name) in [(Environment.Key("INSTALL_IPA"), "install-ipa.sh"),
                            (Environment.Key("IT_HELPER"), "ipod-helper")] {
            if let path = Bundled.tool(name) { environment[key] = path }
        }
        if let tools = Bundled.toolsDirectory { environment["IT_GUEST_TOOLS"] = tools }
        return .inherit.updating(environment)
    }
    
    // MARK: - List
    
    func installedApps() async throws -> [InstalledApp] {
        guard let tool = Self.toolPath("ideviceinstaller") else {
            throw DeviceToolsError.toolMissing("ideviceinstaller")
        }
        let result = try await run(
            .path(FilePath(tool)),
            arguments: ["list", "--user"],
            environment: toolEnvironment,
            output: .string(limit: 1 << 20), error: .string(limit: 1 << 16)
        )
        // A failed list used to be indistinguishable from an empty one: the
        // exit status was never looked at, so "Could not start
        // com.apple.installation_proxy" parsed to zero apps and the sidebar
        // said "No third-party apps installed" about a home screen full of
        // them, with no way to tell it was wrong.
        guard result.terminationStatus.isSuccess else {
            let msg = result.standardError.isEmpty ? "the device did not answer" : result.standardError
            throw DeviceToolsError.failed(msg)
        }
        return Self.parseList(result.standardOutput)
    }
    
    /// ideviceinstaller prints `bundleID, "version", "Display Name"`, one per
    /// line, after a header row. Parse defensively — fields can hold commas.
    static func parseList(_ text: String) -> [InstalledApp] {
        var apps: [InstalledApp] = []
        for line in text.split(separator: "\n") {
            let s = String(line)
            guard let firstComma = s.firstIndex(of: ",") else { continue }
            let bundleID = s[..<firstComma].trimmingCharacters(in: .whitespaces)
            if bundleID.isEmpty || bundleID == "CFBundleIdentifier" { continue }
            let quoted = s.split(separator: "\"").enumerated()
                .filter { $0.offset % 2 == 1 }.map { String($0.element) }
            let version = quoted.first ?? ""
            let name = quoted.count >= 2 ? quoted[1] : bundleID
            apps.append(InstalledApp(id: bundleID, name: name, version: version))
        }
        return apps.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }
    
    // MARK: - Install (through apps/install-app.sh)
    
    /// `progress` is called on every line the script prints, already trimmed to
    /// something worth showing in a table row — an install is minutes of
    /// silence otherwise, on hardware slow enough that silence reads as a hang.
    @discardableResult
    func install(_ ipa: URL, progress: @escaping @Sendable (String) -> Void = { _ in }) async throws -> String {
        let script = "\(filesRoot)/apps/install-app.sh"
        guard FileManager.default.isExecutableFile(atPath: script) else {
            throw DeviceToolsError.toolMissing(script)
        }

        // The guest's lockdown/AFC service is briefly unavailable right after an
        // uninstall ("Could not start com.apple.afc: Invalid service"), so a
        // reinstall can fail transiently. install-ipa.sh retries the one failing
        // command itself; this outer loop is the net for the paths that don't
        // reach it, and re-runs the whole script.
        var lastOutput = "install failed"
        for attempt in 0..<3 {
            let result = try await run(
                .path(FilePath("/bin/bash")),
                arguments: [script, ipa.path],
                environment: toolEnvironment,
                input: .none,
                output: .sequence, error: .string(limit: 1 << 20)
            ) { execution in
                var collected = ""
                var partial = ""
                for try await buffer in execution.standardOutput {
                    let chunk = buffer.withUnsafeBytes { String(decoding: $0, as: UTF8.self) }
                    collected += chunk
                    partial += chunk
                    while let newline = partial.firstIndex(of: "\n") {
                        let line = String(partial[..<newline])
                        partial = String(partial[partial.index(after: newline)...])
                        if let status = Self.status(of: line) { progress(status) }
                    }
                }
                return collected
            }
            let out = result.closureResult + result.standardError
            if result.terminationStatus.isSuccess {
                return out
            }
            lastOutput = out.isEmpty ? "install failed" : out
            guard attempt < 2, Self.isTransientServiceError(out) else { break }
            try await Task.sleep(for: .seconds(2))   // throws if cancelled, which ends the retry
        }
        throw DeviceToolsError.failed(lastOutput)
    }

    /// One line of script output as a row subtitle, or nil for lines that say
    /// nothing to someone watching a progress row. ideviceinstaller's own
    /// status lines look like `Install: CreatingStagingDirectory (5%)`.
    static func status(of line: String) -> String? {
        let text = line.trimmingCharacters(in: .whitespaces)
        if let range = text.range(of: #"^\w+: "#, options: .regularExpression) {
            let rest = String(text[range.upperBound...])
            // "Complete" arrives before the script's own trailing output; the
            // row is about to be replaced by the real one either way.
            return rest.isEmpty ? nil : rest
        }
        if text.hasPrefix("--- ") { return String(text.dropFirst(4)) }
        return nil
    }
    
    private static func isTransientServiceError(_ output: String) -> Bool {
        let markers = ["com.apple.afc", "Invalid service", "Could not start",
                       "Could not connect", "lockdown"]
        return markers.contains { output.localizedCaseInsensitiveContains($0) }
    }
    
    // MARK: - Uninstall
    
    func uninstall(_ bundleID: String) async throws {
        guard let tool = Self.toolPath("ideviceinstaller") else {
            throw DeviceToolsError.toolMissing("ideviceinstaller")
        }
        let result = try await run(
            .path(FilePath(tool)),
            arguments: ["uninstall", bundleID],
            environment: toolEnvironment,
            output: .string(limit: 1 << 16), error: .string(limit: 1 << 16)
        )
        guard result.terminationStatus.isSuccess else {
            let msg = result.standardError.isEmpty ? "uninstall failed" : result.standardError
            throw DeviceToolsError.failed(msg)
        }
    }
    
    // MARK: - SSH terminal (opens Terminal.app itself)
    
    func openTerminal() async throws {
        guard let resolved = Bundled.resolve("it-ssh-terminal.sh", fallbacks: [
            "\(filesRoot)/../qemu-ios/contrib/it-ssh-terminal.sh",
            "\(NSHomeDirectory())/Developer/qemu-ios/contrib/it-ssh-terminal.sh",
        ]) else {
            throw DeviceToolsError.toolMissing("it-ssh-terminal.sh")
        }
        _ = try await run(
            .path(FilePath("/bin/bash")),
            arguments: [resolved],
            environment: toolEnvironment,
            output: .discarded, error: .discarded
        )
    }
}
