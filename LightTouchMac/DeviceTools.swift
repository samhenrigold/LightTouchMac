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
    
    // Resolve Homebrew tools without assuming the app's PATH.
    private static let searchPaths = ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin"]
    
    private static func toolPath(_ name: String) -> String? {
        for dir in searchPaths {
            let p = "\(dir)/\(name)"
            if FileManager.default.isExecutableFile(atPath: p) { return p }
        }
        return nil
    }
    
    private var toolEnvironment: Environment {
        .inherit.updating([
            // SOCK is what apps/install-app.sh keys on; USBMUXD_SOCKET_ADDRESS is
            // what it-ssh-terminal.sh and the raw libimobiledevice tools use.
            // Passing both means neither needs the session.env file to exist.
            "SOCK": clientSocket,
            "USBMUXD_SOCKET_ADDRESS": clientSocket,
            "IPOD_FILES": filesRoot,
            "PATH": (Self.searchPaths + ["/bin", "/usr/sbin", "/sbin"]).joined(separator: ":"),
        ])
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
    
    @discardableResult
    func install(_ ipa: URL) async throws -> String {
        let script = "\(filesRoot)/apps/install-app.sh"
        guard FileManager.default.isExecutableFile(atPath: script) else {
            throw DeviceToolsError.toolMissing(script)
        }
        
        // The guest's lockdown/AFC service is briefly unavailable right after an
        // uninstall ("Could not start com.apple.afc: Invalid service"), so a
        // reinstall can fail transiently. Retry a few times before giving up;
        // failures that aren't service-transient (a bad .ipa) fail immediately.
        var lastOutput = "install failed"
        for attempt in 0..<3 {
            let result = try await run(
                .path(FilePath("/bin/bash")),
                arguments: [script, ipa.path],
                environment: toolEnvironment,
                output: .string(limit: 1 << 20), error: .string(limit: 1 << 20)
            )
            let out = result.standardOutput + result.standardError
            if result.terminationStatus.isSuccess {
                return out
            }
            lastOutput = out.isEmpty ? "install failed" : out
            guard attempt < 2, Self.isTransientServiceError(out) else { break }
            try? await Task.sleep(for: .seconds(2))
        }
        throw DeviceToolsError.failed(lastOutput)
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
        let script = "\(filesRoot)/../qemu-ios/contrib/it-ssh-terminal.sh"
        let resolved = FileManager.default.isExecutableFile(atPath: script)
        ? script : "\(NSHomeDirectory())/Developer/qemu-ios/contrib/it-ssh-terminal.sh"
        _ = try await run(
            .path(FilePath("/bin/bash")),
            arguments: [resolved],
            environment: toolEnvironment,
            output: .discarded, error: .discarded
        )
    }
}
