import Foundation
import HostRuntime
import IOSurface
import LTMLinkC

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

nonisolated public enum DeviceLinkError: Error, Equatable, CustomStringConvertible {
    case spawnFailed(Int32)
    case rendezvous(String)
    case rejected(String)
    case timedOut
    case protocolMismatch(helper: Int)
    case helperFailure(String)
    case closed(String)

    public var description: String {
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

nonisolated public enum DeviceTermination: Sendable, Equatable {
    case exited(Int32)
    case signaled(Int32)
    /// Someone else reaped it; the status is lost.
    case unknown
}

nonisolated public final class DeviceLink: @unchecked Sendable {
    public struct Configuration: Sendable {
        /// Contents/MacOS/LightTouchDevice beside the running executable.
        public static let bundledHelper: URL = {
            guard let executable = Bundle.main.executableURL else {
                preconditionFailure("A running process has an executable")
            }
            return executable.deletingLastPathComponent().appendingPathComponent("LightTouchDevice")
        }()
        public var helper: URL = bundledHelper
        public var instance: UUID
        /// The helper's stdout + stderr, e.g. ProcessLogCapture.writeDescriptor
        /// for Devices/<uuid>/native.log. -1: /dev/null.
        public var outputDescriptor: Int32 = -1
        /// Development: the libqemu-arm.dylib to load (LTM_QEMU_DYLIB). nil: the
        /// helper's own @executable_path/../Frameworks, then its build rpath.
        public var dylib: String? = nil
        /// Extra environment for the helper process (QEMU's boot env goes in BootConfig).
        public var environment: [String: String] = [:]
        /// The board ID for hello's deviceInfo.
        public var board: String? = nil
        /// Code requirement for the helper; nil = DeviceRendezvous.defaultRequirement.
        public var requirement: String? = nil
        /// Spawn -> valid Mach hello + hello reply.
        public var connectTimeout: TimeInterval = 15
        /// The device's lease (HelperLaunch.lease).
        public var lease: URL?
        /// A sandboxed helper's files beyond its device's (SandboxExtension; the harness's own logs).
        public var grants: [SandboxExtension.Grant] = []

        public init(instance: UUID, outputDescriptor: Int32 = -1) {
            self.instance = instance
            self.outputDescriptor = outputDescriptor
        }
    }

    public let configuration: Configuration
    public let queue: DispatchQueue

    public var onEvent: ((LinkEvent) -> Void)?
    /// The link is unusable (fires once). The process may still be exiting.
    public var onInvalidated: ((DeviceLinkError) -> Void)?
    /// The helper process is gone (fires once, after onInvalidated if the link was up).
    public var onTerminated: ((DeviceTermination) -> Void)?

    private let lock = NSLock()
    private var _pid: pid_t = 0
    private var channel: LinkChannel<HelperMessage, AppMessage>?
    private var statusBlock: StatusBlock?
    private var ring: FrameRingReader?
    private var _info: HelperInfo?
    private var _agentReport: String?
    private var nextID: UInt64 = 1
    public typealias Reply = @Sendable (Result<LinkReply, DeviceLinkError>) -> Void
    private struct Pending: @unchecked Sendable {
        let timer: DispatchWorkItem
        let reply: Reply
    }
    private var pending: [UInt64: Pending] = [:]
    private var invalidated = false
    private var startCompletion: (@Sendable (Result<HelperInfo, DeviceLinkError>) -> Void)?
    private var exitSource: DispatchSourceProcess?
    /// The helper is signed for the App Sandbox (HelperSandbox): it gets its files from this link.
    private var sandboxed = false
    /// Its audit token, from the rendezvous (its code requirement checked); its grants are bound to it.
    private var audit: audit_token_t?
    /// The boot's usbmuxd guest socket (its usb-tcp-addr), which the USB bridge connects to for a sandboxed helper.
    private var usbAddress: String?
    /// The boot's Debug Port socket (its -gdb unix: path), which this process binds for a sandboxed helper.
    private var gdbSocket: String?
    #if DEBUG
        private static let debugBuild = true
    #else
        private static let debugBuild = false
    #endif

    public init(configuration: Configuration, queue: DispatchQueue = .main) {
        self.configuration = configuration
        self.queue = queue
    }

    /// Dropping the link closes the socket: EOF asks the helper to halt QEMU.
    /// The bounded host halt does not imply a guest filesystem shutdown.
    deinit {
        channel?.close()
        exitSource?.cancel()
        if _pid > 0 { DeviceRendezvousServer.shared.unregister(_pid) }
    }

    public var pid: pid_t { lock.withLock { _pid } }
    /// The hello reply: protocol, dylib path + mtime, build id, device info.
    public var info: HelperInfo? { lock.withLock { _info } }
    /// The status block, read now. nil until the helper's first hello.
    public var status: SharedStatus? { lock.withLock { statusBlock }?.snapshot() }
    /// The guest agent's latest report (LinkEvent.agentReport), kept so it can be read at any time like `status`;
    /// nil until the helper sent one.
    public var agentReport: String? { lock.withLock { _agentReport } }

    /// The front frame surface. `isNew` when it changed since the last call.
    /// Call from one thread only (the display link); hold the surface, not the tuple.
    public func frontSurface() -> (surface: IOSurface, serial: UInt64, isNew: Bool)? {
        lock.withLock { ring }?.front()
    }

    // MARK: - Start

    /// Spawn the helper and connect. Completes once, on `queue`.
    public func start(completion: @escaping @Sendable (Result<HelperInfo, DeviceLinkError>) -> Void) {
        let server = DeviceRendezvousServer.shared
        let kr = server.start()
        guard kr == 0 else { return queue.async { completion(.failure(.rendezvous("bootstrap_check_in: \(kr)"))) } }
        guard
            let requirement = configuration.requirement
                ?? DeviceRendezvous.defaultRequirement(helper: configuration.helper)
        else {
            return queue.async {
                completion(.failure(.rendezvous("no code requirement for \(self.configuration.helper.path)")))
            }
        }
        sandboxed = HelperSandbox.isSandboxed(configuration.helper)
        guard sandboxed == HelperSandbox.enabled else {
            let reason =
                "\(configuration.helper.path) is \(sandboxed ? "" : "not ")sandboxed, but this process set up its "
                + "rendezvous and sockets for \(sandboxed ? "un" : "")sandboxed helpers (HelperSandbox.use(helper:))"
            return queue.async { completion(.failure(.rendezvous(reason))) }
        }
        // A sandboxed Debug helper's emulator folders, which it loads before the rendezvous: on its standard input,
        // issued to its pid once it is spawned (SandboxExtension). Everything else waits for the rendezvous.
        var grantPipe: [Int32] = [-1, -1]
        if sandboxed, Self.debugBuild {
            guard pipe(&grantPipe) == 0 else {
                let e = errno
                return queue.async { completion(.failure(.spawnFailed(e))) }
            }
            _ = fcntl(grantPipe[0], F_SETFD, FD_CLOEXEC)
            _ = fcntl(grantPipe[1], F_SETFD, FD_CLOEXEC)
        }
        var sv: [Int32] = [-1, -1]
        guard socketpair(AF_UNIX, SOCK_STREAM, 0, &sv) == 0 else {
            let e = errno
            return queue.async { completion(.failure(.spawnFailed(e))) }
        }
        _ = fcntl(sv[0], F_SETFD, FD_CLOEXEC)
        _ = fcntl(sv[1], F_SETFD, FD_CLOEXEC)  // the child gets it via dup2 onto 3
        // A sandboxed helper's USB bridge (LightTouchDevice USBBridge): fd 4, over which it asks for each connection
        // to this device's usbmuxd, which this process makes.
        var bridge: [Int32] = [-1, -1]
        if sandboxed {
            guard socketpair(AF_UNIX, SOCK_STREAM, 0, &bridge) == 0 else {
                let e = errno
                close(sv[0])
                close(sv[1])
                return queue.async { completion(.failure(.spawnFailed(e))) }
            }
            _ = fcntl(bridge[0], F_SETFD, FD_CLOEXEC)
            _ = fcntl(bridge[1], F_SETFD, FD_CLOEXEC)
        }
        let token = (0..<4).map { _ in String(format: "%08x", arc4random()) }.joined()
        let launch = HelperLaunch(
            .connect(service: server.serviceName, token: token, instance: configuration.instance),
            lease: configuration.lease?.path
        )
        var argv = [configuration.helper.path] + launch.arguments
        var environment = ProcessInfo.processInfo.environment.merging(configuration.environment) { $1 }
        #if DEBUG
            // A Release helper loads only its bundle's emulator (LightTouchDevice/Qemu.swift).
            if let dylib = configuration.dylib { environment["LTM_QEMU_DYLIB"] = dylib }
        #endif
        let envp = environment.map { "\($0)=\($1)" }
        lock.withLock { startCompletion = completion }

        let registration = DeviceRendezvousServer.Registration(
            token: token,
            requirement: requirement,
            deliver: { [weak self] hello in self?.surfacesArrived(hello) },
            reject: { [weak self] reason in self?.invalidate(.rejected(reason), kill: true) }
        )
        let pid = server.spawnAndRegister(
            {
                withCStrings(argv) { cargv in
                    withCStrings(envp) { cenv in
                        ltm_spawn(
                            configuration.helper.path,
                            cargv,
                            cenv,
                            grantPipe[0],
                            configuration.outputDescriptor,
                            sv[1],
                            bridge[1]
                        )
                    }
                }
            },
            registration: registration
        )
        argv.removeAll()
        close(sv[1])
        if bridge[1] >= 0 {
            close(bridge[1])
            if pid > 0 { serveUSBBridge(bridge[0]) } else { close(bridge[0]) }
        }
        if grantPipe[0] >= 0 {
            close(grantPipe[0])
            if pid > 0 { sendGrants(emulatorGrants(), to: pid, over: grantPipe[1]) }
            close(grantPipe[1])
        }
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
            fd: sv[0],
            queue: queue,
            onMessage: { [weak self] in self?.received($0) },
            onClose: { [weak self] error in
                self?.invalidate(.closed(error.map { "\($0)" } ?? "end of file"), kill: false)
            }
        )
        lock.withLock { self.channel = channel }

        // A sandboxed helper's hello waits for the rendezvous: its device's grants, bound to the audit token whose
        // code requirement was just checked, go first, and the hello takes the lease with them.
        if !sandboxed { sendHello() }
        queue.asyncAfter(deadline: .now() + configuration.connectTimeout) { [weak self] in
            guard let self, lock.withLock({ self.startCompletion != nil }) else { return }
            invalidate(.timedOut, kill: true)
        }
    }

    private func sendHello() {
        request(
            .hello(protocolVersion: DeviceLinkWire.protocolVersion, board: configuration.board),
            timeout: configuration.connectTimeout
        ) { [weak self] result in
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
    }

    private func surfacesArrived(_ hello: DeviceRendezvousServer.Hello) {
        let status = StatusBlock(hello.surfaces[0])
        guard status.isValid else { return invalidate(.rejected("bad status block"), kill: true) }
        if sandboxed, lock.withLock({ audit == nil }) {
            lock.withLock { audit = hello.audit }
            queue.async { [weak self] in
                guard let self else { return }
                sendGrants(spawnGrants())
                sendHello()
            }
        }
        lock.withLock {
            ring?.release()
            statusBlock = status
            if hello.generation > 0 {
                ring = FrameRingReader(
                    status: status,
                    generation: hello.generation,
                    surfaces: Array(hello.surfaces.dropFirst())
                )
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

    // MARK: - Messages

    /// Fire-and-forget, ordered. Dropped once the link is invalid.
    public func send(_ command: LinkCommand) {
        if sandboxed, case .snapshotSave(let path) = command { grantSnapshot(path) }
        lock.withLock { channel }?.send(.command(command))
    }

    /// One request; `reply` runs once on `queue` (a reply, or .timedOut / .closed).
    public func request(_ request: LinkRequest, timeout: TimeInterval = 10, reply: @escaping Reply) {
        if sandboxed, case .boot(let config) = request {
            grantBoot(config)
            let address = BootRecipe.usbAddress(in: config.argv)
            let gdb = DebugPort.socket(in: config.argv)
            lock.withLock {
                usbAddress = address
                gdbSocket = gdb
            }
        }
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

    public func request(_ request: LinkRequest, timeout: TimeInterval = 10) async throws -> LinkReply {
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
            if case .agentReport(let text) = event { lock.withLock { _agentReport = text } }
            onEvent?(event)
        }
    }

    // MARK: - USB bridge

    /// Answers the helper's USB bridge until it closes: for each request, a socket connected to the boot's usbmuxd
    /// guest socket (in the temporary directory, where no sandboxed helper reaches), or none when there isn't one yet.
    /// The socket is private to this helper: no path in the app group's container that another helper could take.
    /// The Debug Port's gdbstub listens on a socket this process binds (the -gdb unix: path, in the temporary
    /// directory, where no sandboxed helper reaches) and hands over the same bridge.
    private func serveUSBBridge(_ fd: Int32) {
        Thread.detachNewThread { [weak self] in
            defer { close(fd) }
            while true {
                let (ok, kind, _) = BridgeSocket.receive(fd)
                guard ok, let kind else { return }
                let answer: Int32
                switch kind {
                case .usb:
                    let address = self?.lock.withLock { self?.usbAddress } ?? nil
                    answer = address.flatMap { BridgeSocket.connect($0) } ?? -1
                case .gdb:
                    let path = self?.lock.withLock { self?.gdbSocket } ?? nil
                    answer = path.flatMap { DebugPort.listen(at: $0) } ?? -1
                }
                _ = BridgeSocket.send(fd, kind, descriptor: answer)
                if answer >= 0 { close(answer) }
            }
        }
    }

    // MARK: - Sandbox grants

    /// The device's folder (the lease's, <device>/work/lease) and the library root and Devices folder above it,
    /// never granted themselves.
    private var deviceFolder: URL? { configuration.lease?.deletingLastPathComponent().deletingLastPathComponent() }
    private var libraryFolders: [URL] {
        guard let devices = deviceFolder?.deletingLastPathComponent() else { return [] }
        return [devices, devices.deletingLastPathComponent()]
    }

    /// After the rendezvous: the device's folder read-only (its record for the storage proof, the web proxy's
    /// routing, CA and location) and its work folder read-write (the lease, the clean-stop marker), made first (a
    /// grant is for a path that exists). Nothing else the app trusts in the device folder is writable.
    private func spawnGrants() -> [SandboxExtension.Grant] {
        #if DEBUG
            if ProcessInfo.processInfo.environment["LTM_HELPER_NO_GRANTS"] != nil { return [] }  // a negative control
        #endif
        var grants = configuration.grants
        if let lease = configuration.lease {
            let work = lease.deletingLastPathComponent()
            try? FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
            grants += [.init(work.deletingLastPathComponent(), .read), .init(work, .readWrite)]
        }
        return grants
    }

    /// Debug: the emulator the helper loads before the rendezvous, outside the bundle (the rpath's QEMU_BUILD_DIR and
    /// vendor directory, LTM_QEMU_DYLIB's folder), read-only.
    private func emulatorGrants() -> [SandboxExtension.Grant] {
        HelperSandbox.emulatorGrants(
            helper: configuration.helper,
            dylib: configuration.dylib ?? ProcessInfo.processInfo.environment["LTM_QEMU_DYLIB"]
        )
    }

    /// Before a boot: what it opens, by role (BootConfig.files, from the boot recipe; a config without them gets
    /// nothing, and fails at its first file), and its web proxy's URL cache, read-write.
    private func grantBoot(_ config: BootConfig) {
        #if DEBUG
            if ProcessInfo.processInfo.environment["LTM_HELPER_NO_GRANTS"] != nil { return }
        #endif
        guard let files = config.files else { return noteRefused(["this boot (it names no files)"]) }
        var grants = files.grants
        if let proxy = config.webProxy {
            let cache = URL(fileURLWithPath: proxy.config + ".cache")
            try? FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
            grants += [
                .init(URL(fileURLWithPath: proxy.config).deletingLastPathComponent(), .read), .init(cache, .readWrite)
            ]
        }
        sendGrants(grants)
    }

    /// A snapshot is written only inside the device's folder (the app sends none; the harness's helper-driver does):
    /// the file, made empty first, read-write. Anywhere else gets no grant.
    private func grantSnapshot(_ path: String) {
        let url = URL(fileURLWithPath: path).standardizedFileURL
        guard let device = deviceFolder?.standardizedFileURL,
            url.path.hasPrefix(device.path + "/"), !url.path.contains("/../")
        else { return noteRefused(["\(path) (a snapshot outside the device's folder)"]) }
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600])
        }
        sendGrants([.init(url, .readWrite)])
    }

    /// Over the link, ahead of what needs them (the channel is ordered), bound to the rendezvous' audit token.
    private func sendGrants(_ grants: [SandboxExtension.Grant]) {
        guard !grants.isEmpty, let audit = lock.withLock({ audit }) else { return }
        let (tokens, refused) = SandboxExtension.issue(grants, to: .process(audit), deny: libraryFolders)
        noteRefused(refused)
        if !tokens.isEmpty { lock.withLock { channel }?.send(.command(.sandboxExtensions(tokens))) }
    }

    /// On the helper's standard input, as JSON (SandboxExtension.consumeStandardInput), bound to its pid (an unreaped
    /// child's).
    private func sendGrants(_ grants: [SandboxExtension.Grant], to pid: pid_t, over fd: Int32) {
        let (tokens, refused) = SandboxExtension.issue(grants, to: .pid(pid), deny: libraryFolders)
        noteRefused(refused)
        guard let data = try? JSONEncoder().encode(tokens) else { return }
        _ = data.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
    }

    /// Into the device's native.log, beside the helper's own "Operation not permitted". Paths and reasons only.
    private func noteRefused(_ refused: [String]) {
        guard !refused.isEmpty, configuration.outputDescriptor >= 0 else { return }
        let line = "device link: no sandbox grant for \(refused.joined(separator: ", "))\n"
        _ = line.withCString { write(configuration.outputDescriptor, $0, strlen($0)) }
    }

    // MARK: - Teardown

    /// SIGTERM: the helper runs its clean shutdown (bounded) and exits.
    public func terminate() {
        let p = pid
        if p > 0 { _ = Darwin.kill(p, SIGTERM) }
    }
    /// SIGKILL.
    public func kill() {
        let p = pid
        if p > 0 { _ = Darwin.kill(p, SIGKILL) }
    }

    private func invalidate(_ error: DeviceLinkError, kill shouldKill: Bool) {
        let (fire, channel, waiting, completion):
            (
                Bool, LinkChannel<HelperMessage, AppMessage>?, [Pending],
                (@Sendable (Result<HelperInfo, DeviceLinkError>) -> Void)?
            ) = lock.withLock {
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
            for entry in waiting {
                entry.timer.cancel()
                entry.reply(.failure(error))
            }
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
            if status & 0x7f == 0 {
                termination = .exited((status >> 8) & 0xff)
            } else {
                termination = .signaled(status & 0x7f)
            }
        } else if r == 0 {
            // NOTE_EXIT is one-shot: if the kernel hasn't finished the exit yet
            // (seen once in 300 SIGKILLs under load), poll again instead of losing it.
            queue.asyncAfter(deadline: .now() + .milliseconds(10)) { [weak self] in self?.reap() }
            return
        } else {
            termination = .unknown
        }
        // Zero the pid now: a late terminate() or kill() must not signal a reused one.
        lock.withLock {
            exitSource?.cancel()
            exitSource = nil
            _pid = 0
        }
        DeviceRendezvousServer.shared.unregister(p)
        // Its last messages (qemuExited) may still be unread: deliver them before the close.
        lock.withLock { channel }?.drainIncoming()
        invalidate(.closed("helper exited"), kill: false)
        queue.async { [self] in onTerminated?(termination) }
    }
}

/// A sandboxed helper's bridge socket (fd 4 in the helper): a one-byte request from the helper, a one-byte answer of the
/// same kind carrying a descriptor (SCM_RIGHTS) or none.
nonisolated public enum BridgeSocket {
    /// What the helper asks for: a connection to its usbmuxd, or the listener its gdbstub accepts on.
    public enum Kind: CChar, Sendable {
        case usb = 85  // "U"
        case gdb = 71  // "G"
    }

    public static func send(_ socket: Int32, _ kind: Kind = .usb, descriptor: Int32 = -1) -> Bool {
        ltm_send_fd(socket, kind.rawValue, descriptor) == 0
    }
    /// Whether a message came (false at end of file), what it was about, and its descriptor (-1 without one).
    public static func receive(_ socket: Int32) -> (ok: Bool, kind: Kind?, descriptor: Int32) {
        var byte: CChar = 0
        var fd: Int32 = -1
        let ok = ltm_recv_fd(socket, &byte, &fd) == 1
        return (ok, Kind(rawValue: byte), fd)
    }

    /// A socket connected to the Unix socket `path`, or nil.
    public static func connect(_ path: String) -> Int32? {
        var address = sockaddr_un()
        guard path.utf8.count < MemoryLayout.size(ofValue: address.sun_path) else { return nil }
        address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: path.utf8) }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        let ok = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) == 0
            }
        }
        if !ok { close(fd) }
        return ok ? fd : nil
    }
}

nonisolated private func withCStrings<R>(
    _ strings: [String],
    _ body: (UnsafePointer<UnsafeMutablePointer<CChar>?>) -> R
) -> R {
    var pointers = strings.map { strdup($0) }
    pointers.append(nil)
    defer { for p in pointers { free(p) } }
    return pointers.withUnsafeBufferPointer {
        guard let base = $0.baseAddress else { preconditionFailure("The array holds at least its nil terminator") }
        return body(base)
    }
}
