// Whether LightTouchDevice runs under the App Sandbox, and what that changes for whoever spawns it. One switch, the
// LTM_HELPER_SANDBOX build setting (Configuration/Shared.xcconfig), signs the helper with
// LightTouchDevice-Sandbox*.entitlements and the app with the app group; at run time the spawner reads the helper's
// own signature, so a process never treats a sandboxed helper as an unsandboxed one or the other way round.
//
// Sandboxed, the helper may look up only Mach services named under its app group (DeviceRendezvous) and reach Unix
// sockets only inside a container, which every sandboxed helper shares: any of them could connect to, or unlink and
// bind again, a socket another device's helper had there. So a sandboxed helper names no socket: its spawner hands
// it each one over a socket pair. usbmuxd's guest connections come over DeviceLink's bridge (LightTouchDevice
// USBBridge), the web proxy's from QEMU's guestfwd fdpass:, and the Debug Port's gdbstub listens on a socket the
// spawner bound in its own temporary directory. Unsandboxed, nothing changes: the bundle's rendezvous name, and the
// sockets in the temporary directory.

import Foundation
import Security

public nonisolated enum HelperSandbox {
    /// The rendezvous' Mach names are under it.
    public static let appGroup = "SM75355Y6R.ltm"

    nonisolated(unsafe) private static var current: Bool?
    private static let lock = NSLock()

    /// Whether `helper`'s signature asks for the App Sandbox.
    public static func isSandboxed(_ helper: URL) -> Bool {
        var code: SecStaticCode?
        var info: CFDictionary?
        guard SecStaticCodeCreateWithPath(helper as CFURL, [], &code) == errSecSuccess, let code,
            SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSRequirementInformation), &info)
                == errSecSuccess,
            let entitlements = (info as? [String: Any])?[kSecCodeInfoEntitlementsDict as String] as? [String: Any]
        else { return false }
        return entitlements["com.apple.security.app-sandbox"] as? Bool == true
    }

    /// Whether this process's helpers run sandboxed: the LightTouchDevice beside this executable (the app's, a
    /// bundled or built firmwarekit's) unless `use(helper:)` named another first.
    public static var enabled: Bool {
        lock.withLock {
            if let current { return current }
            let sibling = Bundle.main.executableURL?.resolvingSymlinksInPath().deletingLastPathComponent()
                .appendingPathComponent("LightTouchDevice")
            let value = sibling.map(isSandboxed) ?? false
            current = value
            return value
        }
    }

    /// The helper this process spawns (the harness's drivers, which aren't beside one), before any socket path.
    public static func use(helper: URL) {
        let value = isSandboxed(helper)
        lock.withLock { current = value }
    }

    /// The app group's container, whether or not it exists yet. Resolving through `containerURL` lets macOS grant an
    /// entitled, non-sandboxed app access to the protected group container without `secinitd`.
    public static var groupContainer: URL {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroup)
            ?? URL(fileURLWithPath: realHome, isDirectory: true).appendingPathComponent(
                "Library/Group Containers/\(appGroup)",
                isDirectory: true
            )
    }

    /// A Unix socket path for `name`, "ltm-<name>" in the per-user temporary directory, where no sandboxed helper
    /// reaches.
    public static func socketPath(_ name: String) -> String { NSTemporaryDirectory() + "ltm-" + name }

    /// App launch: the socket folders earlier builds made in the group's container for processes that are gone, and
    /// what they left in them. A live process's folder is never touched. What it removed, by name.
    @discardableResult public static func sweepStaleSockets(in container: URL = groupContainer) -> [String] {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: container.path) else { return [] }
        var removed: [String] = []
        for name in names {
            guard let pid = pid_t(name), pid > 0, pid != getpid(), kill(pid, 0) == -1, errno == ESRCH else { continue }
            if (try? fm.removeItem(at: container.appendingPathComponent(name))) != nil { removed.append(name) }
        }
        return removed
    }

    /// The process at the other end of a connected Unix socket. Every sandboxed helper can write the whole group
    /// container (one app group), so a socket there can be connected to, or unlinked and bound again, by another
    /// device's helper: an end that knows which process belongs at the other checks it.
    public static func peerPID(_ fd: Int32) -> pid_t? {
        var pid: pid_t = 0
        var size = socklen_t(MemoryLayout<pid_t>.size)
        return getsockopt(fd, SOL_LOCAL, LOCAL_PEERPID, &pid, &size) == 0 ? pid : nil
    }

    /// Whether the TCP connection `fd` accepted on 127.0.0.1 was made by this same process: its other end is one of
    /// this process's own sockets (another process can connect to any loopback port, but can't be this one).
    public static func isOwnConnection(_ fd: Int32) -> Bool {
        var local = sockaddr_in()
        var remote = sockaddr_in()
        var size = socklen_t(MemoryLayout<sockaddr_in>.size)
        let named = withUnsafeMutablePointer(to: &local) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &size) == 0 }
        }
        size = socklen_t(MemoryLayout<sockaddr_in>.size)
        let peered = withUnsafeMutablePointer(to: &remote) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getpeername(fd, $0, &size) == 0 }
        }
        guard named, peered, local.sin_family == sa_family_t(AF_INET) else { return false }
        // the peer's socket here has local port = remote.sin_port and foreign port = local.sin_port
        let want = (local: Int32(UInt16(bigEndian: remote.sin_port)), foreign: Int32(UInt16(bigEndian: local.sin_port)))
        let pid = getpid()
        let count = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0) / Int32(MemoryLayout<proc_fdinfo>.size)
        guard count > 0 else { return false }
        var fds = [proc_fdinfo](repeating: proc_fdinfo(), count: Int(count) + 16)
        let bytes = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, &fds, Int32(fds.count * MemoryLayout<proc_fdinfo>.size))
        for entry in fds.prefix(Int(bytes) / MemoryLayout<proc_fdinfo>.size)
        where entry.proc_fdtype == UInt32(PROX_FDTYPE_SOCKET) && entry.proc_fd != fd {
            var info = socket_fdinfo()
            let size = Int32(MemoryLayout<socket_fdinfo>.size)
            guard proc_pidfdinfo(pid, entry.proc_fd, PROC_PIDFDSOCKETINFO, &info, size) == size,
                info.psi.soi_kind == Int32(SOCKINFO_TCP)
            else { continue }
            let tcp = info.psi.soi_proto.pri_tcp.tcpsi_ini
            if Int32(UInt16(bigEndian: UInt16(truncatingIfNeeded: tcp.insi_lport))) == want.local
                && Int32(UInt16(bigEndian: UInt16(truncatingIfNeeded: tcp.insi_fport))) == want.foreign
            {
                return true
            }
        }
        return false
    }

    /// The account's home, not a sandboxed process's container.
    static var realHome: String {
        guard let pw = getpwuid(getuid()), let dir = pw.pointee.pw_dir else { return NSHomeDirectory() }
        return String(cString: dir)
    }

    /// What a sandboxed Debug helper loads before anything else, outside its bundle, read-only: its LC_RPATH folders
    /// (QEMU_BUILD_DIR, the vendor directory) and `dylib`'s folder (LTM_QEMU_DYLIB). A Release helper loads only its
    /// bundle's emulator: nothing. Every spawner sends these (DeviceLink, DeviceInfo.list, firmwarekit's one-shots).
    public static func emulatorGrants(
        helper: URL,
        dylib: String? = ProcessInfo.processInfo.environment["LTM_QEMU_DYLIB"]
    ) -> [SandboxExtension.Grant] {
        #if DEBUG
            var grants = runPaths(helper).map { SandboxExtension.Grant(URL(fileURLWithPath: $0), .read) }
            if let dylib, !dylib.isEmpty {
                grants.append(.init(URL(fileURLWithPath: dylib).deletingLastPathComponent(), .read))
            }
            return grants
        #else
            return []
        #endif
    }

    /// The helper's LC_RPATH folders that exist, @executable_path and @loader_path resolved.
    static func runPaths(_ binary: URL) -> [String] {
        guard let data = try? Data(contentsOf: binary, options: .alwaysMapped), data.count > 32 else { return [] }
        func u32(_ at: Int, big: Bool = false) -> Int {
            guard at + 4 <= data.count else { return 0 }
            let v = data.subdata(in: at..<at + 4).withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }
            return Int(big ? v.bigEndian : v)
        }
        var start = 0
        if u32(0, big: true) == 0xcafe_babe {  // fat: this machine's slice
            #if arch(arm64)
                let want = 0x0100_000c
            #else
                let want = 0x0100_0007
            #endif
            guard let slice = (0..<u32(4, big: true)).map({ 8 + $0 * 20 }).first(where: { u32($0, big: true) == want })
            else { return [] }
            start = u32(slice + 8, big: true)
        }
        guard u32(start) == 0xfeed_facf else { return [] }
        let folder = binary.deletingLastPathComponent().path
        var paths: [String] = []
        var at = start + 32
        for _ in 0..<u32(start + 16) {
            let command = u32(at)
            let size = u32(at + 4)
            guard size > 0, at + size <= data.count else { break }
            if command == 0x8000_001c {  // LC_RPATH
                let bytes = data.subdata(in: at + u32(at + 8)..<at + size).prefix { $0 != 0 }
                let path = String(decoding: bytes, as: UTF8.self)
                    .replacingOccurrences(of: "@executable_path", with: folder)
                    .replacingOccurrences(of: "@loader_path", with: folder)
                if FileManager.default.fileExists(atPath: path) { paths.append(path) }
            }
            at += size
        }
        return paths
    }
}
