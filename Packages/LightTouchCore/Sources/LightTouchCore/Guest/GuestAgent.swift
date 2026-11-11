import DeviceRuntime
import Foundation
import HostServiceWire

// The guest agent's wire (qemu-ios contrib/it-agent/README.md): one request per
// op through the device's helper (LinkRequest.agent), the ping's capabilities
// cached per device, and the typed v2 ops with their v1 `exec` fallbacks. The
// app's operations on top of it are GuestServices.
//
// Foundation only, so tests/drivers/session-driver compiles it as the app does.

/// A command the agent ran and refused, with its (negative errno or exit) status.
public nonisolated struct GuestAgentError: LocalizedError, CustomStringConvertible {
    public let operation: String
    public let status: Int
    public let output: Data
    public static let notFound = -2, io = -5, tooBig = -27, again = -35, connectionReset = -54, notImplemented = -78
    /// The alert's words; `description` (what logs interpolate) keeps the status and output.
    public var errorDescription: String? { "The device couldn’t do that. Try again." }
    public var description: String {
        "agent \(operation) failed (\(status)): \(String(decoding: output.prefix(4096), as: UTF8.self))"
    }
}

/// What `ping` said: `it_agent v2\nops …` or a v1's bare `it_agent v1`.
public nonisolated struct GuestAgentCapabilities: Sendable, Equatable {
    public var version: Int
    public var ops: Set<String>

    public static func parse(_ reply: String) -> GuestAgentCapabilities? {
        let lines = reply.split(separator: "\n")
        guard let first = lines.first, first.hasPrefix("it_agent v"), let version = Int(first.dropFirst(10)) else {
            return nil
        }
        let ops =
            lines.first { $0.hasPrefix("ops ") }.map { Set($0.dropFirst(4).split(separator: " ").map(String.init)) }
            ?? []
        return GuestAgentCapabilities(version: version, ops: ops)
    }

    public func has(_ op: String) -> Bool { ops.contains(op) }
}

/// One device's ping result, kept until its agent restarts.
public nonisolated final class GuestAgentCache: @unchecked Sendable {
    public init() {
    }
    private let lock = NSLock()
    private var value: GuestAgentCapabilities?
    public var capabilities: GuestAgentCapabilities? {
        get { lock.withLock { value } }
        set { lock.withLock { value = newValue } }
    }
    public func reset() { capabilities = nil }
}

/// What the agent needs of a device's link: DeviceLink's agent status, report, request and send. Tests stand a fake
/// guest behind it.
public nonisolated protocol GuestAgentLink: AnyObject, Sendable {
    /// 0 absent or not running, 1 alive, 2 stale; nil before the helper published a status.
    var agentStatus: Int? { get }
    /// The agent's latest report of the guest (GuestReport reads it); nil or empty when it has sent none.
    var agentReport: String? { get }
    func request(_ request: LinkRequest, timeout: TimeInterval) async throws -> LinkReply
    func send(_ command: LinkCommand)
}

nonisolated extension DeviceLink: GuestAgentLink {
    public var agentStatus: Int? { status?.agentStatus }
}

/// The guest agent of one device, through its helper (LinkRequest.agent). A
/// submitted request is never retried: a lost reply may follow a mutation.
public nonisolated struct GuestAgent: Sendable {
    public init(link: (any GuestAgentLink)? = nil, cache: GuestAgentCache) {
        self.link = link
        self.cache = cache
    }
    public let link: (any GuestAgentLink)?
    public let cache: GuestAgentCache

    /// 0 absent or not running, 1 alive, 2 stale.
    public var status: Int { link?.agentStatus ?? 0 }
    public var isAlive: Bool { status == 1 }
    /// What a live agent last said of the guest, at most a quarter second old; nil from an agent that doesn't
    /// report (before v6), which is asked instead.
    public var report: GuestReport? { isAlive ? link?.agentReport.flatMap(GuestReport.init) : nil }

    /// The answer a report holds, as the op it stands for would give it: SpringBoard not answering is that op's EIO.
    private func told<Value>(_ operation: String, by report: GuestReport, _ value: Value?) throws -> Value {
        guard report.isAnswering, let value else {
            throw GuestAgentError(
                operation: operation,
                status: GuestAgentError.io,
                output: Data("SpringBoard isn’t answering the guest agent".utf8)
            )
        }
        return value
    }

    // MARK: Wire

    /// Status and body of one op; throws only when no status came back.
    public func raw(
        _ operation: String,
        _ arguments: String = "",
        body: Data = Data(),
        deadline: Double = 65
    ) async throws -> (status: Int, output: Data) {
        guard let link, isAlive else {
            throw DeviceToolsError.failed("The device isn’t ready yet. Try again when it has finished starting.")
        }
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
        case .agent(let wire?):
            // "<id> <status>\n<base64 output>"
            let parts = wire.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
            let header = parts.first?.split(separator: " ", maxSplits: 1) ?? []
            guard parts.count == 2, header.count == 2, header[0] == id, let code = Int(header[1]),
                let output = Data(base64Encoded: String(parts[1]))
            else {
                throw DeviceToolsError.failed("The device returned an invalid command result.")
            }
            return (code, output)
        case .agent(nil): throw DeviceToolsError.failed("The device command timed out; its outcome is unknown.")
        case .failure(let message): throw DeviceToolsError.failed(message)
        default: throw DeviceToolsError.failed("The device returned an invalid command result.")
        }
    }

    /// The output of an op that must succeed.
    @discardableResult
    public func perform(_ operation: String, _ arguments: String = "", body: Data = Data()) async throws -> Data {
        let (status, output) = try await raw(operation, arguments, body: body)
        guard status == 0 else { throw GuestAgentError(operation: operation, status: status, output: output) }
        return output
    }

    public func capabilities() async throws -> GuestAgentCapabilities {
        if let known = cache.capabilities { return known }
        let reply = String(decoding: try await perform("ping"), as: UTF8.self)
        guard let parsed = GuestAgentCapabilities.parse(reply) else {
            throw DeviceToolsError.failed(
                "The device’s guest tools didn’t respond as expected. Restart the device to update them."
            )
        }
        cache.capabilities = parsed
        return parsed
    }

    /// v1 fallback: the agent's exec runs `/bin/sh -c`, which only v1 images have.
    @discardableResult
    private func shell(_ command: String, body: Data = Data()) async throws -> Data {
        try await perform("exec", command, body: body)
    }

    public static func quote(_ word: String) -> String { "'" + word.replacingOccurrences(of: "'", with: "'\\''") + "'" }

    // MARK: Typed ops

    /// argv[0] absolute; no shell. The child's stdout+stderr on success.
    @discardableResult
    public func spawn(_ argv: [String]) async throws -> Data {
        guard try await capabilities().has("spawn") else {
            return try await shell(argv.map(Self.quote).joined(separator: " "))
        }
        return try await perform("spawn", body: Data(argv.map { $0 + "\u{0}" }.joined().utf8))
    }

    public func sync() async throws {
        guard try await capabilities().has("sync") else {
            try await shell("sync")
            return
        }
        try await perform("sync")
    }

    /// Atomic (temp beside the path, fsync, rename) and root-owned. Over one
    /// request (256 KiB with its header) it goes as v3 `putpart` chunks, still
    /// renamed into place by the final one.
    public func put(_ path: String, mode: Int, _ data: Data) async throws {
        let octal = String(mode, radix: 8)
        let part = 256 * 1024 - 4097
        guard data.count > part else {
            try await perform("put", "\(path) \(octal)", body: data)
            return
        }
        guard try await capabilities().has("putpart") else {
            throw DeviceToolsError.failed(
                "The device’s guest tools are too old to receive this file. Restart the device to update them."
            )
        }
        var offset = 0
        while offset < data.count {
            let end = min(offset + part, data.count)
            try await perform(
                "putpart",
                "\(offset) \(end == data.count ? 1 : 0) \(octal) \(path)",
                body: Data(data[(data.startIndex + offset)..<(data.startIndex + end)])
            )
            offset = end
        }
    }

    /// A regular file of at most `limit` bytes (past 1 MiB by `getrange`); nil when absent. The guest decides what's
    /// at `path` and how big it is, so every read names the most its purpose needs; a larger file throws, having read
    /// no more than `limit` + 1 bytes of it.
    public func get(_ path: String, limit: Int) async throws -> Data? {
        let piece = 1024 * 1024
        func overLimit() -> GuestAgentError {
            GuestAgentError(
                operation: "get",
                status: GuestAgentError.tooBig,
                output: Data("\(path) is over \(limit) bytes".utf8)
            )
        }
        let (status, output) = try await raw("get", path)
        if status == GuestAgentError.notFound { return nil }
        if status == GuestAgentError.tooBig {
            var data = Data()
            while data.count <= limit {
                let wanted = min(piece, limit + 1 - data.count)
                let next = try await perform("getrange", "\(data.count) \(wanted) \(path)")
                data.append(next.prefix(wanted))
                if next.count < wanted { break }
            }
            guard data.count <= limit else { throw overLimit() }
            return data
        }
        guard status == 0 else { throw GuestAgentError(operation: "get", status: status, output: output) }
        guard output.count <= limit else { throw overLimit() }
        return output
    }

    public func chown(_ uid: Int, _ gid: Int, _ path: String) async throws {
        guard try await capabilities().has("chown") else {
            try await shell("chown \(uid):\(gid) \(Self.quote(path))")
            return
        }
        try await perform("chown", "\(uid) \(gid) \(path)")
    }

    /// Absent is fine.
    public func unlink(_ path: String) async throws {
        guard try await capabilities().has("unlink") else {
            try await shell("rm -f \(Self.quote(path))")
            return
        }
        let (status, output) = try await raw("unlink", path)
        guard status == 0 || status == GuestAgentError.notFound else {
            throw GuestAgentError(operation: "unlink", status: status, output: output)
        }
    }

    public func launch(_ bundleID: String) async throws { try await perform("launch", bundleID) }

    /// SpringBoard's foreground bundle id and localized name; `Lock Screen` when locked. From the agent's report
    /// where it sends one: no request, so nothing to wait for or lose.
    public func frontmost() async throws -> (bundleID: String, name: String) {
        if let report { return try told("frontmost", by: report, report.foreground) }
        let lines = String(decoding: try await perform("frontmost"), as: UTF8.self).split(separator: "\n").map(
            String.init
        )
        return (lines.first ?? "", lines.dropFirst().first ?? "")
    }

    public func isLocked() async throws -> Bool {
        if let report { return try told("lockstatus", by: report, report.isLocked) }
        return String(decoding: try await perform("lockstatus"), as: UTF8.self).contains("locked=1")
    }

    public func orientation() async throws -> Int {
        if let report {
            // An answering SpringBoard whose report names no orientation is firmware without the call, as the op says.
            guard report.uiDegrees != nil || !report.isAnswering else {
                throw GuestAgentError(operation: "orientation", status: GuestAgentError.notImplemented, output: Data())
            }
            return try told("orientation", by: report, report.uiDegrees)
        }
        let text = String(decoding: try await perform("orientation"), as: UTF8.self)
        guard let degrees = Int(text.trimmingCharacters(in: .whitespacesAndNewlines)),
            [0, 90, 180, -90].contains(degrees)
        else {
            throw DeviceToolsError.failed("The device returned an invalid orientation.")
        }
        return degrees
    }

    /// The home screen's "Waiting…" placeholder; false when this agent has no dlicon (v1).
    @discardableResult
    public func placeholder(_ action: String, id: String, bundleID: String? = nil) async throws -> Bool {
        guard try await capabilities().has("dlicon") else { return false }
        try await perform(
            "dlicon",
            ([action, id] + (action == "add" ? [bundleID].compactMap { $0 } : [])).joined(separator: " ")
        )
        return true
    }

    /// Submit only (deadline 0): the halt takes the agent down with the guest.
    public func requestHalt() async -> Bool {
        guard let link, isAlive else { return false }
        let reply = try? await link.request(.agent(request: "\(UUID().uuidString) halt \n", deadline: 0), timeout: 5)
        return reply == .ok(true)
    }

    /// Waits until the agent's report (which follows the guest within a quarter second) meets `condition`: a wait
    /// for the fact, not for a time. False at `seconds`, on cancellation, or from an agent that doesn't report.
    public func waitForReport(seconds: Double, _ condition: (GuestReport) -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + .seconds(seconds)
        while !Task.isCancelled, let report {
            if condition(report) { return true }
            guard ContinuousClock.now < deadline else { return false }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return false
    }

    /// Wait for a (re)started agent to claim the channel.
    public func waitAlive(seconds: Double) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while !Task.isCancelled, Date() < deadline {
            if isAlive { return true }
            try? await Task.sleep(for: .milliseconds(250))
        }
        return !Task.isCancelled && isAlive
    }
}
