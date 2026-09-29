// Created by Sam on 2026-08-05.
//
// Manages the forked usbmuxd that carries USB between the guest and the host's
// libimobiledevice tools. QEMU dials OUT to usbmuxd when the guest USB core
// comes up, so usbmuxd must be listening BEFORE the VM boots — hence this is
// started ahead of the QEMU thread and its address handed over as IT_USB_TCP.
//
// Spawned with swift-subprocess. The daemon is kept alive inside a detached
// task; cancelling that task makes Subprocess run its teardown (SIGTERM), which
// is the only way a leaked usbmuxd — one holding the client socket and breaking
// the next launch — is reliably avoided.

import Foundation
import Subprocess
import System

@MainActor
final class USBMux {
    
    struct Session: Sendable {
        let clientSocket: String   // USBMUXD_SOCKET_ADDRESS for host tools
        let guestAddress: String   // IT_USB_TCP the VM dials out to
    }
    
    private(set) var session: Session?
    private var daemonTask: Task<Void, Never>?
    private var daemonPID: pid_t?

    /// Called on the main actor if the daemon exits without us stopping it —
    /// the health signal that flips `canManageApps` off and tells the UI USB
    /// is gone. Empty catch used to swallow this entirely.
    var onUnexpectedExit: (() -> Void)?

    /// The fork ships in the bundle; a dev build falls back to the checkout
    /// (see qemu-ios' usbmuxd-qemu). LTM_USBMUXD names another build for a dev
    /// run, e.g. the ipad1 branch's for iPad USB Ethernet.
    private static let root = "\(NSHomeDirectory())/Developer/usbmuxd-qemu"
    private static var binary: String {
        ProcessInfo.processInfo.environment["LTM_USBMUXD"]
            ?? Bundled.tool("usbmuxd") ?? "\(root)/usbmuxd/src/usbmuxd"
    }
    /// The daemon's config dir: bundled first (package.sh stages it), else the
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
                    try? fm.copyItem(at: URL(fileURLWithPath: seed).appendingPathComponent(name),
                                     to: work.appendingPathComponent(name))
                }
            }
        }
        secure(work)
        return work.path
    }

    /// Also run over every device's conf at launch.
    nonisolated static func secure(_ conf: URL) {
        let fm = FileManager.default
        guard fm.fileExists(atPath: conf.path) else { return }
        chmod(conf.path, 0o700)
        for name in (try? fm.contentsOfDirectory(atPath: conf.path)) ?? [] {
            let path = conf.appendingPathComponent(name).path
            if (try? fm.attributesOfItem(atPath: path))?[.type] as? FileAttributeType == .typeRegular { chmod(path, 0o600) }
        }
    }
    
    /// Start usbmuxd and record a session. Returns nil (and does nothing) if the
    /// binary is missing — the app still runs, just without app management.
    /// Everything the daemon writes is the device's own (`paths`), so two
    /// devices' daemons never collide.
    @discardableResult
    func start(paths: DeviceInstance.Paths) -> Session? {
        guard FileManager.default.isExecutableFile(atPath: Self.binary) else {
            logEvent("usbmux: no binary at \(Self.binary); app management disabled")
            return nil
        }
        
        // All writable scratch lives under Application Support, never files-root
        // (which is read-only inside a packaged app's signed bundle).
        do {
            try StorageLocations.privateDirectory(paths.work)
            StorageLocations.excludeFromBackup(paths.work)
        }
        catch {
            logEvent("usbmux: no work directory \(paths.work.path): \(error.localizedDescription); app management disabled")
            return nil
        }
        pidFile = paths.usbmuxPID.path
        // A daemon from a previous run survives anything that skips stop() —
        // Xcode's stop button is a SIGKILL — and orphans accumulate one per
        // dev cycle. The pid file names the only process this may kill, and
        // the executable path is checked so a recycled pid is never someone
        // else's process.
        reapStaleDaemon(pidFile)

        let clientSocket = "127.0.0.1:\(Self.freePort())"
        let guestAddress = "127.0.0.1:\(Self.freePort())"
        let session = Session(clientSocket: clientSocket, guestAddress: guestAddress)
        self.session = session

        let binary = Self.binary, conf = Self.conf(paths.usbmuxConf)
        let logURL = paths.logs.appendingPathComponent("usbmuxd.log")
        daemonTask = Task.detached {
            do {
                // The app drains a pipe to a bounded writer. Giving the child
                // a rotating file descriptor would leave it writing the renamed
                // generation forever and allow a long session to fill the disk.
                let capture: ProcessLogCapture?
                do { capture = try ProcessLogCapture(url: logURL) }
                catch {
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
                    arguments: ["-f", "-v", "-S", clientSocket, "-P", "NONE",
                                "-C", conf],
                    environment: .inherit.updating([
                        "USBMUXD_QEMU_ADDR": guestAddress,
                        // Enumeration has a bounded early-boot probe and retries.
                        // Do not impose a ten-second delay on an already-live
                        // device restored from a snapshot.
                        "USBMUXD_QEMU_DELAY": "0",
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
                            try? "\(pid)\n".write(toFile: pidFile, atomically: true,
                                                  encoding: .utf8)
                        }
                    }
                    // Hold the process open until cancelled, but poll the pid so
                    // the daemon dying on its own is NOTICED — the closure body
                    // gates run()'s return, so a plain long sleep would let a
                    // dead daemon look alive forever (the empty-catch bug).
                    while !Task.isCancelled {
                        try await Task.sleep(for: .seconds(1))
                        if kill(pid, 0) != 0 { break }   // ESRCH: daemon gone
                    }
                }
            } catch {
                if !Task.isCancelled { logEvent("usbmux: could not run daemon: \(error.localizedDescription)") }
            }
            // Distinguish an orderly stop() from an unexpected death: on the
            // latter the task was never cancelled.
            if !Task.isCancelled {
                await MainActor.run { [weak self] in self?.daemonDidDie() }
            }
        }
        return session
    }

    /// The daemon exited without stop() — app management is now dead. Clear the
    /// session so canManageApps flips false and tell whoever is listening.
    private func daemonDidDie() {
        guard session != nil else { return }   // already torn down by stop()
        logEvent("usbmux: daemon exited unexpectedly; app management disabled")
        session = nil
        daemonPID = nil
        onUnexpectedExit?()
    }

    private var pidFile: String?

    private func reapStaleDaemon(_ pidFile: String?) {
        guard let pidFile,
              let text = try? String(contentsOfFile: pidFile, encoding: .utf8),
              let pid = pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines)),
              pid > 0, kill(pid, 0) == 0 else { return }
        // Only an orphan (reparented to launchd): a daemon with a live parent
        // belongs to another running Light Touch, never to this launch.
        guard let identity = StorageLocations.daemonIdentity(pid), identity.parent == 1,
              identity.uid == geteuid(), identity.path.hasSuffix("/usbmuxd") else { return }
        logEvent("usbmux: killing stale usbmuxd \(pid) from a previous run")
        kill(pid, SIGTERM)
    }

    func stop() {
        // Kill synchronously: app termination won't wait for the async teardown
        // the task cancellation would otherwise run. Only ever our own child.
        if let pid = daemonPID { kill(pid, SIGTERM) }
        if let pidFile { try? FileManager.default.removeItem(atPath: pidFile) }
        daemonPID = nil
        daemonTask?.cancel()
        daemonTask = nil
        session = nil
    }
    
    // MARK: - Free-port pick
    
    /// Bind a socket to port 0, read what the kernel assigned, release it. Small
    /// TOCTOU window, same approach the shell tooling uses.
    private static func freePort() -> UInt16 {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return 0 }
        defer { close(fd) }
        
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        addr.sin_port = 0
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0 else { return 0 }
        
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(fd, $0, &len)
            }
        }
        return UInt16(bigEndian: addr.sin_port)
    }
}
