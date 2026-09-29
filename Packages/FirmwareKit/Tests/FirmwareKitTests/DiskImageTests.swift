import Foundation
import Testing
@testable import FirmwareKit

/// DiskImage: the argv of both backends on every host; the real operations on each backend this host has
/// (hdiutil everywhere; `diskutil image` on macOS 27+), and that both produce the same volume.
@Suite(.serialized) struct DiskImageTests {
    static let hasDiskutilImage = DiskImage.exec(["/usr/sbin/diskutil", "image"]).0 == 0
    static var backends: [DiskImage.Backend] { [.hdiutil] + (hasDiskutilImage ? [.diskutil] : []) }

    @Test func argv() {
        let img = URL(fileURLWithPath: "/tmp/v.img"), raw = ["-imagekey", "diskimage-class=CRawDiskImage"]
        #expect(DiskImage.attachCommand(img, readOnly: false, mount: false, backend: .hdiutil)
                == ["/usr/bin/hdiutil", "attach", "-plist"] + raw + ["-nomount", "-nobrowse", "/tmp/v.img"])
        #expect(DiskImage.attachCommand(img, readOnly: true, mount: true, backend: .hdiutil)
                == ["/usr/bin/hdiutil", "attach", "-plist"] + raw + ["-readonly", "-owners", "off", "-noverify", "-noautoopen", "/tmp/v.img"])
        #expect(DiskImage.attachCommand(img, readOnly: false, mount: false, backend: .diskutil)
                == ["/usr/sbin/diskutil", "image", "attach", "--plist", "--noMount", "--nobrowse", "/tmp/v.img"])
        #expect(DiskImage.attachCommand(img, readOnly: true, mount: true, backend: .diskutil)
                == ["/usr/sbin/diskutil", "image", "attach", "--plist", "--readOnly", "--mountOptions", "noowners", "/tmp/v.img"])
        #expect(DiskImage.detachCommand("/dev/disk9", force: false, backend: .hdiutil) == ["/usr/bin/hdiutil", "detach", "/dev/disk9"])
        #expect(DiskImage.detachCommand("/dev/disk9", force: true, backend: .hdiutil) == ["/usr/bin/hdiutil", "detach", "/dev/disk9", "-force"])
        #expect(DiskImage.detachCommand("/dev/disk9", force: false, backend: .diskutil) == ["/usr/sbin/diskutil", "eject", "/dev/disk9"])
        #expect(DiskImage.detachCommand("/dev/disk9", force: true, backend: .diskutil) == ["/usr/sbin/diskutil", "unmountDisk", "force", "/dev/disk9"])
        #expect(DiskImage.resizeCommand(img, bytes: 1 << 30, slack: 4096, backend: .hdiutil) == ["/usr/bin/hdiutil", "resize", "-sectors", "2097152"] + raw + ["/tmp/v.img"])
        #expect(DiskImage.resizeCommand(img, bytes: 1 << 30, slack: 0, backend: .diskutil) == ["/usr/sbin/diskutil", "image", "resize", "--size", "1073741824", "/tmp/v.img"])
        #expect(DiskImage.resizeCommand(img, bytes: 1 << 30, slack: 4096, backend: .diskutil) == ["/usr/sbin/diskutil", "image", "resize", "--size", "1073737728", "/tmp/v.img"])
        let dmg = URL(fileURLWithPath: "/tmp/a.dmg"), out = URL(fileURLWithPath: "/tmp/w/raw")
        #expect(DiskImage.convertCommand(dmg, raw: out, backend: .hdiutil) == ["/usr/bin/hdiutil", "convert", "/tmp/a.dmg", "-format", "UDTO", "-quiet", "-o", "/tmp/w/raw"])
        #expect(DiskImage.convertCommand(dmg, raw: out, backend: .diskutil) == ["/usr/sbin/diskutil", "image", "create", "from", "--format", "RAW", "/tmp/a.dmg", "/tmp/w/raw.raw"])
    }

    /// Both tools' attach plists: dev-entry with or without /dev/, the whole disk chosen, the mount point if any.
    @Test func attachPlist() {
        let diskutil = """
            <?xml version="1.0" encoding="UTF-8"?><plist version="1.0"><dict><key>system-entities</key><array>
            <dict><key>dev-entry</key><string>disk6</string><key>filesystem-type</key><string>hfs</string></dict>
            </array></dict></plist>
            """
        #expect(DiskImage.parseAttach(diskutil) == .init(device: "/dev/disk6", mountPoint: nil))
        let hdiutil = """
            <?xml version="1.0" encoding="UTF-8"?><plist version="1.0"><dict><key>system-entities</key><array>
            <dict><key>dev-entry</key><string>/dev/disk8s2</string><key>mount-point</key><string>/Volumes/Data</string></dict>
            <dict><key>dev-entry</key><string>/dev/disk8</string></dict>
            </array></dict></plist>
            """
        #expect(DiskImage.parseAttach("noise before\n" + hdiutil) == .init(device: "/dev/disk8", mountPoint: "/Volumes/Data"))
        #expect(DiskImage.parseAttach("not a plist") == nil)
    }

    /// Each backend this host has: attach/detach a raw volume (listed while attached, gone after), grow it, and the
    /// grown volumes of both backends are byte-identical, for 4 KiB and 8 KiB allocation blocks (iOS's two sizes)
    /// with 0, 4 and 8 KiB of file slack past the volume (the iPad IPSW volumes carry 4 KiB; hdiutil then stops a
    /// block short).
    @Test(arguments: [(4096, 0), (8192, 0), (8192, 4096), (4096, 4096), (8192, 8192)]) func backendsAgree(blockSize: Int, slack: Int) throws {
        try Oracle.withTemp { dir in
            let base = dir.appendingPathComponent("base.img")
            #expect(FileManager.default.createFile(atPath: base.path, contents: nil) && truncate(base.path, 32 << 20) == 0)
            let dev0 = try DiskImage.attach(base)
            try DiskImage.run(["/sbin/newfs_hfs", "-s", "-J", "-b", String(blockSize), "-v", "Data", dev0.device])
            DiskImage.detach(dev0.device)
            #expect(truncate(base.path, off_t((32 << 20) + slack)) == 0)
            var grown: [DiskImage.Backend: Data] = [:]
            for b in Self.backends {
                let img = dir.appendingPathComponent("\(b.rawValue).img")
                try FileManager.default.copyItem(at: base, to: img)
                let a = try DiskImage.attach(img, backend: b)
                #expect(a.device.hasPrefix("/dev/disk") && a.mountPoint == nil, "\(b)")
                #expect(DiskImage.attachedImages().contains { $0.image == img.path && $0.device == a.device }, "\(b): listed while attached")
                DiskImage.detach(a.device, backend: b)
                #expect(!DiskImage.attachedImages().contains { $0.image == img.path }, "\(b): gone after detach")
                try VolumeMount.grow(img, toBytes: 64 << 20, backend: b)   // resize, then the pad + alternate header move
                let v = try HFSPlusVolume(img)
                #expect(v.blockSize == blockSize && v.totalBlocks == ((64 << 20) - slack % blockSize) / blockSize, "\(b): \(v.totalBlocks) x \(v.blockSize)")
                let dev = try DiskImage.attach(img, backend: b).device
                let fsck = VolumeMount.check(dev)
                DiskImage.detach(dev, backend: b)
                #expect(fsck.ok, "\(b): \(fsck.output.suffix(300))")
                grown[b] = try Data(contentsOf: img)
            }
            if let h = grown[.hdiutil], let d = grown[.diskutil] {
                #expect(h == d, "hdiutil and diskutil image resize differ: first byte \(zip(h, d).enumerated().first { $0.element.0 != $0.element.1 }?.offset ?? -1)")
            }
        }
    }

    /// Each backend converts a UDIF (zlib) image to the same raw disk.
    @Test func convertToRaw() throws {
        try Oracle.withTemp { dir in
            let src = dir.appendingPathComponent("src"), dmg = dir.appendingPathComponent("a.dmg")
            try FileManager.default.createDirectory(at: src, withIntermediateDirectories: true)
            try Data("hello\n".utf8).write(to: src.appendingPathComponent("f"))
            try DiskImage.run(["/usr/bin/hdiutil", "create", "-quiet", "-format", "UDZO", "-fs", "HFS+", "-layout", "SPUD", "-srcfolder", src.path, "-o", dmg.path])
            var raws: [Data] = []
            for b in Self.backends {
                let out = dir.appendingPathComponent("\(b.rawValue).raw")
                try DiskImage.convertToRaw(dmg, to: out, backend: b)
                raws.append(try Data(contentsOf: out))
                #expect(raws.last!.count > 0 && (try? APM.hfsSlice(raws.last!.prefix(64 * 512))) != nil, "\(b): an Apple partition map with an HFS slice")
            }
            if raws.count == 2 {
                let (o1, o2) = (try APM.hfsSlice(raws[0].prefix(64 * 512)), try APM.hfsSlice(raws[1].prefix(64 * 512)))
                #expect(o1 == o2 && raws[0][o1.offset..<o1.offset + o1.length] == raws[1][o2.offset..<o2.offset + o2.length],
                        "the backends' HFS slices differ (\(raws[0].count) vs \(raws[1].count) bytes, first difference at \(zip(raws[0], raws[1]).enumerated().first { $0.element.0 != $0.element.1 }?.offset ?? -1))")
            }
        }
    }
}
