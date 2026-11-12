import Foundation
import Testing

@testable import FirmwareKit

struct A6Setup10Tests {
    /// The same seed writes the same SystemGroup container files (sessions listings prepares a row twice and compares):
    /// the UUID comes from the seed and the identifier, and the plist's keys are written in order.
    @Test func containerMetadataFollowsTheSeed() throws {
        let group = A6FirstBoot.groups[0]
        let a = try A6FirstBoot.containerMetadata(group, seed: "iphone5-14G61-default")
        let b = try A6FirstBoot.containerMetadata(group, seed: "iphone5-14G61-default")
        let other = try A6FirstBoot.containerMetadata(group, seed: "iphone5-14G61-other")
        #expect(a["MCMMetadataUUID"] as? String == b["MCMMetadataUUID"] as? String)
        #expect(a["MCMMetadataUUID"] as? String != other["MCMMetadataUUID"] as? String)
        #expect(A6FirstBoot.validMetadata(a, identifier: group))
        // an NSDictionary, whose order is its keys' (NSString) hashes', the same in every process
        let ordered = try #require(LaunchdCache.ordered(["a": a, "list": [a]]) as? NSDictionary)
        #expect(ordered["a"] is NSMutableDictionary && (ordered["list"] as? [Any])?.first is NSMutableDictionary)
        #expect(ordered.isEqual(to: ["a": a, "list": [a]]))
        // the Setup completion the data ark records is the one the recipe gives
        let day = Date(timeIntervalSince1970: 1_563_796_800)
        let ark = SystemEdits.finishedSetup(major: 10, language: "en", locale: "en_US", now: day)
            .first { $0.path == SystemEdits.dataArk }?.keys
        #expect(ark?["-FirstPurpleBuddyCompletion"] as? Int == 1_563_796_800)
    }

    @Test func matchesQualifiedSetupVersionAndCloudContainer() throws {
        let seeds = SystemEdits.finishedSetup(major: 10, language: "en", locale: "en_US", productVersion: "10.3.4")
        let buddy = try #require(seeds.first { $0.path == SystemEdits.purpleBuddy }?.keys)
        #expect(buddy["SetupVersion"] as? Int == 10)
        #expect(buddy["SetupDone"] as? Bool == true)
        #expect(buddy["SetupFinishedAllSteps"] as? Bool == true)
        #expect(buddy["AssistantPresented"] as? Bool == true)
        // Retain PB6 observed in the earlier completed14G61 records.
        // Runtime qualification must also cover its post-update setup gates.
        #expect(buddy["AppleIDPB6Presented"] as? Bool == true)
        let cloud = try #require(
            seeds.first {
                $0.path
                    == "containers/Shared/SystemGroup/systemgroup.com.apple.configurationprofiles/Library/ConfigurationProfiles/CloudConfigurationDetails.plist"
            }?.keys)
        #expect(cloud["CloudConfigurationUIComplete"] as? Bool == true)
        #expect(!seeds.contains { $0.path == "mobile/Library/ConfigurationProfiles/CloudConfigurationDetails.plist" })
    }

    @Test(
        .enabled(
            if: ProcessInfo.processInfo.environment["FK_ACTIVATION_N42_14G61"] != nil,
            "Set FK_ACTIVATION_N42_14G61 to original mobileactivationd"))
    func qualifiesOriginalRelocatedDaemon() throws {
        let path = try #require(ProcessInfo.processInfo.environment["FK_ACTIVATION_N42_14G61"])
        let bytes = try Data(contentsOf: URL(fileURLWithPath: path))
        let plan = try #require(Activation.nativeGestaltPlan(component: bytes, build: "14G61"))
        #expect(plan.component == "usr/libexec/mobileactivationd")
        #expect(plan.inputSHA256 == plan.outputSHA256)
        #expect(plan.nativeCacheRequired == true)
        #expect(Activation.nativeGestaltPlan(component: bytes, build: "13A344") == nil)
        var changed = bytes
        changed[0] ^= 1
        #expect(Activation.nativeGestaltPlan(component: changed, build: "14G61") == nil)
    }
}
