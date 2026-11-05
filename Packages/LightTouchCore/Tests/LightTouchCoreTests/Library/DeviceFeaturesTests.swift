import Foundation
import HostRuntime
import Testing

@testable import LightTouchCore

/// DeviceFeatures over the shipped catalog and machines: each feature follows the rule the app goes by when the
/// device runs, and GuestPackage.packaged finds the entries an itpack holds the guest agent for.
struct DeviceFeaturesTests {
    static func features(_ id: String, guestPackage: Bool = false) -> DeviceFeatures {
        _ = ShippedResources.machines
        return DeviceFeatures(ShippedResources.catalog.entry(id: id)!, guestPackage: guestPackage)
    }

    @Test func eachBoardAndVersionGetsItsOwnFeatures() {
        // iPhone 3GS 6.1.6: a modem with GPS, a compass, a motor, sound, Skip Setup, Jailbreak.
        let n88 = Self.features("n88ap-10B500")
        #expect(n88.cellular && n88.location && n88.compass && n88.vibration && n88.audio && n88.skipSetup)
        #expect(n88.jailbreak && n88.appInstalls && n88.fileSystem && n88.freeFormScreen && !n88.guestTools)
        // iPhone 3GS 3.1.3: GPS, compass and sound as on 6.x, but no Skip Setup.
        let n88ios3 = Self.features("n88ap-7E18")
        #expect(n88ios3.audio && n88ios3.location && n88ios3.compass && !n88ios3.skipSetup)
        // iPhone 4 7.1.2: a modem, a compass and a motor but no GPS.
        let n90 = Self.features("n90ap-11D257", guestPackage: true)
        #expect(n90.cellular && !n90.location && n90.compass && n90.vibration && n90.guestTools && n90.fileSystem)
        // iPod touch 1.1.4: no apps, no free-form screen, no Skip Setup or Jailbreak; its store edits while stopped.
        let n45 = Self.features("n45ap-4A102")
        #expect(!n45.cellular && !n45.vibration && !n45.compass && !n45.appInstalls && !n45.freeFormScreen)
        #expect(!n45.skipSetup && !n45.jailbreak && n45.fileSystem && n45.audio)
        // iPad 3.2.2: a compass but no modem or motor; before iOS 5, no Skip Setup; SSH packaged for 7B500.
        let k48 = Self.features("k48ap-7B500")
        #expect(!k48.cellular && !k48.location && k48.compass && !k48.vibration && !k48.skipSetup && k48.developerTools)
        #expect(Self.features("k48ap-9B206").skipSetup && !Self.features("k48ap-9B206").developerTools)
        // The iPod touch 2G carries its tools from preparation, package or not; the 3.1.3 image the app ships is
        // never prepared, so it offers no Jailbreak, where a downloaded 3.1.2 does.
        let n72 = Self.features("n72ap-7E18")
        #expect(n72.guestTools && !n72.jailbreak && Self.features("n72ap-7D11").jailbreak)
    }

    @Test func packagedFindsTheBoardsAndBuildsAnItpackHoldsTheAgentFor() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let armv6 = dir.appendingPathComponent("armv6.itpack")
        try GuestPackageOfferTests.itpack(
            armv6,
            GuestPackageOfferTests.package("n72-ios3", builds: ["7E18"], serial: 1)
                + GuestPackageOfferTests.package("n72-ios2", builds: ["5*"], serial: 2)
                + GuestPackageOfferTests.package("n72-ios30", builds: ["7A341"], serial: 3, stub: true)
                // it_prefs and no agent, as the shipped 4.x package is.
                + GuestPackageOfferTests.package("n72-ios4", builds: ["8*"], serial: 4).filter {
                    !$0.name.hasSuffix("bin/it_agent")
                }
        )
        let catalog = ShippedResources.catalog
        let found = GuestPackage.packaged(catalog.entries) { $0 == "armv6" ? armv6 : nil }
        let n72 = catalog.entries.filter { $0.board == "n72ap" }
        #expect(found == Set(n72.filter { $0.build == "7E18" || $0.build.hasPrefix("5") }.map(\.id)))
        #expect(found.contains("n72ap-7E18") && !found.contains("n72ap-7A341") && !found.contains("n72ap-8C148"))
    }

    /// Device ▸ Tweaks' availability: an iPhone takes the agent from a guest package at boot, so its rows aren't all
    /// "Needs the guest tools"; the iPod touch 2G has it from its image, package or not; no package, no agent.
    @Test func aPackagedAgentCountsForTweaks() throws {
        _ = ShippedResources.machines
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let armv7 = dir.appendingPathComponent("armv7.itpack")
        try GuestPackageOfferTests.itpack(
            armv7,
            GuestPackageOfferTests.package("n90-ios5", builds: ["9B208"], board: "n90ap", serial: 1)
        )
        let catalog = ShippedResources.catalog
        func runs(_ id: String, _ pack: URL?) -> Bool {
            GuestPackage.runsAgent(firmware: id, catalog: catalog) { _ in pack }
        }
        #expect(runs("n90ap-9B208", armv7))
        #expect(!runs("n90ap-9B208", nil))
        #expect(!runs("n90ap-8L1", armv7))
        #expect(runs("n72ap-7E18", nil))
        #expect(!runs("no-such-firmware", armv7))
        let tweak = try #require(
            Tweak.allCases.first { $0.unavailable(version: "5.1.1", guestTools: false, clockPinned: false) != nil }
        )
        #expect(tweak.unavailable(version: "5.1.1", guestTools: runs("n90ap-9B208", armv7), clockPinned: false) == nil)
    }
}
