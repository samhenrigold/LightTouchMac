import HostRuntime
// The app's handle on one running LightTouchDevice helper.
//
//     let link = DeviceLink(configuration: .init(instance: id, outputDescriptor: capture.writeDescriptor))
//     link.onEvent = { event in … }                  // .qemuExited, .audio…
//     link.onInvalidated = { error in … }            // link lost (EOF, bad hello, protocol)
//     link.onTerminated = { termination in … }       // the helper process is gone
//     link.start { result in                          // spawn + rendezvous + hello
//         guard case .success(let info) = result else { … }
//         link.request(.boot(config)) { … }
//     }
//     link.send(.touch(slot: 0, phase: 0, x: 0.5, y: 0.5))
//     let status = link.status                        // SharedStatus?, synchronous
//     if let frame = link.frontSurface(), frame.isNew { layer.contents = frame.surface }
//
// Every callback runs on `queue` (main by default). All methods may be called
// from any thread except `frontSurface()`, which belongs to one reader.

import Foundation
import IOSurface
import LTMLinkC

nonisolated enum DeviceLinkError: Error, Equatable, CustomStringConvertible {
    case spawnFailed(Int32)
    case rendezvous(String)
    case rejected(String)
    case timedOut
    case protocolMismatch(helper: Int)
    case helperFailure(String)
    case closed(String)

    var description: String {
        switch self {
        case .spawnFailed(let e): "could not start the device helper (\(String(cString: strerror(e))))"
        case .rendezvous(let s): "device helper rendezvous failed: \(s)"
        case .rejected(let s): "device helper rejected: \(s)"
        case .timedOut: "the device helper did not answer in time"
        case .protocolMismatch(let v): "device helper speaks protocol \(v), expected \(DeviceLinkWire.protocolVersion)"
        case .helperFailure(let s): s
        case .closed(let s): "device helper link closed: \(s)"
        }
    }
}

nonisolated enum DeviceTermination: Sendable, Equatable {
    case exited(Int32)
    case signaled(Int32)
    /// Someone else reaped it; the status is lost.
    case unknown
}

nonisolated final class DeviceLink: @unchecked Sendable {
    struct Configuration: Sendable {
        /// Contents/MacOS/LightTouchDevice beside the running executable.
        var helper: URL = Bundle.main.executableURL!.deletingLastPathComponent()
            .appendingPathComponent("LightTouchDevice")
        var instance: UUID
        /// The helper's stdout + stderr, e.g. ProcessLogCapture.writeDescriptor
        /// for Devices/<uuid>/native.log. -1: /dev/null.
        var outputDescriptor: Int32 = -1
        /// Development: the libqemu-arm.dylib to load (LTM_QEMU_DYLIB). nil: the
        /// helper's own @executable_path/../Frameworks, then its build rpath.
        var dylib: String? = nil
        /// Extra environment for the helper process (QEMU's boot env goes in BootConfig).
        var environment: [String: String] = [:]
        /// Machine for hello's deviceInfo.
        var machine: String? = nil
        /// Code requirement for the helper; nil = DeviceRendezvous.defaultRequirement.
        var requirement: String? = nil
        /// Spawn -> valid Mach hello + hello reply.
        var connectTimeout: TimeInterval = 15
        /// Extra helper arguments (tests).
        var arguments: [String] = []

        init(instance: UUID, outputDescriptor: Int32 = -1) {
            self.instance = instance
            self.outputDescriptor = outputDescriptor
        }
    }

    let configuration: Configuration
    let queue: DispatchQueue

    var onEvent: ((LinkEvent) -> Void)?
    /// The link is unusable (fires once). The process may still be exiting.
    var onInvalidated: ((DeviceLinkError) -> Void)?
    /// The helper process is gone (fires once, after onInvalidated if the link was up).
    var onTerminated: ((DeviceTermination) -> Void)?

    private let lock = NSLock()
    private var _pid: pid_t = 0
    private var channel: LinkChannel<HelperMessage, AppMessage>?
    private var statusBlock: StatusBlock?
    private var ring: FrameRingReader?
    private var _info: HelperInfo?
    private var nextID: UInt64 = 1
    typealias Reply = (Result<LinkReply, DeviceLinkError>) -> Void
    private struct Pending: @unchecked Sendable {
        let timer: DispatchWorkItem
        let reply: Reply
    }
    private var pending: [UInt64: Pending] = [:]
    private var invalidated = false
    private var startCompletion: ((Result<HelperInfo, DeviceLinkError>) -> Void)?
    private var exitSource: DispatchSourceProcess?

    init(configuration: Configuration, queue: DispatchQueue = .main) {
        self.configuration = configuration
        self.queue = queue
    }

    /// Dropping the link closes the socket: the helper sees EOF and shuts down cleanly.
    deinit {
        channel?.close()
        exitSource?.cancel()
        if _pid > 0 { DeviceRendezvousServer.shared.unregister(_pid) }
    }

    var pid: pid_t { lock.withLock { _pid } }
    /// The hello reply: protocol, dylib path + mtime, build id, device info.
    var info: HelperInfo? { lock.withLock { _info } }
    /// The status block, read now. nil until the helper's first hello.
    var status: SharedStatus? { lock.withLock { statusBlock }?.snapshot() }

    /// The front frame surface. `isNew` when it changed since the last call.
    /// Call from one thread only (the display link); hold the surface, not the tuple.
    func frontSurface() -> (surface: IOSurface, serial: UInt64, isNew: Bool)? {
        lock.withLock { ring }?.front()
    }

    // MARK: Start

    /// Spawn the helper and connect. Completes once, on `queue`.
    func start(completion: @escaping (Result<HelperInfo, DeviceLinkError>) -> Void) {
        let server = DeviceRendezvousServer.shared
        let kr = server.start()
        guard kr == 0 else { return queue.async { completion(.failure(.rendezvous("bootstrap_check_in: \(kr)"))) } }
        guard let requirement = configuration.requirement ?? DeviceRendezvous.defaultRequirement(helper: configuration.helper) else {
            return queue.async { completion(.failure(.rendezvous("no code requirement for \(self.configuration.helper.path)"))) }
        }
        var sv: [Int32] = [-1, -1]
        guard socketpair(AF_UNIX, SOCK_STREAM, 0, &sv) == 0 else {
            let e = errno
            return queue.async { completion(.failure(.spawnFailed(e))) }
        }
        _ = fcntl(sv[0], F_SETFD, FD_CLOEXEC)
        _ = fcntl(sv[1], F_SETFD, FD_CLOEXEC)   // the child gets it via dup2 onto 3
        let token = (0..<4).map { _ in String(format: "%08x", arc4random()) }.joined()
        var argv = [configuration.helper.path, "--connect", server.serviceName, "--token", token,
                    "--instance", configuration.instance.uuidString] + configuration.arguments
        var environment = ProcessInfo.processInfo.environment.merging(configuration.environment) { $1 }
        if let dylib = configuration.dylib { environment["LTM_QEMU_DYLIB"] = dylib }
        let envp = environment.map { "\($0)=\($1)" }
        lock.withLock { startCompletion = completion }

        let registration = DeviceRendezvousServer.Registration(
            token: token, requirement: requirement,
            deliver: { [weak self] hello in self?.surfacesArrived(hello) },
            reject: { [weak self] reason in self?.invalidate(.rejected(reason), kill: true) })
        let pid = server.spawnAndRegister({
            withCStrings(argv) { cargv in
                withCStrings(envp) { cenv in
                    ltm_spawn(configuration.helper.path, cargv, cenv, configuration.outputDescriptor, sv[1])
                }
            }
        }, registration: registration)
        argv.removeAll()
        close(sv[1])
        guard pid > 0 else {
            close(sv[0])
            lock.withLock { startCompletion = nil }
            return queue.async { completion(.failure(.spawnFailed(-pid))) }
        }
        lock.withLock { _pid = pid }

        let exit = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: queue)
        exit.setEventHandler { [weak self] in self?.reap() }
        lock.withLock { exitSource = exit }
        exit.resume()

        let channel = LinkChannel<HelperMessage, AppMessage>(
            fd: sv[0], queue: queue,
            onMessage: { [weak self] in self?.received($0) },
            onClose: { [weak self] error in self?.invalidate(.closed(error.map { "\($0)" } ?? "end of file"), kill: false) })
        lock.withLock { self.channel = channel }

        request(.hello(protocolVersion: DeviceLinkWire.protocolVersion, machine: configuration.machine),
                timeout: configuration.connectTimeout) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(.hello(let info)):
                guard info.protocolVersion == DeviceLinkWire.protocolVersion else {
                    return invalidate(.protocolMismatch(helper: info.protocolVersion), kill: true)
                }
                lock.withLock { self._info = info }
                finishStartIfReady()
            case .success(.failure(let message)): invalidate(.helperFailure(message), kill: true)
            case .success(let other): invalidate(.helperFailure("unexpected hello reply \(other)"), kill: true)
            case .failure(let error): invalidate(error, kill: true)
            }
        }
        queue.asyncAfter(deadline: .now() + configuration.connectTimeout) { [weak self] in
            guard let self, lock.withLock({ self.startCompletion != nil }) else { return }
            invalidate(.timedOut, kill: true)
        }
    }

    private func surfacesArrived(_ hello: DeviceRendezvousServer.Hello) {
        let status = StatusBlock(hello.surfaces[0])
        guard status.isValid else { return invalidate(.rejected("bad status block"), kill: true) }
        lock.withLock {
            ring?.release()
            statusBlock = status
            if hello.generation > 0 {
                ring = FrameRingReader(status: status, generation: hello.generation, surfaces: Array(hello.surfaces.dropFirst()))
            }
        }
        queue.async { [weak self] in self?.finishStartIfReady() }
    }

    private func finishStartIfReady() {
        let ready: (HelperInfo, (Result<HelperInfo, DeviceLinkError>) -> Void)? = lock.withLock {
            guard let info = self._info, self.statusBlock != nil, let c = self.startCompletion else { return nil }
            self.startCompletion = nil
            return (info, c)
        }
        if let (info, completion) = ready { completion(.success(info)) }
    }

    // MARK: Messages

    /// Fire-and-forget, ordered. Dropped once the link is invalid.
    func send(_ command: LinkCommand) {
        lock.withLock { channel }?.send(.command(command))
    }

    /// One request; `reply` runs once on `queue` (a reply, or .timedOut / .closed).
    func request(_ request: LinkRequest, timeout: TimeInterval = 10, reply: @escaping Reply) {
        let (id, channel, dead): (UInt64, LinkChannel<HelperMessage, AppMessage>?, Bool) = lock.withLock {
            let id = nextID
            nextID += 1
            return (id, channel, invalidated)
        }
        guard let channel, !dead else { return queue.async { reply(.failure(.closed("not connected"))) } }
        let timer = DispatchWorkItem { [weak self] in
            guard let entry = self?.lock.withLock({ self?.pending.removeValue(forKey: id) }) else { return }
            entry.reply(.failure(.timedOut))
        }
        lock.withLock { pending[id] = Pending(timer: timer, reply: reply) }
        queue.asyncAfter(deadline: .now() + timeout, execute: timer)
        if !channel.send(.request(id: id, request)) {
            if let entry = lock.withLock({ pending.removeValue(forKey: id) }) {
                entry.timer.cancel()
                queue.async { entry.reply(.failure(.helperFailure("request too large"))) }
            }
        }
    }

    func request(_ request: LinkRequest, timeout: TimeInterval = 10) async throws -> LinkReply {
        try await withCheckedThrowingContinuation { continuation in
            self.request(request, timeout: timeout) { continuation.resume(with: $0) }
        }
    }

    private func received(_ message: HelperMessage) {
        switch message {
        case .reply(let id, let reply):
            guard let entry = lock.withLock({ pending.removeValue(forKey: id) }) else { return }
            entry.timer.cancel()
            entry.reply(.success(reply))
        case .event(let event):
            onEvent?(event)
        }
    }

    // MARK: Teardown

    /// SIGTERM: the helper runs its clean shutdown (bounded) and exits.
    func terminate() { let p = pid; if p > 0 { _ = Darwin.kill(p, SIGTERM) } }
    /// SIGKILL.
    func kill() { let p = pid; if p > 0 { _ = Darwin.kill(p, SIGKILL) } }

    private func invalidate(_ error: DeviceLinkError, kill shouldKill: Bool) {
        let (fire, channel, waiting, completion): (Bool, LinkChannel<HelperMessage, AppMessage>?, [Pending], ((Result<HelperInfo, DeviceLinkError>) -> Void)?) = lock.withLock {
            guard !invalidated else { return (false, nil, [], nil) }
            invalidated = true
            let waiting = Array(pending.values)
            pending.removeAll()
            let c = startCompletion
            startCompletion = nil
            ring?.release()
            return (true, self.channel, waiting, c)
        }
        guard fire else { return }
        if shouldKill { self.kill() }
        channel?.close()
        queue.async { [self] in
            for entry in waiting { entry.timer.cancel(); entry.reply(.failure(error)) }
            completion?(.failure(error))
            onInvalidated?(error)
        }
    }

    private func reap() {
        let p = pid
        var status: Int32 = 0
        let r = waitpid(p, &status, WNOHANG)
        let termination: DeviceTermination
        if r == p {
            if status & 0x7f == 0 { termination = .exited((status >> 8) & 0xff) }
            else { termination = .signaled(status & 0x7f) }
        } else if r == 0 {
            // NOTE_EXIT is one-shot: if the kernel hasn't finished the exit yet
            // (seen once in 300 SIGKILLs under load), poll again instead of losing it.
            queue.asyncAfter(deadline: .now() + .milliseconds(10)) { [weak self] in self?.reap() }
            return
        } else {
            termination = .unknown
        }
        // Zero the pid now: a late terminate() or kill() must not signal a reused one.
        lock.withLock { exitSource?.cancel(); exitSource = nil; _pid = 0 }
        DeviceRendezvousServer.shared.unregister(p)
        // Its last messages (qemuExited) may still be unread: deliver them before the close.
        lock.withLock { channel }?.drainIncoming()
        invalidate(.closed("helper exited"), kill: false)
        queue.async { [self] in onTerminated?(termination) }
    }
}

nonisolated private func withCStrings<R>(_ strings: [String], _ body: (UnsafePointer<UnsafeMutablePointer<CChar>?>) -> R) -> R {
    var pointers = strings.map { strdup($0) }
    pointers.append(nil)
    defer { for p in pointers { free(p) } }
    return pointers.withUnsafeBufferPointer { body($0.baseAddress!) }
}
