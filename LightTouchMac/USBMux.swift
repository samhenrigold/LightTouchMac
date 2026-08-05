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
    
    /// The fork lives here (see the qemu-ios usbmuxd-qemu checkout).
    private static let root = "\(NSHomeDirectory())/Developer/usbmuxd-qemu"
    private static var binary: String { "\(root)/usbmuxd/src/usbmuxd" }
    private static var conf: String { "\(root)/run/conf" }
    
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
        
        let clientSocket = "127.0.0.1:\(Self.freePort())"
        let guestAddress = "127.0.0.1:\(Self.freePort())"
        let session = Session(clientSocket: clientSocket, guestAddress: guestAddress)
        self.session = session
        
        writeSessionFile(filesRoot: filesRoot, nand: nand, overlay: overlay,
                         session: session)
        
        let binary = Self.binary, conf = Self.conf
        daemonTask = Task.detached {
            do {
                _ = try await run(
                    .path(FilePath(binary)),
                    arguments: ["-f", "-v", "-v", "-S", clientSocket, "-P", "NONE",
                                "-C", conf],
                    environment: .inherit.updating([
                        "USBMUXD_QEMU_ADDR": guestAddress,
                        "USBMUXD_QEMU_DELAY": "100",
                    ]),
                    input: .none, output: .discarded, error: .discarded
                ) { execution in
                    // Record the pid so stop() can kill it synchronously — an
                    // app quit runs cleanup faster than the async teardown can.
                    let pid = execution.processIdentifier.value
                    await MainActor.run { [weak self] in self?.daemonPID = pid }
                    // Hold the process open until the task is cancelled; the
                    // throw on cancellation triggers Subprocess teardown.
                    while !Task.isCancelled {
                        try await Task.sleep(for: .seconds(3600))
                    }
                }
            } catch {
                // Cancelled (normal shutdown) or the daemon exited.
            }
        }
        return session
    }
    
    func stop() {
        // Kill synchronously: app termination won't wait for the async teardown
        // the task cancellation would otherwise run. Only ever our own child.
        if let pid = daemonPID { kill(pid, SIGTERM) }
        daemonPID = nil
        daemonTask?.cancel()
        daemonTask = nil
        session = nil
    }
    
    // MARK: - session.env (consumed by apps/install-app.sh and it-ssh-terminal.sh)
    
    private func writeSessionFile(filesRoot: String, nand: String,
                                  overlay: String, session: Session) {
        let workDir = "\(filesRoot)/apps/work"
        try? FileManager.default.createDirectory(atPath: workDir,
                                                 withIntermediateDirectories: true)
        // Values are quoted: the overlay lives under "Application Support", whose
        // space would otherwise break `. session.env` in the shell scripts.
        let contents = """
        # written by LightTouchMac; read by apps/install-app.sh and it-ssh-terminal.sh
        SOCK="\(session.clientSocket)"
        QEMU_ADDR="\(session.guestAddress)"
        NAND="\(filesRoot)/\(nand)"
        OVL="\(overlay)"
        """
        try? contents.write(toFile: "\(workDir)/session.env",
                            atomically: true, encoding: .utf8)
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
