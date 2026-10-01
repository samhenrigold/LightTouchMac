import CryptoKit
import Darwin
import Foundation
import Testing
@testable import FirmwareKit

struct StoppedVolumeEditTests {
    /// Real macOS HFS driver, ordinary atomic editor save, resource fork,
    /// symlink and case-sensitive names, then exact NAND logical roundtrip.
    @Test func nativeMetadataAndPublication() throws {
        let fm = FileManager.default
        let root = try Fixtures.tempDir("stopped-native-edit")
        defer {
            if ProcessInfo.processInfo.environment["FK_KEEP_EDIT_FIXTURE"] == nil { try? fm.removeItem(at: root) }
            else { print("stopped-edit fixture retained: \(root.path)") }
        }
        let device = root.appendingPathComponent("device")
        let base = device.appendingPathComponent("base")
        try fm.createDirectory(at: base, withIntermediateDirectories: true)
        let image = root.appendingPathComponent("volume.img")
        try VolumeMount.makeHFS(image, size: 32 << 20, name: "Edit metadata test")
        try VolumeMount.withMounted(image, at: root.appendingPathComponent("initial")) { mount in
            try fm.createDirectory(at: mount.appendingPathComponent("private/var/mobile/Media"), withIntermediateDirectories: true)
            try Data("before".utf8).write(to: mount.appendingPathComponent("Settings.plist"))
            try Data("Alpha".utf8).write(to: mount.appendingPathComponent("Alpha"))
            try Data("alpha".utf8).write(to: mount.appendingPathComponent("alpha"))
            try fm.createSymbolicLink(atPath: mount.appendingPathComponent("symlink").path, withDestinationPath: "Settings.plist")
            try fm.linkItem(at: mount.appendingPathComponent("Alpha"), to: mount.appendingPathComponent("hardlink"))
            let data = Data("resource-fork".utf8)
            #expect(data.withUnsafeBytes { setxattr(mount.appendingPathComponent("Settings.plist").path,
                "com.apple.ResourceFork", $0.baseAddress, $0.count, 0, 0) } == 0)
        }
        let hfs = try HFSPlusVolume(image, writable: true)
        try hfs.setOwner(["Settings.plist"], uid: 0, gid: 0, mode: 0o640)
        try hfs.setOwner(["private/var/mobile", "private/var/mobile/Media"], uid: 501, gid: 501)
        try hfs.setOwner(["Alpha"], uid: 501, gid: 501, mode: 0o644)
        #expect(try hfs.listing(hashes: false).first(where: { $0.path == "hardlink" })?.uid == 501)
        _ = try N72NAND.write(volume: image, blocks: hfs.totalBlocks * hfs.blockSize / N72NAND.page,
                             epoch: 1, out: base.appendingPathComponent("nand"))
        try JSONSerialization.data(withJSONObject: ["derived": ["nand_epoch": 1]]).write(to: base.appendingPathComponent("device.lock.json"))
        try Data(repeating: 0xff, count: 1 << 20).write(to: base.appendingPathComponent("nor.bin"))
        let record: [String: Any] = ["id": UUID().uuidString, "board": "n72ap", "firmware": "test",
            "base": ["kind": "prepared", "path": base.path],
            "storage": ["key": "old", "overlay": device.appendingPathComponent("overlay").path,
                        "snapshot": "old-snapshot", "writableNOR": device.appendingPathComponent("nor.bin").path,
                        "usbmuxConf": "conf"]]
        try JSONSerialization.data(withJSONObject: record).write(to: device.appendingPathComponent("device.json"))
        // A mounted/exported copy must not keep the stopped owner alive merely
        // because the declarative selection remains retained by its caller.
        let selection = try VolumeExport.Source(device: device)
        let readOnlyCopy = try VolumeExport.export(selection, out: root.appendingPathComponent("read-only-export"))
        #expect(readOnlyCopy.count == 1)
        do {
            let released = try StoppedStorageLease(device.appendingPathComponent("work/lease"))
            withExtendedLifetime((selection, released)) {}
        }
        let session = try StoppedVolumeEdit.begin(device: device)
        try VolumeMount.withMounted(session.image, at: root.appendingPathComponent("edit")) { mount in
            try Data("after-atomic-save".utf8).write(to: mount.appendingPathComponent("Settings.plist"), options: .atomic)
            try Data("new-mobile-file".utf8).write(to: mount.appendingPathComponent("private/var/mobile/Media/new.plist"))
        }
        try StoppedVolumeEdit.commit(device: device, id: session.id)
        let published = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: device.appendingPathComponent("device.json"))) as? [String: Any])
        let generationBase = URL(fileURLWithPath: try #require((published["base"] as? [String: String])?["path"]))
        let logical = try #require(try VolumeRebuild.rebuild(base: generationBase.appendingPathComponent("nand"), overlay: nil,
            into: root.appendingPathComponent("verify")).first)
        let volume = try HFSPlusVolume(logical.image)
        let settings = try volume.record(at: "Settings.plist")
        #expect(settings.uid == 0 && settings.gid == 0 && settings.mode & 0o7777 == 0o640)
        #expect(try volume.contents(settings) == Data("after-atomic-save".utf8))
        #expect(settings.resource?.logicalSize == UInt64("resource-fork".utf8.count))
        #expect(try volume.record(at: "private/var/mobile/Media/new.plist").uid == 501)
        #expect(try volume.record(at: "symlink").isSymlink)
        #expect(try volume.record(at: "hardlink").isHardLink)
        #expect(try volume.contents(volume.record(at: "Alpha")) == Data("Alpha".utf8))
        #expect(try volume.contents(volume.record(at: "alpha")) == Data("alpha".utf8))
        #expect(!fm.fileExists(atPath: device.appendingPathComponent("work/edit.json").path))
        #expect(fm.fileExists(atPath: base.appendingPathComponent("nand").path))
    }
}
