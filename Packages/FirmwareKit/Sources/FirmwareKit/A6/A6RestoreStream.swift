import Crypto
import Foundation

/// Bounded System-image updates consumed by the existing native A6 restore
/// helper. Inputs must be immutable snapshots from a stopped VM. This never
/// opens NAND or changes a partition map, protected Data volume or keybag.
public enum A6RestoreStream {
    public struct Options: Sendable {
        public var mediaBytes: UInt64 = A6StorageLayout.defaultMediaBytes
        public var partitionOffset: UInt64 = 16 << 20
        public var repairAllocatedZeroes = false
        public var verifyAllocated = false
        /// Initial media has no meaningful base contents. Restore every used
        /// filesystem block, including zeroes, without copying free space.
        public var allocatedOnly = false
        public init() {}
    }

    public struct Manifest: Codable, Sendable {
        public let baseSHA256: String, imageSHA256: String
        public let mediaBytes: UInt64, partitionOffset: UInt64
        public let records: UInt32, payloadBytes: UInt64, forcedAllocatedBlocks: UInt64
        public let repairAllocatedZeroes: Bool, verifyOnly: Bool
    }

    private struct Allocation {
        let bitmap: Data
        let volumeBlocks: Int
        func used(_ index: Int) -> Bool {
            guard index < volumeBlocks else { return false }
            return index == 0 || index == volumeBlocks - 1 ||
                bitmap[index / 8] & (0x80 >> (index % 8)) != 0
        }
    }

    private static func invalid(_ message: String) -> FirmwareError {
        FirmwareError(.unsupported, "A6 restore stream: \(message)")
    }
    private static func read(_ file: FileHandle, _ count: Int) throws -> Data {
        var bytes = Data()
        while bytes.count < count {
            guard let part = try file.read(upToCount: count - bytes.count), !part.isEmpty else {
                throw invalid("short image read")
            }
            bytes.append(part)
        }
        return bytes
    }
    private static func append<T: FixedWidthInteger>(_ value: T, to data: inout Data) {
        var little = value.littleEndian
        withUnsafeBytes(of: &little) { data.append(contentsOf: $0) }
    }

    /// Read only the allocation fork's eight primary extents. Like the native
    /// writer, refuse unsupported overflow rather than guessing which zeroes
    /// were previously restored. Header and alternate-header blocks are used.
    private static func allocation(_ file: FileHandle, bytes: UInt64) throws -> Allocation? {
        guard bytes >= 1536 else { return nil }
        try file.seek(toOffset: 1024)
        let header = [UInt8](try read(file, 512))
        guard header[0] == 0x48, header[1] == 0x2b || header[1] == 0x58 else { return nil }
        let blockSize = UInt64(try be32(header, 40)), blocks = UInt64(try be32(header, 44))
        guard blockSize == 4096, blocks > 0, blocks <= bytes / 4096 else {
            throw invalid("unsupported HFS+ allocation geometry")
        }
        let logical = try be64(header, 112)
        guard logical >= (blocks + 7) / 8, logical <= 4 << 20 else {
            throw invalid("invalid allocation bitmap size")
        }
        var bitmap = Data()
        for index in 0..<8 {
            let start = UInt64(try be32(header, 128 + index * 8))
            let count = UInt64(try be32(header, 132 + index * 8))
            if count == 0 { continue }
            guard start < blocks, count <= blocks - start else {
                throw invalid("allocation extent outside volume")
            }
            if bitmap.count < Int(logical) {
                try file.seek(toOffset: start * 4096)
                bitmap.append(try read(file, min(Int(count * 4096), Int(logical) - bitmap.count)))
            }
        }
        guard bitmap.count == Int(logical) else { throw invalid("allocation bitmap needs overflow extents") }
        return Allocation(bitmap: bitmap, volumeBlocks: Int(blocks))
    }

    /// Write a new, exclusive A6DI stream. Newly allocated zero blocks must be
    /// included even if equal in the image files: their NAND contents are not
    /// known. Records are at most 64 KiB and carry the native CRC-32 checksum.
    @discardableResult
    public static func writeDelta(base: URL, image: URL, output: URL,
                                  options: Options = .init()) throws -> Manifest {
        let source = try FileHandle(forReadingFrom: base)
        defer { try? source.close() }
        let target = try FileHandle(forReadingFrom: image)
        defer { try? target.close() }
        let baseSize = try source.seekToEnd(), size = try target.seekToEnd()
        let offset = options.partitionOffset
        guard size > 0, baseSize <= size, baseSize % 4096 == 0, size % 4096 == 0,
              offset >= 4096, offset % 4096 == 0,
              options.mediaBytes > 0, options.mediaBytes <= 1 << 40,
              options.mediaBytes % 4096 == 0, size <= options.mediaBytes,
              offset <= options.mediaBytes - size else {
            throw invalid("unaligned or out-of-range image/partition")
        }
        let baseUsed = try allocation(source, bytes: baseSize)
        let targetUsed = try allocation(target, bytes: size)
        if (options.repairAllocatedZeroes || options.verifyAllocated || options.allocatedOnly) && targetUsed == nil {
            throw invalid("allocation-aware options require HFS+")
        }
        // Never truncate an existing artifact, image, symlink or hard link.
        let fd = open(output.path, O_WRONLY | O_CREAT | O_EXCL, 0o600)
        guard fd >= 0 else { throw invalid("output must be a new file") }
        let stream = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        var complete = false
        defer {
            try? stream.close()
            if !complete { try? FileManager.default.removeItem(at: output) }
        }
        try source.seek(toOffset: 0); try target.seek(toOffset: 0)
        var header = Data("A6DI".utf8)
        // Header capacity describes the whole device, not this partition.
        append(UInt32(1), to: &header); append(options.mediaBytes, to: &header)
        append(UInt32(0), to: &header); append(UInt32(options.verifyAllocated ? 1 : 0), to: &header)
        try stream.write(contentsOf: header)
        var beforeHash = SHA256(), afterHash = SHA256()
        var records: UInt32 = 0, payload: UInt64 = 0, forced: UInt64 = 0
        var position: UInt64 = 0
        while position < size {
            try Task.checkCancellation()
            let amount = Int(min(65536, size - position))
            let oldSize = Int(position < baseSize ? min(UInt64(amount), baseSize - position) : 0)
            let old = try read(source, oldSize), new = try read(target, amount)
            beforeHash.update(data: old); afterHash.update(data: new)
            var run: Int?
            for index in stride(from: 0, through: amount, by: 4096) {
                var changed = false
                if index < amount {
                    changed = index >= oldSize || old[index..<(index + 4096)] != new[index..<(index + 4096)]
                    if let allocation = targetUsed {
                        let block = Int(position / 4096) + index / 4096
                        let used = allocation.used(block)
                        let newlyUsed = used && !(baseUsed?.used(block) ?? false)
                        let repair = used && options.repairAllocatedZeroes &&
                            new[index..<(index + 4096)].allSatisfy { $0 == 0 }
                        if (newlyUsed || repair) && !changed { forced += 1 }
                        changed = (options.verifyAllocated || options.allocatedOnly) ? used : changed || newlyUsed || repair
                    }
                }
                if changed && run == nil { run = index }
                if !changed, let start = run {
                    guard records < 1_000_000 else { throw invalid("too many native records") }
                    let bytes = new.subdata(in: start..<index)
                    var record = Data()
                    append(offset + position + UInt64(start), to: &record)
                    append(UInt32(bytes.count), to: &record)
                    append(crc(Array(bytes)[...]), to: &record)
                    try stream.write(contentsOf: record); try stream.write(contentsOf: bytes)
                    records += 1; payload += UInt64(bytes.count); run = nil
                }
            }
            position += UInt64(amount)
        }
        try stream.seek(toOffset: 16)
        var count = Data(); append(records, to: &count); try stream.write(contentsOf: count)
        try stream.synchronize()
        complete = true
        return Manifest(baseSHA256: beforeHash.finalize().hexString,
                        imageSHA256: afterHash.finalize().hexString, mediaBytes: options.mediaBytes,
                        partitionOffset: offset,
                        records: records, payloadBytes: payload, forcedAllocatedBlocks: forced,
                        repairAllocatedZeroes: options.repairAllocatedZeroes,
                        verifyOnly: options.verifyAllocated)
    }

    /// Initial full-capacity restore, from fresh prepared volumes rather than
    /// an initialized NAND. Every allocated block is explicit, even if zero.
    public static func writeInitial(system: URL, data: URL, output: URL,
                                    layout requestedLayout: A6StorageLayout? = nil) throws {
        let layout = try requestedLayout ?? A6StorageLayout()
        let fm = FileManager.default
        guard !fm.fileExists(atPath: output.path) else { throw invalid("output already exists") }
        for (url, expected) in [(system, layout.systemBytes), (data, layout.dataBytes)] {
            let attributes = try fm.attributesOfItem(atPath: url.path)
            guard (attributes[.size] as? NSNumber)?.uint64Value == expected else {
                throw invalid("prepared volume does not fill its partition: \(url.lastPathComponent)")
            }
        }
        let scratch = output.deletingLastPathComponent().appendingPathComponent("initial-" + UUID().uuidString)
        try fm.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: scratch) }
        let empty = scratch.appendingPathComponent("empty")
        try Data().write(to: empty, options: .withoutOverwriting)
        var pieces: [(URL, Manifest)] = []
        for (i, pair) in [(system, layout.systemOffset), (data, layout.dataOffset)].enumerated() {
            var options = Options(); options.mediaBytes = layout.mediaBytes
            options.partitionOffset = pair.1; options.allocatedOnly = true
            let part = scratch.appendingPathComponent("part\(i)")
            pieces.append((part, try writeDelta(base: empty, image: pair.0, output: part, options: options)))
        }
        let fd = open(output.path, O_WRONLY | O_CREAT | O_EXCL, 0o600)
        guard fd >= 0 else { throw invalid("output must be new") }
        let stream = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        var completed = false
        defer { try? stream.close(); if !completed { try? fm.removeItem(at: output) } }
        let records = 1 + pieces.reduce(UInt32(0)) { $0 + $1.1.records }
        guard records <= 1_000_000 else { throw invalid("too many initial restore records") }
        var header = Data("A6DI".utf8)
        append(UInt32(1), to: &header); append(layout.mediaBytes, to: &header)
        append(records, to: &header); append(UInt32(0), to: &header)
        let table = layout.partitionTable()
        append(UInt64(0), to: &header); append(UInt32(table.count), to: &header)
        append(crc(Array(table)[...]), to: &header)
        try stream.write(contentsOf: header); try stream.write(contentsOf: table)
        for (part, _) in pieces {
            let source = try FileHandle(forReadingFrom: part)
            do {
                try source.seek(toOffset: 24)
                while let block = try source.read(upToCount: 65536), !block.isEmpty {
                    try Task.checkCancellation(); try stream.write(contentsOf: block)
                }
                try source.close()
            } catch { try? source.close(); throw error }
        }
        try stream.synchronize(); completed = true
    }
}
