// Manages the forked usbmuxd that carries USB between the guest and the host's
// libimobiledevice tools. QEMU dials OUT to usbmuxd when the guest USB core
// comes up, so usbmuxd must be listening BEFORE the VM boots — hence this is
// started ahead of the QEMU thread and its address handed over (usb-tcp-addr).
// Both ends are Unix sockets in the per-user temporary directory, owner-only (a sandboxed helper can't reach it:
// DeviceLink's USB bridge hands it each connection):
// no loopback port any local process could reach, and no free-port race.
//
// Spawned with swift-subprocess. The daemon is kept alive inside a detached
// task; cancelling that task makes Subprocess run its teardown (SIGTERM), which
// is the only way a leaked usbmuxd — one holding the client socket and breaking
// the next launch — is reliably avoided.

import Foundation
import HostRuntime
import Observation
import Subprocess
import System

/// Observable: `session` is whether app management has a daemon (the controller's canManageApps).
@MainActor @Observable public final class USBMux {
    /// `binary`: another daemon (tests); nil, the bundled one.
    public init(session: Session? = nil, binary: String? = nil, onUnexpectedExit: (() -> Void)? = nil) {
        self.session = session
        self.binaryOverride = binary
        self.onUnexpectedExit = onUnexpectedExit
    }
    private let binaryOverride: String?

    public struct Session: Sendable {
        public let clientSocket: String  // USBMUXD_SOCKET_ADDRESS for host tools: "UNIX:<path>"
        public let guestAddress: String  // usb-tcp-addr the VM dials out to: a socket path

        /// Fresh socket paths under the per-user temporary directory (a Unix socket path stays under 104 bytes), where no
        /// sandboxed helper reaches either: a sandboxed helper's QEMU gets each connection to the guest socket from
        /// the app (DeviceLink's USB bridge), so another device's helper can't take either path.
        public static func make() -> (session: Session, client: String) {
            let base = NSTemporaryDirectory() + "ltm-mux-" + UUID().uuidString.prefix(8)
            return (Session(clientSocket: "UNIX:" + base + "-c.sock", guestAddress: base + "-g.sock"), base + "-c.sock")
        }
        public var paths: [String] { [String(clientSocket.dropFirst("UNIX:".count)), guestAddress] }
    }

    public private(set) var session: Session?
    private var daemonTask: Task<Void, Never>?
    private var daemonPID: pid_t?

    /// Called on the main actor if the daemon exits without us stopping it —
    /// the health signal that flips `canManageApps` off and tells the UI USB
    /// is gone. Empty catch used to swallow this entirely.
    public var onUnexpectedExit: (() -> Void)?

    /// The daemon dies and is started again on the same sockets this many times per start() before app management
    /// is given up (the emulator redials a lost bridge every few seconds); a boot's ensureRunning() starts over.
    static let restartLimit = 3
    private var restarts = 0
    /// This start()'s sockets and device paths, kept for a restart.
    private var launched: (session: Session, paths: DeviceInstance.Paths)?

    /// The fork ships in the bundle; a dev build falls back to the checkout
    /// (see qemu-ios' usbmuxd-qemu). LTM_USBMUXD names another build for a Debug
    /// run. A Release build runs only the bundled one.
    public static var binary: String {
        #if DEBUG
            if let override = ProcessInfo.processInfo.environment["LTM_USBMUXD"] { return override }
            return Bundled.tool("usbmuxd") ?? "\(NSHomeDirectory())/Developer/usbmuxd-qemu/usbmuxd/src/usbmuxd"
        #else
            return Bundled.tool("usbmuxd") ?? "usbmuxd (not in the bundle)"
        #endif
    }
    /// The daemon's config dir: bundled first (scripts/vendor stages it), else the
    /// dev checkout. Was hardcoded to the checkout with no bundle fallback, so
    /// a packaged app always passed `-C` a path that does not exist.
    /// usbmuxd's `-C` directory is WRITABLE STATE, not a resource: the daemon
    /// creates it if absent and writes SystemConfiguration.plist plus a pairing
    /// record per device into it. Pointed at the bundle it cannot write at all
    /// (read-only, and writing would break the signature), so pairing could
    /// never persist. Seed a copy in Application Support once and use that.
    /// Each device has its own (DeviceInstance.Storage.usbmuxConf).
    /// Pairing records are secrets: the directory is 0700 and its plists
    /// 0600, including ones an older build or the daemon left wider.
    private static func conf(_ work: URL) -> String {
        let fm = FileManager.default
        if !fm.fileExists(atPath: work.path) {
            try? fm.createDirectory(at: work, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            if let seed = Bundled.resource("usbmuxd-conf") {
                for name in (try? fm.contentsOfDirectory(atPath: seed)) ?? [] {
                    try? fm.copyItem(
                        at: URL(fileURLWithPath: seed).appendingPathComponent(name),
                        to: work.appendingPathComponent(name)
                    )
                }
            }
        }
        secure(work)
        return work.path
    }

    /// Also run over every device's conf at launch.
    public nonisolated static func secure(_ conf: URL) {
        let fm = FileManager.default
        guard fm.fileExists(atPath: conf.path) else { return }
        chmod(conf.path, 0o700)
        for name in (try? fm.contentsOfDirectory(atPath: conf.path)) ?? [] {
            let path = conf.appendingPathComponent(name).path
            if (try? fm.attributesOfItem(atPath: path))?[.type] as? FileAttributeType == .typeRegular {
                chmod(path, 0o600)
            }
        }
    }

    /// Start usbmuxd and record a session. Returns nil (and does nothing) if the
    /// binary is missing — the app still runs, just without app management.
    /// Everything the daemon writes is the device's own (`paths`), so two
    /// devices' daemons never collide.
    @discardableResult
    public func start(paths: DeviceInstance.Paths) -> Session? {
        let binary = binaryOverride ?? Self.binary
        guard FileManager.default.isExecutableFile(atPath: binary) else {
            logEvent("usbmux: no binary at \(binary); app management disabled")
            AppReports.failed("Services.usbmuxdMissing")
            return nil
        }

        // All writable scratch lives under Application Support, never files-root
        // (which is read-only inside a packaged app's signed bundle).
        do {
            try StorageLocations.privateDirectory(paths.work)
            StorageLocations.excludeFromBackup(paths.work)
        } catch {
            logEvent(
                "usbmux: no work directory \(paths.work.path): \(error.localizedDescription); app management disabled"
            )
            return nil
        }
        pidFile = paths.usbmuxPID.path
        // A daemon from a previous run survives anything that skips stop() —
        // Xcode's stop button is a SIGKILL — and orphans accumulate one per
        // dev cycle. The pid file names the only process this may kill, and
        // the executable path is checked so a recycled pid is never someone
        // else's process.
        reapStaleDaemon(pidFile)

        let session = Session.make().session
        restarts = 0
        launch(session, paths: paths)
        return session
    }

    /// A boot begins (Restart, Power On): a daemon that was given up on starts again on the sockets the emulator
    /// dials (state audit A-11).
    public func ensureRunning() {
        guard session == nil, let launched else { return }
        logEvent("usbmux: starting the daemon again for the new boot")
        restarts = 0
        launch(launched.session, paths: launched.paths)
    }

    private func launch(_ session: Session, paths: DeviceInstance.Paths) {
        let clientSocket = String(session.clientSocket.dropFirst("UNIX:".count))
        let guestAddress = session.guestAddress
        // A dead daemon leaves its socket files behind.
        for path in session.paths { unlink(path) }
        self.session = session
        launched = (session, paths)

        let binary = binaryOverride ?? Self.binary
        let conf = Self.conf(paths.usbmuxConf)
        let logURL = paths.logs.appendingPathComponent("usbmuxd.log")
        daemonTask = Task.detached {
            do {
                // The app drains a pipe to a bounded writer. Giving the child
                // a rotating file descriptor would leave it writing the renamed
                // generation forever and allow a long session to fill the disk.
                let capture: ProcessLogCapture?
                do { capture = try ProcessLogCapture(url: logURL) } catch {
                    capture = nil
                    logEvent("usbmux: log capture unavailable: \(error.localizedDescription)")
                }
                let log: FileDescriptor
                let fallback: FileDescriptor?
                if let capture {
                    log = FileDescriptor(rawValue: capture.writeDescriptor)
                    fallback = nil
                } else {
                    log = try FileDescriptor.open("/dev/null", .writeOnly)
                    fallback = log
                }
                defer {
                    capture?.flush()
                    try? fallback?.close()
                }
                _ = try await run(
                    .path(FilePath(binary)),
                    arguments: [
                        "-f", "-v", "-S", clientSocket, "-P", "NONE",
                        "-C", conf
                    ],
                    environment: .inherit.updating([
                        "USBMUXD_QEMU_ADDR": guestAddress,
                        // Enumeration has a bounded early-boot probe and retries.
                        // Do not impose a ten-second delay on an already-live
                        // device restored from a snapshot.
                        "USBMUXD_QEMU_DELAY": "0"
                    ]),
                    input: .none,
                    output: .fileDescriptor(log, closeAfterSpawningProcess: false),
                    error: .fileDescriptor(log, closeAfterSpawningProcess: false)
                ) { execution in
                    // Record the pid so stop() can kill it synchronously — an
                    // app quit runs cleanup faster than the async teardown can.
                    // The pid file is what lets the NEXT launch reap this
                    // daemon when this one dies without running stop().
                    let pid = execution.processIdentifier.value
                    await MainActor.run { [weak self] in
                        self?.daemonPID = pid
                        if let pidFile = self?.pidFile {
                            try? "\(pid)\n".write(
                                toFile: pidFile,
                                atomically: true,
                                encoding: .utf8
                            )
                        }
                    }
                    // Hold the process open until cancelled, but poll the pid so
                    // the daemon dying on its own is NOTICED — the closure body
                    // gates run()'s return, so a plain long sleep would let a
                    // dead daemon look alive forever (the empty-catch bug).
                    while !Task.isCancelled {
                        try await Task.sleep(for: .seconds(1))
                        if !Self.isRunning(pid) { break }
                    }
                }
            } catch {
                if !Task.isCancelled {
                    logEvent("usbmux: could not run daemon: \(error.localizedDescription)")
                    AppReports.failed("Services.usbmuxdFailed", error)
                }
            }
            // Distinguish an orderly stop() from an unexpected death: on the
            // latter the task was never cancelled.
            if !Task.isCancelled {
                await MainActor.run { [weak self] in self?.daemonDidDie() }
            }
        }
    }

    /// The daemon exited without stop(): started again on the same sockets, which the emulator redials, up to
    /// `restartLimit` times (it used to leave app management off until Force Stop then Start: state audit A-11);
    /// past that the session goes, so canManageApps flips false, and whoever is listening is told.
    private func daemonDidDie() {
        guard let session, let launched else { return }  // already torn down by stop()
        daemonPID = nil
        if restarts < Self.restartLimit {
            restarts += 1
            logEvent("usbmux: daemon exited unexpectedly; starting it again (\(restarts) of \(Self.restartLimit))")
            AppReports.failed("Services.usbmuxdExited", nil, ["restarts": "\(restarts)"])
            launch(session, paths: launched.paths)
            return
        }
        logEvent("usbmux: daemon exited unexpectedly; app management disabled")
        AppReports.failed("Services.usbmuxdGaveUp")
        self.session = nil
        onUnexpectedExit?()
    }

    private var pidFile: String?

    /// Whether the daemon still runs. Not kill(pid, 0): a daemon that exited stays a zombie until run() returns and
    /// reaps it, and that succeeds on a zombie, so a death was never noticed.
    private nonisolated static func isRunning(_ pid: pid_t) -> Bool {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return false }
        return info.pbi_status != 5  // SZOMB
    }

    private func reapStaleDaemon(_ pidFile: String?) {
        if let pidFile { Self.reapOrphan(pidFile: pidFile) }
    }

    /// Launch, with the library's lock held: every device's daemon left by a run that never stopped it. A daemon
    /// whose parent is alive belongs to a running app and is left alone.
    @discardableResult
    public nonisolated static func reapOrphans(_ devices: [DeviceInstance], state: URL, logs: URL) -> [pid_t] {
        devices.compactMap { reapOrphan(pidFile: $0.paths(state: state, logs: logs).usbmuxPID.path) }
    }

    /// The daemon a pid file names, killed if it is an orphan of a previous run (an app that crashed, or was
    /// SIGKILLed, never ran stop()). Launch runs it over every device's pid file, so a device that isn't started
    /// again doesn't keep its daemon forever. The pid that was signalled, if any.
    @discardableResult
    public nonisolated static func reapOrphan(pidFile: String) -> pid_t? {
        guard let text = try? String(contentsOfFile: pidFile, encoding: .utf8),
            let pid = pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines)),
            pid > 0, kill(pid, 0) == 0
        else { return nil }
        // Only an orphan (reparented to launchd): a daemon with a live parent
        // belongs to another running Light Touch, never to this launch.
        guard let identity = StorageLocations.daemonIdentity(pid), identity.parent == 1,
            identity.uid == geteuid(), identity.path.hasSuffix("/usbmuxd")
        else { return nil }
        logEvent("usbmux: killing stale usbmuxd \(pid) from a previous run")
        kill(pid, SIGTERM)
        try? FileManager.default.removeItem(atPath: pidFile)
        return pid
    }

    public func stop() {
        // Kill synchronously: app termination won't wait for the async teardown
        // the task cancellation would otherwise run. Only ever our own child.
        if let pid = daemonPID { kill(pid, SIGTERM) }
        if let pidFile { try? FileManager.default.removeItem(atPath: pidFile) }
        for path in session?.paths ?? [] { unlink(path) }
        daemonPID = nil
        daemonTask?.cancel()
        daemonTask = nil
        session = nil
        launched = nil
    }
}
