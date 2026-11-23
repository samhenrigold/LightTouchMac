import Foundation
import HostRuntime
import Testing

@testable import LightTouchCore

/// usbmuxd that dies is started again on the sockets the emulator dials, a few times; given up, a new boot starts it.
struct USBMuxTests {
    /// State audit A-11: an unexpected daemon death left app management off until Force Stop then Start.
    @Test func aDaemonThatDiesStartsAgainOnItsSockets() async throws {
        try await withScratchDirectory { directory in
            let starts = directory.appendingPathComponent("starts")
            let daemon = directory.appendingPathComponent("usbmuxd")
            try "#!/bin/sh\necho \"$USBMUXD_QEMU_ADDR\" >> '\(starts.path)'\nsleep 0.2\n".write(
                to: daemon,
                atomically: true,
                encoding: .utf8
            )
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: daemon.path)
            let paths = DeviceInstance.Paths(
                directory: directory,
                base: directory,
                overlay: directory,
                writableNOR: nil,
                snapshot: directory.appendingPathComponent("snapshot"),
                usbmuxConf: directory.appendingPathComponent("conf"),
                work: directory.appendingPathComponent("work"),
                logs: directory.appendingPathComponent("logs")
            )
            func launches() -> [String] {
                ((try? String(contentsOf: starts, encoding: .utf8)) ?? "").split(separator: "\n").map(String.init)
            }
            var gaveUp = false
            let mux = USBMux(binary: daemon.path) { gaveUp = true }
            let session = try #require(mux.start(paths: paths))
            await eventually("started again") { launches().count >= 2 }
            #expect(mux.session?.guestAddress == session.guestAddress, "the same sockets")
            await eventually("given up") { gaveUp }
            #expect(launches().count == 1 + USBMux.restartLimit && mux.session == nil)
            #expect(Set(launches()) == [session.guestAddress])

            mux.ensureRunning()
            #expect(mux.session?.guestAddress == session.guestAddress, "a new boot starts it on the same sockets")
            await eventually("started for the new boot") { launches().count == 2 + USBMux.restartLimit }
            mux.stop()
        }
    }

    /// A crashed app's daemons are reparented to launchd and outlive it; launch reaps every device's orphan (one
    /// lasted until its device happened to start again), never a daemon whose parent is alive.
    @Test func launchReapsOrphanedDaemons() async throws {
        try await withScratchDirectory { state in
            let source = state.appendingPathComponent("daemon.c")
            try "#include <unistd.h>\nint main(void) { sleep(60); return 0; }\n".write(
                to: source,
                atomically: true,
                encoding: .utf8
            )
            let daemon = state.appendingPathComponent("usbmuxd")
            try LibraryFixtures.run("/usr/bin/cc", ["-o", daemon.path, source.path])
            func device() throws -> (DeviceInstance, URL) {
                let id = UUID()
                let instance = DeviceInstance(
                    id: id,
                    name: "device",
                    board: "n72ap",
                    firmware: "ipod-3.1.3",
                    created: .now,
                    base: .init(kind: .prepared, path: "Devices/\(id)/base"),
                    storage: .init(
                        key: id.uuidString,
                        overlay: "Devices/\(id)/overlay",
                        snapshot: "Devices/\(id)/snapshot",
                        usbmuxConf: "Devices/\(id)/usbmuxd-conf"
                    )
                )
                let pidFile = instance.paths(state: state, logs: state).usbmuxPID
                try FileManager.default.createDirectory(
                    at: pidFile.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                return (instance, pidFile)
            }
            // The orphan: started by a shell that exits at once.
            let orphan = try #require(
                pid_t(
                    try LibraryFixtures.run("/bin/sh", ["-c", "\"$0\" >/dev/null 2>&1 & echo $!", daemon.path])
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                )
            )
            await eventually("reparented") { StorageLocations.daemonIdentity(orphan)?.parent == 1 }
            let (crashed, crashedPID) = try device()
            try "\(orphan)\n".write(to: crashedPID, atomically: true, encoding: .utf8)
            // A running app's daemon: its parent (this process) is alive.
            let owned = Process()
            owned.executableURL = daemon
            try owned.run()
            defer { owned.terminate() }
            let (running, runningPID) = try device()
            try "\(owned.processIdentifier)\n".write(to: runningPID, atomically: true, encoding: .utf8)

            #expect(USBMux.reapOrphans([crashed, running], state: state, logs: state) == [orphan])
            await eventually("the orphan exited") { StorageLocations.daemonIdentity(orphan) == nil }
            #expect(owned.isRunning && FileManager.default.fileExists(atPath: runningPID.path))
            #expect(!FileManager.default.fileExists(atPath: crashedPID.path))
        }
    }

    /// With the services worker under the App Sandbox the daemon is the worker's usbmuxd operation, granted only its
    /// device's usbmuxd-conf; with an unsandboxed one (LTM_HELPER_SANDBOX=NO) it runs itself, granted nothing.
    @Test func theDaemonRunsInASandboxedWorkersSandbox() async throws {
        try await withScratchDirectory { directory in
            let plain = USBMux.command(binary: "/x/usbmuxd", worker: "/usr/bin/true", clientSocket: "/s", conf: "/c")
            #expect(plain.executable == "/x/usbmuxd" && plain.grants == nil)
            #expect(plain.arguments == ["-f", "-v", "-S", "/s", "-P", "NONE", "-C", "/c"])
            #expect(USBMux.command(binary: "/x/usbmuxd", worker: nil, clientSocket: "/s", conf: "/c").grants == nil)

            let source = directory.appendingPathComponent("worker.c")
            try "int main(void) { return 0; }\n".write(to: source, atomically: true, encoding: .utf8)
            let worker = directory.appendingPathComponent("LightTouchServices")
            try LibraryFixtures.run("/usr/bin/cc", ["-o", worker.path, source.path])
            let entitlements = directory.appendingPathComponent("sandbox.entitlements")
            try (["com.apple.security.app-sandbox": true] as NSDictionary).write(to: entitlements)
            try LibraryFixtures.run(
                "/usr/bin/codesign",
                ["-f", "-s", "-", "--entitlements", entitlements.path, worker.path]
            )
            let conf = directory.appendingPathComponent("conf")
            let sandboxed = USBMux.command(
                binary: "/x/usbmuxd",
                worker: worker.path,
                clientSocket: "/s",
                conf: conf.path
            )
            #expect(sandboxed.executable == worker.path)
            #expect(sandboxed.arguments == ["usbmuxd", "/x/usbmuxd"] + plain.arguments.dropLast() + [conf.path])
            #expect(sandboxed.grants?.first == SandboxExtension.Grant(conf, .readWrite))
            #expect(sandboxed.grants?.dropFirst().allSatisfy { $0.access == .read } == true)
        }
    }
}
