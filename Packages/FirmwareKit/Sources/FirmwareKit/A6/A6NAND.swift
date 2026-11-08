import Foundation

/// New N42 PPN media. Only factory partition/reservation metadata is supplied;
/// the original restore kernel formats its FTL. Never use this on existing media.
public enum A6NAND {
    public static let pageBytes = 16384, spareBytes = 64, pagesPerBlock = 256, blocksPerCE = 2128

    public static func factoryHeader() -> Data {
        var b = Data(repeating: 0, count: 1536)
        func put(_ value: Int, _ at: Int, count: Int = 4) {
            for i in 0..<count { b[at + i] = UInt8(truncatingIfNeeded: value >> (8 * i)) }
        }
        func tag(_ value: String, _ at: Int) { b.replaceSubrange(at..<(at + 4), with: value.utf8) }
        func checksum(_ start: Int, _ size: Int) {
            var a = 255, c = 255
            for i in 0..<size {
                a += Int(b[start + i]); c += a
                if (i + 1).isMultiple(of: 21) { a = (a & 255) + (a >> 8); c = (c & 255) + (c >> 8) }
            }
            for _ in 0..<2 { a = (a & 255) + (a >> 8); c = (c & 255) + (c >> 8) }
            b[start + size] = UInt8(a); b[start + size + 1] = UInt8(c)
        }
        tag("ndrG", 0); put(1, 8); put(9, 12)
        for (i, v) in [1, 2, blocksPerCE, pagesPerBlock, pageBytes / 512, spareBytes, 6, 0xdeadcafe].enumerated() {
            put(v, 0x200 + 4 * i)
        }
        put(0xdeadcafe, 0x224); checksum(0x224, 42)
        let parts = [("boot", 0, 1, 2), ("plog", 4, 1, 0x108), ("nvrm", 2, 3, 0x108),
                     ("firm", 2, 1, 0x308), ("fsys", 1, blocksPerCE - 1, 6),
                     ("scfg", 0, 1, 1), ("diag", 0, 1, 1), ("fbbt", 0, 1, 1)]
        for i in 0..<32 {
            let p = i < parts.count ? parts[i] : ("none", 0, 0, 0), at = 0x400 + 16 * i
            tag(String(p.0.reversed()), at); put(p.1, at + 4); put(p.2, at + 8); put(p.3, at + 12)
        }
        // Virtual boot-unit partitions reserve physical blocks 1...6 on both
        // banks. Without this mapping NVRAM/PLOG alias the factory header.
        tag("rAps", 0x250); put(12, 0x254, count: 2)
        tag("sbus", 0x35c); put(12, 0x360, count: 2); put(2, 0x362, count: 1)
        for i in 0..<12 {
            put(1 + i / 2, 0x25a + 4 * i, count: 3); put(i % 2, 0x25d + 4 * i, count: 1)
            put(i + 2, 0x366 + i, count: 1)
        }
        checksum(0x250, 0x10a); checksum(0x35c, 0x4a)
        return b
    }

    public static func create(at directory: URL) throws {
        let fm = FileManager.default
        guard !fm.fileExists(atPath: directory.path) else { throw FirmwareError(.internal, "NAND output already exists") }
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        let geometry: [String: Any] = ["page_bytes": pageBytes, "spare_bytes": spareBytes,
            "pages_per_block": pagesPerBlock, "blocks_per_ce": blocksPerCE, "ce_per_bus": 1, "buses": 2,
            "chip_id": "0x014E5050", "storage_format": "nand-xor-ff-v2", "layout": "ppn-factory"]
        try JSONSerialization.data(withJSONObject: geometry, options: [.prettyPrinted, .sortedKeys])
            .write(to: directory.appendingPathComponent("geometry.json"), options: .withoutOverwriting)
        let recordSize = pageBytes + spareBytes
        let header = factoryHeader()
        var record = Data(repeating: 0, count: recordSize)
        record.replaceSubrange(0..<header.count, with: header.map { $0 ^ 255 })
        for bus in 0..<2 {
            let file = directory.appendingPathComponent("bus\(bus)-ce0.pages")
            guard fm.createFile(atPath: file.path, contents: nil) else { throw FirmwareError(.internal, "Cannot create NAND bank") }
            let h = try FileHandle(forWritingTo: file)
            do {
                try h.truncate(atOffset: UInt64(blocksPerCE * pagesPerBlock * recordSize))
                try h.seek(toOffset: 0)
                try h.write(contentsOf: record); try h.write(contentsOf: record)
                try h.synchronize(); try h.close()
            } catch { try? h.close(); throw error }
        }
    }
}
