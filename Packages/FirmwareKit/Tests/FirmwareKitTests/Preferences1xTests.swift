import Foundation
import HostRuntime
import Testing

@testable import FirmwareKit

@Suite(.detachesItsImages) struct Preferences1xTests {
    /// A stopped 1.x device (N45FTLTests' booted-guest store) around a volume laid out as 1.0's (SpringBoard runs as
    /// root, no UserName in its job) or 1.1.3's on (mobile, 501): the keys go into that user's Preferences, the
    /// existing SpringBoard plist keeps its other keys, owner and mode, a new plist takes the folder's owner, the
    /// same keys again change nothing, and a removal takes its key out; on an image store (format 2, the edit writing
    /// the device's live clone) and on page files (format 1, the edit writing overlay page files).
    @Test(arguments: [false, true], [false, true])
    func writesIntoTheUserSpringBoardRunsAs(mobile: Bool, formatOne: Bool) async throws {
        let fm = FileManager.default
        let root = try Fixtures.tempDir("prefs1x-edit")
        defer { TemporaryTrees.remove(root) }
        let device = root.appendingPathComponent("device")
        let base = device.appendingPathComponent("base")
        try fm.createDirectory(at: base, withIntermediateDirectories: true)
        let image = root.appendingPathComponent("volume.img")
        let (home, uid): (String, UInt32) = mobile ? ("private/var/mobile", 501) : ("private/var/root", 0)
        let prefs = home + "/Library/Preferences"
        // Under seven logical blocks: the booted fixture remaps logical block 0 onto virtual block 30, logical block 7's
        // in the prepared store, so an edit there would land on block 0's pages.
        try Fixtures.makeVolume(image, size: 6 << 20, name: "Prefs test") { v in
            try v.makeDirectory("System/Library/LaunchDaemons")
            let jobPlist: [String: Any] =
                mobile ? ["Label": "com.apple.SpringBoard", "UserName": "mobile"] : ["Label": "com.apple.SpringBoard"]
            try v.put(
                PropertyListSerialization.data(fromPropertyList: jobPlist, format: .xml, options: 0),
                at: "System/Library/LaunchDaemons/com.apple.SpringBoard.plist"
            )
            for other in ["private/var/root/Library/Preferences", "private/var/mobile/Library/Preferences"] {
                try v.makeDirectory(other)
            }
            try v.put(
                PropertyListSerialization.data(
                    fromPropertyList: ["SBDisableIdleSleep": true], format: .binary, options: 0),
                at: prefs + "/com.apple.springboard.plist"
            )
        }
        let hfs = try HFSPlusVolume(image, writable: true)
        _ = try hfs.setOwner([home, home + "/Library", prefs], uid: uid, gid: uid, mode: 0o40755)
        _ = try hfs.setOwner([prefs + "/com.apple.springboard.plist"], uid: uid, gid: uid, mode: 0o100600)
        try N45NAND.write(
            volume: image,
            out: base.appendingPathComponent("nand"),
            filID: 0x4330_3030,
            banks: N45FTLTests.banks
        )
        let overlay = device.appendingPathComponent("overlay")
        try N45FTLTests.booted(overlay, base.appendingPathComponent("nand"), changeData: false)
        if formatOne { try N45FTLTests.asFormat1(base.appendingPathComponent("nand"), overlay: overlay) }
        try Data("{}".utf8).write(to: base.appendingPathComponent("device.lock.json"))
        let record: [String: Any] = [
            "id": UUID().uuidString, "board": mobile ? "n45ap" : "m68ap", "firmware": "test",
            "base": ["kind": "prepared", "path": base.path],
            "storage": ["key": "old", "overlay": overlay.path, "snapshot": "old-snapshot"]
        ]
        try DeviceRecord.data(record).write(to: device.appendingPathComponent(DeviceRecord.name))

        let set: [[String: Any]] = [
            ["domain": "com.apple.springboard", "key": "SBFakeTime", "value": true],
            ["domain": "com.apple.springboard", "key": "SBFakeTimeString", "value": "9:41 AM"],
            ["domain": "com.apple.mobilesafari", "key": "ConsoleEnabled", "value": true]
        ]
        #expect(try await Preferences1x.write(device: device, changes: set))
        #expect(try await Preferences1x.write(device: device, changes: set) == false, "the overlay holds them")

        func volume() throws -> HFSPlusVolume {
            let published = try DeviceRecord.object(Data(contentsOf: device.appendingPathComponent(DeviceRecord.name)))
            let newBase = URL(fileURLWithPath: try #require((published["base"] as? [String: Any])?["path"] as? String))
            let newOverlay = URL(
                fileURLWithPath: try #require((published["storage"] as? [String: Any])?["overlay"] as? String)
            )
            let out = root.appendingPathComponent("verify-\(UUID().uuidString)")
            let rebuilt = try VolumeRebuild.rebuild(
                base: newBase.appendingPathComponent("nand"),
                overlay: newOverlay,
                into: out
            )[0]
            return try HFSPlusVolume(rebuilt.image)
        }
        func plist(_ v: HFSPlusVolume, _ domain: String) throws -> NSDictionary? {
            try PropertyListSerialization.propertyList(
                from: v.contents(v.record(at: "\(prefs)/\(domain).plist")),
                format: nil
            ) as? NSDictionary
        }
        var v = try volume()
        let sb = try #require(try plist(v, "com.apple.springboard"))
        #expect(sb["SBFakeTime"] as? Bool == true && sb["SBFakeTimeString"] as? String == "9:41 AM")
        #expect(sb["SBDisableIdleSleep"] as? Bool == true, "the plist's other keys are kept")
        #expect(try plist(v, "com.apple.mobilesafari")?["ConsoleEnabled"] as? Bool == true)
        let entries = Dictionary(uniqueKeysWithValues: try v.listing(hashes: false).map { ($0.path, $0) })
        let sbEntry = try #require(entries[prefs + "/com.apple.springboard.plist"])
        #expect(sbEntry.uid == uid && sbEntry.gid == uid && sbEntry.mode & 0o777 == 0o600, "\(sbEntry)")
        let safari = try #require(entries[prefs + "/com.apple.mobilesafari.plist"])
        #expect(safari.uid == uid && safari.gid == uid, "a new plist takes its folder's owner: \(safari)")
        let other = mobile ? "private/var/root" : "private/var/mobile"
        #expect(entries[other + "/Library/Preferences/com.apple.springboard.plist"] == nil, "not the other home")

        // Turning the keynote clock off: its key removed, the others as they were.
        let removed: [[String: Any]] = [
            ["domain": "com.apple.springboard", "key": "SBFakeTimeString", "value": "9:41 AM"],
            ["domain": "com.apple.mobilesafari", "key": "ConsoleEnabled", "value": true],
            ["domain": "com.apple.springboard", "key": "SBFakeTime"]
        ]
        #expect(try await Preferences1x.write(device: device, changes: removed))
        v = try volume()
        let after = try #require(try plist(v, "com.apple.springboard"))
        #expect(after["SBFakeTime"] == nil && after["SBFakeTimeString"] as? String == "9:41 AM")
    }

    @Test func refusesABoardWithGuestTools() async throws {
        let root = try Fixtures.tempDir("prefs1x-refuse")
        defer { TemporaryTrees.remove(root) }
        try DeviceRecord.data(["id": UUID().uuidString, "board": "n72ap"]).write(
            to: root.appendingPathComponent(DeviceRecord.name)
        )
        await #expect(throws: FirmwareError.self) {
            try await Preferences1x.write(device: root, changes: [])
        }
    }
}
