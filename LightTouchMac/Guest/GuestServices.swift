// Guest services without a shell (qemu-ios docs/archive/guest-services-plan.md, P2).
//
// Everything the app asks of a running iPod goes through the guest agent's
// typed v2 ops (contrib/it-agent/README.md): spawn with no shell, put/get,
// chown/unlink, sync, launch, frontmost, lockstatus, orientation, dlicon,
// halt. Stock lockdown services (installs, AFC, the time zone through the
// lockdown-tz child process) are DeviceServices (Services/).
//
// Capabilities come from the agent's ping: a v2 agent lists its ops; a v1
// agent (older images, which still carry freeze's /bin/sh) answers only its
// version, and each op it lacks falls back here to its `exec` with the same
// command a shell would have run. No SSH anywhere.
//
// Foundation only, so tests/drivers/session-driver compiles it as the app does.

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
            return "A component (\(t)) is missing from this copy of Light Touch. Reinstall Light Touch."
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
    /// The alert's words; `description` (what logs interpolate) keeps the status and output.
    var errorDescription: String? { "The device couldn’t complete the request. Open Device Logs for details." }
    var description: String { "agent \(operation) failed (\(status)): \(String(decoding: output.prefix(4096), as: UTF8.self))" }
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
        guard let link, isAlive else { throw DeviceToolsError.failed("The device isn’t ready yet. Try again when it has finished starting.") }
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
            throw DeviceToolsError.failed("The device’s guest tools didn’t respond as expected. Restart the device to update them.")
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
    /// report arrived): its binaries are under `packageBin`.
    var packaged = false

    static let packageBin = "/usr/local/lighttouch/current/bin"
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

    // MARK: Trust

    /// Trust a CA in the guest's own trust store the way a profile install
    /// does, through securityd's API (ittrust: SecTrustStoreSetTrustSettings
    /// in the user domain), with no screen on the device. The package's copy,
    /// or the app's uploaded to /tmp for the one run. Idempotent; the store
    /// keeps it across boots, so nothing asks twice. ittrust adapts at runtime
    /// (dlopen), one source for both arches.
    func trustCertificate(_ der: Data, localTool: (String) throws -> Data) async throws {
        let cert = "/tmp/ltm-ca-\(UUID().uuidString).der"
        try await agent.put(cert, mode: 0o644, der)
        let output: String
        do { output = try await runTool("ittrust", ["add", cert], localTool: localTool) }
        catch { try? await agent.unlink(cert); throw error }
        try? await agent.unlink(cert)
        guard output.contains("Guest trust add: 0") else {
            throw DeviceToolsError.failed("The device did not accept the certificate: \(output)")
        }
    }

    /// The image's baked PAC (/usr/local/share/ltm/proxy.pac: every request to the itwebproxy guestfwd,
    /// DIRECT as fallback) routes the guest through the proxy. An image without it (the legacy iPod
    /// image) goes straight out through slirp, so the trusted CA never sees a request: itproxy points
    /// the Wi-Fi service's HTTP and HTTPS proxies at the guestfwd through configd (idempotent; it keeps
    /// a backup of the keys it owns). The host's "off" mode passes those connections straight through.
    func routeThroughProxy(localTool: (String) throws -> Data) async throws {
        guard try await agent.get(Self.proxyPAC) == nil else { return }
        let output = try await runTool("itproxy", ["on"], localTool: localTool)
        guard output.contains("Proxy enabled") else {
            throw DeviceToolsError.failed("The device did not accept the proxy setting: \(output)")
        }
    }

    static let proxyPAC = "/usr/local/share/ltm/proxy.pac"

    /// A guest tool's output: the package's copy, or the app's uploaded to /tmp for the one run.
    private func runTool(_ name: String, _ arguments: [String], localTool: (String) throws -> Data) async throws -> String {
        if packaged {
            do { return String(decoding: try await agent.spawn(["\(Self.packageBin)/\(name)"] + arguments), as: UTF8.self) }
            catch let error as GuestAgentError where error.status == GuestAgentError.notFound {}
        }
        let executable = "/tmp/ltm-\(name)-\(UUID().uuidString)"
        try await agent.put(executable, mode: 0o755, try localTool(name))
        let output: Data
        do { output = try await agent.spawn([executable] + arguments) }
        catch { try? await agent.unlink(executable); throw error }
        try? await agent.unlink(executable)
        return String(decoding: output, as: UTF8.self)
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
}
