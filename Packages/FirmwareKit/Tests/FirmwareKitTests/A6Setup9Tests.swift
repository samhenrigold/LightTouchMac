import Foundation
import Testing
@testable import FirmwareKit

struct A6Setup9Tests {
    @Test(arguments: [6, 7, 8, 9, 10]) func explicitLocationChoiceCoversBothNativeDomains(major: Int) {
        let enabled = SystemEdits.finishedSetup(major: major, language: "en", locale: "en_US", locationServicesEnabled: true)
        let legacy = SystemEdits.finishedSetup(major: major, language: "en", locale: "en_US")
        let key = major >= 8 ? "LocationServicesEnabledIn8.0" : major == 7 ? "LocationServicesEnabledIn7.0" : "LocationServicesEnabled"
        for path in [SystemEdits.locationd, SystemEdits.locationdLocal] {
            #expect(enabled.first { $0.path == path }?.keys[key] as? Int == 1)
            #expect(legacy.first { $0.path == path }?.keys[key] as? Int == 0)
        }
    }
    @Test func seedsNativeSetupCompletionPredicates() throws {
        let seeds = SystemEdits.finishedSetup(major: 9, language: "en", locale: "en_US", productVersion: "9.0")
        let buddy = try #require(seeds.first { $0.path == SystemEdits.purpleBuddy }?.keys)
        #expect(buddy["SetupVersion"] as? Int == 9)
        for key in ["AppleIDPB9Presented", "Passcode4Presented", "PBDiagnostics2Presented", "AssistantPresented", "SetupDone", "SetupFinishedAllSteps"] {
            #expect(buddy[key] as? Bool == true)
        }
        #expect(buddy["AppleIDPB5Presented"] == nil)
        let local = try #require(seeds.first { $0.path == SystemEdits.purpleBuddyLocal }?.keys)
        #expect(local["LocationServices5Presented"] as? Bool == true)
        for key in ["ShouldRunKeychainSyncMiniBuddy", "ShouldRunMesaMiniBuddy", "ShouldRunPaymentMiniBuddy", "ShouldRunDiagnosticsMiniBuddy"] {
            #expect(local[key] as? Bool == false)
        }
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["FK_ACTIVATION_N42_13A344"] != nil,
                   "Set FK_ACTIVATION_N42_13A344 to original mobactivationd"))
    func admitsOnlyMatchingOriginalActivationComponent() throws {
        let path = try #require(ProcessInfo.processInfo.environment["FK_ACTIVATION_N42_13A344"])
        let bytes = try Data(contentsOf: URL(fileURLWithPath: path))
        let plan = try #require(Activation.nativeGestaltPlan(component: bytes, build: "13A344"))
        #expect(plan.inputSHA256 == plan.outputSHA256)
        #expect(plan.nativeCacheRequired == true)
        #expect(plan.gestaltOverrides?.count == 1)
        #expect(Activation.nativeGestaltPlan(component: bytes, build: "12A365") == nil)
    }
}
