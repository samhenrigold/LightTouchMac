import DeviceRuntime
import Foundation

@testable import LightTouchCore

/// A device link with a fake guest behind it that answers like contrib/it-agent's v2 ops (ping with an op list,
/// spawn with a NUL-separated argv and no shell, put/get/chown/unlink/sync/launch/frontmost/lockstatus/orientation/
/// dlicon/halt) or like a v1 agent (only `it_agent v1`, -ENOSYS for the v2 ops, `exec` through /bin/sh).
nonisolated final class FakeGuestLink: GuestAgentLink, @unchecked Sendable {
    let lock = NSLock()
    var agent = 1, hold = false, version = 2, locked = false, launchFails = false, angle = "90"
    var files: [String: Data] = [:], modes: [String: String] = [:], owners: [String: String] = [:]
    var cancelled: [String] = [], ops: [String] = [], spawns: [[String]] = [], shells: [String] = [], halts = 0
    var spawnOutput: [String: (Int, String)] = [:]
    /// The v4 agent's live ops (it_agent v4): what statusbar and cadebug were sent.
    var v4 = false, statusBars: [Data] = [], caDebug: [String] = []
    /// A v5 agent's statusbarget: what SpringBoard holds (the last post; nil after a respring, read as zeros).
    var v5 = false, held: Data?
    var failPut: String?
    /// Bytes `getrange` handed out: a get over 1 MiB comes in ranges, as it_agent's EFBIG makes it.
    var rangeBytes = 0
    var waiting: [String: CheckedContinuation<LinkReply, Error>] = [:]

    init(version: Int = 2) { self.version = version }

    var agentStatus: Int? { lock.withLock { agent } }
    /// A v6 agent's report of the guest; nil for the agents before it, which are asked.
    var report: String?
    /// SpringBoard refuses this many launches (another app is still closing) before it takes one.
    var launchesRefused = 0
    /// The `type` op: what was typed, the status it answers, or no answer at all (its deadline passes).
    var typed: [String] = [], typeStatus = 0, typeUnanswered = false, types = false
    var agentReport: String? { lock.withLock { report } }

    func send(_ command: LinkCommand) {
        guard case .agentCancel(let id) = command else { return }
        let c: CheckedContinuation<LinkReply, Error>? = lock.withLock {
            cancelled.append(id)
            return waiting.removeValue(forKey: id)
        }
        c?.resume(returning: .agent(nil))
    }

    static let v2ops = [
        "exec", "spawn", "sync", "put", "get", "chown", "unlink", "launch", "frontmost", "lockstatus", "orientation",
        "dlicon", "halt"
    ]

    private func answer(_ op: String, _ args: String, _ body: Data) -> (Int, Data) {
        let v2only: Set<String> = ["spawn", "sync", "chown", "unlink", "dlicon"]
        if version == 1 && v2only.contains(op) { return (-78, Data()) }
        switch op {
        case "ping":
            return (
                0,
                Data(
                    (version == 2
                        ? "it_agent v\(v4 ? 4 : 2)\nops ping "
                            + (Self.v2ops + (v4 ? ["cadebug", "statusbar"] : []) + (v5 ? ["statusbarget"] : [])
                            + (types ? ["type"] : []))
                            .joined(separator: " ") + "\n" : "it_agent v1\n").utf8
                )
            )
        case "spawn":
            precondition(body.last == 0, "argv is NUL-terminated")
            let argv = body.split(separator: 0, omittingEmptySubsequences: false).dropLast().map {
                String(decoding: $0, as: UTF8.self)
            }
            spawns.append(argv)
            precondition(argv[0].hasPrefix("/"), "argv[0] absolute")
            if let (status, out) = spawnOutput[argv[0]] { return (status, Data(out.utf8)) }
            if argv[0].hasPrefix("/tmp/") && files[argv[0]] == nil { return (-2, Data()) }
            if argv[0].hasPrefix("/usr/local/lighttouch/") && files[argv[0]] == nil { return (-2, Data()) }
            return (0, Data())
        case "exec":
            shells.append(args)
            return (0, Data())
        case "sync": return (0, Data())
        case "put":
            let words = args.split(separator: " ")
            let path = words.dropLast().joined(separator: " ")
            if path == failPut { return (-28, Data()) }
            files[path] = body
            modes[path] = String(words.last!)
            owners[path] = "0:0"
            return (0, Data())
        case "get":
            guard let file = files[args] else { return (-2, Data()) }
            return file.count > 1024 * 1024 ? (-27, Data()) : (0, file)
        case "getrange":
            let w = args.split(separator: " ", maxSplits: 2).map(String.init)
            guard let file = files[w[2]], let offset = Int(w[0]), let length = Int(w[1]) else { return (-2, Data()) }
            let piece = file.dropFirst(offset).prefix(length)
            rangeBytes += piece.count
            return (0, Data(piece))
        case "chown":
            let w = args.split(separator: " ", maxSplits: 2).map(String.init)
            owners[w[2]] = w[0] + ":" + w[1]
            return (0, Data())
        case "unlink": return files.removeValue(forKey: args) == nil ? (-2, Data()) : (0, Data())
        case "type":
            if typeStatus == 0 { typed.append(String(decoding: body, as: UTF8.self)) }
            return (typeStatus, Data())
        case "launch":
            if launchFails { return (-1, Data()) }
            if launchesRefused > 0 {
                launchesRefused -= 1
                return (7, Data())
            }
            return (0, Data())
        case "lockstatus": return (0, Data("locked=\(locked ? 1 : 0) passcode=0\n".utf8))
        case "frontmost":
            return (0, Data((locked ? "com.apple.springboard\nLock Screen\n" : "com.example.game\nGame\n").utf8))
        case "orientation": return (0, Data((angle + "\n").utf8))
        case "dlicon": return (0, Data())
        case "statusbar":
            statusBars.append(body)
            held = body
            return (0, Data())
        case "statusbarget":
            let size = Int(args.split(separator: " ")[1])!
            return (0, held.map { $0.prefix(size) } ?? Data(count: size))
        case "cadebug":
            caDebug.append(args)
            return (0, Data("0x0\n".utf8))
        default: preconditionFailure(op)
        }
    }

    func request(_ request: LinkRequest, timeout: TimeInterval) async throws -> LinkReply {
        guard case .agent(let wire, let deadline) = request else { fatalError("not an agent request") }
        let lines = wire.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
        let header = lines[0].split(separator: " ", maxSplits: 2, omittingEmptySubsequences: false)
        let id = String(header[0])
        let op = String(header[1])
        let args = header.count > 2 ? String(header[2]) : ""
        let body = Data(base64Encoded: String(lines[1]))!
        lock.withLock { ops.append(op) }
        if deadline <= 0 {
            precondition(op == "halt")
            lock.withLock { halts += 1 }
            return .ok(true)
        }
        let (status, data) = lock.withLock { answer(op, args, body) }
        if op == "type", lock.withLock({ typeUnanswered }) { return .agent(nil) }
        let reply = "\(id) \(status)\n\(data.base64EncodedString())"
        return try await withCheckedThrowingContinuation { c in
            let held: Bool = lock.withLock {
                waiting[id] = c
                return hold
            }
            guard !held else { return }
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.01) {
                let c: CheckedContinuation<LinkReply, Error>? = self.lock.withLock {
                    self.waiting.removeValue(forKey: id)
                }
                c?.resume(returning: .agent(reply))
            }
        }
    }
}
