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
    /// (see qemu-ios' usbmuxd-qemu).
    private static let root = "\(NSHomeDirectory())/Developer/usbmuxd-qemu"
    private static var binary: String {
        Bundled.tool("usbmuxd") ?? "\(root)/usbmuxd/src/usbmuxd"
    }
    /// The daemon's config dir: bundled first (package.sh stages it), else the
    /// dev checkout. Was hardcoded to the checkout with no bundle fallback, so
    /// a packaged app always passed `-C` a path that does not exist.
    private static var conf: String {
        Bundled.resource("usbmuxd-conf") ?? "\(root)/run/conf"
    }
    
    /// Start usbmuxd and record a session. Returns nil (and does nothing) if the
    /// binary is missing — the app still runs, just without app management.
    /// `filesRoot`/`nand`/`overlay` are written into the session file the
    /// existing install/terminal scripts read.
    @discardableResult
    func start(filesRoot: String, nand: String, overlay: String) -> Session? {
        guard FileManager.default.isExecutableFile(atPath: Self.binary) else {
            NSLog("usbmux: no binary at \(Self.binary); app management disabled")
            return nil
        }
        
        // All writable scratch lives under Application Support, never files-root
        // (which is read-only inside a packaged app's signed bundle).
        let work = Bundled.workDirectory
        pidFile = work.appendingPathComponent("usbmuxd.pid").path
        // A daemon from a previous run survives anything that skips stop() —
        // Xcode's stop button is a SIGKILL — and orphans accumulate one per
        // dev cycle. The pid file names the only process this may kill, and
        // the executable path is checked so a recycled pid is never someone
        // else's process.
        reapStaleDaemon()

        let clientSocket = "127.0.0.1:\(Self.freePort())"
        let guestAddress = "127.0.0.1:\(Self.freePort())"
        let session = Session(clientSocket: clientSocket, guestAddress: guestAddress)
        self.session = session

        writeSessionFile(filesRoot: filesRoot, nand: nand, overlay: overlay,
                         session: session)

        Bundled.rotateLog(at: work.appendingPathComponent("usbmuxd.log"))
        let binary = Self.binary, conf = Self.conf
        // The daemon's log lands where install-ipa.sh's error message has
        // always claimed it is. It was .discarded before, which made every
        // "check usbmuxd.log" a dead end.
        let logPath = FilePath(work.appendingPathComponent("usbmuxd.log").path)
        daemonTask = Task.detached {
            do {
                // The work directory exists — Bundled.workDirectory made it —
                // so this only fails in circumstances /dev/null also covers.
                let log = (try? FileDescriptor.open(
                    logPath, .writeOnly,
                    options: [.create, .truncate], permissions: .ownerReadWrite))
                    ?? (try! FileDescriptor.open("/dev/null", .writeOnly))
                defer { try? log.close() }
                _ = try await run(
                    .path(FilePath(binary)),
                    arguments: ["-f", "-v", "-S", clientSocket, "-P", "NONE",
                                "-C", conf],
                    environment: .inherit.updating([
                        "USBMUXD_QEMU_ADDR": guestAddress,
                        // SECONDS, not ms — "100" here was a hundred-second
                        // stall between QEMU connecting and the first USB
                        // enumeration attempt, which is why the device took
                        // forever to "attach" on every boot. Ten skips the
                        // iBoot phase's noise; the daemon's own retries (now
                        // uncapped) carry it from there.
                        "USBMUXD_QEMU_DELAY": "10",
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
                // Cancelled (normal shutdown) or a spawn failure.
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
        NSLog("usbmux: daemon exited unexpectedly; app management disabled")
        session = nil
        daemonPID = nil
        onUnexpectedExit?()
    }

    private var pidFile: String?

    private func reapStaleDaemon() {
        guard let pidFile,
              let text = try? String(contentsOfFile: pidFile, encoding: .utf8),
              let pid = pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines)),
              pid > 0, kill(pid, 0) == 0 else { return }
        var buffer = [CChar](repeating: 0, count: 4096)
        guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0,
              String(cString: buffer).hasSuffix("/usbmuxd") else { return }
        NSLog("usbmux: killing stale usbmuxd \(pid) from a previous run")
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
    
    // MARK: - session.env (consumed by it-ssh-terminal.sh; installs are in-process)

    /// Where the SSH-terminal script reads the mux socket from. DeviceTools
    /// points the script at this via the SESSION env var.
    static var sessionFile: String {
        Bundled.workDirectory.appendingPathComponent("session.env").path
    }

    private func writeSessionFile(filesRoot: String, nand: String,
                                  overlay: String, session: Session) {
        // Values are quoted: the overlay lives under "Application Support", whose
        // space would otherwise break `. session.env` in the shell scripts.
        let contents = """
        # written by LightTouchMac; read by it-ssh-terminal.sh
        SOCK="\(session.clientSocket)"
        QEMU_ADDR="\(session.guestAddress)"
        NAND="\(filesRoot)/\(nand)"
        OVL="\(overlay)"
        """
        do {
            try contents.write(toFile: Self.sessionFile, atomically: true, encoding: .utf8)
        } catch {
            // Not fatal — only the Terminal feature reads this — but no longer
            // silent: a write failure here used to be invisible.
            NSLog("usbmux: could not write session.env: \(error.localizedDescription)")
        }
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
