import Darwin
import Foundation
import Testing

@testable import HostRuntime

struct HelperSandboxTests {
    func scratch() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("helper-sandbox-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return URL(fileURLWithPath: SandboxExtension.canonical(url.path)!)
    }

    /// A symlink the helper could have made (inside something it may write) is never followed into a grant; one
    /// above (a library moved to another volume and linked back) is.
    @Test func aPlantedSymlinkIsRefused() throws {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let fm = FileManager.default
        let device = root.appendingPathComponent("library/Devices/dev")
        let elsewhere = root.appendingPathComponent("elsewhere")
        try fm.createDirectory(at: device.appendingPathComponent("work"), withIntermediateDirectories: true)
        try fm.createDirectory(at: elsewhere, withIntermediateDirectories: true)
        try fm.createSymbolicLink(at: device.appendingPathComponent("work/planted"), withDestinationURL: elsewhere)
        try fm.createSymbolicLink(
            at: root.appendingPathComponent("linked"),
            withDestinationURL: root.appendingPathComponent("library")
        )
        let planted = SandboxExtension.Grant(device.appendingPathComponent("work/planted"), .read)
        let (tokens, refused) = SandboxExtension.issue(
            [
                .init(device.appendingPathComponent("work"), .readWrite), planted,
                .init(root.appendingPathComponent("linked/Devices/dev"), .read)
            ],
            to: .pid(getpid())
        )
        #expect(refused.count == 1 && refused[0].hasPrefix(planted.path + " (a symlink"), "\(refused)")
        #expect(tokens.count == 2)
        #expect(SandboxExtension.consume(tokens).isEmpty, "issued to this process, so it takes them")
        SandboxExtension.releaseAll()
    }

    /// Tokens are bound to the process they were issued to.
    @Test func aTokenForAnotherProcessIsRefused() throws {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let (tokens, _) = SandboxExtension.issue([.init(root, .read)], to: .pid(getppid()))
        #expect(tokens.count == 1)
        #expect(SandboxExtension.consume(tokens) == [String(cString: strerror(EPERM))])
    }

    /// Never /, the home folder or above, ~/Library and what configures or runs things from it, a library root and
    /// its Devices folder, or anything writable inside an app.
    @Test func theDenyListHolds() throws {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let home = HelperSandbox.realHome
        let app = root.appendingPathComponent("Light Touch.app/Contents/Resources/Device")
        try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
        let library = root.appendingPathComponent("library")
        try FileManager.default.createDirectory(
            at: library.appendingPathComponent("Devices/dev"),
            withIntermediateDirectories: true
        )
        let denied: [SandboxExtension.Grant] = [
            .init(URL(fileURLWithPath: "/"), .read), .init(URL(fileURLWithPath: "/Users"), .read),
            .init(URL(fileURLWithPath: home), .read), .init(URL(fileURLWithPath: home + "/Library"), .readWrite),
            .init(URL(fileURLWithPath: home + "/Library/Preferences"), .read),
            .init(URL(fileURLWithPath: "/Applications"), .read), .init(app, .readWrite),
            .init(library, .readWrite), .init(library.appendingPathComponent("Devices"), .read),
            .init(URL(fileURLWithPath: home + "/Library/../Library/LaunchAgents/../LaunchAgents"), .read)
        ].filter { FileManager.default.fileExists(atPath: $0.path) }
        let (tokens, refused) = SandboxExtension.issue(
            denied,
            to: .pid(getpid()),
            deny: [library, library.appendingPathComponent("Devices")]
        )
        #expect(tokens.isEmpty, "\(refused)")
        #expect(refused.count == denied.count)
        // what a boot does get
        let (allowed, none) = SandboxExtension.issue(
            [.init(app, .read), .init(library.appendingPathComponent("Devices/dev"), .readWrite)],
            to: .pid(getpid()),
            deny: [library, library.appendingPathComponent("Devices")]
        )
        #expect(allowed.count == 2 && none.isEmpty, "\(none)")
    }

    /// macOS 14's only flag (issue 137) issues a folder as NOFOLLOW_ANY does; every macOS still defines it.
    @Test func noFollowIsReadAndIssuesAFolder() throws {
        let flag = try #require(SandboxExtension.noFollow)
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        typealias Issue =
            @convention(c) (UnsafePointer<CChar>, UnsafePointer<CChar>, UInt32, pid_t) -> UnsafeMutablePointer<CChar>?
        let issue = unsafeBitCast(
            try #require(
                dlsym(UnsafeMutableRawPointer(bitPattern: -2), "sandbox_extension_issue_file_to_process_by_pid")
            ),
            to: Issue.self
        )
        let token = issue(SandboxExtension.Access.read.rawValue, root.path, flag, getpid())
        #expect(token != nil)
        free(token)
    }

    /// The flag that refuses a symlink swapped in between resolving and issuing is this macOS's, read at run time.
    @Test func noFollowAnyIsReadAndRefusesASymlink() throws {
        let flag = try #require(SandboxExtension.noFollowAny)
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root.appendingPathComponent("d"), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("l"),
            withDestinationURL: root.appendingPathComponent("d")
        )
        typealias Issue =
            @convention(c) (UnsafePointer<CChar>, UnsafePointer<CChar>, UInt32, pid_t) -> UnsafeMutablePointer<CChar>?
        let issue = unsafeBitCast(
            try #require(
                dlsym(UnsafeMutableRawPointer(bitPattern: -2), "sandbox_extension_issue_file_to_process_by_pid")
            ),
            to: Issue.self
        )
        let read = SandboxExtension.Access.read.rawValue
        #expect(issue(read, root.appendingPathComponent("l").path, flag, getpid()) == nil)
        let direct = issue(read, root.appendingPathComponent("d").path, flag, getpid())
        #expect(direct != nil)
        free(direct)
    }

    /// Launch sweeps the folders of processes that are gone and nothing else.
    @Test func theSweepRemovesOnlyGoneProcessesFolders() throws {
        let container = try scratch()
        defer { try? FileManager.default.removeItem(at: container) }
        let gone = Process()
        gone.executableURL = URL(fileURLWithPath: "/usr/bin/true")
        try gone.run()
        gone.waitUntilExit()
        let fm = FileManager.default
        for name in ["\(gone.processIdentifier)", "\(getpid())", "\(getppid())", "Library", "1"] {
            try fm.createDirectory(at: container.appendingPathComponent(name), withIntermediateDirectories: true)
        }
        try Data().write(to: container.appendingPathComponent("\(gone.processIdentifier)/mux-1-g.sock"))
        #expect(HelperSandbox.sweepStaleSockets(in: container) == ["\(gone.processIdentifier)"])
        #expect(
            Set(try fm.contentsOfDirectory(atPath: container.path)) == ["\(getpid())", "\(getppid())", "Library", "1"]
        )
    }

    /// A socket's peer is the process that connected: the web proxy and firmwarekit's gdbstub client refuse any other.
    @Test func aSocketsPeerIsTheProcessThatConnected() throws {
        // short: sun_path holds 104 bytes
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("hs-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let path = root.appendingPathComponent("p.sock").path
        let listener = socket(AF_UNIX, SOCK_STREAM, 0)
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: path.utf8) }
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(listener, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        #expect(bound == 0 && listen(listener, 4) == 0)
        defer { close(listener) }
        // another process connects (nc -U), and this one
        let other = Process()
        other.executableURL = URL(fileURLWithPath: "/usr/bin/nc")
        other.arguments = ["-U", path]
        other.standardInput = Pipe()
        try other.run()
        defer { other.terminate() }
        let fromOther = accept(listener, nil, nil)
        #expect(HelperSandbox.peerPID(fromOther) == other.processIdentifier)
        close(fromOther)
        let mine = socket(AF_UNIX, SOCK_STREAM, 0)
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(mine, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        #expect(connected == 0)
        let fromMe = accept(listener, nil, nil)
        #expect(HelperSandbox.peerPID(fromMe) == getpid())
        #expect(HelperSandbox.peerPID(mine) == getpid(), "and from the connecting end, the listener's")
        close(fromMe)
        close(mine)
    }

    @Test func anUnsignedOrUnsandboxedHelperIsNotSandboxed() {
        #expect(!HelperSandbox.isSandboxed(URL(fileURLWithPath: "/usr/bin/true")))
        #expect(!HelperSandbox.isSandboxed(URL(fileURLWithPath: "/nonexistent")))
    }
}
