import Foundation
import Testing

@testable import FirmwareKit

struct A6Setup10Tests {
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
