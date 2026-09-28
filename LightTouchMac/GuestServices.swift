// Guest services without a shell (qemu-ios docs/ipod/guest-services-plan.md, P2).
//
// Everything the app asks of a running iPod goes through the guest agent's
// typed v2 ops (contrib/it-agent/README.md): spawn with no shell, put/get,
// chown/unlink, sync, launch, frontmost, lockstatus, orientation, dlicon,
// halt. Stock lockdown services (installs, AFC, the time zone through the
// lockdown-tz child process) stay in DeviceServices and DeviceTools.
//
// Capabilities come from the agent's ping: a v2 agent lists its ops; a v1
// agent (older images, which still carry freeze's /bin/sh) answers only its
// version, and each op it lacks falls back here to its `exec` with the same
// command a shell would have run. No SSH anywhere.
//
// Foundation only, so tests/session-driver compiles it as the app does.

import Foundation

enum AppLaunchError: Error {
    case locked, unavailable, failed

    func message(for profile: DeviceProfile) -> String {
        switch self {
        case .locked: "Unlock the \(profile.shortName), then try again."
        case .unavailable: "Wait for the \(profile.shortName) to finish starting, then try again."
        case .failed: "Try opening the app on the \(profile.shortName)."
        }
    }
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

/// A command the agent ran and refused, with its (negative errno or exit) status.
nonisolated struct GuestAgentError: LocalizedError, CustomStringConvertible {
    let operation: String
    let status: Int
    let output: Data
    static let notFound = -2, again = -35, connectionReset = -54, notImplemented = -78
    var errorDescription: String? {
        "The device command \(operation) failed (\(status)). \(String(decoding: output.prefix(4096), as: UTF8.self))"
    }
    var description: String { errorDescription ?? operation }
}

/// What `ping` said: `it_agent v2\nops …` or a v1's bare `it_agent v1`.
nonisolated struct GuestAgentCapabilities: Sendable, Equatable {
    var version: Int
    var ops: Set<String>

    static func parse(_ reply: String) -> GuestAgentCapabilities? {
        let lines = reply.split(separator: "\n")
        guard let first = lines.first, first.hasPrefix("it_agent v"), let version = Int(first.dropFirst(10)) else { return nil }
        let ops = lines.first { $0.hasPrefix("ops ") }.map { Set($0.dropFirst(4).split(separator: " ").map(String.init)) } ?? []
        return GuestAgentCapabilities(version: version, ops: ops)
    }

    func has(_ op: String) -> Bool { ops.contains(op) }
}

/// One device's ping result, kept until its agent restarts.
nonisolated final class GuestAgentCache: @unchecked Sendable {
    private let lock = NSLock()
    private var value: GuestAgentCapabilities?
    var capabilities: GuestAgentCapabilities? {
        get { lock.withLock { value } }
        set { lock.withLock { value = newValue } }
    }
    func reset() { capabilities = nil }
}

/// The guest agent of one device, through its helper (LinkRequest.agent). A
/// submitted request is never retried: a lost reply may follow a mutation.
nonisolated struct GuestAgent: Sendable {
    let link: DeviceLink?
    let cache: GuestAgentCache

    /// 0 absent or not running, 1 alive, 2 stale.
    var status: Int { link?.status?.agentStatus ?? 0 }
    var isAlive: Bool { status == 1 }

    // MARK: Wire

    /// Status and body of one op; throws only when no status came back.
    func raw(_ operation: String, _ arguments: String = "", body: Data = Data(),
             deadline: Double = 65) async throws -> (status: Int, output: Data) {
        guard let link, isAlive else { throw DeviceToolsError.failed("The device agent is not ready.") }
        try Task.checkCancellation()
        let id = UUID().uuidString
        let request = "\(id) \(operation) \(arguments)\n\(body.base64EncodedString())"
        let reply: LinkReply
        do {
            // The helper answers `.agent(nil)` at the deadline (and cancels the
            // request); the link's own timeout is only the backstop.
            reply = try await withTaskCancellationHandler {
                try await link.request(.agent(request: request, deadline: deadline), timeout: deadline + 10)
            } onCancel: {
                link.send(.agentCancel(id: id))
            }
        } catch {
            throw DeviceToolsError.failed("The device stopped before its command completed.")
        }
        try Task.checkCancellation()
        switch reply {
        case let .agent(wire?):
            // "<id> <status>\n<base64 output>"
            let parts = wire.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
            let header = parts.first?.split(separator: " ", maxSplits: 1) ?? []
            guard parts.count == 2, header.count == 2, header[0] == id, let code = Int(header[1]),
                  let output = Data(base64Encoded: String(parts[1])) else {
                throw DeviceToolsError.failed("The device returned an invalid command result.")
            }
            return (code, output)
        case .agent(nil): throw DeviceToolsError.failed("The device command timed out; its outcome is unknown.")
        case let .failure(message): throw DeviceToolsError.failed(message)
        default: throw DeviceToolsError.failed("The device returned an invalid command result.")
        }
    }

    /// The output of an op that must succeed.
    @discardableResult
    func perform(_ operation: String, _ arguments: String = "", body: Data = Data()) async throws -> Data {
        let (status, output) = try await raw(operation, arguments, body: body)
        guard status == 0 else { throw GuestAgentError(operation: operation, status: status, output: output) }
        return output
    }

    func capabilities() async throws -> GuestAgentCapabilities {
        if let known = cache.capabilities { return known }
        let reply = String(decoding: try await perform("ping"), as: UTF8.self)
        guard let parsed = GuestAgentCapabilities.parse(reply) else {
            throw DeviceToolsError.failed("The device agent answered an unknown version.")
        }
        cache.capabilities = parsed
        return parsed
    }

    /// v1 fallback: the agent's exec runs `/bin/sh -c`, which only v1 images have.
    @discardableResult
    private func shell(_ command: String, body: Data = Data()) async throws -> Data {
        try await perform("exec", command, body: body)
    }

    static func quote(_ word: String) -> String { "'" + word.replacingOccurrences(of: "'", with: "'\\''") + "'" }

    // MARK: Typed ops

    /// argv[0] absolute; no shell. The child's stdout+stderr on success.
    @discardableResult
    func spawn(_ argv: [String]) async throws -> Data {
        guard try await capabilities().has("spawn") else { return try await shell(argv.map(Self.quote).joined(separator: " ")) }
        return try await perform("spawn", body: Data(argv.map { $0 + "\u{0}" }.joined().utf8))
    }

    func sync() async throws {
        guard try await capabilities().has("sync") else { try await shell("sync"); return }
        try await perform("sync")
    }

    /// Atomic (mkstemp beside the path, fsync, rename) and root-owned.
    func put(_ path: String, mode: Int, _ data: Data) async throws {
        try await perform("put", "\(path) \(String(mode, radix: 8))", body: data)
    }

    /// A regular file up to 1 MiB; nil when absent.
    func get(_ path: String) async throws -> Data? {
        let (status, output) = try await raw("get", path)
        if status == GuestAgentError.notFound { return nil }
        guard status == 0 else { throw GuestAgentError(operation: "get", status: status, output: output) }
        return output
    }

    func chown(_ uid: Int, _ gid: Int, _ path: String) async throws {
        guard try await capabilities().has("chown") else { try await shell("chown \(uid):\(gid) \(Self.quote(path))"); return }
        try await perform("chown", "\(uid) \(gid) \(path)")
    }

    /// Absent is fine.
    func unlink(_ path: String) async throws {
        guard try await capabilities().has("unlink") else { try await shell("rm -f \(Self.quote(path))"); return }
        let (status, output) = try await raw("unlink", path)
        guard status == 0 || status == GuestAgentError.notFound else {
            throw GuestAgentError(operation: "unlink", status: status, output: output)
        }
    }

    func launch(_ bundleID: String) async throws { try await perform("launch", bundleID) }

    /// SpringBoard's foreground bundle id and localized name; `Lock Screen` when locked.
    func frontmost() async throws -> (bundleID: String, name: String) {
        let lines = String(decoding: try await perform("frontmost"), as: UTF8.self).split(separator: "\n").map(String.init)
        return (lines.first ?? "", lines.dropFirst().first ?? "")
    }

    func isLocked() async throws -> Bool {
        String(decoding: try await perform("lockstatus"), as: UTF8.self).contains("locked=1")
    }

    func orientation() async throws -> Int {
        let text = String(decoding: try await perform("orientation"), as: UTF8.self)
        guard let degrees = Int(text.trimmingCharacters(in: .whitespacesAndNewlines)), [0, 90, 180, -90].contains(degrees) else {
            throw DeviceToolsError.failed("The device returned an invalid orientation.")
        }
        return degrees
    }

    /// The home screen's "Waiting…" placeholder; false when this agent has no dlicon (v1).
    @discardableResult
    func placeholder(_ action: String, id: String, bundleID: String? = nil) async throws -> Bool {
        guard try await capabilities().has("dlicon") else { return false }
        try await perform("dlicon", ([action, id] + (action == "add" ? [bundleID].compactMap { $0 } : [])).joined(separator: " "))
        return true
    }

    /// Submit only (deadline 0): the halt takes the agent down with the guest.
    func requestHalt() async -> Bool {
        guard let link, isAlive else { return false }
        let reply = try? await link.request(.agent(request: "\(UUID().uuidString) halt \n", deadline: 0), timeout: 5)
        return reply == .ok(true)
    }

    /// Wait for a (re)started agent to claim the channel.
    func waitAlive(seconds: Double) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if isAlive { return true }
            try? await Task.sleep(for: .milliseconds(250))
        }
        return isAlive
    }
}

/// The app's guest operations, over the agent.
nonisolated struct GuestServices: Sendable {
    let agent: GuestAgent
    /// True when the guest runs a package from the loader (a guest-package
    /// report arrived): its binaries are under `packageBin`, and the loader,
    /// not the app, keeps the agent, the GL engine and typein current.
    var packaged = false

    static let packageBin = "/usr/local/lighttouch/current/bin"
    static let springBoardJob = "/System/Library/LaunchDaemons/com.apple.SpringBoard.plist"
    static let springBoardPreferences = "/var/mobile/Library/Preferences/com.apple.springboard.plist"
    static let agentJob = "/System/Library/LaunchDaemons/com.qemu.it-agent.plist"
    static let legacyClipboardJob = "/System/Library/LaunchDaemons/com.qemu.it-pbd.plist"
    static let engine = "/System/Library/Frameworks/OpenGLES.framework/MBXGLEngine.bundle/MBXGLEngine"
    static let typing = "/usr/lib/it_typein.dylib"
    static let launchctl = "/bin/launchctl"

    // MARK: Media

    /// Commit staged media into the library with itmedia (Music, Videos: a
    /// metadata plist) or itphoto (Saved Photos): the package's copy, or the
    /// app's uploaded to /tmp for the one run. The tool must end with `imported`.
    func commitMedia(id: String, helper: String, localHelper: () throws -> URL, metadata: URL?) async throws -> Bool {
        guard UUID(uuidString: id) != nil else { throw DeviceToolsError.failed("Invalid media staging identifier.") }
        try await agent.chown(501, 501, "/var/mobile/Media/LightTouch")
        try await agent.chown(501, 501, "/var/mobile/Media/LightTouch/\(id)")
        var temporary: [String] = []
        var arguments = [id]
        if let metadata {
            let remote = "/tmp/ltm-media-\(id).plist"
            try await agent.put(remote, mode: 0o644, try Data(contentsOf: metadata))
            temporary.append(remote)
            arguments.insert(remote, at: 0)
        }
        do {
            var output: Data?
            if packaged {
                do { output = try await agent.spawn(["\(Self.packageBin)/\(helper)"] + arguments) }
                catch let error as GuestAgentError where error.status == GuestAgentError.notFound { output = nil }
            }
            if output == nil {
                let executable = "/tmp/ltm-\(helper)-\(id)"
                try await agent.put(executable, mode: 0o755, try Data(contentsOf: localHelper()))
                temporary.append(executable)
                output = try await agent.spawn([executable] + arguments)
            }
            for path in temporary { try? await agent.unlink(path) }
            return String(decoding: output ?? Data(), as: UTF8.self).hasSuffix("imported\n")
        } catch {
            for path in temporary { try? await agent.unlink(path) }
            throw error
        }
    }

    // MARK: SpringBoard and launchd

    /// launchd's KeepAlive brings SpringBoard straight back.
    func respring() async throws { try await agent.spawn([Self.launchctl, "stop", "com.apple.SpringBoard"]) }

    /// launchd owns and relaunches lockdownd.
    func reconnectManagement() async throws { try await agent.spawn([Self.launchctl, "stop", "com.apple.mobile.lockdown"]) }

    /// SpringBoardServices' launch, the same path a tap on the icon takes. It
    /// refuses a locked device, which lockstatus then tells apart.
    func launch(_ bundleID: String) async throws {
        do { try await agent.launch(bundleID) }
        catch is CancellationError { throw CancellationError() }
        catch {
            logEvent("launch \(bundleID): \(error.localizedDescription)")
            if (try? await agent.isLocked()) == true { throw AppLaunchError.locked }
            throw AppLaunchError.failed
        }
    }

    func foregroundAppName() async throws -> String? {
        let name = try await agent.frontmost().name.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? nil : String(name.prefix(200))
    }

    // MARK: Component upgrade (images without the loader)

    /// The app's copies of the components it keeps current on a legacy image.
    struct Components {
        var engine: URL
        var agent: URL
        var typing: URL
    }

    /// Upgrade an image that has no guest-package loader in place: the agent
    /// (at the path its own launch job names), it_typein, the GL engine and
    /// SpringBoard's environment, plus the old lock-disabling preferences.
    /// Reloads SpringBoard after a change; the caller waits for it to answer.
    /// A packaged image is the loader's to keep current, so nothing happens.
    func updateComponents(_ bundled: Components) async throws -> Bool {
        guard !packaged else { return false }
        guard await agent.waitAlive(seconds: 30) else {
            throw DeviceToolsError.failed("The device's guest agent did not start.")
        }
        let engineData = try Data(contentsOf: bundled.engine)
        let agentData = try Data(contentsOf: bundled.agent)
        let typingData = try Data(contentsOf: bundled.typing)
        guard [engineData, agentData, typingData].allSatisfy({ !$0.isEmpty && $0.count <= 250_000 }) else {
            throw DeviceToolsError.failed("The bundled guest components are invalid.")
        }
        var guest: [String: Data] = [:]
        for path in [Self.springBoardPreferences, Self.springBoardJob, Self.engine, Self.typing, Self.agentJob, Self.legacyClipboardJob] {
            try Task.checkCancellation()
            guest[path] = try await agent.get(path)
        }
        // Where this image runs its agent from: its own job says. Under the
        // loader's package it is not ours to replace.
        let agentPath = (guest[Self.agentJob].flatMap {
            try? PropertyListSerialization.propertyList(from: $0, format: nil) as? [String: Any]
        }?["ProgramArguments"] as? [String])?.first
        var changedAgent = false
        if let agentPath, agentPath.hasPrefix("/"), !agentPath.hasPrefix("/usr/local/lighttouch/") {
            let running = try await agent.get(agentPath)
            let version = try await agent.capabilities().version
            // Never replace an agent with an older one (a development build can
            // resolve a stale checkout's copy).
            changedAgent = running != agentData && Self.agentVersion(agentData) >= version
            if changedAgent {
                try await agent.put(agentPath, mode: 0o755, agentData)
            }
        }
        let newPreferences = try Self.lockButtonPreferences(guest[Self.springBoardPreferences] ?? Data())
        let newPlist = try Self.mediaLaunchConfiguration(guest[Self.springBoardJob] ?? Data(), includeTyping: true)
        let changedEngine = guest[Self.engine] != engineData
        let changedTyping = guest[Self.typing] != typingData
        // put is atomic (mkstemp beside the file, fsync, rename): a torn engine
        // or job never reaches the next boot.
        if changedTyping { try await agent.put(Self.typing, mode: 0o755, typingData) }
        if changedEngine { try await agent.put(Self.engine, mode: 0o755, engineData) }
        if let newPlist { try await agent.put(Self.springBoardJob, mode: 0o644, newPlist) }
        if guest[Self.legacyClipboardJob] != nil {
            // Two clipboard daemons must never compete; stock launchctl, no shell.
            _ = try? await agent.spawn([Self.launchctl, "unload", Self.legacyClipboardJob])
            try await agent.unlink(Self.legacyClipboardJob)
        }
        if changedAgent {
            // A daemon can't reload its own job, but it can be stopped: KeepAlive
            // relaunches the new binary, which claims the channel ~11 s later.
            // The reply is ECONNRESET from the daemon that stopped.
            _ = try? await agent.spawn([Self.launchctl, "stop", "com.qemu.it-agent"])
            agent.cache.reset()
            try? await Task.sleep(for: .seconds(2))
            guard await agent.waitAlive(seconds: 40) else {
                throw DeviceToolsError.failed("The upgraded guest agent did not start.")
            }
            logEvent("media: guest agent upgraded (v\((try? await agent.capabilities().version) ?? 0))")
        }
        let changed = changedEngine || changedTyping || newPlist != nil || newPreferences != nil
        if changed { try await reloadSpringBoard(preferences: newPreferences) }
        return changed || changedAgent
    }

    /// Host-sequenced, as the old shell trap was: stop SpringBoard (it can
    /// flush its cached preferences on exit), replace them, and always load
    /// the job again, even if the replacement failed.
    private func reloadSpringBoard(preferences: Data?) async throws {
        try Task.checkCancellation()
        try await agent.sync()
        try await agent.spawn([Self.launchctl, "unload", Self.springBoardJob])
        var failure: Error?
        if let preferences {
            do {
                try await agent.put(Self.springBoardPreferences, mode: 0o600, preferences)
                try await agent.chown(501, 501, Self.springBoardPreferences)
            } catch { failure = error }
        }
        try await agent.spawn([Self.launchctl, "load", Self.springBoardJob])
        try await agent.sync()
        if let failure { throw failure }
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

    /// "it_agent v<N>" inside the binary; 0 when it has none.
    static func agentVersion(_ binary: Data) -> Int {
        guard let range = binary.range(of: Data("it_agent v".utf8)) else { return 0 }
        return Int(String(decoding: binary[range.upperBound...].prefix { $0 >= 0x30 && $0 <= 0x39 }, as: UTF8.self)) ?? 0
    }

    // MARK: Stock lockdown

    /// The guest's time zone through the lockdown-tz child process — a child ON
    /// PURPOSE: lockdownd_set_value in-process corrupts the app's heap against
    /// 3.1.3's lockdownd (memory lockdown-setvalue-trap). The tool reads first,
    /// sets only on a mismatch and prints the zone in effect.
    static func setTimeZone(_ identifier: String, tool: String, socket: String) async throws -> String {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: tool)
        task.arguments = [identifier]
        task.environment = ProcessInfo.processInfo.environment.merging(["USBMUXD_SOCKET_ADDRESS": socket]) { $1 }
        let output = Pipe(), error = Pipe()
        task.standardOutput = output
        task.standardError = error
        task.standardInput = FileHandle.nullDevice
        let status: Int32 = try await withCheckedThrowingContinuation { done in
            task.terminationHandler = { done.resume(returning: $0.terminationStatus) }
            do { try task.run() } catch { task.terminationHandler = nil; done.resume(throwing: error) }
        }
        let out = String(decoding: output.fileHandleForReading.readDataToEndOfFile().prefix(1024), as: UTF8.self)
        guard status == 0 else {
            let err = String(decoding: error.fileHandleForReading.readDataToEndOfFile().prefix(1024), as: UTF8.self)
            throw DeviceToolsError.failed("Could not set the device timezone. \(err)")
        }
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
