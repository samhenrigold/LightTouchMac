import HostRuntime
// The app <-> LightTouchDevice wire protocol (docs/multi-device-plan.md, section A).
//
// Control travels over a socketpair (the helper's end is fd 3) as length-framed
// JSON: a 4-byte big-endian length, then one `AppMessage` or `HelperMessage`.
// Frames and status never cross it: they live in IOSurfaces (SharedStatus.swift)
// whose Mach ports arrive in the rendezvous hello (DeviceRendezvous.swift).
//
// Imported by the GUI, helper and standalone clients through DeviceRuntime.

import Foundation

nonisolated public enum DeviceLinkWire {
    /// Bumped on any incompatible change to the messages below, the status block
    /// layout or the Mach hello. The helper refuses a hello with another version.
    public static let protocolVersion = 1
    /// The helper's hello refusal when another helper holds the device's lease; the app shows it as is.
    public static let leaseRefusal = "This device is in use by another copy of Light Touch."
    /// Upper bound on one framed message, either direction. An agent request is
    /// at most ~350 KB of base64 and an audio event ~22 KB; anything bigger is
    /// a bug or an attack, and closes the link.
    public static let maxMessageBytes = 4 << 20
}

// MARK: - Messages

/// App -> helper.
nonisolated public enum AppMessage: Codable, Sendable {
    /// Fire-and-forget, applied in order.
    case command(LinkCommand)
    /// Answered by exactly one `HelperMessage.reply` with the same id.
    case request(id: UInt64, LinkRequest)
}

/// Helper -> app.
nonisolated public enum HelperMessage: Codable, Sendable {
    case reply(id: UInt64, LinkReply)
    case event(LinkEvent)
}

nonisolated public enum MachineOp: String, Codable, Sendable {
    case pause, resume, reset, powerdown, quit
}

nonisolated public enum LinkCommand: Codable, Sendable, Equatable {
    /// qemu_ios_ui_touch; phase is QEMU_IOS_TOUCH_*; x, y normalised, y down.
    case touch(slot: Int, phase: Int, x: Double, y: Double)
    case touch2(phase: Int, x: Double, y: Double)
    /// QEMU_IOS_BUTTON_*.
    case button(Int, down: Bool)
    case key(macKeyCode: Int, down: Bool)
    case rotate(clockwise: Bool)
    case shake
    case attitude(pitch: Double, roll: Double, pose: Int)
    case paste(String)
    case machine(MachineOp)
    /// qemu_ios_snapshot_save2; poll `LinkRequest.snapshotStatus`.
    case snapshotSave(path: String)
    case snapshotResume
    case agentCancel(id: String)
    case audioStop(generation: UInt64)
    /// qemu_ios_ui_net_restrict on the wifi0 user netdev: flip slirp's restrict
    /// flag in place (false opens outbound networking after Setup, no link event).
    case netRestrict(Bool)
}

nonisolated public enum LinkRequest: Codable, Sendable, Equatable {
    /// Always first. `machine` selects the reply's `deviceInfo`.
    case hello(protocolVersion: Int, machine: String?)
    /// Starts qemu_ios_main once; `.ok(true)` when the QEMU thread is running.
    case boot(BootConfig)
    /// -> `.snapshot(status:error:)`, QemuIosSnapshotStatus values.
    case snapshotStatus
    /// One qemu_ios_agent_request wire string ("<id> <op> <args>\n<base64>").
    /// The helper polls for the result with the same id, frees it and replies
    /// `.agent(result)`, or `.agent(nil)` after `deadline` seconds (and cancels it).
    /// `deadline <= 0` only submits: `.ok(submitted)` (the halt request).
    /// `.failure` if the queue refused it.
    case agent(request: String, deadline: Double)
    /// -> `.audio(generation:)`, then `.audio` events until `audioStop`.
    case audioStart
    case battery(level: Int, charging: Int)
    case usbConnection(Bool)
    case compass(Int)
    case usbCharger(Bool)
    case orientation(Int)
    /// Generic automation in guest virtual milliseconds; optional dylib ABI.
    case inputSequence(id: UInt64, events: [VirtualInputEvent])
    case inputSequenceStatus(id: UInt64)
    case inputSequenceCancel(id: UInt64)
}

nonisolated public enum LinkReply: Codable, Sendable, Equatable {
    case hello(HelperInfo)
    case ok(Bool)
    case snapshot(status: Int, error: String?)
    case agent(String?)
    case audio(generation: UInt64)
    case failure(String)
    case inputSequenceStatus(Int)
}

nonisolated public enum LinkEvent: Codable, Sendable, Equatable {
    /// qemu_ios_main returned; the helper exits with this code right after.
    case qemuExited(Int32)
    /// 44100 Hz stereo S16LE. Empty `pcm` with `seconds >= 0` marks silence through `seconds`.
    case audio(generation: UInt64, seconds: Double, pcm: Data)
    /// No more events for this generation: drained after `audioStop` (failed
    /// false), or the capture stopped or overflowed on its own (failed true).
    case audioEnded(generation: UInt64, failed: Bool)
}

nonisolated public struct DeviceInfo: Codable, Sendable, Equatable {
    public var machine: String
    public var screenWidth: Int
    public var screenHeight: Int
    public var screenScale: Int
    public var defaultOrientation: Int
    public var hasCellular: Bool
    public init(machine: String, screenWidth: Int, screenHeight: Int, screenScale: Int, defaultOrientation: Int, hasCellular: Bool) {
        self.machine = machine
        self.screenWidth = screenWidth
        self.screenHeight = screenHeight
        self.screenScale = screenScale
        self.defaultOrientation = defaultOrientation
        self.hasCellular = hasCellular
    }
}

nonisolated public struct HelperInfo: Codable, Sendable, Equatable {
    public var protocolVersion: Int
    public var pid: Int32
    /// The libqemu-arm.dylib the helper loaded, and its mtime (seconds since 1970).
    public var dylibPath: String
    public var dylibModified: Double
    /// qemu_ios_build_id(): the loaded Mach-O's UUID.
    public var buildID: String?
    /// qemu_ios_device_info(hello.machine).
    public var deviceInfo: DeviceInfo?
    /// The helper rechecks admitted storage under its lease before boot.
    public var storageProofValidation: Bool?
    public init(protocolVersion: Int, pid: Int32, dylibPath: String, dylibModified: Double, buildID: String? = nil, deviceInfo: DeviceInfo? = nil, storageProofValidation: Bool? = nil) {
        self.protocolVersion = protocolVersion
        self.pid = pid
        self.dylibPath = dylibPath
        self.dylibModified = dylibModified
        self.buildID = buildID
        self.deviceInfo = deviceInfo
        self.storageProofValidation = storageProofValidation
    }
}

// MARK: - Framing

nonisolated public enum DeviceLinkWireError: Error, Equatable {
    case oversized(Int)
    case malformed(String)
}

/// One end of the socketpair: framed messages in, framed messages out.
///
/// Reads run on a dispatch read source; writes go through a private serial
/// queue, so a wedged peer can never block the caller (the app's main thread).
/// `onClose` fires once: EOF, a read error, or a protocol violation.
nonisolated public final class LinkChannel<Incoming: Decodable, Outgoing: Encodable>: @unchecked Sendable {
    public let fd: Int32
    private let source: DispatchSourceRead
    private let writeQueue: DispatchQueue
    private let queue: DispatchQueue
    private var buffer = Data()
    private var closed = false          // on `queue`
    private let lock = NSLock()
    private var writeFailed = false     // under lock

    public init(fd: Int32, queue: DispatchQueue, onMessage: @escaping (Incoming) -> Void,
         onClose: @escaping (Error?) -> Void) {
        self.fd = fd
        self.queue = queue
        self.onMessage = onMessage
        writeQueue = DispatchQueue(label: "LightTouch.link.write.\(fd)")
        var size: Int32 = 1 << 20
        setsockopt(fd, SOL_SOCKET, SO_SNDBUF, &size, socklen_t(MemoryLayout<Int32>.size))
        setsockopt(fd, SOL_SOCKET, SO_RCVBUF, &size, socklen_t(MemoryLayout<Int32>.size))
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [unowned self] in
            var chunk = [UInt8](repeating: 0, count: 65536)
            let n = read(fd, &chunk, chunk.count)
            if n < 0, errno == EAGAIN || errno == EINTR { return }
            if n <= 0 { finish(n == 0 ? nil : POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)); return }
            buffer.append(contentsOf: chunk[0..<n])
            deliverFrames()
        }
        onCloseHandler = onClose
        source.setCancelHandler { Darwin.close(fd) }
        source.resume()
    }

    private var onCloseHandler: ((Error?) -> Void)?
    private let onMessage: (Incoming) -> Void

    private func deliverFrames() {
        do {
            while let body = try Self.takeFrame(&buffer) {
                let message = try JSONDecoder().decode(Incoming.self, from: body)
                onMessage(message)
                if closed { return }
            }
        } catch {
            finish(error)
        }
    }

    /// The peer is gone: deliver what it wrote before exiting (its last messages may
    /// still sit in the socket, the read source not yet run) so they land before the
    /// channel closes. On `queue`; never blocks (reads only what poll reports ready).
    public func drainIncoming() {
        var chunk = [UInt8](repeating: 0, count: 65536)
        while !closed {
            var ready = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            guard poll(&ready, 1, 0) > 0, ready.revents & Int16(POLLIN | POLLHUP) != 0 else { return }
            let n = read(fd, &chunk, chunk.count)
            guard n > 0 else { return }
            buffer.append(contentsOf: chunk[0..<n])
            deliverFrames()
        }
    }

    private func finish(_ error: Error?) {
        guard !closed else { return }
        closed = true
        source.cancel()
        let handler = onCloseHandler
        onCloseHandler = nil
        handler?(error)
    }

    /// Close from any thread; `onClose` still fires once, on the channel's queue.
    public func close() { queue.async { self.finish(nil) } }

    /// Encode and enqueue. False if the message is over the bound (not sent).
    @discardableResult
    public func send(_ message: Outgoing) -> Bool {
        guard let frame = try? Self.frame(message) else { return false }
        writeQueue.async { [self] in
            lock.lock(); let failed = writeFailed; lock.unlock()
            guard !failed else { return }
            if !Self.writeAll(fd, frame) { lock.lock(); writeFailed = true; lock.unlock() }
        }
        return true
    }

    /// Blocks until everything queued so far has been written (the helper's exit path).
    public func drain(timeout: TimeInterval = 2) {
        let done = DispatchSemaphore(value: 0)
        writeQueue.async { done.signal() }
        _ = done.wait(timeout: .now() + timeout)
    }

    public static func frame(_ message: Outgoing) throws -> Data {
        let body = try JSONEncoder().encode(message)
        guard body.count <= DeviceLinkWire.maxMessageBytes else { throw DeviceLinkWireError.oversized(body.count) }
        var length = UInt32(body.count).bigEndian
        var frame = Data(bytes: &length, count: 4)
        frame.append(body)
        return frame
    }

    /// The next whole frame's body, or nil if more bytes are needed.
    public static func takeFrame(_ buffer: inout Data) throws -> Data? {
        guard buffer.count >= 4 else { return nil }
        let start = buffer.startIndex
        let length = buffer[start..<start + 4].reduce(0) { $0 << 8 | Int($1) }
        guard length <= DeviceLinkWire.maxMessageBytes else { throw DeviceLinkWireError.oversized(length) }
        guard buffer.count >= 4 + length else { return nil }
        let body = buffer.subdata(in: start + 4..<start + 4 + length)
        buffer.removeSubrange(start..<start + 4 + length)
        return body
    }

    private static func writeAll(_ fd: Int32, _ data: Data) -> Bool {
        data.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                let n = write(fd, raw.baseAddress! + offset, raw.count - offset)
                if n < 0, errno == EINTR { continue }
                if n <= 0 { return false }
                offset += n
            }
            return true
        }
    }
}

/// Host-authored physical input only. QEMU owns execution deadlines and pins.
nonisolated public struct VirtualInputEvent: Codable, Sendable, Equatable {
    public var atMilliseconds: Int64
    public var kind: Int32
    public var value: Int32
    public var phase: Int32
    public var x: Double
    public var y: Double

    public static func button(_ button: Int32, down: Bool, at: Int64) -> Self {
        .init(atMilliseconds: at, kind: 0, value: button, phase: down ? 1 : 0, x: 0, y: 0)
    }
    public static func touch(phase: Int32, x: Double, y: Double, at: Int64) -> Self {
        .init(atMilliseconds: at, kind: 1, value: 0, phase: phase, x: x, y: y)
    }
    public static func valid(_ events: [Self]) -> Bool {
        guard !events.isEmpty, events.count <= 256 else { return false }
        var buttons = [Bool](repeating: false, count: 4), touch = false
        var previous: Int64 = 0
        for event in events {
            guard event.atMilliseconds >= previous, event.atMilliseconds <= 600_000 else { return false }
            previous = event.atMilliseconds
            if event.kind == 0 {
                guard (0...3).contains(event.value), (0...1).contains(event.phase),
                      buttons[Int(event.value)] != (event.phase == 1) else { return false }
                buttons[Int(event.value)] = event.phase == 1
            } else if event.kind == 1 {
                guard event.value == 0, (0...2).contains(event.phase),
                      event.x.isFinite, event.y.isFinite,
                      (0...1).contains(event.x), (0...1).contains(event.y),
                      event.phase == 0 ? !touch : touch else { return false }
                touch = event.phase != 2
            } else { return false }
        }
        return !touch && !buttons.contains(true)
    }
}
