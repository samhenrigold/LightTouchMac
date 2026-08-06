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

/// Talks to one running device, identified by its usbmuxd client socket. The
/// facade the UI calls; list/install/uninstall run in-process through
/// DeviceServices, and only the SSH terminal (and the fallback install for a
/// non-baked NAND) still shell out.
struct DeviceTools: Sendable {
    let clientSocket: String
    let filesRoot: String
    /// True when the guest image already carries the GL engine shim and
    /// sblaunch (nand-ultimate). When false, a GL app needs the ssh engine
    /// copy, which only the install script does — so we fall back to it.
    var bakedGuestTools: Bool = true

    private var services: DeviceServices { DeviceServices(clientSocket: clientSocket) }

    // The app's own tools first, then Homebrew's — without assuming any PATH.
    private static let searchPaths = Bundled.binarySearchPaths

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
    
    // MARK: - List (in-process)

    func installedApps() async throws -> [InstalledApp] {
        try await services.installedApps()
    }

    // MARK: - Install

    /// Install a decrypted .ipa. Baked images go the fast in-process route
    /// (AFC stage + instproxy, no shell); a non-baked image falls back to the
    /// install script, which copies the GL engine over ssh. `progress` gets
    /// short, human phase strings for the sidebar row. The return string is
    /// non-empty only to carry the "SDK too new" marker the caller warns on.
    @discardableResult
    func install(_ ipa: URL, progress: @escaping @Sendable (String) -> Void = { _ in }) async throws -> String {
        // A GL app on a non-baked image needs the ssh engine copy that only the
        // script performs — installing it in-process would wedge the device.
        // MinimumOSVersion, NOT DTSDKName. The SDK an app was BUILT with says
        // nothing about whether it runs: Temple Run 1.0 is DTSDKName
        // iphoneos4.2 with MinimumOSVersion 3.0 and runs fine on 3.1.3. Gating
        // on the build SDK cried wolf on most of the library, which trains
        // people to click through the one warning that is real. iPhone OS
        // enforces MinimumOSVersion, so that is what we check.
        let minOS = await AppMetadataCache.shared.minimumOS(from: ipa)
        let sdkMarker = Self.sdkTooNew(minOS) ? "\nnewer than the device's SDK" : ""

        if bakedGuestTools {
            // Placeholder first, before anything slow: the exec-bit repair
            // repacks the whole archive and the free-space check is a round
            // trip, and until now this path put nothing on the home screen for
            // any of it.
            //
            // Keyed on the bundle id, falling back to the filename. Info.plist
            // is already unzipped just above for minimumOS, so this is free —
            // and keying on the filename alone meant the same app dropped from
            // two differently named files raised two placeholders. The filter
            // is also what makes the value safe inside the single quotes it is
            // interpolated into below.
            let key = await AppMetadataCache.bundleID(of: ipa)
                ?? ipa.deletingPathExtension().lastPathComponent
            let placeholder = "qemu-install-" + key
                .filter { $0.isLetter || $0.isNumber || $0 == "." || $0 == "-" || $0 == "_" }
            placeholderIcon("add", placeholder)
            defer { placeholderIcon("cancel", placeholder) }

            // An .ipa whose binary is archived 0644 installs fine and then never
            // launches: posix_spawn fails EACCES, SpringBoard logs only "exited
            // abnormally", the icon bounces once and NO crash report is written
            // — it reads as an emulator bug. install-ipa.sh repacks it 0755;
            // the in-process path skipped that, so every 2009-era .ipa of this
            // shape (Cube Runner among them) regressed on the default image.
            let ipa = await Self.execBitRepaired(ipa) ?? ipa
            let bytes = (try? FileManager.default.attributesOfItem(atPath: ipa.path)[.size] as? Int) ?? 0
            let free = try await services.freeSpaceBytes()
            let needed = Int64(bytes) * 2 + (16 << 20)
            guard free >= needed else { throw DeviceError.diskFull(free: free, needed: needed) }

            progress("Sending to device…")
            let staged = try await services.stage(ipa) { frac in
                progress("Sending to device… \(Int(frac * 100))%")
            }
            defer { Task { await services.removeStaged(staged) } }

            try await withTransientRetry(attempts: 3) {
                try await services.install(stagedPath: staged) { pct, _ in
                    progress(pct >= 0 ? "Installing… \(pct)%" : "Installing…")
                }
            }
            return "installed" + sdkMarker
        }
        return try await installViaScript(ipa, progress: progress) + sdkMarker
    }

    /// If the .ipa stores its main binary without the exec bit, a copy repacked
    /// 0755 (via the bundled ipod-helper, the same tool install-ipa.sh uses);
    /// nil if no repair is needed or anything is unreadable — callers fall back
    /// to the original, which is exactly today's behaviour.
    private static func execBitRepaired(_ ipa: URL) async -> URL? {
        guard let member = await AppMetadataCache.executableMember(of: ipa),
              let helper = Bundled.tool("ipod-helper") else { return nil }
        // `unzip -Z` long listing: the mode string is the first field and the
        // member the last, e.g. "-rw-r--r--  2.0 unx  … Payload/X.app/X".
        guard let listing = try? await run(
            .path(FilePath("/usr/bin/unzip")), arguments: ["-Z", ipa.path],
            output: .string(limit: 1 << 22), error: .discarded).standardOutput,
              let line = listing.split(separator: "\n").first(where: {
                  $0.hasSuffix(" " + member)
              }),
              let mode = line.split(separator: " ").first,
              mode.count >= 4, !mode.contains("x")
        else { return nil }

        let out = FileManager.default.temporaryDirectory
            .appendingPathComponent("ltm-fixed-\(UUID().uuidString)")
            .appendingPathExtension("ipa")
        guard let rc = try? await run(
            .path(FilePath(helper)),
            arguments: ["ipa-chmod", ipa.path, out.path, member],
            output: .discarded, error: .discarded).terminationStatus,
              rc.isSuccess,
              FileManager.default.fileExists(atPath: out.path) else { return nil }
        NSLog("install: \(member) archived non-executable — repacked 0755")
        return out
    }

    /// Whether a declared MinimumOSVersion ("4.0", "6.1") is newer than the
    /// device's OS — the version iPhone OS itself refuses to launch past.
    /// Tolerates a leading "iphoneos" so an accidental DTSDKName still parses.
    static func sdkTooNew(_ sdkName: String?, deviceOS: String = "3.1.3") -> Bool {
        guard let sdkName else { return false }
        let digits = sdkName.drop { !$0.isNumber }
        let parts = digits.split(separator: ".").compactMap { Int($0) }
        let device = deviceOS.split(separator: ".").compactMap { Int($0) }
        for (a, b) in zip(parts, device) where a != b { return a > b }
        return parts.count > device.count && parts[device.count] > 0
    }

    /// Retry only genuinely transient device errors (a service refusing
    /// connections right after boot or an uninstall); a rejected package or a
    /// full disk fails immediately.
    private func withTransientRetry(attempts: Int, _ body: () async throws -> Void) async throws {
        var lastError: Error = DeviceError.failed("no attempt made")
        for i in 0..<attempts {
            do { return try await body() }
            catch let error as DeviceError where error.isTransient {
                lastError = error
                try await Task.sleep(for: .seconds(Double(min(i + 1, 5)) * 2))
            }
        }
        throw lastError
    }

    // MARK: - Install fallback (non-baked image, through apps/install-app.sh)

    private func installViaScript(_ ipa: URL, progress: @escaping @Sendable (String) -> Void) async throws -> String {
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

    /// One line of installer output as a row subtitle, translated for a human.
    /// The script narrates for its log ("device is up: iOS 3.1.3",
    /// "TakingInstallLock (0%)") and none of that reads as status under an
    /// app's name in a sidebar. Only lines that map to a phase someone would
    /// recognise become a subtitle; everything else returns nil so the last
    /// real status stays put instead of being replaced by noise.
    static func status(of line: String) -> String? {
        let text = line.trimmingCharacters(in: .whitespaces)
        // ideviceinstaller's per-phase progress: `Install: StagingPackage (10%)`.
        // The phase names are installd internals; the percentage is the story.
        if let match = text.range(of: #"^Install: \w+ \((\d+)%\)"#, options: .regularExpression) {
            let percent = text[match].drop { !$0.isNumber }.prefix { $0.isNumber }
            return "Installing… \(percent)%"
        }
        let lower = text.lowercased()
        if lower.contains("waiting for the device") ||
           lower.contains("services are still starting") { return "Waiting for the device…" }
        if lower.contains("retrying in") { return "Device is busy — retrying…" }
        if lower.contains("gl engine") { return "Setting up graphics support…" }
        if lower.hasPrefix("--- installing") || lower.hasPrefix("copying ") {
            return "Sending to device…"
        }
        return nil
    }
    
    private static func isTransientServiceError(_ output: String) -> Bool {
        let markers = ["com.apple.afc", "Invalid service", "Could not start",
                       "Could not connect", "lockdown"]
        return markers.contains { output.localizedCaseInsensitiveContains($0) }
    }
    
    // MARK: - Uninstall (in-process)

    func uninstall(_ bundleID: String) async throws {
        try await services.uninstall(bundleID)
    }

    // MARK: - Free space (in-process)

    func freeSpaceBytes() async throws -> Int64 { try await services.freeSpaceBytes() }

    /// Respring: kill SpringBoard and let launchd bring it straight back.
    ///
    /// This is the cheap fix for the "a freshly sideloaded app crashes until I
    /// restart the iPod" problem — SpringBoard caches what it knows about
    /// installed apps, and a respring rebuilds that in a few seconds where a
    /// full boot costs ~40. ssh is the only route (there is no service for it),
    /// which is why this is a deliberate, user-invoked action rather than
    /// something the install path does behind your back.
    ///
    /// Non-interactive password auth via SSH_ASKPASS_REQUIRE=force, the
    /// supported way since OpenSSH 8.4; macOS ships 9.x.
    func restartSpringBoard() async throws {
        try await guestRun("killall SpringBoard")
    }

    /// Raise or drop the App Store-style "downloading" placeholder on the
    /// guest's home screen. `sbdlicon` is baked into nand-ultimate at this path;
    /// see qemu-ios/contrib/it-instprogress for what SpringBoard does with it.
    ///
    /// Deliberately fire-and-forget. This is the only ssh left on the in-process
    /// install path and it is cosmetic, so a slow or unreachable guest must cost
    /// the install nothing and can never fail it. An unstructured Task does not
    /// inherit cancellation, which is what lets the `cancel` in a defer still
    /// run when the install itself was cancelled; and if even that is lost, the
    /// icon is placed with saveIconState:NO and dies with the running
    /// SpringBoard rather than being written to disk.
    private func placeholderIcon(_ action: String, _ id: String) {
        Task { try? await guestRun("/usr/local/bin/sbdlicon \(action) '\(id)'") }
    }

    /// Run one command on the guest over USB. Best-effort and bounded.
    private func guestRun(_ command: String) async throws {
        guard let iproxy = Bundled.tool("iproxy")
                ?? Self.searchPaths.map({ "\($0)/iproxy" }).first(where: {
                    FileManager.default.isExecutableFile(atPath: $0)
                }) else {
            throw DeviceToolsError.toolMissing("iproxy")
        }
        let port = Int.random(in: 29200...29399)
        let password = ProcessInfo.processInfo.environment["DEVICE_PASSWORD"] ?? "alpine"
        // ControlPath is deliberately absent: it is the 104-byte socket-path
        // limit that silently disabled every guest command once before.
        let script = """
        set -e
        "\(iproxy)" \(port) 22 >/dev/null 2>&1 &
        IP=$!
        trap 'kill $IP 2>/dev/null' EXIT
        sleep 1
        ASK="$(mktemp -t ltmask)"
        printf '#!/bin/sh\\necho %s\\n' "\(password)" > "$ASK"
        chmod 700 "$ASK"
        SSH_ASKPASS="$ASK" SSH_ASKPASS_REQUIRE=force DISPLAY=:0 \
        ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
            -o LogLevel=ERROR -o ConnectTimeout=10 -o NumberOfPasswordPrompts=1 \
            -p \(port) root@127.0.0.1 '\(command)'
        rm -f "$ASK"
        """
        let result = try await run(
            .path(FilePath("/bin/bash")),
            arguments: ["-c", script],
            environment: toolEnvironment,
            output: .discarded, error: .string(limit: 1 << 16)
        )
        guard result.terminationStatus.isSuccess else {
            throw DeviceToolsError.failed(
                "Could not reach the device over SSH. \(result.standardError)")
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
