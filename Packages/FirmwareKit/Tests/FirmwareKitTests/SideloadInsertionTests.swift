import Crypto
import Foundation
import Testing

@testable import FirmwareKit

struct SideloadInsertionTests {
    private func fixture(nonempty: Bool = false) -> Data {
        var b = ActivationTests.syntheticMachO()
        func word(_ offset: Int, _ value: UInt32) {
            for i in 0..<4 { b[offset + i] = UInt8(truncatingIfNeeded: value >> (i * 8)) }
        }
        func name(_ offset: Int, _ value: String) {
            let raw = Array(value.utf8)
            b.replaceSubrange(offset..<(offset + raw.count), with: raw)
        }
        word(4, 12)
        word(8, 9)
        word(16, 2)
        word(20, 140)
        word(44, 1)
        word(48, 124)
        name(52, "__RESTRICT")
        word(92, 1)
        name(100, "__restrict")
        name(116, "__RESTRICT")
        if nonempty { word(136, 1) }
        return Data(b)
    }

    @Test func removesOnlyTheEmptyMarkerAndKeepsSigningMetadata() throws {
        let before = fixture()
        let after = try SideloadTools.installationServiceAllowingHelper(before)
        #expect(before.count == after.count)
        #expect(String(decoding: after[100..<114], as: UTF8.self) == "__qemu_appsync")
        #expect(after[0..<100] == before[0..<100])
        #expect(after[116..<256] == before[116..<256])
        #expect(after[364..<380] == before[364..<380])  // original entitlement blob
        #expect(
            after[(ActivationTests.cd + 52)..<(ActivationTests.cd + 72)]
                == Data(Insecure.SHA1.hash(data: after[0..<256])))
        #expect(try SideloadTools.installationServiceAllowingHelper(after) == after)
    }

    @Test func preservesUnrestrictedServicesAndRejectsNonemptyMarkers() throws {
        var unrestricted = fixture()
        unrestricted[100] = Character("x").asciiValue!
        #expect(try SideloadTools.installationServiceAllowingHelper(unrestricted) == unrestricted)
        #expect(throws: FirmwareError.self) {
            try SideloadTools.installationServiceAllowingHelper(fixture(nonempty: true))
        }
        #expect(throws: FirmwareError.self) {
            try SideloadTools.installationServiceAllowingHelper(Data([0, 1, 2]))
        }
    }

    @Test(
        .enabled(
            if: ProcessInfo.processInfo.environment["FK_SIDELOAD_INSTALLD"] != nil,
            "Optional original installd fixture"))
    func nativeInstallationServicePreservesItsEntitlements() throws {
        let path = try #require(ProcessInfo.processInfo.environment["FK_SIDELOAD_INSTALLD"])
        let before = try Data(contentsOf: URL(fileURLWithPath: path))
        let after = try SideloadTools.installationServiceAllowingHelper(before)
        #expect(before.count == after.count && before != after)
        #expect(try SideloadTools.installationServiceAllowingHelper(after) == after)
        func entitlementBlob(_ bytes: Data) throws -> Data {
            let signature = try #require(MachOSignature.codeSignature(in: bytes))
            func be(_ offset: Int) -> Int {
                (0..<4).reduce(0) { $0 | Int(bytes[offset + $1]) << (24 - 8 * $1) }
            }
            for index in 0..<be(signature.offset + 8) {
                let entry = signature.offset + 12 + index * 8
                if be(entry) == 5 {
                    let blob = signature.offset + be(entry + 4)
                    return bytes.subdata(in: blob..<(blob + be(blob + 4)))
                }
            }
            Issue.record("Original installation service has no entitlement blob")
            return Data()
        }
        #expect(try entitlementBlob(before) == entitlementBlob(after))
        if let path = ProcessInfo.processInfo.environment["FK_SIDELOAD_INSTALLD_OUTPUT"] {
            try after.write(to: URL(fileURLWithPath: path), options: .withoutOverwriting)
        }
    }

}
