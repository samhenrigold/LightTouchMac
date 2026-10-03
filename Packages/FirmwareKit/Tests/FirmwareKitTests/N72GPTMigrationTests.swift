import Foundation
import HostRuntime
import Testing
@testable import FirmwareKit
import FirmwareSchema

/// Boot admission moves a recipe-1 N72 device (every base up to RC7) to recipe 2's GPT in its overlay.
struct N72GPTMigrationTests {
    static let blocks = 1835008, epoch = 4
    static let gpt = [1, 2].map { N72NAND.Page(cs: $0, page: 256) }

    /// A stopped standalone device: base/nand with recipe 1's metadata pages (the historical digests, recorded
    /// before 0b43f26), a lock naming `recipe`, an empty overlay.
    func device(recipe: Int = 1, exactBase: Bool = false) throws -> (root: URL, device: URL, base: URL, overlay: URL) {
        let root = try Fixtures.tempDir("n72-gpt")
        let device = root.appendingPathComponent("device"), base = device.appendingPathComponent("base")
        let overlay = device.appendingPathComponent("overlay")
        var pages = N72NAND.metadataPages(blocks: Self.blocks, epoch: Self.epoch)
        if !exactBase {
            for (cs, data) in N72NAND.gptPages(Self.blocks, slack: 11).enumerated() {
                pages[.init(cs: cs, page: 256)] = data + N72NAND.blankSpare
            }
        }
        // The volume: an HFSX primary header at block 0 whose catalog grew to 4046 blocks, and the alternate the
        // guest left behind under the overlong GPT (still the prepared 1998) in the last block, after other data.
        pages[N72NAND.predict(0)] = Self.volumeHeader(catalogBlocks: 4046) + N72NAND.blankSpare
        var tail = [UInt8](repeating: 0x5A, count: 3072) + Self.volumeHeader(catalogBlocks: 1998)[1024..<1536]
        tail += [UInt8](repeating: 0, count: 4096 - tail.count)
        pages[N72NAND.predict(Self.blocks - 1)] = tail + N72NAND.blankSpare
        for (page, data) in pages {
            let url = base.appendingPathComponent("nand/cs\(page.cs)/\(page.page).page")
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(data).write(to: url)
        }
        let lock: [String: Any] = ["board": "n72ap", "entry": ["id": "n72ap-7E18", "content": ["recipe": ["name": "n72", "version": recipe]]]]
        try JSONSerialization.data(withJSONObject: lock).write(to: base.appendingPathComponent("device.lock.json"))
        try FileManager.default.createDirectory(at: overlay, withIntermediateDirectories: true)
        let record: [String: Any] = ["id": UUID().uuidString, "board": "n72ap", "firmware": "n72ap-7E18",
            "base": ["kind": "prepared", "path": base.path], "storage": ["key": "base-7E18", "overlay": overlay.path]]
        try JSONSerialization.data(withJSONObject: record).write(to: device.appendingPathComponent("device.json"))
        return (root, device, base, overlay)
    }

    /// Block 0 of an HFSX volume of `blocks` 4 KiB blocks (the header at 1024; fields big-endian).
    static func volumeHeader(catalogBlocks: Int) -> [UInt8] {
        var b = [UInt8](repeating: 0, count: 4096)
        func be32(_ o: Int, _ v: Int) { for k in 0..<4 { b[1024 + o + k] = UInt8(v >> (24 - 8 * k) & 0xFF) } }
        b[1024] = 0x48; b[1025] = 0x58; b[1027] = 5
        be32(4, 0x8000_0100); be32(40, 4096); be32(44, blocks)
        be32(0x110 + 12, catalogBlocks)
        return b
    }

    func files(_ dir: URL) throws -> [String: Data] {
        var out: [String: Data] = [:]
        guard let walk = FileManager.default.enumerator(atPath: dir.path) else { return [:] }
        for case let name as String in walk {
            var isDirectory: ObjCBool = false
            let url = dir.appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), !isDirectory.boolValue {
                out["/" + name] = try Data(contentsOf: url)
            }
        }
        return out
    }

    @Test func recipe1MigratesToRecipe2PagesOnceThroughAdmission() async throws {
        let f = try device(); defer { try? FileManager.default.removeItem(at: f.root) }
        // The fixture is the shipped layout: its GPT pages hash to the pre-0b43f26 references.
        let legacy = Dictionary(uniqueKeysWithValues: LegacyPreparationGoldens.n72Metadata.map {
            let w = $0.split(separator: " "); return ("\(w[0]) \(w[1])", String(w[2]))
        })
        for p in Self.gpt {
            let data = try Data(contentsOf: f.base.appendingPathComponent("nand/cs\(p.cs)/256.page"))
            #expect(Oracle.sha256(data) == legacy["\(p.cs) 256"])
        }
        let baseBefore = try files(f.base)

        let first = try await FirmwareBootAdmission.admit(device: f.device)
        #expect(first.changed)
        let recipe2 = N72NAND.metadataPages(blocks: Self.blocks, epoch: Self.epoch)
        for p in Self.gpt {
            let got = try Data(contentsOf: f.overlay.appendingPathComponent("cs\(p.cs)/256.page"))
            #expect(got == Data(recipe2[p]!))   // a recipe-2 prepare's page, data and spare
            #expect(Oracle.sha256(got) == LegacyPreparationGoldens.n72ExactPartitionGPT["\(p.cs) 256"])
        }
        // The alternate is now the primary; the rest of its block is kept.
        let end = N72NAND.predict(Self.blocks - 1)
        let alt = try [UInt8](Data(contentsOf: f.overlay.appendingPathComponent("cs\(end.cs)/\(end.page).page")))
        #expect(alt[3072..<3584] == Self.volumeHeader(catalogBlocks: 4046)[1024..<1536])
        #expect(alt[0..<3072].allSatisfy { $0 == 0x5A } && alt[4096...] == N72NAND.blankSpare[...])
        #expect(try files(f.overlay).keys.sorted() == ["/.base-identity", "/cs1/256.page", "/cs2/256.page", "/cs\(end.cs)/\(end.page).page"])
        #expect(try String(contentsOf: f.overlay.appendingPathComponent(".base-identity"), encoding: .utf8) == "base-7E18")
        #expect(try files(f.base) == baseBefore)
        let marker = f.device.appendingPathComponent(FirmwareWire.migratedRecipeFile)
        let mark = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: marker)) as? [String: Any])
        #expect(mark["recipe"] as? Int == 2)

        let overlayAfter = try files(f.overlay), markAfter = try Data(contentsOf: marker)
        let second = try await FirmwareBootAdmission.admit(device: f.device)
        #expect(!second.changed)
        #expect(try files(f.overlay) == overlayAfter && Data(contentsOf: marker) == markAfter)
    }

    /// Write, then mark: a crash after the pages leaves them exact; the next start only marks.
    @Test func interruptedBeforeTheMarkIsMarkedNextTime() async throws {
        let f = try device(); defer { try? FileManager.default.removeItem(at: f.root) }
        _ = try await FirmwareBootAdmission.admit(device: f.device)
        let marker = f.device.appendingPathComponent(FirmwareWire.migratedRecipeFile)
        try FileManager.default.removeItem(at: marker)
        let pages = try files(f.overlay)
        #expect(try await FirmwareBootAdmission.admit(device: f.device).changed)
        #expect(FileManager.default.fileExists(atPath: marker.path))
        #expect(try files(f.overlay) == pages)
    }

    /// Erase deletes the overlay; the marker stays and the next start writes the pages again.
    @Test func erasedOverlayGetsThePagesAgain() async throws {
        let f = try device(); defer { try? FileManager.default.removeItem(at: f.root) }
        _ = try await FirmwareBootAdmission.admit(device: f.device)
        let pages = try files(f.overlay)
        try FileManager.default.removeItem(at: f.overlay)
        #expect(try await FirmwareBootAdmission.admit(device: f.device).changed)
        #expect(try files(f.overlay) == pages)
    }

    @Test func recipe2BaseIsLeftAlone() async throws {
        let f = try device(recipe: 2, exactBase: true); defer { try? FileManager.default.removeItem(at: f.root) }
        #expect(try await !FirmwareBootAdmission.admit(device: f.device).changed)
        #expect(try files(f.overlay).isEmpty)
        #expect(!FileManager.default.fileExists(atPath: f.device.appendingPathComponent(FirmwareWire.migratedRecipeFile).path))
    }

    /// A running device (its helper holds the lease) is never touched.
    @Test func runningDeviceIsNotMigrated() async throws {
        let f = try device(); defer { try? FileManager.default.removeItem(at: f.root) }
        let lease = try StorageLease(f.device.appendingPathComponent("work/lease"))
        await #expect(throws: (any Error).self) { try await FirmwareBootAdmission.admit(device: f.device) }
        lease.close()
        #expect(try files(f.overlay).isEmpty)
        #expect(!FileManager.default.fileExists(atPath: f.device.appendingPathComponent(FirmwareWire.migratedRecipeFile).path))
    }

    /// A GPT the guest (or anything else) rewrote is neither layout: left alone.
    @Test func unknownGPTIsLeftAlone() async throws {
        let f = try device(); defer { try? FileManager.default.removeItem(at: f.root) }
        try FileManager.default.createDirectory(at: f.overlay.appendingPathComponent("cs2"), withIntermediateDirectories: true)
        var odd = N72NAND.gptPages(Self.blocks - 5)[2] + N72NAND.blankSpare
        odd[0x40] = 0x41
        try Data(odd).write(to: f.overlay.appendingPathComponent("cs2/256.page"))
        #expect(try await !FirmwareBootAdmission.admit(device: f.device).changed)
        #expect(try files(f.overlay).keys.sorted() == ["/cs2/256.page"])
    }
}
