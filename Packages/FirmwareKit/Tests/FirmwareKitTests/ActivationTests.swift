import CryptoKit
import Foundation
import Testing
@testable import FirmwareKit

struct ActivationTests {
    private func u32(_ b: [UInt8], _ o: Int, big: Bool = true) -> Int {
        (0..<4).reduce(0) { $0 | Int(b[o + $1]) << (big ? 24 - 8 * $1 : 8 * $1) }
    }

    // Independently check every code-page hash and retained special blobs in real fixtures.
    @Test func activationCorpus() throws {
        let corpus = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Developer/qemu-ios-files/activation-native/corpus-stock")
        guard FileManager.default.fileExists(atPath: corpus.path) else { return }
        let names = try FileManager.default.contentsOfDirectory(atPath: corpus.path)
        for name in names where name.hasSuffix(".lockdownd") && !name.contains("4B1") {
            try Oracle.withTemp { dir in
                let target = dir.appendingPathComponent("lockdownd")
                try FileManager.default.copyItem(at: corpus.appendingPathComponent(name), to: target)
                try FileManager.default.setAttributes([.posixPermissions: 0o751], ofItemAtPath: target.path)
                let before = [UInt8](try Data(contentsOf: target))
                let result = try Activation.run(on: target)
                let after = [UInt8](try Data(contentsOf: target))
                #expect(result.inputSHA256 != result.outputSHA256)
                #expect((try FileManager.default.attributesOfItem(atPath: target.path)[.posixPermissions] as? NSNumber)?.intValue == 0o751)
                let command = try #require(MachOSignature.commands(after[...]).first { $0.cmd == 0x1d })
                let start = u32(after, command.at + 8, big: false)
                let count = u32(after, start + 8)
                for index in 0..<count {
                    let type = u32(after, start + 12 + index * 8)
                    #expect(type != 0x10000)
                    let blob = start + u32(after, start + 16 + index * 8)
                    let length = u32(after, blob + 4)
                    if type == 0 || (0x1000...0x1005).contains(type) {
                        #expect(u32(after, blob + 12) & 2 == 2)
                        let hashOffset = u32(after, blob + 16), special = u32(after, blob + 24)
                        let slots = u32(after, blob + 28), limit = u32(after, blob + 32)
                        let size = Int(after[blob + 36]), page = 1 << Int(after[blob + 39])
                        #expect(after[(blob + hashOffset - special * size)..<(blob + hashOffset)] == before[(blob + hashOffset - special * size)..<(blob + hashOffset)])
                        for slot in 0..<slots {
                            let bytes = Data(after[(slot * page)..<min(limit, (slot + 1) * page)])
                            let digest = after[blob + 37] == 1 ? Array(Insecure.SHA1.hash(data: bytes)) : Array(SHA256.hash(data: bytes))
                            #expect(Array(after[(blob + hashOffset + slot * size)..<(blob + hashOffset + (slot + 1) * size)]) == digest)
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

    @Test func activationSignsSyntheticMachO() throws {
        var bytes = [UInt8](repeating: 0, count: 512)
        func put(_ offset: Int, _ value: UInt32, big: Bool = true) {
            for i in 0..<4 { bytes[offset + i] = UInt8(truncatingIfNeeded: value >> (big ? 24 - i * 8 : i * 8)) }
        }
        put(0, 0xfeedface, big: false)
        put(16, 1, big: false); put(20, 16, big: false)
        put(28, 0x1d, big: false); put(32, 16, big: false)
        put(36, 256, big: false); put(40, 256, big: false)
        put(256, 0xfade0cc0); put(260, 140); put(264, 3)
        put(268, 0); put(272, 36)
        put(276, 5); put(280, 108)
        put(284, 0x10000); put(288, 124)
        let cd = 292
        put(cd, 0xfade0c02); put(cd + 4, 72); put(cd + 8, 0x20001)
        put(cd + 16, 52); put(cd + 20, 44)
        put(cd + 28, 1); put(cd + 32, 256)
        bytes[cd + 36] = 20; bytes[cd + 37] = 1; bytes[cd + 39] = 12
        put(364, 0xfade7171); put(368, 16)
        put(380, 0xfade0b01); put(384, 16)
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
