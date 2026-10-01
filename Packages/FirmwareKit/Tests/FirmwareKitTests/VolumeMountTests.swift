import Foundation
import Testing
@testable import FirmwareKit

@Suite(.serialized) struct VolumeMountTests {
    static func attached(_ image: URL) async throws -> Bool {
        try await VolumeMount.exec("/usr/bin/hdiutil", ["info"]).1.contains(image.resolvingSymlinksInPath().path)
    }

    /// A fresh volume against ipad1_nand.make_hfs_image; files written through the mount land in the catalog,
    /// the junk is gone, fsck passed and nothing stays attached.
    @Test(.enabled(if: FixtureRequirements.corpusEnabled, "Firmware corpus test; set FK_TEST_CORPUS=1 to run")) func makeMountEdit() async throws {
        try await Oracle.withTemp { dir in
            let img = dir.appendingPathComponent("data.img"), mnt = dir.appendingPathComponent("mnt")
            try await VolumeMount.makeHFS(img, size: 64 << 20 + 123)
            #expect(try VolumeMount.size(img) == 64 << 20)
            try await VolumeMount.withMounted(img, at: mnt) { root in
                try FileManager.default.createDirectory(at: root.appendingPathComponent("a/b"), withIntermediateDirectories: true)
                try Data("hi\n".utf8).write(to: root.appendingPathComponent("a/b/c.txt"))
                try FileManager.default.createSymbolicLink(atPath: root.appendingPathComponent("a/l").path, withDestinationPath: "b/c.txt")
                try FileManager.default.createDirectory(at: root.appendingPathComponent(".fseventsd"), withIntermediateDirectories: true)
            }
            #expect(!(try await Self.attached(img)))
            let vol = try HFSPlusVolume(img)
            #expect(vol.signature == "HX")
            let l = try vol.listing()
            #expect(l.first { $0.path == "a/b/c.txt" }?.sha256 == Oracle.sha256(Data("hi\n".utf8)))
            #expect(l.first { $0.path == "a/l" }?.link == "b/c.txt")
            #expect(!l.contains { $0.path.hasPrefix(".fseventsd") })

            // A host-written journal (header bytes, need-init clear) handed to the device: zeroed, need-init set.
            let w = try HFSPlusVolume(img, writable: true), j = try #require(try w.journal())
            let jib = try Data(contentsOf: img)[1036..<1040].reduce(0) { $0 << 8 | Int($1) } * w.blockSize
            try w.restore([(j.offset, Data(repeating: 0xAB, count: 512)), (jib, Data([0, 0, 0, 1]))])
            #expect(try w.journal()?.needsInit == false)
            try w.leaveJournalToDevice()
            #expect(try w.journal()?.needsInit == true && w.journalSnapshot()?.last?.bytes == Data(count: j.size))

            guard HFSOracle.available else { try FixtureRequirements.missing(#"VolumeMountTests.swift: HFSOracle.available"#) }
            let py = dir.appendingPathComponent("py.img")
            _ = try HFSOracle.python("import ipad1_nand; ipad1_nand.make_hfs_image(sys.argv[1], int(sys.argv[2]))", [py.path, String(64 << 20 + 123)])
            let a = try HFSPlusVolume(dir.appendingPathComponent("py.img"))
            let fresh = dir.appendingPathComponent("fresh.img")
            try await VolumeMount.makeHFS(fresh, size: 64 << 20 + 123)
            let b = try HFSPlusVolume(fresh)
            let geo = { (v: HFSPlusVolume) in "\(v.signature) \(v.blockSize) \(v.totalBlocks) \(v.freeBlocks)" }
            #expect(geo(a) == geo(b))
            #expect(try a.listing() == b.listing())
        }
    }

    /// A handle left open on the volume: unmount fails, the image is force-detached and the call throws.
    @Test func busyVolumeIsDetached() async throws {
        try await Oracle.withTemp { dir in
            let img = dir.appendingPathComponent("v.img")
            try await VolumeMount.makeHFS(img, size: 16 << 20)
            var held: FileHandle?
            await #expect(throws: FirmwareError.self) {
                try await VolumeMount.withMounted(img, at: dir.appendingPathComponent("mnt")) { root in
                    FileManager.default.createFile(atPath: root.appendingPathComponent("f").path, contents: Data())
                    held = try FileHandle(forWritingTo: root.appendingPathComponent("f"))
                }
            }
            try? held?.close()
            #expect(!(try await Self.attached(img)))
        }
    }

    /// Growing the raw 7B500 / 8C148 system volume to partition 1 (1280 MiB) against grow_to_partition:
    /// same size, same volume-header geometry, same tree.
    @Test(.enabled(if: FixtureRequirements.corpusEnabled, "Firmware corpus test; set FK_TEST_CORPUS=1 to run"), arguments: HFSOracle.ipads) func growMatchesPython(_ fw: Oracle.Firmware) async throws {
        try await Oracle.withTemp { dir in
            guard HFSOracle.available, let raw = try await HFSOracle.rawSystem(fw, in: dir) else { try FixtureRequirements.missing(#"VolumeMountTests.swift: HFSOracle.available, let raw = try await HFSOracle.rawSystem(fw, in: dir)"#) }
            let py = dir.appendingPathComponent("py.hfs")
            try FileManager.default.copyItem(at: raw, to: py)
            let blocks = 1280 << 20 / 4096
            _ = try HFSOracle.python("import ipad1_rootfs as r; r.grow_to_partition(sys.argv[1], int(sys.argv[2]))", [py.path, String(blocks)])
            try await Oracle.time("grow \(fw.entryID)") { try await VolumeMount.grow(raw, toBytes: blocks * 4096) }
            #expect(try VolumeMount.size(raw) == blocks * 4096 && VolumeMount.size(py) == blocks * 4096)
            let a = try HFSPlusVolume(raw), b = try HFSPlusVolume(py)
            #expect(a.totalBlocks == b.totalBlocks && a.freeBlocks == b.freeBlocks && a.blockSize == b.blockSize,
                    "swift \(a.totalBlocks) x \(a.blockSize), \(a.freeBlocks) free; python \(b.totalBlocks) x \(b.blockSize), \(b.freeBlocks) free")
            #expect(try a.listing(hashes: false) == b.listing(hashes: false))
            let avh = { (u: URL) throws -> Data in
                let f = try FileHandle(forReadingFrom: u); defer { try? f.close() }
                try f.seek(toOffset: UInt64(blocks * 4096 - 1024)); return try f.read(upToCount: 2) ?? Data()
            }
            #expect(try avh(raw) == Data("HX".utf8))
            let dev = try await VolumeMount.attach(raw)
            let fsck = try await VolumeMount.check(dev)
            try await VolumeMount.detach(dev)
            #expect(fsck.ok, "\(fsck.output)")
        }
    }
    private actor AttachGate {
        private var reached = false
        private var arrival: CheckedContinuation<Void, Never>?
        private var release: CheckedContinuation<Void, Never>?
        func pause() async {
            reached = true; arrival?.resume(); arrival = nil
            await withCheckedContinuation { release = $0 }
        }
        func wait() async { if !reached { await withCheckedContinuation { arrival = $0 } } }
        func open() { release?.resume(); release = nil }
    }

    @Test func cancelledAttachAfterActualSideEffectCleansOnlyNewOwnedDevice() async throws {
        try await Oracle.withTemp { dir in
            let image = dir.appendingPathComponent("cancelled.img")
            let preserved = dir.appendingPathComponent("preserved.img")
            try await VolumeMount.makeHFS(image, size: 16 << 20)
            try await VolumeMount.makeHFS(preserved, size: 16 << 20)
            let retained = try await DiskImage.attach(preserved, readOnly: true)
            do {
                let gate = AttachGate()
                let tool = Task {
                    try await DiskImage.attach(image, execute: { argv in
                        let output = try await DiskImage.run(argv)
                        await gate.pause()
                        return output
                    })
                }
                await gate.wait()
                let observed = try await DiskImage.checkedAttachedImages()
                #expect(observed.contains { URL(fileURLWithPath: $0.image).resolvingSymlinksInPath().path == image.resolvingSymlinksInPath().path })
                tool.cancel(); await gate.open()
                await #expect(throws: CancellationError.self) { _ = try await tool.value }
                let after = try await DiskImage.checkedAttachedImages()
                #expect(!after.contains { URL(fileURLWithPath: $0.image).resolvingSymlinksInPath().path == image.resolvingSymlinksInPath().path })
                #expect(after.contains { $0.device == retained.device })
            } catch {
                try await DiskImage.detach(retained.device)
                throw error
            }
            try await DiskImage.detach(retained.device)
        }
    }

    @Test func cancelledMountedBodyAwaitsUncancelledCleanup() async throws {
        try await Oracle.withTemp { dir in
            let image = dir.appendingPathComponent("cancelled-body.img")
            try await VolumeMount.makeHFS(image, size: 16 << 20)
            let gate = AttachGate()
            let operation = Task {
                try await VolumeMount.withMounted(image, at: dir.appendingPathComponent("mount")) { _ in
                    await gate.pause()
                }
            }
            await gate.wait(); operation.cancel(); await gate.open()
            await #expect(throws: CancellationError.self) { try await operation.value }
            let attached = try await DiskImage.checkedAttachedImages()
            #expect(!attached.contains { URL(fileURLWithPath: $0.image).resolvingSymlinksInPath().path == image.resolvingSymlinksInPath().path })
        }
    }

}
