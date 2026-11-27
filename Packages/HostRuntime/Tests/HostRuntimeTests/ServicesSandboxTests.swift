import Darwin
import Foundation
import Testing

@testable import HostRuntime

struct ServicesSandboxTests {
    /// Sandboxed, a process's sockets go in its own owner-only folder of the services' container, which the launch
    /// sweep removes once it is gone; unsandboxed, in the temporary directory as before.
    @Test func socketsGoInThisProcesssFolderOfTheContainer() throws {
        let container = FileManager.default.temporaryDirectory.appendingPathComponent("ss-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: container) }
        #expect(ServicesSandbox.socketFolder(sandboxed: false, in: container) == NSTemporaryDirectory())
        #expect(!FileManager.default.fileExists(atPath: container.path))
        let folder = ServicesSandbox.socketFolder(sandboxed: true, in: container)
        #expect(folder == container.appendingPathComponent("\(getpid())").path + "/")
        let mode = try FileManager.default.attributesOfItem(atPath: folder)[.posixPermissions] as? Int
        #expect(mode == 0o700)
        #expect(HelperSandbox.sweepStaleSockets(in: container).isEmpty, "this process is alive")
        #expect(ServicesSandbox.container.path.hasSuffix("/Library/Group Containers/\(ServicesSandbox.group)"))
    }

    /// `prepareSocketFolder` creates only a direct child folder inside the services container (0700) and ignores paths
    /// outside it.
    @Test func prepareSocketFolderCreatesOnlyDirectContainerChildren() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ss-\(UUID().uuidString)")
        let container = root.appendingPathComponent("container", isDirectory: true)
        let outside = root.appendingPathComponent("outside", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let insideSocket = container.appendingPathComponent("12345/mux-1-c.sock").path
        ServicesSandbox.prepareSocketFolder(forSocketPath: insideSocket, in: container)
        let folder = container.appendingPathComponent("12345").path
        let mode = try FileManager.default.attributesOfItem(atPath: folder)[.posixPermissions] as? Int
        #expect(mode == 0o700)

        let outsideSocket = outside.appendingPathComponent("12345/mux-1-c.sock").path
        ServicesSandbox.prepareSocketFolder(forSocketPath: outsideSocket, in: container)
        #expect(!FileManager.default.fileExists(atPath: outside.path))

        let nestedSocket = container.appendingPathComponent("12345/nested/mux-1-c.sock").path
        ServicesSandbox.prepareSocketFolder(forSocketPath: nestedSocket, in: container)
        #expect(!FileManager.default.fileExists(atPath: container.appendingPathComponent("12345/nested").path))
    }

    /// The tokens a spawner writes to a child's standard input are its grants as JSON, which only that pid takes.
    @Test func standardInputCarriesTokensOnlyThatProcessTakes() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ss-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let grants = [
            SandboxExtension.Grant(root, .readWrite),
            SandboxExtension.Grant(root.appendingPathComponent("missing"), .read)
        ]
        let (data, refused) = SandboxExtension.standardInput(grants, for: getpid())
        #expect(refused.count == 1 && refused[0].hasSuffix("missing (missing)"), "\(refused)")
        let tokens = try JSONDecoder().decode([String].self, from: data)
        #expect(tokens.count == 1)
        #expect(SandboxExtension.consume(tokens).isEmpty)
        SandboxExtension.releaseAll()
        let other = try JSONDecoder().decode(
            [String].self,
            from: SandboxExtension.standardInput(grants, for: getppid()).data
        )
        #expect(SandboxExtension.consume(other) == [String(cString: strerror(EPERM))])
    }

    /// A Debug build's development usbmuxd is granted its own folder, read-only, to be run and loaded from.
    @Test func aDevelopmentBinaryIsGrantedItsFolderReadOnly() {
        let grants = ServicesSandbox.loadGrants("/usr/bin/true")
        #if DEBUG
            #expect(grants.first == SandboxExtension.Grant(URL(fileURLWithPath: "/usr/bin"), .read))
            #expect(grants.allSatisfy { $0.access == .read })
        #else
            #expect(grants.isEmpty)
        #endif
    }
}
