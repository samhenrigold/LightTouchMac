import Foundation
import Testing

@testable import FirmwareKit

struct RootFilesystemImageTests {
    private func image() -> Data {
        var image = Data(count: 1024)
        var trailer = Data("koly".utf8) + be(4, 4) + be(512, 4)
        trailer += Data(count: 512 - trailer.count)
        trailer.replaceSubrange(0xD8..<0xE8, with: be(512, 8) + be(128, 8))
        image += trailer
        return image
    }

    private func be(_ value: UInt64, _ count: Int) -> Data {
        Data((0..<count).reversed().map { UInt8(truncatingIfNeeded: value >> ($0 * 8)) })
    }

    @Test func plaintextNeedsNoKeyAndPreservesBytes() throws {
        try Oracle.withTemp { dir in
            let source = dir.appendingPathComponent("plain.dmg")
            let output = dir.appendingPathComponent("out.dmg")
            let bytes = image()
            try bytes.write(to: source)
            let input = try FileHandle(forReadingFrom: source)
            defer { try? input.close() }
            try RootFilesystemImage.extract(from: input.fileDescriptor, output: output) {
                Issue.record("a clear UDIF must not request a key")
                throw FirmwareError(.keyMissing, "no key")
            }
            #expect(try Data(contentsOf: output) == bytes)
        }
    }

    @Test(arguments: [0, 1, 2]) func rejectsMalformedPlaintext(_ damage: Int) throws {
        try Oracle.withTemp { dir in
            var bytes = image()
            switch damage {
            case 0: bytes[1024] = 0  // no koly signature
            case 1: bytes.replaceSubrange(1024 + 0xD8..<1024 + 0xE0, with: be(UInt64.max, 8))
            default: bytes = Data(bytes.prefix(300))
            }
            let source = dir.appendingPathComponent("bad.dmg")
            let output = dir.appendingPathComponent("out.dmg")
            try bytes.write(to: source)
            let input = try FileHandle(forReadingFrom: source)
            defer { try? input.close() }
            #expect(throws: FirmwareError.self) {
                try RootFilesystemImage.extract(from: input.fileDescriptor, output: output) { Data() }
            }
            #expect(!FileManager.default.fileExists(atPath: output.path))
        }
    }
}
