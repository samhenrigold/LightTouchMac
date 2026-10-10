import CryptoKit
import Foundation
import Testing

@testable import FirmwareKit

struct ActivationTests {
    private func u32(_ b: [UInt8], _ o: Int, big: Bool = true) -> Int {
        (0..<4).reduce(0) { $0 | Int(b[o + $1]) << (big ? 24 - 8 * $1 : 8 * $1) }
    }

    /// iOS 6: lockdownd naming the lockdown_cache domain and FactoryActivated gets the data route, unchanged.
    @Test func dataArkRoute() {
        let ld = Data("xx\0com.apple.mobile.lockdown_cache\0FactoryActivated\0".utf8)
        let r = Activation.dataArkRoute(lockdownd: ld)
        #expect(r?.dataArk == ["com.apple.mobile.lockdown_cache-ActivationState": "FactoryActivated"])
        #expect(r?.inputSHA256 == r?.outputSHA256 && r?.patch == nil)
        #expect(Activation.dataArkRoute(lockdownd: Data("com.apple.mobile.lockdown_cache\0".utf8)) == nil)
    }

    // Independently check every code-page hash and retained special blobs in real fixtures.
    @Test(.enabled(if: FixtureRequirements.corpusEnabled, "Firmware corpus test; set FK_TEST_CORPUS=1 to run"))
    func activationCorpus() throws {
        let corpus = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Developer/qemu-ios-files/activation-native/corpus-stock")
        guard FileManager.default.fileExists(atPath: corpus.path) else {
            try FixtureRequirements.missing(
                #"ActivationTests.swift: FileManager.default.fileExists(atPath: corpus.path)"#
            )
        }
        let names = try FileManager.default.contentsOfDirectory(atPath: corpus.path)
        for name in names where name.hasSuffix(".lockdownd") {
            try Oracle.withTemp { dir in
                let target = dir.appendingPathComponent("lockdownd")
                try FileManager.default.copyItem(at: corpus.appendingPathComponent(name), to: target)
                try FileManager.default.setAttributes([.posixPermissions: 0o751], ofItemAtPath: target.path)
                let before = [UInt8](try Data(contentsOf: target))
                let result = try Activation.run(on: target)
                let after = [UInt8](try Data(contentsOf: target))
                #expect(result.inputSHA256 != result.outputSHA256)
                let patch = try #require(result.patch)
                #expect(!patch.strategy.isEmpty && !patch.isa.isEmpty)
                #expect(patch.original != patch.replacement)
                #expect(Data(before[patch.offset..<(patch.offset + patch.original.count)]) == patch.original)
                #expect(Data(after[patch.offset..<(patch.offset + patch.replacement.count)]) == patch.replacement)
                if name.contains("9B206") {
                    #expect(patch.strategy == "development-activation-shortcut")
                    #expect(patch.original == Data([0x3f, 0xf4, 0x71, 0xaf]))
                    #expect(patch.replacement == Data([0, 0xbf, 0, 0xbf]))
                }
                if name.contains("9A5220p") {  // a pointer load (LDR immediate) between the log arguments
                    #expect(
                        patch.offset == 35502 && patch.original == Data([0x81, 0xd0])
                            && patch.replacement == Data([0, 0xbf])
                    )
                }
                #expect(
                    (try FileManager.default.attributesOfItem(atPath: target.path)[.posixPermissions] as? NSNumber)?
                        .intValue == 0o751
                )
                if name.contains("4B1") {
                    #expect(MachOSignature.codeSignature(in: Data(after)) == nil)
                    #expect(throws: ActivationFailure.self) { try Activation.run(on: target) }
                    #expect(try Data(contentsOf: target) == Data(after))
                    return
                }
                let start = try #require(MachOSignature.codeSignature(in: Data(after))).offset
                let count = u32(after, start + 8)
                for index in 0..<count {
                    let type = u32(after, start + 12 + index * 8)
                    #expect(type != 0x10000)
                    let blob = start + u32(after, start + 16 + index * 8)
                    let length = u32(after, blob + 4)
                    if type == 0 || (0x1000...0x1005).contains(type) {
                        #expect(u32(after, blob + 12) & 2 == 2)
                        let hashOffset = u32(after, blob + 16)
                        let special = u32(after, blob + 24)
                        let slots = u32(after, blob + 28)
                        let limit = u32(after, blob + 32)
                        let size = Int(after[blob + 36])
                        let page = 1 << Int(after[blob + 39])
                        #expect(
                            after[(blob + hashOffset - special * size)..<(blob + hashOffset)]
                                == before[(blob + hashOffset - special * size)..<(blob + hashOffset)]
                        )
                        for slot in 0..<slots {
                            let bytes = Data(after[(slot * page)..<min(limit, (slot + 1) * page)])
                            let digest =
                                after[blob + 37] == 1
                                ? Array(Insecure.SHA1.hash(data: bytes)) : Array(SHA256.hash(data: bytes))
                            #expect(
                                Array(
                                    after[(blob + hashOffset + slot * size)..<(blob + hashOffset + (slot + 1) * size)]
                                ) == digest
                            )
                        }
                    } else {
                        #expect(after[blob..<(blob + length)] == before[blob..<(blob + length)])
                    }
                }
                #expect(throws: ActivationFailure.self) { try Activation.run(on: target) }
                #expect(try Data(contentsOf: target) == Data(after))
            }
        }
    }

    /// 1.0 (1A543a): no strategy before this one matched; the no-record initializer is conditional code
    /// (cmp; moveq brick,#1; ldreq state,=Unactivated; ...; beq store). Only it changes.
    @Test(.enabled(if: FileManager.default.fileExists(atPath: Self.lockdownd10.path), "needs the 1A543a lockdownd"))
    func iPhone10() throws {
        try Oracle.withTemp { dir in
            let target = dir.appendingPathComponent("lockdownd")
            try FileManager.default.copyItem(at: Self.lockdownd10, to: target)
            let before = try Data(contentsOf: target)
            let patch = try #require(try Activation.run(on: target).patch)
            #expect(
                patch.strategy == "conditional-no-record-initializer" && patch.isa == "arm" && patch.offset == 0x90a4
            )
            #expect(patch.original == Data([0x01, 0xa0, 0xa0, 0x03, 0x3c, 0x53, 0x9f, 0x05]))
            // moveq r10,#0; ldreq r5,=Activated
            #expect(patch.replacement == Data([0x00, 0xa0, 0xa0, 0x03, 0x44, 0x53, 0x9f, 0x05]))
            let after = try Data(contentsOf: target)
            #expect(after.count == before.count && zip(before, after).filter { $0 != $1 }.count == 2)
            #expect(throws: ActivationFailure.self) { try Activation.run(on: target) }
        }
    }
    static let lockdownd10 = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Developer/qemu-ios-files/m68/m68_10/lockdownd.copy")

    @Test func olderPreparationRecordsRemainReadable() throws {
        let old = Data(#"{"inputSHA256":"input","outputSHA256":"output"}"#.utf8)
        let result = try JSONDecoder().decode(Activation.Result.self, from: old)
        #expect(result.patch == nil)
        #expect(result.inputSHA256 == "input")
    }

    /// A 32-bit Mach-O of 512 bytes signed over its first page (256 bytes, code from offset 44 free): a SHA-1 code
    /// directory at `cd`, a requirements blob at 364, an entitlements blob at 380 and a CMS slot.
    static let cd = 292
    static func syntheticMachO() -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: 512)
        func put(_ offset: Int, _ value: UInt32, big: Bool = true) {
            for i in 0..<4 { bytes[offset + i] = UInt8(truncatingIfNeeded: value >> (big ? 24 - i * 8 : i * 8)) }
        }
        put(0, 0xfeed_face, big: false)
        put(16, 1, big: false)
        put(20, 16, big: false)
        put(28, 0x1d, big: false)
        put(32, 16, big: false)
        put(36, 256, big: false)
        put(40, 256, big: false)
        put(256, 0xfade_0cc0)
        put(260, 140)
        put(264, 3)
        put(268, 0)
        put(272, 36)
        put(276, 5)
        put(280, 108)
        put(284, 0x10000)
        put(288, 124)
        put(cd, 0xfade_0c02)
        put(cd + 4, 72)
        put(cd + 8, 0x20001)
        put(cd + 16, 52)
        put(cd + 20, 44)
        put(cd + 28, 1)
        put(cd + 32, 256)
        bytes[cd + 36] = 20
        bytes[cd + 37] = 1
        bytes[cd + 39] = 12
        put(364, 0xfade_7171)
        put(368, 16)
        put(380, 0xfade_0b01)
        put(384, 16)
        return bytes
    }

    @Test func activationSignsSyntheticMachO() throws {
        var bytes = Self.syntheticMachO()
        let cd = Self.cd
        let output = [UInt8](try Activation.signed(Data(bytes)))
        #expect(u32(output, 264) == 2)
        #expect(u32(output, cd + 12) == 2)
        #expect(Array(output[(cd + 52)..<(cd + 72)]) == Array(Insecure.SHA1.hash(data: Data(bytes[0..<256]))))
        #expect(output[364..<380] == bytes[364..<380])
        // Invalid signing layouts fail rather than guessing at page mappings.
        bytes[cd + 39] = 0
        #expect(throws: ActivationFailure.self) { try Activation.signed(Data(bytes)) }
    }

    @Test func activationRejectsMalformedSignatures() throws {
        for length in [0, 27, 28, 128] {
            #expect(throws: ActivationFailure.self) { try Activation.signed(Data(repeating: 0, count: length)) }
        }
    }
}
