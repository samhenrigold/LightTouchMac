import Crypto
import Darwin
import Foundation
import HostRuntime
import Testing

@testable import FirmwareKit

@Suite(.detachesItsImages) struct StoppedVolumeEditTests {
    /// Real macOS HFS driver, ordinary atomic editor save, resource fork,
    /// symlink and case-sensitive names, then exact NAND logical roundtrip.
    @Test func nativeMetadataAndPublication() async throws {
        let fm = FileManager.default
        let root = try Fixtures.tempDir("stopped-native-edit")
        defer {
            if ProcessInfo.processInfo.environment["FK_KEEP_EDIT_FIXTURE"] == nil {
                TemporaryTrees.remove(root)
            } else {
                print("stopped-edit fixture retained: \(root.path)")
            }
        }
        let device = root.appendingPathComponent("device")
        let base = device.appendingPathComponent("base")
        try fm.createDirectory(at: base, withIntermediateDirectories: true)
        let image = root.appendingPathComponent("volume.img")
        try await VolumeMount.makeHFS(image, size: 32 << 20, name: "Edit metadata test")
        try await VolumeMount.withMounted(image, at: root.appendingPathComponent("initial")) { mount in
            try fm.createDirectory(
                at: mount.appendingPathComponent("private/var/mobile/Media"),
                withIntermediateDirectories: true
            )
            try Data("before".utf8).write(to: mount.appendingPathComponent("Settings.plist"))
            try Data("Alpha".utf8).write(to: mount.appendingPathComponent("Alpha"))
            try Data("alpha".utf8).write(to: mount.appendingPathComponent("alpha"))
            try Data().write(to: mount.appendingPathComponent(".file"))
            try fm.createSymbolicLink(
                atPath: mount.appendingPathComponent("symlink").path,
                withDestinationPath: "Settings.plist"
            )
            try fm.linkItem(at: mount.appendingPathComponent("Alpha"), to: mount.appendingPathComponent("hardlink"))
            let data = Data("resource-fork".utf8)
            #expect(
                data.withUnsafeBytes {
                    setxattr(
                        mount.appendingPathComponent("Settings.plist").path,
                        "com.apple.ResourceFork",
                        $0.baseAddress,
                        $0.count,
                        0,
                        0
                    )
                } == 0
            )
        }
        let hfs = try HFSPlusVolume(image, writable: true)
        try hfs.setOwner(["Settings.plist"], uid: 0, gid: 0, mode: 0o640)
        try hfs.setOwner(["private/var/mobile", "private/var/mobile/Media"], uid: 501, gid: 501)
        try hfs.setOwner(["Alpha"], uid: 501, gid: 501, mode: 0o644)
        try hfs.setOwner([".file"], uid: 0, gid: 80, mode: 0)  // iOS 4's /.file: mode 000, unreadable when mounted
        #expect(try hfs.listing(hashes: false).first(where: { $0.path == "hardlink" })?.uid == 501)
        _ = try N72NAND.write(
            volume: image,
            blocks: hfs.totalBlocks * hfs.blockSize / N72NAND.page,
            epoch: 1,
            out: base.appendingPathComponent("nand")
        )
        try JSONSerialization.data(withJSONObject: ["derived": ["nand_epoch": 1]]).write(
            to: base.appendingPathComponent("device.lock.json")
        )
        try Data(repeating: 0xff, count: 1 << 20).write(to: base.appendingPathComponent("nor.bin"))
        let record: [String: Any] = [
            "id": UUID().uuidString, "board": "n72ap", "firmware": "test",
            "base": ["kind": "prepared", "path": base.path],
            "storage": [
                "key": "old", "overlay": device.appendingPathComponent("overlay").path,
                "snapshot": "old-snapshot", "writableNOR": device.appendingPathComponent("nor.bin").path,
                "usbmuxConf": "conf"
            ]
        ]
        try DeviceRecord.data(record).write(to: device.appendingPathComponent(DeviceRecord.name))
        // A mounted/exported copy must not keep the stopped owner alive merely
        // because the declarative selection remains retained by its caller.
        let selection = try VolumeExport.Source(device: device)
        let readOnlyCopy = try await VolumeExport.export(
            selection,
            out: root.appendingPathComponent("read-only-export")
        )
        #expect(readOnlyCopy.count == 1)
        do {
            let released = try OwnedStorageRecord.acquire(device: device)
            withExtendedLifetime((selection, released)) {}
        }
        let preparedRecord = try Data(contentsOf: device.appendingPathComponent(DeviceRecord.name))
        let session = try await StoppedVolumeEdit.begin(device: device)
        try await VolumeMount.withMounted(session.image, at: root.appendingPathComponent("edit")) { mount in
            try Data("after-atomic-save".utf8).write(
                to: mount.appendingPathComponent("Settings.plist"),
                options: .atomic
            )
            try Data("new-mobile-file".utf8).write(
                to: mount.appendingPathComponent("private/var/mobile/Media/new.plist")
            )
        }
        try await StoppedVolumeEdit.commit(device: device, id: session.id)
        let published = try DeviceRecord.object(Data(contentsOf: device.appendingPathComponent(DeviceRecord.name)))
        let generationBase = URL(fileURLWithPath: try #require((published["base"] as? [String: String])?["path"]))
        let logical = try #require(
            try VolumeRebuild.rebuild(
                base: generationBase.appendingPathComponent("nand"),
                overlay: nil,
                into: root.appendingPathComponent("verify")
            ).first
        )
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
        #expect(try volume.record(at: ".file").mode & 0o7777 == 0)
        #expect(!fm.fileExists(atPath: device.appendingPathComponent("work/edit.json").path))
        #expect(fm.fileExists(atPath: base.appendingPathComponent("nand").path))
        // What Erase returns to (DeviceStateStorage.returnToPrepared): the replaced record, kept by the generation.
        #expect(
            try Data(
                contentsOf: device.appendingPathComponent(
                    "generations/\(session.id.uuidString)/original-\(DeviceRecord.name)"
                )
            ) == preparedRecord
        )
    }
}

@Suite(.detachesItsImages) struct StoppedYaFTLEditTests {
    /// A YaFTL device (the selfcheck geometry; whitened as the A4 boards, plain as the S5L8920 boards): an overlay that
    /// rewrote the whole store, as the guest's writes do, is what begin exports; a file written into an app's Documents
    /// on the data volume is in the published store's data volume, owned by mobile, beside the guest's file, with the
    /// store's signature kept and an empty overlay.
    @Test(arguments: [true, false]) func dataVolumeEdit(whitening: Bool) async throws {
        let fm = FileManager.default
        let root = try Fixtures.tempDir("stopped-yaftl-edit")
        defer { TemporaryTrees.remove(root) }
        let geo = K48NAND.Geometry.selfcheck
        let mbr = root.appendingPathComponent("mbr.bin")
        try K48NAND.makeMBR(geometry: geo, systemMiB: 8).write(to: mbr)
        let system = root.appendingPathComponent("system.img")
        try await VolumeMount.makeHFS(system, size: 8 << 20, name: "System")
        try await VolumeMount.withMounted(system, at: root.appendingPathComponent("mnt-system")) {
            try fm.createDirectory(at: $0.appendingPathComponent("private/var"), withIntermediateDirectories: true)
        }
        let documents = "mobile/Applications/APP/Documents"
        let data = root.appendingPathComponent("data.img")
        try await VolumeMount.makeHFS(data, size: 8 << 20)
        try await VolumeMount.withMounted(data, at: root.appendingPathComponent("mnt-data")) {
            try fm.createDirectory(at: $0.appendingPathComponent(documents), withIntermediateDirectories: true)
            // files with attributes the Mac can't read back (6.x's, with their protection class): a log left alone,
            // an app's save replaced
            for name in ["log.asl", "\(documents)/save.dat"] {
                let file = $0.appendingPathComponent(name)
                try Data("old".utf8).write(to: file)
                #expect(setxattr(file.path, "com.apple.test", "x", 1, 0, 0) == 0)
            }
        }
        let dataHFS = try HFSPlusVolume(data, writable: true)
        try dataHFS.setOwner(
            ["mobile", "mobile/Applications", "mobile/Applications/APP", documents],
            uid: 501,
            gid: 501
        )
        try dataHFS.setOwner(["log.asl", "\(documents)/save.dat"], uid: 0, gid: 0, mode: 0)
        let kernel = Array("Darwin Kernel Version selfcheck".utf8)
        func store(_ out: URL, data: URL) async throws {
            try await K48NAND.build(
                geometry: geo,
                mbr: mbr,
                kernelVersion: kernel,
                epoch: 4,
                system: system,
                data: .image(data),
                out: out,
                whitening: whitening
            )
        }
        let device = root.appendingPathComponent("device")
        let base = device.appendingPathComponent("base")
        try await store(base.appendingPathComponent("nand"), data: data)
        // The guest's store: the data volume with its file, every page of it in the overlay.
        let guest = root.appendingPathComponent("guest.img")
        #expect(clonefile(data.path, guest.path, 0) == 0)
        try await VolumeMount.withMounted(guest, at: root.appendingPathComponent("mnt-guest")) {
            try Data("guest".utf8).write(to: $0.appendingPathComponent("\(documents)/guest.txt"))
        }
        let overlay = device.appendingPathComponent("overlay")
        try await store(overlay, data: guest)
        for b in 0..<geo.buses {
            for c in 0..<geo.cePerBus {
                try Data(repeating: 0xFF, count: geo.pagesPerCE / 8).write(
                    to: overlay.appendingPathComponent("bus\(b)-ce\(c).dirty")
                )
            }
        }
        try fm.removeItem(at: overlay.appendingPathComponent("geometry.json"))
        try JSONSerialization.data(withJSONObject: ["board": "n90ap"]).write(
            to: base.appendingPathComponent("device.lock.json")
        )
        try Data(repeating: 0xff, count: 1 << 20).write(to: base.appendingPathComponent("nor.bin"))
        let record: [String: Any] = [
            "id": UUID().uuidString, "board": "n90ap", "firmware": "test",
            "base": ["kind": "prepared", "path": base.path],
            "storage": [
                "key": "old", "overlay": overlay.path, "snapshot": "old-snapshot",
                "writableNOR": device.appendingPathComponent("nor.bin").path, "usbmuxConf": "conf"
            ]
        ]
        try DeviceRecord.data(record).write(to: device.appendingPathComponent(DeviceRecord.name))

        let session = try await StoppedVolumeEdit.begin(device: device)
        let edited = try #require(session.data)
        try await VolumeMount.withMounted(edited, at: root.appendingPathComponent("edit")) {
            #expect(try Data(contentsOf: $0.appendingPathComponent("\(documents)/guest.txt")) == Data("guest".utf8))
            try Data("from the Mac".utf8).write(to: $0.appendingPathComponent("\(documents)/hello.txt"))
            try fm.removeItem(at: $0.appendingPathComponent("\(documents)/save.dat"))
            try Data("new save".utf8).write(to: $0.appendingPathComponent("\(documents)/save.dat"))
        }
        // A commit cut short (the app quit): half a store in the base, made read-only. The next commit starts over.
        let generationBase = device.appendingPathComponent("generations/\(session.id.uuidString)/base")
        #expect(!fm.fileExists(atPath: generationBase.appendingPathComponent("nand").path))
        try fm.createDirectory(at: generationBase.appendingPathComponent("nand"), withIntermediateDirectories: false)
        try Data("partial".utf8).write(to: generationBase.appendingPathComponent("nand/bus0-ce0.pages"))
        try Preparer.readOnly(generationBase)
        try await StoppedVolumeEdit.commit(device: device, id: session.id)

        let published = try DeviceRecord.object(Data(contentsOf: device.appendingPathComponent(DeviceRecord.name)))
        let generation = URL(fileURLWithPath: try #require((published["base"] as? [String: String])?["path"]))
        #expect(generation.standardizedFileURL == generationBase.standardizedFileURL)
        #expect(
            !fm.fileExists(atPath: generation.deletingLastPathComponent().appendingPathComponent("guest-nand").path)
        )
        let newOverlay = try #require((published["storage"] as? [String: Any])?["overlay"] as? String)
        #expect(try fm.contentsOfDirectory(atPath: newOverlay).isEmpty)
        let nand = generation.appendingPathComponent("nand")
        let st = try K48NAND.StoreReader(nand, geo: geo)
        #expect(st.signature()?.epoch == 4 && st.signature()?.kernelVersion == kernel && st.plain == !whitening)
        let volumes = try VolumeRebuild.rebuild(base: nand, overlay: nil, into: root.appendingPathComponent("verify"))
        #expect(volumes.map(\.name) == ["system", "data"])
        _ = try HFSPlusVolume(volumes[0].image).record(at: "private/var")
        let volume = try HFSPlusVolume(volumes[1].image)
        let hello = try volume.record(at: "\(documents)/hello.txt")
        #expect(try volume.contents(hello) == Data("from the Mac".utf8))
        #expect(hello.uid == 501 && hello.gid == 501)
        #expect(try volume.contents(volume.record(at: "\(documents)/guest.txt")) == Data("guest".utf8))
        #expect(try volume.contents(volume.record(at: "\(documents)/save.dat")) == Data("new save".utf8))
    }
}
