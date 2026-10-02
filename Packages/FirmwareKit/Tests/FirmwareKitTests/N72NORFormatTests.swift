import Foundation
import Testing
@testable import FirmwareKit

struct N72NORFormatTests {
    func fixture() throws -> (base: Data, images: [String: Data]) {
        let id = try UnitIdentity.synthesizeIPod(seed: "nor-format-test", modelNumber: "MB528", regionInfo: "LL/A")
        var images: [String: Data] = [:]
        for type in ["illb", "ibot", "dtre"] {
            let payload = Data("ATAD".utf8) + DeviceTree.Value.le([28, 16]) + Data(0..<16)
            let signature = Data("HSHS".utf8) + DeviceTree.Value.le([140, 128]) + Data(0..<128)
            images[type] = Data("3gmI".utf8) + DeviceTree.Value.le([UInt32(20 + payload.count + signature.count), UInt32(payload.count + signature.count), UInt32(payload.count)])
                + Data(type.utf8.reversed()) + payload + signature
        }
        return (try N72NOR.build(identity: id, images: images, types: ["illb", "ibot", "dtre"], wrapTypes: ["ibot"]), images)
    }

    @Test func signatureConversionPreservesEverythingElse() throws {
        let (base, _) = try fixture()
        var writable = base
        // Identity, effaceable/keybag space and NVRAM belong to this device.
        for offset in [0x4100, 0x2000, 0xfc100, 0xfffff] { writable[offset] ^= 0x55 }
        let plan = try N72NORFormat.migrate(build: "5F138", base: base, writable: writable, legacyWrappedTypes: ["ibot"], expectedImageTypes: ["illb", "ibot", "dtre"])
        var expectedBase = base, expectedWritable = writable
        for range in plan.signatureRanges {
            expectedBase.replaceSubrange(range, with: plan.base.subdata(in: range))
            expectedWritable.replaceSubrange(range, with: plan.writable.subdata(in: range))
        }
        #expect(plan.base == expectedBase)
        #expect(plan.writable == expectedWritable)
        #expect(plan.signatureRanges.count == 3)
        let vector = try #require(Data(hex: "17b7f833ad9c2d7cba7a549e1f237f8ea448c17c33ccf4106b1f3f7a5045e0e545ddceda22d7cc089abd0e51a0fc264dd8be95d4ca096e5a0611ff7db4aec38b6ee551d4500602e03eb0f9bf7d9ebf6acb7a94283fa058a29bdf2fbb7b4582354dd6f1b39e250bea5e596bc6c6ebfeb9b18f46e9957b4c5adaa374674d8799f4"))
        for range in plan.signatureRanges { #expect(plan.base.subdata(in: range) == vector) }
        // A prior candidate whose working envelopes were already converted is
        // recognized exactly; no heuristic interprets arbitrary signatures.
        let retried = try N72NORFormat.migrate(build: "5F138", base: base, writable: plan.writable, legacyWrappedTypes: ["ibot"], expectedImageTypes: ["illb", "ibot", "dtre"])
        #expect(retried.writable == plan.writable)
    }

    @Test func changedFirmwareRetainsOriginal() throws {
        let (base, _) = try fixture()
        var writable = base
        writable[0x8000 + 32] ^= 1
        #expect(throws: N72NORFormat.Failure.changedFirmware) {
            try N72NORFormat.migrate(build: "5F138", base: base, writable: writable, legacyWrappedTypes: ["ibot"], expectedImageTypes: ["illb", "ibot", "dtre"])
        }
        writable = base; writable[0x8000 + 60] ^= 1
        #expect(throws: N72NORFormat.Failure.changedFirmware) {
            try N72NORFormat.migrate(build: "5F138", base: base, writable: writable, legacyWrappedTypes: ["ibot"], expectedImageTypes: ["illb", "ibot", "dtre"])
        }
    }

    @Test(arguments: [0, 16, 0xfffff]) func malformedInputFailsWithoutMutation(_ size: Int) throws {
        let (base, _) = try fixture()
        #expect(throws: N72NORFormat.Failure.malformedNOR) {
            try N72NORFormat.migrate(build: "5F138", base: Data(count: size), writable: base, legacyWrappedTypes: [], expectedImageTypes: ["illb", "ibot", "dtre"])
        }
    }

    @Test func missingImageAndUnrecognizedGapAreRejected() throws {
        let (base, _) = try fixture()
        // Each fixture image is padded to192 bytes; corrupt the second marker
        // rather than permitting scan to silently migrate only the first image.
        for replacement: UInt8 in [0, 0xff] {
            var broken = base
            broken.replaceSubrange(0x80c0..<0x80c4, with: Data(repeating: replacement, count: 4))
            #expect(throws: N72NORFormat.Failure.malformedNOR) {
                try N72NORFormat.migrate(build: "5F138", base: broken, writable: broken,
                    legacyWrappedTypes: [], expectedImageTypes: ["illb", "ibot", "dtre"])
            }
        }
        var truncated = base
        truncated.replaceSubrange(0x80c0..<0xfc000, with: Data(repeating: 0xff, count: 0xfc000 - 0x80c0))
        #expect(throws: N72NORFormat.Failure.malformedNOR) {
            try N72NORFormat.migrate(build: "5F138", base: truncated, writable: truncated,
                legacyWrappedTypes: [], expectedImageTypes: ["illb", "ibot", "dtre"])
        }
        // Even a changed inventory cannot admit a prefix shorter than the
        // IMG2 span recorded by the original generated image.
        var zeroTail = base
        zeroTail.replaceSubrange(0x80c0..<0xfc000, with: Data(count: 0xfc000 - 0x80c0))
        #expect(throws: N72NORFormat.Failure.malformedNOR) {
            try N72NORFormat.migrate(build: "5F138", base: zeroTail, writable: zeroTail,
                legacyWrappedTypes: [], expectedImageTypes: ["illb"])
        }
        var gap = base; gap[0x9000] = 0x42
        #expect(throws: N72NORFormat.Failure.malformedNOR) {
            try N72NORFormat.migrate(build: "5F138", base: gap, writable: gap,
                legacyWrappedTypes: ["ibot"], expectedImageTypes: ["illb", "ibot", "dtre"])
        }
    }

    @Test func otherBuildsAndUnknownStagePolicyAreNotGuessed() throws {
        let (base, _) = try fixture()
        #expect(throws: N72NORFormat.Failure.unsupportedBuild) {
            try N72NORFormat.migrate(build: "7E18", base: base, writable: base, legacyWrappedTypes: ["ibot"], expectedImageTypes: ["illb", "ibot", "dtre"])
        }
        #expect(throws: N72NORFormat.Failure.unknownWrapping) {
            try N72NORFormat.migrate(build: "5F138", base: base, writable: base, legacyWrappedTypes: ["missing"], expectedImageTypes: ["illb", "ibot", "dtre"])
        }
    }
}
