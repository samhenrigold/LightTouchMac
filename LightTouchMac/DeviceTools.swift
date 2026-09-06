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
    /// The `CFBundleIdentifier`
    let id: String
    let name: String
    let version: String
}

enum DeviceToolsError: LocalizedError {
    case toolMissing(String)
    case failed(String)
    var errorDescription: String? {
        switch self {
        case .toolMissing(let t):
            return "\(t) is missing from this build of LightTouchMac."
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

    // MARK: - Music import

    func stageSong(_ song: MediaSong, progress: @escaping @Sendable (Double) -> Void) async throws {
        try await services.stageSong(song, progress: progress)
    }

    /// Once this starts, keep the staged audio even on an uncertain outcome.
    /// The guest service owns database mutations and reconciles the same path.
    func commitSong(_ song: MediaSong) async throws {
        guard UUID(uuidString: song.id) != nil else {
            throw DeviceToolsError.failed("Invalid media staging identifier.")
        }
        guard let helper = Bundled.resolve("itmedia", fallbacks: [
            "\(filesRoot)/../qemu-ios/contrib/it-media/itmedia",
        ]) else { throw DeviceToolsError.toolMissing("itmedia") }
        let executable = "/tmp/ltm-itmedia-\(song.id)"
        let metadata = "/tmp/ltm-song-\(song.id).plist"
        try await guestRun("cat > \(executable) && chmod 755 \(executable) && "
                           + "chown 501:501 /var/mobile/Media/LightTouch /var/mobile/Media/LightTouch/\(song.id)",
                           stdinPath: helper)
        let result = try await guestRun(
            "cat > \(metadata) && chmod 644 \(metadata) && \(executable) \(metadata) \(song.id); "
                + "result=$?; rm -f \(executable) \(metadata); exit $result",
            stdinPath: song.metadata.path)
        guard String(decoding: result, as: UTF8.self).hasSuffix("imported\n") else {
            throw DeviceToolsError.failed("The device did not confirm the music import. Its staged audio has been retained.")
        }
    }

    // MARK: - Photo import

    func stageMedia(_ media: PreparedMedia, progress: @escaping @Sendable (Double) -> Void) async throws {
        switch media {
        case .song(let song): try await stageSong(song, progress: progress)
        case .photo(let photo): try await services.stagePhoto(photo, progress: progress)
        }
    }

    func commitMedia(_ media: PreparedMedia) async throws {
        switch media {
        case .song(let song): try await commitSong(song)
        case .photo(let photo): try await commitPhoto(photo)
        }
    }

    func commitPhoto(_ photo: MediaPhoto) async throws {
        guard UUID(uuidString: photo.id) != nil else {
            throw DeviceToolsError.failed("Invalid photo staging identifier.")
        }
        guard let helper = Bundled.resolve("itphoto", fallbacks: [
            "\(filesRoot)/../qemu-ios/contrib/it-media/itphoto",
        ]) else { throw DeviceToolsError.toolMissing("itphoto") }
        let executable = "/tmp/ltm-itphoto-\(photo.id)"
        let result = try await guestRun(
            "cat > \(executable) && chmod 755 \(executable) && "
                + "chown 501:501 /var/mobile/Media/LightTouch /var/mobile/Media/LightTouch/\(photo.id) && "
                + "\(executable) \(photo.id); result=$?; rm -f \(executable); exit $result",
            stdinPath: helper)
        guard String(decoding: result, as: UTF8.self).hasSuffix("imported\n") else {
            throw DeviceToolsError.failed("Photos did not confirm the import. Check Saved Photos before importing it again.")
        }
    }

    // MARK: - Install

    /// Install a decrypted .ipa. Baked images go the fast in-process route
    /// (AFC stage + instproxy, no shell); a non-baked image falls back to the
    /// install script, which copies the GL engine over ssh. `progress` gets
    /// short, human phase strings for the sidebar row. The return string is
    /// non-empty only to carry the "SDK too new" marker the caller warns on.
    @discardableResult
    func install(_ ipa: URL, placeholderRaised: Bool = false,
                 progress: @escaping @Sendable (String) -> Void = { _ in }) async throws -> String {
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

        // Cheapest possible pre-flight, and the app had none: without a
        // Payload/<name>.app/Info.plist this is not an iPhone app archive at
        // all — a renamed zip, a truncated download, a .ipa of something else.
        // installd's answer to that is PackageExtractionFailed, which the app
        // renders as "package extraction failed (device may be full)": the user
        // is told to uninstall things to make room, after waiting out a
        // multi-minute upload, for a file that was never installable.
        guard await AppMetadataCache.bundleID(of: ipa) != nil else {
            throw DeviceError.preflight(
                "“\(ipa.lastPathComponent)” doesn't look like an iPhone app archive — "
                + "it has no Payload/…app/Info.plist inside.")
        }

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
            let placeholder = Self.placeholderID(for: key)
            // The add and the cancel are two independent fire-and-forget ssh
            // sessions, each with a ~1s floor, so a fast failure below (disk
            // full answers in about that long) could run the cancel FIRST and
            // strand a "downloading" placeholder on the home screen with nothing
            // ever coming to replace it. Chaining the cancel behind the add's
            // own task is what orders them.
            //
            // placeholderRaised: a catalog install already put this exact icon
            // up at download start (installPlaceholder derives the same id from
            // the same bundle id). Adding it again drew a SECOND placeholder —
            // so adopt the existing one and only own the cancel.
            let raised = placeholderRaised ? nil : placeholderIcon("add", placeholder)
            defer { placeholderIcon("cancel", placeholder, after: raised) }

            // An .ipa whose binary is archived 0644 installs fine and then never
            // launches: posix_spawn fails EACCES, SpringBoard logs only "exited
            // abnormally", the icon bounces once and NO crash report is written
            // — it reads as an emulator bug. install-ipa.sh repacks it 0755;
            // the in-process path skipped that, so every 2009-era .ipa of this
            // shape (Cube Runner among them) regressed on the default image.
            let repaired = try await Self.execBitRepaired(ipa)
            defer { if let repaired { try? FileManager.default.removeItem(at: repaired) } }
            let ipa = repaired ?? ipa
            try Task.checkCancellation()
            let bytes = (try? FileManager.default.attributesOfItem(atPath: ipa.path)[.size] as? Int) ?? 0
            let free = try await services.freeSpaceBytes()
            let needed = Int64(bytes) * 2 + (16 << 20)
            guard free >= needed else { throw DeviceError.diskFull(free: free, needed: needed) }

            progress("Sending to device…")
            let staged = try await services.stage(ipa) { frac in
                progress("Sending to device… \(Int(frac * 100))%")
            }
            defer { Task { await services.removeStaged(staged) } }

            // Cancelling during the upload is honoured here, at the last point
            // where it can be: instproxy_install runs on a detached thread that
            // ignores cancellation, so once it starts, the install finishes.
            try Task.checkCancellation()

            // attempts: 1. An install that hit its watchdog leaves a live
            // libimobiledevice thread and an open lockdown service behind
            // (deliberately — freeing them under the library is worse), so
            // retrying a TIMEOUT meant three of those against a guest that
            // serves about one, which is how a wedged install took the rest of
            // the session's app management down with it. Transient CONNECT
            // failures still retry; see DeviceError.isTransient.
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
    private static func execBitRepaired(_ ipa: URL) async throws -> URL? {
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
        var succeeded = false
        defer { if !succeeded { try? FileManager.default.removeItem(at: out) } }
        let rc = try await run(
            .path(FilePath(helper)),
            arguments: ["ipa-chmod", ipa.path, out.path, member],
            output: .discarded, error: .discarded).terminationStatus
        guard rc.isSuccess, FileManager.default.fileExists(atPath: out.path) else {
            throw DeviceError.preflight("Could not repair the IPA's executable permissions.")
        }
        succeeded = true
        logEvent("install: \(member) archived non-executable — repacked 0755")
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

    /// Upgrade existing images, including legacy lock-disabling preferences.
    /// Reload SpringBoard after changes; the caller waits for it to answer.
    func updateMediaComponents() async throws -> Bool {
        guard let engine = Bundled.resolve("MBXGLEngine", fallbacks: [
            "\(NSHomeDirectory())/Developer/qemu-ios/contrib/it-gles/MBXGLEngine",
        ]) else { throw DeviceToolsError.toolMissing("MBXGLEngine") }
        let guestToolsRoot = "\(filesRoot)/../qemu-ios/contrib/it-agent"
        guard let agent = Bundled.resolve("it_agent", fallbacks: ["\(guestToolsRoot)/it_agent"]),
              let typing = Bundled.resolve("it_typein.dylib", fallbacks: ["\(guestToolsRoot)/it_typein.dylib"]),
              let agentJob = Bundled.resolve("com.qemu.it-agent.plist", fallbacks: ["\(guestToolsRoot)/com.qemu.it-agent.plist"]) else {
            throw DeviceToolsError.toolMissing("guest agent components")
        }
        let agentPath = "/usr/local/bin/it_agent"
        let typingPath = "/usr/lib/it_typein.dylib"
        let agentJobPath = "/System/Library/LaunchDaemons/com.qemu.it-agent.plist"
        let agentData = try Data(contentsOf: URL(fileURLWithPath: agent))
        let typingData = try Data(contentsOf: URL(fileURLWithPath: typing))
        let jobData = try Data(contentsOf: URL(fileURLWithPath: agentJob))
        guard [agentData, typingData, jobData].allSatisfy({ !$0.isEmpty && $0.count <= 250_000 }),
              let job = try PropertyListSerialization.propertyList(from: jobData, format: nil) as? [String: Any],
              job["Label"] as? String == "com.qemu.it-agent",
              job["ProgramArguments"] as? [String] == [agentPath] else {
            throw DeviceToolsError.failed("The bundled guest agent is invalid.")
        }
        let enginePath = "/System/Library/Frameworks/OpenGLES.framework/MBXGLEngine.bundle/MBXGLEngine"
        let plistPath = "/System/Library/LaunchDaemons/com.apple.SpringBoard.plist"
        let engineData = try Data(contentsOf: URL(fileURLWithPath: engine))
        guard !engineData.isEmpty, engineData.count <= 1 << 20 else {
            throw DeviceToolsError.failed("The bundled graphics engine is invalid.")
        }
        let preferencesPath = "/var/mobile/Library/Preferences/com.apple.springboard.plist"
        let oldPreferences = try await guestRun("cat \(preferencesPath)")
        let newPreferences = try Self.lockButtonPreferences(oldPreferences)
        let oldPlist = try await guestRun("cat \(plistPath)")
        let newPlist = try Self.mediaLaunchConfiguration(oldPlist, includeTyping: true)
        let oldEngine = try await guestRun("cat \(enginePath)")
        let changedEngine = oldEngine != engineData
        let oldAgent = try await guestRun("if [ -f \(agentPath) ]; then cat \(agentPath); fi")
        let oldTyping = try await guestRun("if [ -f \(typingPath) ]; then cat \(typingPath); fi")
        let oldJob = try await guestRun("if [ -f \(agentJobPath) ]; then cat \(agentJobPath); fi")
        let legacy = "/System/Library/LaunchDaemons/com.qemu.it-pbd.plist"
        let legacyPresent = try await guestRun("test ! -e \(legacy) || printf legacy")
        let changedAgent = oldAgent != agentData
        let changedTyping = oldTyping != typingData
        let changedJob = oldJob != jobData
        for (changed, source, destination, mode) in [
            (changedAgent, agent, agentPath, "755"),
            (changedTyping, typing, typingPath, "755"),
            (changedJob, agentJob, agentJobPath, "644")
        ] where changed {
            try Task.checkCancellation()
            try await guestRun("cat > \(destination).ltm-new && chmod \(mode) \(destination).ltm-new"
                               + " && mv -f \(destination).ltm-new \(destination)", stdinPath: source)
        }
        // Validate both inputs before changing either guest file. Stage beside
        // the destination: /tmp is a different guest filesystem, so a move
        // from there is a non-atomic copy and can leave an unbootable plist.
        if changedEngine {
            try Task.checkCancellation()
            try await guestRun("cat > \(enginePath).ltm-new && chmod 755 \(enginePath).ltm-new"
                               + " && mv -f \(enginePath).ltm-new \(enginePath)", stdinPath: engine)
        }
        if let newPlist {
            try Task.checkCancellation()
            let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try newPlist.write(to: file, options: .atomic)
            defer { try? FileManager.default.removeItem(at: file) }
            try await guestRun("cat > \(plistPath).ltm-new && chmod 644 \(plistPath).ltm-new"
                               + " && mv -f \(plistPath).ltm-new \(plistPath)", stdinPath: file.path)
        }
        if changedAgent || changedJob || !legacyPresent.isEmpty || qemu_ios_agent_status() != 1 {
            // A daemon cannot unload its own launch job and return a result.
            // Use the independent USB/SSH path only for this lifecycle step.
            try await guestRun("launchctl unload \(legacy) >/dev/null 2>&1 || :; rm -f \(legacy); "
                               + "launchctl unload \(agentJobPath) >/dev/null 2>&1 || :; launchctl load \(agentJobPath)",
                               usingAgent: false)
        }
        let changed = changedEngine || changedTyping || newPlist != nil || newPreferences != nil
        if changed {
            let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: file) }
            if let newPreferences { try newPreferences.write(to: file, options: .atomic) }
            try await reloadMediaCompositor(preferencesFile: newPreferences == nil ? nil : file.path)
        }
        return changed
    }

    private func reloadMediaCompositor(preferencesFile: String?) async throws {
        try Task.checkCancellation()
        let plist = "/System/Library/LaunchDaemons/com.apple.SpringBoard.plist"
        let preferences = "/var/mobile/Library/Preferences/com.apple.springboard.plist"
        // Stop SpringBoard before replacing its preferences: it can flush its
        // cached copy on exit. Reload the job even if the replacement fails.
        var command = "set -e; sync; launchctl unload \(plist); trap 'result=$?; launchctl load \(plist) || exit $?; exit $result' EXIT; trap 'exit 1' HUP INT TERM; "
        if preferencesFile != nil {
            command += "cat > \(preferences).ltm-new; chown 501:501 \(preferences).ltm-new"
                + "; chmod 600 \(preferences).ltm-new; mv -f \(preferences).ltm-new \(preferences); "
        }
        command += "sync"
        try await guestRun(command, stdinPath: preferencesFile)
    }

    static func lockButtonPreferences(_ data: Data) throws -> Data? {
        var format = PropertyListSerialization.PropertyListFormat.xml
        guard var preferences = try PropertyListSerialization.propertyList(from: data, format: &format) as? [String: Any] else {
            throw DeviceToolsError.failed("The device's SpringBoard preferences are invalid.")
        }
        let keys = ["SBDontLockEver", "SBDisableCABlanking"]
        guard keys.contains(where: { preferences[$0] != nil }) else { return nil }
        for key in keys { preferences.removeValue(forKey: key) }
        return try PropertyListSerialization.data(fromPropertyList: preferences, format: format, options: 0)
    }

    /// Preserve the launch job and unrelated environment, including binary
    /// plists. A malformed job must never be replaced with a guessed default.
    static func mediaLaunchConfiguration(_ data: Data, includeTyping: Bool = false) throws -> Data? {
        var format = PropertyListSerialization.PropertyListFormat.xml
        guard var job = try PropertyListSerialization.propertyList(from: data, format: &format) as? [String: Any],
              job["Label"] as? String == "com.apple.SpringBoard",
              job["EnvironmentVariables"] == nil || job["EnvironmentVariables"] is [String: Any] else {
            throw DeviceToolsError.failed("The device's SpringBoard configuration is invalid.")
        }
        var environment = job["EnvironmentVariables"] as? [String: Any] ?? [:]
        let original = environment
        let keys = ["CA_ENABLE_OGL", "LK_ENABLE_OGL"]
        for key in keys { environment[key] = "1" }
        if includeTyping {
            guard environment["DYLD_INSERT_LIBRARIES"] == nil || environment["DYLD_INSERT_LIBRARIES"] is String else {
                throw DeviceToolsError.failed("The device's injected-library configuration is invalid.")
            }
            var libraries = (environment["DYLD_INSERT_LIBRARIES"] as? String ?? "")
                .split(separator: ":").map(String.init)
                .filter { $0 != "/usr/lib/it_kbd_agent.dylib" }
            if !libraries.contains("/usr/lib/it_typein.dylib") { libraries.append("/usr/lib/it_typein.dylib") }
            environment["DYLD_INSERT_LIBRARIES"] = libraries.joined(separator: ":")
        }
        if NSDictionary(dictionary: environment).isEqual(to: original) { return nil }
        job["EnvironmentVariables"] = environment
        return try PropertyListSerialization.data(fromPropertyList: job, format: format, options: 0)
    }

    /// Nil means this image has no agent; failures must not start a second transport.
    func guestOrientation() async throws -> Int? {
        try await GuestAgentTransport.shared.orientationIfAvailable()
    }

    /// Read-only helper uses SpringBoard's foreground identifier and localized
    /// display name. It never writes sblaunch's shared command file.
    func foregroundAppName(stageHelper: Bool) async throws -> String? {
        let data: Data
        if stageHelper {
            guard let helper = Bundled.resolve("itstatus", fallbacks: [
                "\(filesRoot)/../qemu-ios/contrib/it-status/itstatus"
            ]) else { throw DeviceToolsError.toolMissing("itstatus") }
            data = try await guestRun("cat > /tmp/ltm-itstatus.new && chmod 755 /tmp/ltm-itstatus.new && mv /tmp/ltm-itstatus.new /tmp/ltm-itstatus && /tmp/ltm-itstatus", stdinPath: helper)
        } else {
            data = try await guestRun("/tmp/ltm-itstatus")
        }
        let value = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : String(value.prefix(200))
    }

    func configureWebProxy(enabled: Bool) async throws {
        guard let helper = Bundled.resolve("itproxy", fallbacks: [
            "\(filesRoot)/../qemu-ios/contrib/it-proxy/itproxy"
        ]) else { throw DeviceToolsError.toolMissing("itproxy") }
        let certificate = WebProxyConfiguration.file.path + ".ca.der"
        if enabled {
            guard let host = Bundled.resolve("itwebproxy", fallbacks: [
                "\(filesRoot)/../qemu-ios/contrib/it-webproxy/itwebproxy"
            ]) else { throw DeviceToolsError.toolMissing("itwebproxy") }
            let status = try await run(.path(FilePath(host)),
                                       arguments: ["--init-ca", WebProxyConfiguration.file.path],
                                       output: .discarded, error: .discarded).terminationStatus
            guard status.isSuccess else {
                throw DeviceToolsError.failed("Could not prepare this device’s HTTP proxy certificate.")
            }
            try await configureProxyTrust(certificate: certificate, enabled: true)
        }
        let action = enabled ? "on" : "off"
        try await guestRun("cat > /tmp/ltm-itproxy.new && chmod 755 /tmp/ltm-itproxy.new && mv /tmp/ltm-itproxy.new /tmp/ltm-itproxy && /tmp/ltm-itproxy \(action)", stdinPath: helper)
        if !enabled && FileManager.default.fileExists(atPath: certificate) {
            try await configureProxyTrust(certificate: certificate, enabled: false)
        }
    }

    private func configureProxyTrust(certificate: String, enabled: Bool) async throws {
        guard let helper = Bundled.resolve("ittrust", fallbacks: [
            "\(filesRoot)/../qemu-ios/contrib/it-proxy/ittrust"
        ]) else { throw DeviceToolsError.toolMissing("ittrust") }
        try await guestRun("cat > /tmp/ltm-ittrust.new && chmod 755 /tmp/ltm-ittrust.new && mv /tmp/ltm-ittrust.new /tmp/ltm-ittrust", stdinPath: helper)
        let action = enabled ? "add" : "remove"
        try await guestRun("cat > /tmp/ltm-proxy-ca.der && /tmp/ltm-ittrust \(action) /tmp/ltm-proxy-ca.der", stdinPath: certificate)
    }

    /// Push the guest's dirty buffers to flash.
    func syncFilesystem() async throws {
        try await guestRun("sync")
    }

    /// Ask SpringBoard to launch an installed app — the same path a tap on
    /// its icon takes (SBSLaunchApplicationWithIdentifier). sblaunch has no
    /// argv (these guest binaries have no crt1), so the bundle id travels via
    /// /tmp/sblaunch.id. SpringBoard refuses the request on a locked device.
    func launchApp(_ bundleID: String) async throws {
        guard bakedGuestTools else {
            throw DeviceToolsError.failed("Launching apps from the sidebar needs the standard device image.")
        }
        // The filter is what makes the value safe inside the single quotes.
        let id = bundleID.filter { $0.isLetter || $0.isNumber || $0 == "." || $0 == "-" || $0 == "_" }
        try await guestRun("printf %s '\(id)' > /tmp/sblaunch.id && /usr/local/bin/sblaunch")
    }

    /// Shut the guest's filesystem down through the kernel: sync, unmount
    /// everything, halt. No SpringBoard, no gesture, nothing drawn.
    ///
    /// The alternative — the machine model's synthetic press-and-hold plus a
    /// slide across the power-off sheet — only works while the UI is healthy,
    /// which is not when a shutdown gets asked for. Measured: a powerdown
    /// requested while a full-screen GL app was foreground never completed,
    /// while the same build powers off in 14s from the home screen. A hung game
    /// is not going to draw the slider.
    ///
    /// `reboot(2)` needs nobody's cooperation: XNU syncs, calls
    /// vfs_unmountall() and halts. /sbin/halt does not exist on these images,
    /// so the helper is a 20-line armv6 binary streamed in and exec'd from
    /// /tmp, exactly the way the orientation reporter is.
    ///
    /// Throws if the helper is missing or ssh cannot reach the guest — the
    /// caller falls back from there. Note that a SUCCESSFUL halt kills the
    /// connection, so a non-zero exit from ssh is the expected outcome, not a
    /// failure: `guestRun` is asked to tolerate it and the caller checks the
    /// guest instead.
    func haltFilesystem() async throws {
        guard let helper = Self.haltHelperPath else {
            throw DeviceToolsError.toolMissing("ithalt")
        }
        // rm first: /tmp/ithalt from a previous run may still be a RUNNING image,
        // and Darwin answers ETXTBSY to opening one for write — which would make
        // the whole command fail with no clue why.
        try await guestRun("rm -f /tmp/ithalt && cat > /tmp/ithalt && chmod 755 /tmp/ithalt"
                           + " && exec /tmp/ithalt",
                           stdinPath: helper, expecting: "syncing and halting")
    }

    /// The bundled guest-side halt helper, or the checkout's copy in a dev build.
    static var haltHelperPath: String? {
        Bundled.resolve("ithalt", fallbacks: [
            "\(NSHomeDirectory())/Developer/qemu-ios/contrib/it-halt/ithalt",
        ])
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
    /// The one id both phases share for a given app, so a placeholder raised
    /// at download start is the SAME icon the install phase adopts and
    /// cancels — never two. (Two ids was tried: the download's icon and the
    /// install's coexisted on the home screen through the whole install.)
    static func placeholderID(for key: String) -> String {
        "qemu-install-" + key
            .filter { $0.isLetter || $0.isNumber || $0 == "." || $0 == "-" || $0 == "_" }
    }

    /// Raise or drop the placeholder from outside the install path (the
    /// catalog's download phase). Cancel of an id that is already gone is a
    /// no-op on SpringBoard, so belt-and-suspenders cancels are safe.
    @discardableResult
    func installPlaceholder(_ action: String, bundleID: String,
                            after previous: Task<Void, Never>? = nil) -> Task<Void, Never>? {
        guard bakedGuestTools else { return nil }
        return placeholderIcon(action, Self.placeholderID(for: bundleID), after: previous)
    }

    @discardableResult
    private func placeholderIcon(_ action: String, _ id: String,
                                 after previous: Task<Void, Never>? = nil) -> Task<Void, Never> {
        Task {
            await previous?.value
            _ = try? await guestRun("/usr/local/bin/sbdlicon \(action) '\(id)'")
        }
    }

    /// Run one command on the guest over USB, bounded and cancellable.
    ///
    /// `expecting` is how a command that KILLS ITS OWN SESSION proves it ran:
    /// the halt takes the system down, so ssh always exits non-zero and the
    /// exit status cannot tell "the guest halted" from "ssh never got there".
    /// Tolerating the failure without demanding evidence made haltFilesystem
    /// report success when sshd was not up yet — and the caller then skipped
    /// the sync and the powerdown, which is the entire ladder, and lost the
    /// session's installs. The marker is the guest's own stdout.
    @discardableResult
    private func guestRun(_ command: String, stdinPath: String? = nil,
                         expecting marker: String? = nil, usingAgent: Bool = true) async throws -> Data {
        if usingAgent, marker == nil,
           let result = try await GuestAgentTransport.shared.runIfAvailable(command, stdinPath: stdinPath) {
            return result
        }
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
        "$1" "$2" 22 >/dev/null 2>&1 &
        IP=$!
        ASK=""
        trap 'kill "$IP" 2>/dev/null || :; rm -f "$ASK"' EXIT
        trap 'exit 143' INT TERM HUP
        sleep 1
        kill -0 "$IP" 2>/dev/null || { echo "iproxy could not bind port $2" >&2; exit 1; }
        ASK="$(mktemp -t ltmask)"
        printf '%s\\n' '#!/bin/sh' 'printf "%s" "$LTM_SSH_PASSWORD"' > "$ASK"
        chmod 700 "$ASK"
        export LTM_SSH_PASSWORD="$3"
        SSH_ASKPASS="$ASK" SSH_ASKPASS_REQUIRE=force DISPLAY=:0 \
        ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
            -o LogLevel=ERROR -o ConnectTimeout=10 -o NumberOfPasswordPrompts=1 \
            -o ServerAliveInterval=5 -o ServerAliveCountMax=3 \
            -p "$2" root@127.0.0.1 "$4" < "$5"
        """
        var platform = PlatformOptions()
        platform.createSession = true
        platform.teardownSequence = [.gracefulShutDown(toProcessGroup: true,
                                                       allowedDurationToNextStep: .seconds(2))]
        let environment = toolEnvironment
        let options = platform
        return try await withThrowingTaskGroup(of: Data.self) { group in
            group.addTask {
                let result = try await run(
                    .path(FilePath("/bin/bash")),
                    arguments: ["-c", script, "ltm-ssh", iproxy, String(port), password, command, stdinPath ?? "/dev/null"],
                    environment: environment, platformOptions: options,
                    output: .data(limit: 1 << 20), error: .string(limit: 1 << 16)
                )
                if let marker {
                    guard String(decoding: result.standardOutput, as: UTF8.self).contains(marker) else {
                        throw DeviceToolsError.failed(
                            "The device did not run the command. \(result.standardError)")
                    }
                    return result.standardOutput // it ran; its own exit status is meaningless by then
                }
                guard result.terminationStatus.isSuccess else {
                    throw DeviceToolsError.failed(
                        "Could not reach the device over SSH. \(result.standardError)")
                }
                return result.standardOutput
            }
            group.addTask {
                try await Task.sleep(for: .seconds(30))
                throw DeviceToolsError.failed("The device's SSH command timed out.")
            }
            defer { group.cancelAll() }
            return try await group.next()!
        }
    }

    // MARK: - Timezone

    /// Sync the guest's timezone through the bundled lockdown-tz helper — a
    /// child process ON PURPOSE. lockdownd_set_value called in-process against
    /// 3.1.3's lockdownd corrupts the heap: the app died ~20 s later in
    /// unrelated Swift runtime code, reproducibly, while the identical call
    /// from a child process is clean (scripts/lockdown-tz.c). The tool reads
    /// first, sets only on mismatch, and prints the zone in effect. Dev builds
    /// without the bundled tool skip quietly — the zone is cosmetic.
    func setTimeZone(_ identifier: String) async throws {
        guard let tool = Bundled.tool("lockdown-tz") else {
            logEvent("timezone: no bundled lockdown-tz (dev build) — leaving the guest's zone alone")
            return
        }
        let result = try await run(
            .path(FilePath(tool)),
            arguments: [identifier],
            environment: toolEnvironment,
            output: .string(limit: 1 << 10), error: .string(limit: 1 << 10)
        )
        guard result.terminationStatus.isSuccess else {
            throw DeviceToolsError.failed(
                "Could not set the device timezone. \(result.standardError)")
        }
        logEvent("timezone: guest zone now \(result.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines))")
    }

    // MARK: - SSH terminal (opens Terminal.app itself)
    
    func openTerminal() async throws {
        guard let resolved = Bundled.resolve("it-ssh-terminal.sh", fallbacks: [
            "\(filesRoot)/../qemu-ios/contrib/it-ssh-terminal.sh",
            "\(NSHomeDirectory())/Developer/qemu-ios/contrib/it-ssh-terminal.sh",
        ]) else {
            throw DeviceToolsError.toolMissing("it-ssh-terminal.sh")
        }
        let result = try await run(
            .path(FilePath("/bin/bash")),
            arguments: [resolved],
            environment: toolEnvironment,
            output: .discarded, error: .string(limit: 1 << 16)
        )
        // Was `.discarded` with the status ignored, so every failure — no sshd
        // on this image, a refused connection, a wrong password — produced
        // no Terminal window, no error, nothing. This is the command people
        // reach for when things are already broken.
        guard result.terminationStatus.isSuccess else {
            throw DeviceToolsError.failed(
                "Could not open a shell on the device. This NAND image may not have sshd "
                + "installed. \(result.standardError)")
        }
    }
}


/// One result dispatcher for the process's embedded emulator. A submitted
/// command is never retried through SSH: a lost response may follow a mutation.
private actor GuestAgentTransport {
    static let shared = GuestAgentTransport()
    private var waiting: Set<String> = []
    private var results: [String: (Int, Data)] = [:]

    func runIfAvailable(_ command: String, stdinPath: String?) async throws -> Data? {
        guard qemu_ios_agent_status() == 1,
              command.utf8.allSatisfy({ $0 >= 32 && $0 <= 126 }),
              command.utf8.count < 4000 else { return nil }
        var body = Data()
        if let stdinPath {
            let size = try FileManager.default.attributesOfItem(atPath: stdinPath)[.size] as? NSNumber
            guard let size, size.intValue <= 250_000 else { return nil }
            body = try Data(contentsOf: URL(fileURLWithPath: stdinPath))
        }
        guard body.count + command.utf8.count + 40 <= 256 * 1024 else { return nil }
        return try await perform("exec", arguments: command, body: body)
    }

    func orientationIfAvailable() async throws -> Int? {
        guard qemu_ios_agent_status() != 0 else { return nil }
        let data = try await perform("orientation")
        guard let degrees = Int(String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)),
              [0, 90, 180, -90].contains(degrees) else {
            throw DeviceToolsError.failed("The device returned an invalid orientation.")
        }
        return degrees
    }

    private func perform(_ operation: String, arguments: String = "", body: Data = Data()) async throws -> Data {
        guard qemu_ios_agent_status() == 1 else {
            throw DeviceToolsError.failed("The device agent is not ready.")
        }
        try Task.checkCancellation()
        let id = UUID().uuidString
        let request = "\(id) \(operation) \(arguments)\n\(body.base64EncodedString())"
        guard request.withCString({ qemu_ios_agent_request($0) }) else {
            throw DeviceToolsError.failed("The device command queue is full or unavailable.")
        }
        waiting.insert(id)
        var completed = false
        defer {
            waiting.remove(id)
            results[id] = nil
            if !completed { id.withCString { qemu_ios_agent_cancel($0) } }
        }
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(65))
        while clock.now < deadline {
            try Task.checkCancellation()
            while let pointer = qemu_ios_agent_result() {
                let wire = String(cString: pointer)
                qemu_ios_agent_free_result(pointer)
                let parts = wire.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
                guard parts.count == 2 else { continue }
                let header = parts[0].split(separator: " ", maxSplits: 1)
                guard header.count == 2, let status = Int(header[1]),
                      let output = Data(base64Encoded: String(parts[1])) else { continue }
                let resultID = String(header[0])
                if waiting.contains(resultID) { results[resultID] = (status, output) }
            }
            if let (status, output) = results.removeValue(forKey: id) {
                completed = true
                guard status == 0 else {
                    throw DeviceToolsError.failed("The device command failed (\(status)). \(String(decoding: output.prefix(4096), as: UTF8.self))")
                }
                return output
            }
            guard qemu_ios_ui_ready() else {
                throw DeviceToolsError.failed("The device stopped before its command completed.")
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw DeviceToolsError.failed("The device command timed out; its outcome is unknown.")
    }
}
