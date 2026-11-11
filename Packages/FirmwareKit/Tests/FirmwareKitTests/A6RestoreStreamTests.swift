import Foundation
import Testing

@testable import FirmwareKit

struct A6RestoreStreamTests {
    private func temporary(_ body: (URL) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try body(root)
    }
    private func little(_ b: Data, _ offset: Int, _ count: Int) -> UInt64 {
        (0..<count).reduce(0) { $0 | UInt64(b[offset + $1]) << ($1 * 8) }
    }
    private func blocks(_ stream: Data) -> [(UInt64, Data)] {
        var rows: [(UInt64, Data)] = []
        var offset = 24
        for _ in 0..<little(stream, 16, 4) {
            let destination = little(stream, offset, 8)
            let count = Int(little(stream, offset + 8, 4))
            rows.append((destination, stream.subdata(in: (offset + 16)..<(offset + 16 + count))))
            offset += 16 + count
        }
        #expect(offset == stream.count)
        return rows
    }

    @Test func boundedChangesAndGrowthRetainNativeWireFormat() throws {
        try temporary { root in
            let before = root.appendingPathComponent("base")
            let after = root.appendingPathComponent("image")
            let output = root.appendingPathComponent("stream")
            let original = Data(repeating: 0, count: 65536)
            var image = original + Data(repeating: 0, count: 4096)
            image.replaceSubrange(0..<8192, with: repeatElement(0x41, count: 8192))
            image[12288] = 0x42
            try original.write(to: before)
            try image.write(to: after)
            let result = try A6RestoreStream.writeDelta(base: before, image: after, output: output)
            let stream = try Data(contentsOf: output)
            let rows = blocks(stream)
            #expect(stream.prefix(4) == Data("A6DI".utf8))
            #expect(little(stream, 4, 4) == 1 && little(stream, 8, 8) == 16_000_000_000)
            #expect(result.records == 3 && result.payloadBytes == 16384)
            #expect(rows.map(\.0) == [16_777_216, 16_789_504, 16_842_752])
            #expect(rows[0].1 == image[0..<8192])
            #expect(rows[2].1 == Data(repeating: 0, count: 4096))  // growth includes zeroes
            #expect(try Data(contentsOf: before) == original)
        }
    }

    private func hfs(allocated: Bool) -> Data {
        var b = [UInt8](repeating: 0, count: 32 * 4096)
        b[1024] = 0x48
        b[1025] = 0x58
        putBE32(&b, 1024 + 40, 4096)
        putBE32(&b, 1024 + 44, 32)
        putBE64(&b, 1024 + 112, 4)
        putBE32(&b, 1024 + 128, 1)
        putBE32(&b, 1024 + 132, 1)
        b[4096] = allocated ? 0xc8 : 0xc0  // bitmap's newly allocated block4 stays all-zero
        return Data(b)
    }

    @Test func includesNewlyAllocatedZeroesAndSupportsReadOnlyVerification() throws {
        try temporary { root in
            let base = root.appendingPathComponent("base")
            let target = root.appendingPathComponent("image")
            try hfs(allocated: false).write(to: base)
            try hfs(allocated: true).write(to: target)
            let output = root.appendingPathComponent("delta")
            let result = try A6RestoreStream.writeDelta(base: base, image: target, output: output)
            #expect(result.forcedAllocatedBlocks == 1)
            let rows = blocks(try Data(contentsOf: output))
            #expect(rows.contains { $0.0 == 16_777_216 + 4 * 4096 && $0.1.allSatisfy { $0 == 0 } })
            var options = A6RestoreStream.Options()
            options.verifyAllocated = true
            let verify = root.appendingPathComponent("verify")
            let manifest = try A6RestoreStream.writeDelta(base: target, image: target, output: verify, options: options)
            let stream = try Data(contentsOf: verify)
            #expect(manifest.verifyOnly && little(stream, 20, 4) == 1)
            #expect(manifest.payloadBytes == 4 * 4096)  // headers, bitmap, allocated block4
        }
    }

    @Test func refusesInvalidInputsAndNeverOverwritesArtifacts() throws {
        try temporary { root in
            let base = root.appendingPathComponent("base")
            let image = root.appendingPathComponent("image")
            let output = root.appendingPathComponent("out")
            try Data(repeating: 0, count: 4096).write(to: base)
            try Data(repeating: 0, count: 4095).write(to: image)
            #expect(throws: FirmwareError.self) {
                try A6RestoreStream.writeDelta(base: base, image: image, output: output)
            }
            #expect(!FileManager.default.fileExists(atPath: output.path))
            try Data(repeating: 0, count: 4096).write(to: image)
            let sentinel = Data("keep".utf8)
            try sentinel.write(to: output)
            #expect(throws: FirmwareError.self) {
                try A6RestoreStream.writeDelta(base: base, image: image, output: output)
            }
            #expect(try Data(contentsOf: output) == sentinel)
            var options = A6RestoreStream.Options()
            options.partitionOffset = UInt64.max
            #expect(throws: FirmwareError.self) {
                try A6RestoreStream.writeDelta(
                    base: base, image: image, output: root.appendingPathComponent("new"), options: options)
            }
        }
    }

    @Test func initialRestoreWritesBothVolumesAndAllocatedZeroesWithoutFreeSpace() throws {
        try temporary { root in
            let system = root.appendingPathComponent("system")
            let data = root.appendingPathComponent("data")
            let image = hfs(allocated: true)
            try image.write(to: system)
            try image.write(to: data)
            let layout = try A6StorageLayout(
                mediaBytes: (16 << 20) + UInt64(2 * image.count), systemBytes: UInt64(image.count))
            let output = root.appendingPathComponent("initial")
            try A6RestoreStream.writeInitial(system: system, data: data, output: output, layout: layout)
            let stream = try Data(contentsOf: output)
            let rows = blocks(stream)
            #expect(little(stream, 20, 4) == 0)  // restore, not verification
            #expect(rows.count == 7)
            #expect(rows[0].0 == 0 && rows[0].1 == layout.partitionTable())
            for offset in [layout.systemOffset, layout.dataOffset] {
                #expect(rows.contains { $0.0 == offset + 4 * 4096 && $0.1 == Data(repeating: 0, count: 4096) })
                #expect(!rows.contains { $0.0 <= offset + 2 * 4096 && $0.0 + UInt64($0.1.count) > offset + 2 * 4096 })
            }
            #expect(rows.reduce(0) { $0 + $1.1.count } == 9 * 4096)
            #expect(throws: FirmwareError.self) {
                try A6RestoreStream.writeInitial(system: system, data: data, output: output, layout: layout)
            }
        }
    }

    @Test(
        .enabled(
            if: ProcessInfo.processInfo.environment["FK_A6_DELTA_BASE"] != nil,
            "Optional real System delta, already restored natively"))
    func matchesTheQualifiedNativeRestoreExactly() throws {
        let env = ProcessInfo.processInfo.environment
        let base = URL(fileURLWithPath: try #require(env["FK_A6_DELTA_BASE"]))
        let image = URL(fileURLWithPath: try #require(env["FK_A6_DELTA_IMAGE"]))
        let reference = URL(fileURLWithPath: try #require(env["FK_A6_DELTA_REFERENCE"]))
        try temporary { root in
            let output = root.appendingPathComponent("native.a6di")
            let result = try A6RestoreStream.writeDelta(base: base, image: image, output: output)
            #expect(try Data(contentsOf: output) == Data(contentsOf: reference))
            #expect(result.records == 58 && result.payloadBytes == 1_658_880)
        }
    }
}
