import Foundation
import Testing
@testable import FirmwareKit

@Suite(.serialized) struct VolumeMountTests {
    static func attached(_ image: URL) -> Bool {
        VolumeMount.exec("/usr/bin/hdiutil", ["info"]).1.contains(image.resolvingSymlinksInPath().path)
    }

    /// A fresh volume against ipad1_nand.make_hfs_image; files written through the mount land in the catalog,
    /// the junk is gone, fsck passed and nothing stays attached.
    @Test func makeMountEdit() throws {
        try Oracle.withTemp { dir in
            let img = dir.appendingPathComponent("data.img"), mnt = dir.appendingPathComponent("mnt")
            try VolumeMount.makeHFS(img, size: 64 << 20 + 123)
            #expect(try VolumeMount.size(img) == 64 << 20)
            try VolumeMount.withMounted(img, at: mnt) { root in
                try FileManager.default.createDirectory(at: root.appendingPathComponent("a/b"), withIntermediateDirectories: true)
                try Data("hi\n".utf8).write(to: root.appendingPathComponent("a/b/c.txt"))
                try FileManager.default.createSymbolicLink(atPath: root.appendingPathComponent("a/l").path, withDestinationPath: "b/c.txt")
                try FileManager.default.createDirectory(at: root.appendingPathComponent(".fseventsd"), withIntermediateDirectories: true)
            }
            #expect(!Self.attached(img))
            let vol = try HFSPlusVolume(img)
            #expect(vol.signature == "HX")
            let l = try vol.listing()
            #expect(l.first { $0.path == "a/b/c.txt" }?.sha256 == Oracle.sha256(Data("hi\n".utf8)))
            #expect(l.first { $0.path == "a/l" }?.link == "b/c.txt")
            #expect(!l.contains { $0.path.hasPrefix(".fseventsd") })

            guard HFSOracle.available else { return }
            let py = dir.appendingPathComponent("py.img")
            _ = try HFSOracle.python("import ipad1_nand; ipad1_nand.make_hfs_image(sys.argv[1], int(sys.argv[2]))", [py.path, String(64 << 20 + 123)])
            let a = try HFSPlusVolume(dir.appendingPathComponent("py.img"))
            let fresh = dir.appendingPathComponent("fresh.img")
            try VolumeMount.makeHFS(fresh, size: 64 << 20 + 123)
            let b = try HFSPlusVolume(fresh)
            let geo = { (v: HFSPlusVolume) in "\(v.signature) \(v.blockSize) \(v.totalBlocks) \(v.freeBlocks)" }
            #expect(geo(a) == geo(b))
            #expect(try a.listing() == b.listing())
        }
    }

    /// A handle left open on the volume: unmount fails, the image is force-detached and the call throws.
    @Test func busyVolumeIsDetached() throws {
        try Oracle.withTemp { dir in
            let img = dir.appendingPathComponent("v.img")
            try VolumeMount.makeHFS(img, size: 16 << 20)
            var held: FileHandle?
            #expect(throws: FirmwareError.self) {
                try VolumeMount.withMounted(img, at: dir.appendingPathComponent("mnt")) { root in
                    FileManager.default.createFile(atPath: root.appendingPathComponent("f").path, contents: Data())
                    held = try FileHandle(forWritingTo: root.appendingPathComponent("f"))
                }
            }
            try? held?.close()
            #expect(!Self.attached(img))
        }
    }

    /// Growing the raw 7B500 / 8C148 system volume to partition 1 (1280 MiB) against grow_to_partition:
    /// same size, same volume-header geometry, same tree.
    @Test(arguments: HFSOracle.ipads) func growMatchesPython(_ fw: Oracle.Firmware) throws {
        try Oracle.withTemp { dir in
            guard HFSOracle.available, let raw = try HFSOracle.rawSystem(fw, in: dir) else { return }
            let py = dir.appendingPathComponent("py.hfs")
            try FileManager.default.copyItem(at: raw, to: py)
            let blocks = 1280 << 20 / 4096
            _ = try HFSOracle.python("import ipad1_rootfs as r; r.grow_to_partition(sys.argv[1], int(sys.argv[2]))", [py.path, String(blocks)])
            try Oracle.time("grow \(fw.entryID)") { try VolumeMount.grow(raw, toBytes: blocks * 4096) }
            #expect(try VolumeMount.size(raw) == blocks * 4096 && VolumeMount.size(py) == blocks * 4096)
            let a = try HFSPlusVolume(raw), b = try HFSPlusVolume(py)
            #expect(a.totalBlocks == b.totalBlocks && a.freeBlocks == b.freeBlocks && a.blockSize == b.blockSize)
            #expect(try a.listing(hashes: false) == b.listing(hashes: false))
            let avh = { (u: URL) throws -> Data in
                let f = try FileHandle(forReadingFrom: u); defer { try? f.close() }
                try f.seek(toOffset: UInt64(blocks * 4096 - 1024)); return try f.read(upToCount: 2) ?? Data()
            }
            #expect(try avh(raw) == Data("HX".utf8))
            let dev = try VolumeMount.attach(raw)
            let fsck = VolumeMount.check(dev)
            VolumeMount.detach(dev)
            #expect(fsck.ok, "\(fsck.output)")
        }
    }
}
