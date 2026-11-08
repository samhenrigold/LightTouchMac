import Foundation
import Testing
import Crypto
@testable import FirmwareKit

struct SideloadDeveloperEnvironmentTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["FK_SIDELOAD_INSTALLD_IOS9"] != nil,
                   "Set path to the prepared iOS 9 installer without the developer entitlement"))
    func nativeInstallerPreservesCodeAndExistingEntitlements() throws {
        let input = try Data(contentsOf: URL(fileURLWithPath:
            #require(ProcessInfo.processInfo.environment["FK_SIDELOAD_INSTALLD_IOS9"])))
        let oldSignature = try #require(MachOSignature.codeSignature(in: input))
        let output = try SideloadTools.installationServiceAllowingEnvironment(input)
        let signature = try #require(MachOSignature.codeSignature(in: output))
        #expect(signature.offset == oldSignature.offset && signature.size >= oldSignature.size)
        #expect(output.count == signature.offset + signature.size)
        let image = try #require(MachOSignature.images(input)?.images.first)
        var permitted = Set<Int>()
        for command in image.commands {
            if command.cmd == MachOSignature.lcCodeSignature {
                permitted.formUnion((command.offset + 12)..<(command.offset + 16))
            } else if command.cmd == 1,
                      String(decoding: input[(command.offset + 8)..<(command.offset + 24)].prefix(while: { $0 != 0 }), as: UTF8.self) == "__LINKEDIT" {
                permitted.formUnion((command.offset + 28)..<(command.offset + 32))
                permitted.formUnion((command.offset + 36)..<(command.offset + 40))
            }
        }
        let differences = Set((0..<signature.offset).filter { input[$0] != output[$0] })
        #expect(differences.isSubset(of: permitted))
        func blobs(_ data: Data) throws -> [Int: Data] {
            let s = try #require(MachOSignature.codeSignature(in: data))
            func be(_ offset: Int) -> Int {
                (0..<4).reduce(0) { $0 | Int(data[offset + $1]) << (24 - $1 * 8) }
            }
            var result: [Int: Data] = [:]
            for i in 0..<be(s.offset + 8) {
                let type = be(s.offset + 12 + i * 8), offset = s.offset + be(s.offset + 16 + i * 8)
                result[type] = data.subdata(in: offset..<(offset + be(offset + 4)))
            }
            return result
        }
        let oldBlobs = try blobs(input), newBlobs = try blobs(output)
        let oldEnt = try #require(oldBlobs[5]), newEnt = try #require(newBlobs[5])
        var expected = try #require(PropertyListSerialization.propertyList(
            from: Data(oldEnt.dropFirst(8)), format: nil) as? [String: Any])
        #expect(expected["get-task-allow"] == nil)
        expected["get-task-allow"] = true
        let actual = try #require(PropertyListSerialization.propertyList(
            from: Data(newEnt.dropFirst(8)), format: nil) as? NSDictionary)
        #expect(actual == expected as NSDictionary)
        for (type, blob) in newBlobs where type == 0 || (0x1000...0x1005).contains(type) {
            func be(_ offset: Int) -> Int {
                (0..<4).reduce(0) { $0 | Int(blob[offset + $1]) << (24 - $1 * 8) }
            }
            let width = Int(blob[36]), start = be(16) - 5 * width
            let digest = blob[37] == 1 ? Data(Insecure.SHA1.hash(data: newEnt)) : Data(SHA256.hash(data: newEnt))
            #expect(blob.subdata(in: start..<(start + width)) == digest)
        }
        #expect(try Activation.signed(output) == output)
        #expect(try SideloadTools.installationServiceAllowingEnvironment(output) == output)
        var truncated = input
        truncated.removeSubrange(oldSignature.offset..<truncated.count)
        #expect(throws: Error.self) { try SideloadTools.installationServiceAllowingEnvironment(truncated) }
        if let path = ProcessInfo.processInfo.environment["FK_SIDELOAD_INSTALLD_IOS9_OUTPUT"] {
            try output.write(to: URL(fileURLWithPath: path), options: .withoutOverwriting)
        }
    }
}
