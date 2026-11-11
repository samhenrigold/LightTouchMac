import DeviceRuntime
import Foundation
import HostRuntime
import Testing

@testable import LightTouchCore

/// The guest package per boot: no offer without the machine's support or an itpack; health as the board shows
/// it (the iPod's agent, the iPad's lockdown round trip); the watch publishing the loader's report into the
/// "Guest tools" status and the device record, for its own boot only.
struct GuestPackageWatchTests {
    final class Host: GuestPackageHost {
        var instance = DeviceInstance(
            id: UUID(),
            name: "iPod",
            board: "n72ap",
            firmware: "n72ap-7E18",
            created: Date(),
            base: .init(kind: .prepared, path: "base"),
            storage: .init(key: "k", overlay: "o", snapshot: "s", usbmuxConf: "u")
        )
        let bootScope = BootSessionScope()
        var status: SharedStatus? = helperStatus()
        var guestArch = "armv6"
        var state = VMState.running
        var isDead = false, shuttingDown = false, hasGuestTools = true
        var deviceReachable: Bool?
        var agentSessionEnded: Date?
    }

    func report(_ serial: Int64) -> SharedStatus {
        var status = helperStatus()
        status.guestPackage = GuestPackageReport(serial: serial, result: 1)
        status.guestPackageSupported = true
        status.agentStatus = 1
        return status
    }

    @Test func noOfferWithoutSupportOrAPack() throws {
        try withTemporaryDirectory { state in
            let host = Host()
            var asked: [String] = []
            let watch = GuestPackageWatch(host: host, stateDirectory: state) {
                asked.append($0)
                return nil
            }
            let stale = host.instance.paths.work.appendingPathComponent("guest-offer", isDirectory: true)
            try FileManager.default.createDirectory(at: stale, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: host.instance.paths.directory) }
            #expect(watch.compose() == nil && watch.offer == nil && asked.isEmpty, "an older dylib: no property")
            #expect(!FileManager.default.fileExists(atPath: stale.path), "last boot's offer is gone")
            host.status = report(1)
            #expect(watch.compose() == nil && watch.offer == nil && asked == ["armv6"], "no itpack for the arch")
            watch.start()
            #expect(watch.status == .unknown && host.bootScope[.guestPackage] == nil, "no offer, nothing to judge")
        }
    }

    @Test func healthIsTheAgentOnAnIPodAndLockdownOnAnIPad() throws {
        try withTemporaryDirectory { state in
            let host = Host()
            let watch = GuestPackageWatch(host: host, stateDirectory: state) { _ in nil }
            host.status = report(3)
            let generation = host.bootScope.generation
            #expect(watch.sample(generation: generation)?.healthy == true)
            #expect(watch.sample(generation: generation)?.report == GuestPackageReport(serial: 3, result: 1))
            host.status?.agentStatus = 2
            #expect(watch.sample(generation: generation)?.healthy == false, "a stale agent")
            host.hasGuestTools = false
            #expect(watch.sample(generation: generation)?.healthy == false, "the iPad: lockdown hasn't answered")
            host.deviceReachable = true
            #expect(watch.sample(generation: generation)?.healthy == true)
            // An agent that keeps dying (a session ended moments ago, again and again) isn't a healthy package's,
            // though lockdown answers and its status reads alive between deaths; one that has stayed up since is.
            host.agentSessionEnded = Date()
            #expect(watch.sample(generation: generation)?.healthy == false, "the iPad: its agent just died")
            host.hasGuestTools = true
            host.status?.agentStatus = 1
            #expect(watch.sample(generation: generation)?.healthy == false, "the iPod: alive again, for now")
            host.agentSessionEnded = Date(timeIntervalSinceNow: -GuestPackageWatch.agentSettle - 1)
            #expect(watch.sample(generation: generation)?.healthy == true, "it stayed up past a lease")
            host.hasGuestTools = false
            host.state = .booting
            #expect(watch.sample(generation: generation)?.healthy == false)
            host.isDead = true
            #expect(watch.sample(generation: generation) == nil, "a dead device ends the watch")
            host.isDead = false
            host.bootScope.renew()
            #expect(watch.sample(generation: generation) == nil, "so does a later boot")
        }
    }

    @Test func theWatchPublishesTheReportForItsOwnBoot() async throws {
        try await withScratchDirectory { state in
            let host = Host()
            try host.instance.write(state: state)
            let watch = GuestPackageWatch(host: host, stateDirectory: state) { _ in nil }
            watch.interval = .milliseconds(5)
            watch.offer = GuestPackage.Offer(bundled: 7, version: "1.0", serial: 7, glHook: false)
            host.status = report(7)
            var published = false
            let tracking = ObservationLoop(read: { _ = watch.status }, onChange: { published = true })
            watch.start()
            await eventually("the report reached the record") { watch.guestRecord?.active == 7 }
            await eventually("the status line updated") { published && watch.status != .unknown }
            _ = tracking

            host.bootScope.renew()  // Restart in place: this watch belongs to the old boot
            host.status = report(8)
            try await Task.sleep(for: .milliseconds(50))
            #expect(watch.guestRecord?.active == 7, "an old boot's watch writes nothing")
        }
    }
}
