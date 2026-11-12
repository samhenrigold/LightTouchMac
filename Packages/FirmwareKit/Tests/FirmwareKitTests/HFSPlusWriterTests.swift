import Crypto
import FirmwareSchema
import Foundation
import Testing

@testable import FirmwareKit

/// HFSPlusWriter against two oracles: fsck_hfs -fn (through a read-only attach, the only use of the kernel here)
/// and an in-memory model of what the volume should hold, compared with HFSPlusVolume's listing.
@Suite(.serialized) struct HFSPlusWriterTests {
    /// What a path should be: a folder, a file's content, a symlink's target; hard links share `group`.
    enum Expected: Equatable {
        case folder
        case file(Data, group: Int)
        case symlink(String)
    }

    struct Model {
        var items: [String: Expected] = [:]
        var nextGroup = 0
        func children(_ dir: String) -> [String] {
            items.keys.filter { ($0 as NSString).deletingLastPathComponent == dir }.sorted()
        }
    }

    /// SplitMix64: the same operations on every run.
    struct Seeded: RandomNumberGenerator {
        var state: UInt64
        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
    }

    static func fsck(_ image: URL) async throws -> (ok: Bool, output: String) {
        let dev = try await DiskImage.attach(image, readOnly: true).device
        do {
            let r = try await VolumeMount.check(dev)
            try await DiskImage.detach(dev)
            return r
        } catch {
            try? await DiskImage.detach(dev, force: true)
            throw error
        }
    }

    /// The volume's listing as the model's terms: content for files, targets for symlinks.
    static func check(_ image: URL, _ model: Model) throws {
        let v = try HFSPlusVolume(image)
        var got: [String: HFSPlusVolume.Entry] = [:]
        for e in try v.listing() where !e.path.isEmpty && !e.path.hasPrefix(".journal") { got[e.path] = e }
        #expect(Set(got.keys) == Set(model.items.keys))
        for (path, want) in model.items {
            guard let e = got[path] else { continue }
            switch want {
            case .folder: #expect(e.mode & 0o170000 == 0o40000, "\(path)")
            case .file(let d, _):
                #expect(e.mode & 0o170000 == 0o100000, "\(path)")
                #expect(e.size == UInt64(d.count) && e.sha256 == Oracle.sha256(d), "\(path)")
            case .symlink(let t): #expect(e.link == t, "\(path)")
            }
        }
    }

    /// leaveJournalToDevice writes the whole .journal_info_block, not the bytes newfs left after offset/size (0x5a
    /// on some hosts, 0 on others), so two hosts prepare the same block: the block is a zeroed 4096 bytes with only
    /// the in-FS and need-init flags and the journal's offset and size. Here the block is pre-filled with 0x5a, as a
    /// host's kernel can leave it, and comes out the same as newfs's.
    @Test func leaveJournalToDeviceWritesADeterministicInfoBlock() async throws {
        try await Oracle.withTemp { dir in
            let img = dir.appendingPathComponent("j.img")
            try HFSPlusWriter.makeHFS(img, size: 64 << 20, journaled: true)
            let v = try HFSPlusVolume(img, writable: true)
            // the info block's location (volume header journalInfoBlock, at file offset 1024 + 12), then its offset
            // and size as makeHFS wrote them
            let at = try Data(contentsOf: img)[1036..<1040].reduce(0) { $0 << 8 | Int($1) } * v.blockSize
            let before = try Data(contentsOf: img)[at..<(at + 52)]
            let offsetSize = before[(at + 36)..<(at + 52)]
            // a host's kernel fill: 0x5a over the whole block, offset and size restored
            var dirty = Data(repeating: 0x5a, count: v.blockSize)
            // kJIJournalInFSMask, as the block says before the handoff
            dirty.replaceSubrange(0..<4, with: [0, 0, 0, 1])
            dirty.replaceSubrange(36..<52, with: offsetSize)
            try v.restore([(at, dirty)])
            try v.leaveJournalToDevice()
            let block = try Data(contentsOf: img)[at..<(at + v.blockSize)]
            #expect(block[(at)..<(at + 4)].elementsEqual([0, 0, 0, 5]))  // in-FS + need-init
            #expect(block[(at + 4)..<(at + 36)].allSatisfy { $0 == 0 })  // the device signature, zeroed
            #expect(block[(at + 36)..<(at + 52)].elementsEqual(offsetSize))  // the journal's offset and size kept
            #expect(block[(at + 52)...].allSatisfy { $0 == 0 })  // the fill newfs leaves zero
        }
    }

    @Test func aFreshVolumeIsCleanAndEmpty() async throws {
        try await Oracle.withTemp { dir in
            for journaled in [true, false] {
                let img = dir.appendingPathComponent("v\(journaled).img")
                try HFSPlusWriter.makeHFS(img, size: 64 << 20, journaled: journaled)
                let fsck = try await Self.fsck(img)
                #expect(fsck.ok, "\(fsck.output)")
                let v = try HFSPlusVolume(img)
                #expect(v.signature == "HX")
                #expect(try v.listing().map(\.path) == (journaled ? ["", ".journal", ".journal_info_block"] : [""]))
                #expect(try v.journal()?.needsInit == (journaled ? true : nil))
            }
        }
    }

    /// create and unpack-base bind --hfs for their run (VolumeMount.backend): withVolume, grow and makeHFS follow it;
    /// and a volume the writer can't edit (newfs_hfs without -s: case-insensitive HFS+) is refused before anything is
    /// written, naming HFSRoute.writerRefusal so the app can say to turn the writer off.
    @Test func theRunsRouteChoosesTheWriterAndItRefusesCaseInsensitiveVolumes() async throws {
        try await Oracle.withTemp { dir in
            let mnt = dir.appendingPathComponent("mnt")
            let made = dir.appendingPathComponent("made.img")
            let kind = try await VolumeMount.$backend.withValue(.writer) {
                try await VolumeMount.makeHFS(made, size: 16 << 20)
                try await VolumeMount.grow(made, toBytes: 32 << 20)
                return try await VolumeMount.withVolume(made, at: mnt) { "\(type(of: $0))" }
            }
            #expect(kind == "HFSPlusWriter" && !FileManager.default.fileExists(atPath: mnt.path), "nothing mounted")
            #expect(try HFSPlusVolume(made).totalBlocks * HFSPlusVolume(made).blockSize == 32 << 20)

            let plain = dir.appendingPathComponent("plain.img")
            #expect(FileManager.default.createFile(atPath: plain.path, contents: nil))
            #expect(truncate(plain.path, 16 << 20) == 0)
            let dev = try await VolumeMount.attach(plain)
            _ = try await VolumeMount.run("/sbin/newfs_hfs", ["-v", "Plain", dev])
            try await VolumeMount.detach(dev)
            let before = try Data(contentsOf: plain)
            func refused(_ error: any Error) -> Bool {
                (error as? FirmwareError)?.piece == HFSRoute.writerRefusal
                    && (error as? FirmwareError)?.code == .unsupported
            }
            await #expect(
                performing: {
                    try await VolumeMount.$backend.withValue(.writer) {
                        try await VolumeMount.grow(plain, toBytes: 32 << 20)
                    }
                }, throws: refused)
            await #expect(
                performing: {
                    try await VolumeMount.$backend.withValue(.writer) {
                        try await VolumeMount.withVolume(plain, at: mnt) { try $0.makeDirectory("x", mode: 0o755) }
                    }
                }, throws: refused)
            #expect(try Data(contentsOf: plain) == before, "the refused volume is untouched")
        }
    }

    /// Batches of random creates, overwrites, renames, hard links and removals (many long names, so the catalog
    /// grows to three levels and shrinks back), each batch written, checked by fsck_hfs and against the model, and reopened.
    @Test func randomOperationsKeepTheVolumeConsistent() async throws {
        try await Oracle.withTemp { dir in
            let img = dir.appendingPathComponent("r.img")
            try HFSPlusWriter.makeHFS(img, size: 96 << 20)
            var rng = Seeded(state: 0x4C54_4846_5357)
            var model = Model()
            var depths: [Int] = []
            for batch in 0..<6 {
                let w = try HFSPlusWriter(img)
                // the last two batches remove most of what the first four made
                let removing = batch >= 4
                for _ in 0..<(removing ? 2500 : 2500) {
                    try Self.step(w, &model, &rng, removing: removing)
                }
                try w.close()
                let fsck = try await Self.fsck(img)
                #expect(fsck.ok, "batch \(batch): \(fsck.output.suffix(800))")
                try Self.check(img, model)
                let v = try HFSPlusVolume(img)
                depths.append(Int(try be16(try v.read(v.catalogFork, fileID: 4, offset: 0, count: 512), 14)))
            }
            // the catalog grew index levels and lost some again
            #expect(depths.max() ?? 0 >= 3 && depths.last ?? 0 < depths.max() ?? 0, "catalog depths \(depths)")
        }
    }

    static func step(_ w: HFSPlusWriter, _ m: inout Model, _ rng: inout Seeded, removing: Bool) throws {
        let folders = [""] + m.items.filter { $0.value == .folder }.keys.sorted()
        let files = m.items.filter { if case .file = $0.value { true } else { false } }.keys.sorted()
        let dir = folders.randomElement(using: &rng) ?? ""
        let long = String(repeating: "n", count: Int.random(in: 1...240, using: &rng))
        let name = "\(long)\(rng.next() % 100_000)"
        let path = dir.isEmpty ? name : dir + "/" + name
        let roll = Int.random(in: 0..<100, using: &rng)
        func content() -> Data {
            let n = Int.random(in: 0...(rng.next() % 10 == 0 ? 40 * 4096 : 3000), using: &rng)
            var d = Data(count: (n + 7) / 8 * 8)
            d.withUnsafeMutableBytes { p in
                for i in 0..<p.count / 8 { p.storeBytes(of: rng.next(), toByteOffset: 8 * i, as: UInt64.self) }
            }
            return d.prefix(n)
        }
        if removing && roll < 60, let victim = m.items.keys.sorted().randomElement(using: &rng) {
            try w.remove(victim)
            for k in m.items.keys where k == victim || k.hasPrefix(victim + "/") { m.items[k] = nil }
            return
        }
        guard m.items[path] == nil else { return }
        switch roll {
        case 0..<35:
            let d = content()
            try w.put(d, at: path)
            m.items[path] = .file(d, group: m.nextGroup)
            m.nextGroup += 1
        case 35..<55:
            try w.makeDirectory(path)
            m.items[path] = .folder
        case 55..<62:
            let t = "../target/\(name)"
            try w.makeSymlink(path, to: t)
            m.items[path] = .symlink(t)
        case 62..<70:
            guard let f = files.randomElement(using: &rng), case .file(let d, let g) = m.items[f] else { return }
            try w.link(path, to: f)
            m.items[path] = .file(d, group: g)
        case 70..<80:
            // overwrite in place; one name of a hard-linked file is replaced instead (DevicePath's rule)
            guard let f = files.randomElement(using: &rng), case .file(_, let g) = m.items[f] else { return }
            let d = content()
            try w.put(d, at: f)
            let names = m.items.filter { if case .file(_, g) = $0.value { true } else { false } }.count
            m.items[f] = .file(d, group: names > 1 ? m.nextGroup : g)
            if names > 1 { m.nextGroup += 1 }
        case 80..<90:
            guard let src = m.items.keys.sorted().randomElement(using: &rng),
                !(path + "/").hasPrefix(src + "/")
            else { return }
            try w.rename(src, to: path)
            for k in m.items.keys.sorted() where k == src || k.hasPrefix(src + "/") {
                m.items[path + k.dropFirst(src.count)] = m.items.removeValue(forKey: k)
            }
        default:
            guard let victim = m.items.keys.sorted().randomElement(using: &rng) else { return }
            try w.remove(victim)
            for k in m.items.keys where k == victim || k.hasPrefix(victim + "/") { m.items[k] = nil }
        }
    }

    /// A file written into a volume whose free space is all one-block holes takes one extent per block, past the
    /// eighth in extents overflow records, and removing it frees them; fsck_hfs agrees each time.
    @Test func fragmentedFilesTakeOverflowExtents() async throws {
        try await Oracle.withTemp { dir in
            let img = dir.appendingPathComponent("f.img")
            try HFSPlusWriter.makeHFS(img, size: 8 << 20, journaled: false)
            var w = try HFSPlusWriter(img)
            var n = 0
            while (try? w.put(Data(repeating: 1, count: 4096), at: "fill\(n)")) != nil { n += 1 }
            for i in stride(from: 0, to: n - 40, by: 2) { try w.remove("fill\(i)") }
            let big = Data((0..<(30 * 4096)).map { UInt8(truncatingIfNeeded: $0 * 7) })
            try w.put(big, at: "big")
            try w.close()
            let v = try HFSPlusVolume(img)
            #expect(try v.extents(v.record(at: "big").data!, fileID: v.record(at: "big").cnid).count == 30)
            #expect(try v.contents(v.record(at: "big")) == big)
            var fsck = try await Self.fsck(img)
            #expect(fsck.ok, "\(fsck.output)")
            w = try HFSPlusWriter(img)
            #expect(try w.contents(at: "big") == big)
            try w.remove("big")
            try w.close()
            let header = try HFSPlusVolume(img).read(v.extentsFork, fileID: 3, offset: 0, count: 512)
            #expect(try be32(header, 14 + 6) == 0)  // no overflow records left
            fsck = try await Self.fsck(img)
            #expect(fsck.ok, "\(fsck.output)")
        }
    }

    /// The Cydia bootstrap extracted by TarArchive into a writer-made volume lists the same (paths, owners, modes,
    /// sizes, content, link targets, flags) as the kernel route's extraction (MountedVolume.extract: /usr/bin/tar
    /// -xkf on the host, merged in) into a kernel-mounted newfs_hfs one, both over the same existing folder and file,
    /// which -k keeps; and every file and folder the archive dates has the same modification date in both.
    @Test(.enabled(if: FixtureRequirements.corpusEnabled, "Firmware corpus test; set FK_TEST_CORPUS=1 to run"))
    func tarExtractionMatchesTheKernel() async throws {
        let tar = Oracle.path("Library/Caches/gold.samhenri.LightTouchMac/Jailbreak/freeze.tar.gz")
        guard Oracle.exists(tar) else { try FixtureRequirements.missing(tar.path) }
        try await Oracle.withTemp { dir in
            let kernel = dir.appendingPathComponent("k.img")
            try await VolumeMount.makeHFS(kernel, size: 128 << 20)
            try await VolumeMount.withMounted(kernel, at: dir.appendingPathComponent("mnt")) { m in
                try FileManager.default.createDirectory(
                    at: m.appendingPathComponent("usr/bin"),
                    withIntermediateDirectories: true,
                    attributes: [.posixPermissions: 0o700]
                )
                try Data("keep".utf8).write(to: m.appendingPathComponent("usr/bin/gunzip"))
                try MountedVolume(root: m).extract(tar: tar, excluding: [])
            }
            let writer = dir.appendingPathComponent("w.img")
            try HFSPlusWriter.makeHFS(writer, size: 128 << 20)
            let w = try HFSPlusWriter(writer)
            try w.makeDirectory("usr/bin")
            try w.setAttributes("usr", mode: 0o700)
            try w.setAttributes("usr/bin", mode: 0o700)
            try w.put(Data("keep".utf8), at: "usr/bin/gunzip")
            #expect(try TarArchive(contentsOf: tar).extract(into: w) > 900)
            try w.close()
            let fsck = try await Self.fsck(writer)
            #expect(fsck.ok, "\(fsck.output)")
            // the journal files' content is where each lays the journal out
            let unhashed = { (e: HFSPlusVolume.Entry) in
                var e = e
                if e.path.hasPrefix(".journal") { e.sha256 = nil }
                return e
            }
            let a = try HFSPlusVolume(kernel).listing().filter { !$0.path.isEmpty }.map(unhashed)
            let b = try HFSPlusVolume(writer).listing().filter { !$0.path.isEmpty }.map(unhashed)
            #expect(a.count == b.count)
            for (x, y) in zip(a, b) where x != y { Issue.record("kernel \(x)\nwriter \(y)") }
            // the archive's dates (a folder only the extraction made, or a symlink, is dated by whoever made it)
            let members = try TarArchive(contentsOf: tar).members
            let dated = Set(members.filter { $0.kind != .symlink }.map(\.path)).subtracting(["", "usr", "usr/bin"])
            let modified = { (image: URL) in
                Dictionary(try HFSPlusVolume(image).paths().map { ($0.path, $0.record.dates[1]) }) { a, _ in a }
            }
            let (k, wd) = (try modified(kernel), try modified(writer))
            let differing = dated.filter { k[$0] != wd[$0] }.sorted()
            #expect(dated.count > 900 && differing.isEmpty, "\(differing.count): \(differing.prefix(5))")
        }
    }

    /// An IPSW root filesystem (each in the local decrypt caches) grown and edited: fsck_hfs passes it, the edits
    /// read back, and everything the edits did not touch lists as before.
    @Test(
        .enabled(if: FixtureRequirements.corpusEnabled, "Firmware corpus test; set FK_TEST_CORPUS=1 to run"),
        arguments: ["n72ap-7E18", "n72ap-8C148", "k48ap-7B500", "k48ap-8C148"]
    )
    func rootFilesystemsTakeEdits(_ id: String) async throws {
        let dmg = try #require(Oracle.firmware(id).cache).appendingPathComponent("rootfs.dmg")
        guard Oracle.exists(dmg) else { try FixtureRequirements.missing(dmg.path) }
        try await Oracle.withTemp { dir in
            let img = dir.appendingPathComponent("system.img")
            try await UDIF.extractRootfs(dmg: dmg, to: img, backend: .writer)
            let before = try HFSPlusVolume(img).listing()
            let size = try FileManager.default.attributesOfItem(atPath: img.path)[.size] as! Int
            try HFSPlusWriter.grow(img, toBytes: (size + (200 << 20)) / 4096 * 4096)
            let w = try HFSPlusWriter(img)
            let plist = "System/Library/CoreServices/SystemVersion.plist"
            let version = try w.contents(at: plist)
            try w.put(version + Data("<!-- -->".utf8), at: plist)
            try w.remove("usr/share/zoneinfo/Asia")
            try w.rename("usr/share/zoneinfo/Europe", to: "usr/share/zoneinfo/Europe2")
            try w.makeDirectory("usr/local/bin")
            try w.put(Data(repeating: 1, count: 50 << 20), at: "usr/local/bin/big")
            try w.makeSymlink("usr/local/lib", to: "../lib")
            try w.close()
            let fsck = try await Self.fsck(img)
            #expect(fsck.ok, "\(fsck.output.suffix(600))")
            let touched = ["usr/share/zoneinfo", "usr/local", plist]
            let keep = { (e: HFSPlusVolume.Entry) in
                !touched.contains { e.path == $0 || e.path.hasPrefix($0 + "/") }
            }
            #expect(try HFSPlusVolume(img).listing().filter(keep) == before.filter(keep))
            let v = try HFSPlusVolume(img)
            #expect(try v.contents(v.record(at: plist)) == version + Data("<!-- -->".utf8))
            let europe = before.filter { $0.path.hasPrefix("usr/share/zoneinfo/Europe/") }.map {
                "usr/share/zoneinfo/Europe2/" + $0.path.dropFirst("usr/share/zoneinfo/Europe/".count)
            }
            #expect(try v.listing(under: "usr/share/zoneinfo/Europe2").dropFirst().map(\.path) == europe)
            #expect(!(try HFSPlusVolume(img).paths().contains { $0.path.hasPrefix("usr/share/zoneinfo/Asia") }))
        }
    }

    /// A file HFS-compressed by macOS (ditto --hfsCompression onto a kernel-mounted volume: its content in the
    /// com.apple.decmpfs attribute or the resource fork) overwritten in place is stored plainly: compressed flag and
    /// decmpfs attribute gone, its record and owner kept, and fsck_hfs passes. kHFSHasAttributesMask stays only while
    /// another attribute does: macOS 13 on adds com.apple.provenance to what ditto writes, which the overwrite keeps.
    @Test func overwritingACompressedFileStoresItPlainly() async throws {
        try await Oracle.withTemp { dir in
            let img = dir.appendingPathComponent("c.img")
            try await VolumeMount.makeHFS(img, size: 64 << 20, journaled: false)
            let src = dir.appendingPathComponent("text")
            try Data(String(repeating: "compress me ", count: 100_000).utf8).write(to: src)
            try await VolumeMount.withMounted(img, at: dir.appendingPathComponent("mnt")) { m in
                _ = try await DiskImage.run([
                    "/usr/bin/ditto", "--hfsCompression", src.path, m.appendingPathComponent("f").path
                ])
            }
            func flags() throws -> (record: UInt16, owner: UInt8, cnid: UInt32) {
                let v = try HFSPlusVolume(img)
                let r = try v.record(at: "f")
                let t = try v.read(v.catalogFork, fileID: 4, offset: 0, count: 512)
                let rec = try v.read(
                    v.catalogFork,
                    fileID: 4,
                    offset: r.node * Int(try be16(t, 32)) + r.bodyOffset,
                    count: 4
                )
                return (try be16(rec, 2), r.ownerFlags, r.cnid)
            }
            let before = try flags()
            try #require(before.owner & 0x20 != 0 && before.record & 0x04 != 0, "ditto did not compress the file")
            let w = try HFSPlusWriter(img)
            try w.put(Data("plain".utf8), at: "f")
            try w.close()
            let after = try flags()
            #expect(after.owner & 0x20 == 0 && after.cnid == before.cnid)
            let v = try HFSPlusVolume(img)
            #expect(try v.decmpfsHeader(after.cnid) == nil)
            #expect((after.record & 0x04 != 0) == (try v.attributeOwners().contains(after.cnid)))
            #expect(try HFSPlusVolume(img).contents(HFSPlusVolume(img).record(at: "f")) == Data("plain".utf8))
            let fsck = try await Self.fsck(img)
            #expect(fsck.ok, "\(fsck.output)")
        }
    }

    /// A tree copied in and out through VolumeFiles keeps each item's modification time, as the kernel route's copy
    /// (the data volume seeded from the /private/var skeleton): the writer-built volume's createDate and
    /// contentModDate of every copied file and folder are the kernel-built one's (a modification before the creation
    /// moves the creation back), and copied back out they are the originals.
    @Test func copiedTreesKeepTheirDates() async throws {
        try await Oracle.withTemp { dir in
            let fm = FileManager.default
            let src = try DevicePath.real(dir).appendingPathComponent("src")
            for rel in ["a/b", "c"] {
                try fm.createDirectory(at: src.appendingPathComponent(rel), withIntermediateDirectories: true)
            }
            for (i, rel) in ["a/b/f", "a/g", "c/h", "top"].enumerated() {
                try Data(rel.utf8).write(to: src.appendingPathComponent(rel))
                try fm.setAttributes(
                    [.modificationDate: Date(timeIntervalSince1970: 1_200_000_000 + Double(i) * 86_400)],
                    ofItemAtPath: src.appendingPathComponent(rel).path
                )
            }
            try fm.createSymbolicLink(atPath: src.appendingPathComponent("c/l").path, withDestinationPath: "../top")
            // folders after their contents, as a copy leaves them
            for (i, rel) in ["a/b", "a", "c"].enumerated() {
                try fm.setAttributes(
                    [.modificationDate: Date(timeIntervalSince1970: 1_100_000_000 + Double(i) * 3_600)],
                    ofItemAtPath: src.appendingPathComponent(rel).path
                )
            }
            let kernel = dir.appendingPathComponent("k.img")
            try await VolumeMount.makeHFS(kernel, size: 32 << 20, journaled: false)
            try await VolumeMount.withVolume(kernel, at: dir.appendingPathComponent("mnt"), backend: .kernel) { v in
                try SystemEdits.copyTree(MountedVolume(root: src), "", to: v, "")
            }
            let writer = dir.appendingPathComponent("w.img")
            try HFSPlusWriter.makeHFS(writer, size: 32 << 20, journaled: false)
            // the writer dates what it makes as a mount would: now
            let now = UInt32(Date().timeIntervalSince1970 + HFSPlusWriter.hfsEpoch)
            try await VolumeMount.withVolume(
                writer,
                at: dir.appendingPathComponent("mnt"),
                date: now,
                backend: .writer
            ) { v in
                try SystemEdits.copyTree(MountedVolume(root: src), "", to: v, "")
            }
            let modified = { (img: URL) in
                Dictionary(
                    uniqueKeysWithValues: try HFSPlusVolume(img).paths().map { ($0.path, $0.record.dates[0..<2]) }
                )
            }
            let k = try modified(kernel)
            let w = try modified(writer)
            for rel in ["a", "a/b", "a/b/f", "a/g", "c", "c/h", "top"] {
                #expect(w[rel] != nil && w[rel] == k[rel], "\(rel): writer \(w[rel] ?? []), kernel \(k[rel] ?? [])")
            }
            let back = try DevicePath.real(dir).appendingPathComponent("back")
            let wv = try HFSPlusWriter(writer)
            try SystemEdits.copyTree(wv, "", to: MountedVolume(root: back), "")
            for rel in ["a", "a/b", "a/b/f", "a/g", "c", "c/h", "top"] {
                let a =
                    try fm.attributesOfItem(atPath: src.appendingPathComponent(rel).path)[.modificationDate] as? Date
                let b =
                    try fm.attributesOfItem(atPath: back.appendingPathComponent(rel).path)[.modificationDate] as? Date
                #expect(a == b, "\(rel) copied back out")
            }
        }
    }

    /// The same edits give the same image, byte for byte.
    @Test func theSameEditsGiveTheSameBytes() throws {
        try Oracle.withTemp { dir in
            var digests: [String] = []
            for run in 0..<2 {
                let img = dir.appendingPathComponent("d\(run).img")
                try HFSPlusWriter.makeHFS(img, size: 64 << 20, date: 3_000_000_000)
                var rng = Seeded(state: 7)
                var model = Model()
                let w = try HFSPlusWriter(img)
                for _ in 0..<800 { try Self.step(w, &model, &rng, removing: false) }
                for _ in 0..<300 { try Self.step(w, &model, &rng, removing: true) }
                try w.close()
                digests.append(try Oracle.sha256(file: img))
            }
            #expect(digests[0] == digests[1])
        }
    }

    /// Names are stored decomposed, except in the ranges Apple keeps composed; ":" in a path is "/" in a name.
    @Test func namesAreStoredAsHFSStoresThem() throws {
        #expect(HFSUnicode.catalogName("caf\u{E9}") == Array("cafe\u{301}".utf16))
        #expect(HFSUnicode.catalogName("\u{2126}") == [0x2126])  // OHM SIGN, in U+2000-2FFF: kept
        try Oracle.withTemp { dir in
            let img = dir.appendingPathComponent("n.img")
            try HFSPlusWriter.makeHFS(img, size: 16 << 20, journaled: false)
            let w = try HFSPlusWriter(img)
            try w.put(Data("x".utf8), at: "caf\u{E9}")
            try w.put(Data("y".utf8), at: "GMT-0:15")
            // as DevicePath: a path under a missing folder is nothing there, and nothing can be made in it
            try w.remove("no/such/file")
            #expect(try w.item(at: "no/such/file") == nil && !w.exists("no/such"))
            #expect(throws: FirmwareError.self) { try w.put(Data(), at: "no/such/file") }
            try w.setMode("", 0o700)  // the root, keyed by the volume's name
            #expect(try w.item(at: "")?.mode == 0o40700)
            #expect(try w.contents(at: "cafe\u{301}") == Data("x".utf8))
            try w.close()
            let names = try HFSPlusVolume(img).catalog().map(\.name)
            #expect(names.contains("cafe\u{301}") && names.contains("GMT-0/15"))
        }
    }

    /// A tree too big for its header node's map takes map nodes; the laid-out file reads back to the same records.
    @Test func bigTreesTakeMapNodesAndReadBack() throws {
        var t = BTreeFile(nodeSize: 512, maxKeyLength: 10, clumpSize: 0, attributes: BTreeFile.bigKeys) {
            BTreeFile.extentsOrder($0, $1)
        }
        for i in (0..<20_000).reversed() {
            var k = [UInt8](repeating: 0, count: 12)
            putBE16(&k, 0, 10)
            putBE32(&k, 4, UInt32(i))
            t[k] = [UInt8](repeating: UInt8(i % 251), count: 64)
        }
        let total = try t.nodesNeeded(totalNodes: 5000)
        #expect(total > (512 - 256) * 8)  // more nodes than the header's map covers
        let file = try t.layout(totalNodes: 5000)
        #expect(try be32(file, 0) == 1 && file[512 + 8] == 2)  // the header links to map node 1
        let back = try BTreeFile(file, compare: BTreeFile.extentsOrder)
        #expect(back.records == t.records)
        // every node in use is marked, and no other
        let map = Array(file[248..<512 - 8]) + Array(file[512 + 14..<1024 - 6])
        let marked = (0..<5000).filter { map[$0 / 8] & (0x80 >> UInt8($0 % 8)) != 0 }
        #expect(marked == Array(0..<total))
        #expect(try be32(file, 14 + 22) == 5000)
        #expect(Int(try be32(file, 14 + 26)) == 5000 - total)
    }

    /// Growing keeps every file and leaves a volume fsck passes, its alternate header at the new end.
    @Test func growingKeepsTheContent() async throws {
        try await Oracle.withTemp { dir in
            let img = dir.appendingPathComponent("g.img")
            try HFSPlusWriter.makeHFS(img, size: 32 << 20, journaled: false)
            let w = try HFSPlusWriter(img)
            try w.makeDirectory("a/b")
            try w.put(Data(repeating: 7, count: 100_000), at: "a/b/c")
            try w.close()
            let before = try HFSPlusVolume(img).listing()
            try HFSPlusWriter.grow(img, toBytes: 300 << 20)
            let v = try HFSPlusVolume(img)
            #expect(v.totalBlocks == (300 << 20) / 4096)
            #expect(try v.listing() == before)
            let fsck = try await Self.fsck(img)
            #expect(fsck.ok, "\(fsck.output)")
        }
    }
}
