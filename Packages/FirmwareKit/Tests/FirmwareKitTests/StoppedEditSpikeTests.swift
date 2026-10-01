import CryptoKit
import Foundation
import Testing
@testable import FirmwareKit

/// Opt-in disposable candidate, never an in-place device editor. Leaves output
/// for a separate native boot/AFC test; an offline round trip is not boot proof.
struct StoppedEditSpikeTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["FK_EDIT_SPIKE_DEVICE"] != nil,
                   "Set FK_EDIT_SPIKE_DEVICE and FK_EDIT_SPIKE_OUT for the disposable N72 edit spike"))
    func n72Candidate() throws {
        let env = ProcessInfo.processInfo.environment
        let source = URL(fileURLWithPath: try #require(env["FK_EDIT_SPIKE_DEVICE"]))
        let out = URL(fileURLWithPath: try #require(env["FK_EDIT_SPIKE_OUT"]))
        let fm = FileManager.default
        #expect(fm.fileExists(atPath: out.path) == false)
        guard !fm.fileExists(atPath: out.path) else { throw FirmwareError(.internal, "spike output already exists") }
        try fm.createDirectory(at: out, withIntermediateDirectories: true)
        let device = out.appendingPathComponent("device")
        guard clonefile(source.path, device.path, 0) == 0 else {
            throw FirmwareError(.internal, "clone device: \(String(cString: strerror(errno)))")
        }
        // Prepared device roots are intentionally read-only. Only the private
        // candidate root becomes writable, to swap its cloned NAND directory.
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: device.path)
        let lease = try StoppedStorageLease(device.appendingPathComponent("work/lease"))
        defer { withExtendedLifetime(lease) {} }
        let base = device.appendingPathComponent("nand")
        let overlay = fm.fileExists(atPath: device.appendingPathComponent("overlay").path) ? device.appendingPathComponent("overlay") : nil
        #expect(try VolumeRebuild.board(of: base) == .ipod)
        let volume = try #require(try VolumeExport.export(.init(base: base, overlay: overlay),
            out: out.appendingPathComponent("export")).first).image
        let image = URL(fileURLWithPath: volume)
        let before = try HFSPlusVolume(image).record(at: "System/Library/CoreServices/SystemVersion.plist")
        let marker = Data("<?xml version=\"1.0\"?><!DOCTYPE plist PUBLIC \"-//Apple//DTD PLIST 1.0//EN\" \"http://www.apple.com/DTDs/PropertyList-1.0.dtd\"><plist version=\"1.0\"><dict><key>probe</key><string>stopped-edit-candidate</string></dict></plist>".utf8)
        try VolumeMount.withMounted(image, at: out.appendingPathComponent("mnt")) { root in
            let file = root.appendingPathComponent("System/Library/CoreServices/SystemVersion.plist")
            var plist = try #require(try PropertyListSerialization.propertyList(from: Data(contentsOf: file), format: nil) as? [String: Any])
            plist["LTStoppedEditProbe"] = "stopped-edit-candidate"
            try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0).write(to: file, options: .atomic)
            try marker.write(to: root.appendingPathComponent("private/var/mobile/Media/ltm-stopped-edit.plist"), options: .atomic)
        }
        // Atomic editor saves replaced the catalog record. Restore its original
        // owner/mode explicitly, and give the newly created media file its guest owner.
        let hfs = try HFSPlusVolume(image, writable: true)
        try hfs.setOwner(["System/Library/CoreServices/SystemVersion.plist"], uid: before.uid, gid: before.gid, mode: before.mode)
        try hfs.setOwner(["private/var/mobile/Media/ltm-stopped-edit.plist"], uid: 501, gid: 501, mode: 0o644)
        let after = try hfs.record(at: "System/Library/CoreServices/SystemVersion.plist")
        #expect(after.uid == before.uid && after.gid == before.gid && after.mode == before.mode)
        #expect(after.adminFlags == before.adminFlags && after.ownerFlags == before.ownerFlags)
        let lock = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: device.appendingPathComponent("device.lock.json"))) as? [String: Any])
        let epoch = try #require((lock["derived"] as? [String: Any])?["nand_epoch"] as? Int)
        let candidate = out.appendingPathComponent("candidate-nand")
        try N72NAND.write(volume: image, blocks: hfs.totalBlocks * hfs.blockSize / N72NAND.page, epoch: epoch, out: candidate)
        let roundtrip = try #require(try VolumeRebuild.rebuild(base: candidate, overlay: nil,
            into: out.appendingPathComponent("roundtrip")).first)
        let expected = SHA256.hash(data: try Data(contentsOf: image, options: .alwaysMapped))
        let actual = SHA256.hash(data: try Data(contentsOf: roundtrip.image, options: .alwaysMapped))
        #expect(actual == expected)
        // Replace NAND only in the disposable clone, retaining original for inspection.
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: base.path)
        try fm.moveItem(at: base, to: out.appendingPathComponent("original-nand"))
        try fm.moveItem(at: candidate, to: base)
        if let overlay = overlay { try fm.moveItem(at: overlay, to: out.appendingPathComponent("original-overlay")) }
        try marker.write(to: out.appendingPathComponent("expected-marker.plist"))
        print("N72 offline edit candidate ready: \(device.path); native boot/readback/persistence NOT implied")
    }
}
