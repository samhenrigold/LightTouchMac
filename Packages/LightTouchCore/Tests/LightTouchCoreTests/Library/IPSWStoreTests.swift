import Crypto
import FirmwareSchema
import Foundation
import Testing

@testable import LightTouchCore

/// The IPSW store: streamed SHA1, install checks, dedupe across downloads and imports, disk space, catalog
/// matching, imports of real zips, and the launch sweep. Every path is a temp dir.
struct IPSWStoreTests {
    let fm = FileManager.default
    static let catalog = try! FirmwareCatalog.load(from: LibraryFixtures.shippedCatalog)
    var iPad32: FirmwareCatalog.Entry { Self.catalog.entry(id: "k48ap-7B367")! }

    func hex(_ digest: some Sequence<UInt8>) -> String { digest.map { String(format: "%02x", $0) }.joined() }
    func store(_ tmp: URL, _ name: String = "") -> IPSWStore {
        IPSWStore(
            downloads: tmp.appendingPathComponent("Caches\(name)/IPSW"),
            imports: tmp.appendingPathComponent("State\(name)/IPSW")
        )
    }
    /// 9 MiB: over two 4 MiB chunks.
    var big: Data {
        var big = Data(count: 9 << 20)
        for i in stride(from: 0, to: big.count, by: 4093) { big[i] = UInt8(truncatingIfNeeded: i &* 31) }
        return big
    }

    @Test func sha1IsStreamedInChunks() throws {
        try withTemporaryDirectory { tmp in
            let abc = tmp.appendingPathComponent("abc")
            try Data("abc".utf8).write(to: abc)
            #expect(try IPSWStore.sha1(of: abc) == "a9993e364706816aba3e25717850c26c9cd0d89d")
            let big = big
            let url = tmp.appendingPathComponent("big")
            try big.write(to: url)
            var fractions: [Double] = []
            #expect(try IPSWStore.sha1(of: url) { fractions.append($0) } == hex(Insecure.SHA1.hash(data: big)))
            #expect(fractions.count == 3 && fractions.last == 1, "progress per 4 MiB chunk")
        }
    }

    @Test func installChecksSizeAndSHA1ThenDedupesAcrossStores() throws {
        try withTemporaryDirectory { tmp in
            let store = store(tmp)
            let big = big
            let sha = hex(Insecure.SHA1.hash(data: big))
            try StorageLocations.privateDirectory(store.downloads)
            // A size mismatch, then a sha1 mismatch: refused, the file deleted.
            try big.write(to: store.partial(sha))
            #expect(throws: FirmwareError.corrupted) {
                try store.install(store.partial(sha), sha1: sha, bytes: Int64(big.count) + 1)
            }
            #expect(!fm.fileExists(atPath: store.partial(sha).path))
            var bad = big
            bad[5] ^= 1
            try bad.write(to: store.partial(sha))
            #expect(throws: FirmwareError.corrupted) {
                try store.install(store.partial(sha), sha1: sha, bytes: Int64(big.count))
            }
            #expect(!fm.fileExists(atPath: store.partial(sha).path))
            #expect(FirmwareError.corrupted.localizedDescription == "The download is damaged. Try again.")
            #expect(store.existing(sha) == nil)
            try big.write(to: store.partial(sha))
            #expect(try store.install(store.partial(sha), sha1: sha, bytes: Int64(big.count)) == store.download(sha))
            #expect(!fm.fileExists(atPath: store.partial(sha).path), "renamed into place")
            // Either store satisfies the sha1.
            #expect(store.existing(sha) == store.download(sha))
            try StorageLocations.privateDirectory(store.imports)
            try fm.moveItem(at: store.download(sha), to: store.imported(sha))
            #expect(store.existing(sha) == store.imported(sha))
        }
    }

    @Test func diskSpaceAndEstimates() throws {
        try IPSWStore.checkSpace(100, available: 100)
        #expect(throws: FirmwareError.notEnoughSpace(required: 3_700_184_797, available: 1_000_000_000)) {
            try IPSWStore.checkSpace(iPad32.estimates.peakBytes, available: 1_000_000_000)
        }
        #expect(
            FirmwareError.notEnoughSpace(required: 3_700_184_797, available: 1_000_000_000).localizedDescription
                == "Not enough disk space: this needs 3.7 GB, and 1 GB is available."
        )
        try withTemporaryDirectory { tmp in
            try IPSWStore.checkSpace(1, at: tmp.appendingPathComponent("not/made/yet"))
            do {
                try IPSWStore.checkSpace(Int64.max, at: tmp)
                Issue.record("no volume has Int64.max free")
            } catch let FirmwareError.notEnoughSpace(required, available) { #expect(required == .max && available > 0) }
        }
        #expect(iPad32.estimates.peakBytes == iPad32.source.bytes! + (3 << 30) && iPad32.estimates.seconds == 90)
        for id in ["k48ap-7B500", "k48ap-8C148"] {
            let e = Self.catalog.entry(id: id)!
            #expect(
                e.estimates.peakBytes == e.source.bytes! + (3 << 30) && e.estimates.preparedBytes > 1 << 30,
                "\(id)"
            )
        }
    }

    @Test func catalogMatching() throws {
        let other = String(repeating: "1", count: 40)
        #expect(try IPSWStore.match(sha1: iPad32.source.sha1!, restore: nil, in: Self.catalog).id == iPad32.id)
        #expect(throws: FirmwareError.wrongFile(model: "iPad", version: "3.2")) {
            try IPSWStore.match(sha1: other, restore: ("iPad1,1", "7B367"), in: Self.catalog)
        }
        #expect(
            FirmwareError.wrongFile(model: "iPad", version: "3.2").localizedDescription
                == "This isn’t the IPSW Light Touch knows for iPad iOS 3.2."
        )
        #expect(throws: FirmwareError.unsupported) {
            try IPSWStore.match(sha1: other, restore: ("iPad1,1", "7B999"), in: Self.catalog)
        }
        #expect(throws: FirmwareError.unsupported) { try IPSWStore.match(sha1: other, restore: nil, in: Self.catalog) }
        #expect(FirmwareError.unsupported.localizedDescription == "This IPSW isn’t supported.")
    }

    @Test func importOfRealZips() throws {
        try withTemporaryDirectory { tmp in
            let known = tmp.appendingPathComponent("known.ipsw")
            let other = tmp.appendingPathComponent("other.ipsw")
            try LibraryFixtures.restoreZip(known, product: "iPad1,1", build: "7B367")
            try LibraryFixtures.restoreZip(other, product: "iPhone1,2", build: "5A347")  // iPhone 3G: no board for it
            let junk = tmp.appendingPathComponent("junk")
            try Data("not a zip".utf8).write(to: junk)
            let store = store(tmp)
            #expect(IPSWStore.restoreInfo(known).map { "\($0.productType) \($0.build)" } == "iPad1,1 7B367")
            #expect(IPSWStore.restoreInfo(junk) == nil)
            #expect(throws: FirmwareError.wrongFile(model: "iPad", version: "3.2")) {
                try store.importIPSW(known, catalog: Self.catalog)
            }
            #expect(throws: FirmwareError.unsupported) { try store.importIPSW(other, catalog: Self.catalog) }
            #expect(throws: FirmwareError.unsupported) { try store.importIPSW(junk, catalog: Self.catalog) }
            // Pinned to this zip's sha1: matched and cloned into State/IPSW, the original kept; a second import dedupes.
            var pinned = Self.catalog
            let sha = try IPSWStore.sha1(of: known)
            pinned.entries[pinned.entries.firstIndex { $0.id == iPad32.id }!].source.sha1 = sha
            let fresh = self.store(tmp, "2")
            let imported = try fresh.importIPSW(known, catalog: pinned)
            #expect(imported.entry.id == iPad32.id && imported.ipsw == fresh.imported(sha))
            #expect(try IPSWStore.sha1(of: imported.ipsw) == sha && fm.fileExists(atPath: known.path))
            #expect(try fresh.importIPSW(known, catalog: pinned).ipsw == fresh.imported(sha))
            #expect(try fm.contentsOfDirectory(atPath: fresh.imports.path) == ["\(sha).ipsw"], "no temp left")
            #expect(
                try fm.attributesOfItem(atPath: fresh.imported(sha).path)[.type] as? FileAttributeType == .typeRegular,
                "the same volume: a clone, not a reference"
            )
        }
    }

    /// An IPSW on another volume (a disk image mounted for the test) isn't copied: State/IPSW holds a reference that
    /// reads it in place, while it's there unchanged. A changed or deleted file drops the reference, and Remove IPSW
    /// takes the reference, never the file.
    @Test func importFromAnotherVolumeIsReferenced() throws {
        func diskutil(_ arguments: [String]) throws {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/sbin/diskutil")
            process.arguments = arguments
            process.standardOutput = FileHandle.nullDevice
            try process.run()
            process.waitUntilExit()
            try #require(process.terminationStatus == 0, "diskutil \(arguments.joined(separator: " "))")
        }
        try withTemporaryDirectory { tmp in
            let image = tmp.appendingPathComponent("other.dmg")
            let volume = tmp.appendingPathComponent("Other")
            try diskutil(["image", "create", "blank", "--size", "20m", "--fs", "APFS", image.path])
            try diskutil(["image", "attach", "--nobrowse", "--mountPoint", volume.path, image.path])
            defer { try? diskutil(["eject", volume.path]) }
            let known = volume.appendingPathComponent("known.ipsw")
            try LibraryFixtures.restoreZip(known, product: "iPad1,1", build: "7B367")
            let original = try Data(contentsOf: known)
            var pinned = Self.catalog
            let sha = try IPSWStore.sha1(of: known)
            pinned.entries[pinned.entries.firstIndex { $0.id == iPad32.id }!].source.sha1 = sha
            let store = store(tmp)
            try StorageLocations.privateDirectory(store.imports)
            #expect(!IPSWStore.sameVolume(known, store.imports))

            func importKnown() throws {
                let imported = try store.importIPSW(known, catalog: pinned)
                #expect(imported.entry.id == iPad32.id && imported.ipsw == store.imported(sha))
                #expect(store.referenced(sha)?.path == known.path, "a reference to the file")
                #expect(try store.existing(sha) == store.imported(sha) && IPSWStore.sha1(of: imported.ipsw) == sha)
                #expect(try fm.contentsOfDirectory(atPath: store.imports.path) == ["\(sha).ipsw"])
                #expect(
                    try fm.attributesOfItem(atPath: store.imported(sha).path)[.type] as? FileAttributeType
                        == .typeSymbolicLink,
                    "nothing copied"
                )
            }
            try importKnown()
            #expect(try store.importIPSW(known, catalog: pinned).ipsw == store.imported(sha), "a second import dedupes")

            // Copy into Light Touch: a whole copy in the reference's place; the user's file is untouched.
            try store.copyIn(sha)
            #expect(store.referenced(sha) == nil && store.existing(sha) == store.imported(sha), "no longer a reference")
            #expect(
                try fm.attributesOfItem(atPath: store.imported(sha).path)[.type] as? FileAttributeType == .typeRegular
            )
            #expect(try IPSWStore.sha1(of: store.imported(sha)) == sha && Data(contentsOf: known) == original)
            #expect(try fm.contentsOfDirectory(atPath: store.imports.path) == ["\(sha).ipsw"], "no copy left over")

            // Removed: the reference goes, the file stays.
            try store.remove(sha)
            #expect(store.existing(sha) == nil && store.referenced(sha) == nil && fm.fileExists(atPath: known.path))

            // Changed: no longer the IPSW that was hashed; the reference goes, the file stays.
            try importKnown()
            let handle = try FileHandle(forWritingTo: known)
            try handle.seekToEnd()
            try handle.write(contentsOf: Data([0]))
            try handle.close()
            #expect(store.existing(sha) == nil, "a changed file isn't used")
            #expect(store.referenced(sha) == nil && fm.fileExists(atPath: known.path), "the reference is dropped")

            // Deleted: the entry isn't downloaded anymore.
            try original.write(to: known)
            try importKnown()
            try fm.removeItem(at: known)
            #expect(store.existing(sha) == nil && store.referenced(sha) == nil)
            #expect(try fm.contentsOfDirectory(atPath: store.imports.path).isEmpty)
        }
    }

    @Test func launchSweepAndRemove() throws {
        try withTemporaryDirectory { tmp in
            let swept = store(tmp, "3")
            for url in [
                swept.partial("a"), swept.download("b"), swept.resumeData("b"),
                swept.imports.appendingPathComponent(".c.importing"), swept.imported("d")
            ] {
                try StorageLocations.privateDirectory(url.deletingLastPathComponent())
                try Data("x".utf8).write(to: url)
            }
            swept.sweep()
            #expect(
                !fm.fileExists(atPath: swept.partial("a").path)
                    && !fm.fileExists(atPath: swept.imports.appendingPathComponent(".c.importing").path)
            )
            #expect(swept.existing("b") != nil && swept.existing("d") != nil)
            var posts = 0
            let observer = NotificationCenter.default.addObserver(
                forName: IPSWStore.didChangeNotification,
                object: nil,
                queue: nil
            ) { _ in posts += 1 }
            defer { NotificationCenter.default.removeObserver(observer) }
            try swept.remove("b")
            #expect(posts == 1, "the sidebar and Storage hear of it (state audit B-5)")
            #expect(
                swept.existing("b") == nil && !fm.fileExists(atPath: swept.resumeData("b").path),
                "Remove IPSW takes its .resume too"
            )
        }
    }
}
