import Foundation
import HostRuntime
import Testing

@testable import FirmwareKit

/// Device ▸ Jailbreak… on a stopped 1.x device (StoppedVolumeEdit.jailbreak on a legacy FTL store): the edits a
/// jailbroken preparation makes land through the 1.x FTL, the user's file is kept, and the published generation's
/// lock says jailbroken.
@Suite(.detachesItsImages) struct StoppedJailbreak1xTests {
    @Test func aStopped1xDeviceIsJailbrokenAndSaysSo() async throws {
        let fm = FileManager.default
        let root = try Fixtures.tempDir("jailbreak1x-edit")
        defer { TemporaryTrees.remove(root) }
        let device = root.appendingPathComponent("device")
        let base = device.appendingPathComponent("base")
        try fm.createDirectory(at: base, withIntermediateDirectories: true)
        let tree = try Jailbreak1xTests().firmware(
            root.appendingPathComponent("tree"),
            springBoard: Jailbreak1xTests.springBoard(),
            displayOrder: true
        )
        try JailbreakTests.put(Data("saved".utf8), tree, "private/var/root/user.txt")
        let image = root.appendingPathComponent("volume.img")
        // Under seven logical blocks, as Preferences1xTests' (the booted fixture remaps logical block 0).
        try await VolumeMount.makeHFS(image, size: 6 << 20, name: "Jailbreak 1x test")
        try await VolumeMount.withMounted(image, at: root.appendingPathComponent("initial")) { mount in
            for item in try fm.contentsOfDirectory(atPath: tree.path) {
                try fm.copyItem(at: tree.appendingPathComponent(item), to: mount.appendingPathComponent(item))
            }
        }
        try N45NAND.write(
            volume: image,
            out: base.appendingPathComponent("nand"),
            filID: 0x4330_3030,
            banks: N45FTLTests.banks
        )
        let overlay = device.appendingPathComponent("overlay")
        try N45FTLTests.booted(overlay, base.appendingPathComponent("nand"), changeData: false)
        try JSONSerialization.data(withJSONObject: ["board": "m68ap", "product_version": "1.0"])
            .write(to: base.appendingPathComponent("device.lock.json"))
        let record: [String: Any] = [
            "id": UUID().uuidString, "board": "m68ap", "firmware": "test",
            "base": ["kind": "prepared", "path": base.path],
            "storage": ["key": "old", "overlay": overlay.path, "snapshot": "old-snapshot"]
        ]
        try DeviceRecord.data(record).write(to: device.appendingPathComponent(DeviceRecord.name))
        let tools = try Jailbreak1xTests().guestTools(root.appendingPathComponent("guest"))

        try await StoppedVolumeEdit.jailbreak(
            device: device,
            bootstrap: { throw FirmwareError(.internal, "no Cydia on 1.x") }(),
            guestTools: { tools }
        )

        let published = try DeviceRecord.object(Data(contentsOf: device.appendingPathComponent(DeviceRecord.name)))
        let generation = URL(fileURLWithPath: try #require((published["base"] as? [String: Any])?["path"] as? String))
        #expect(try DeviceLock.read(base: generation)?.jailbroken == true)
        let newOverlay = URL(
            fileURLWithPath: try #require((published["storage"] as? [String: Any])?["overlay"] as? String)
        )
        let rebuilt = try VolumeRebuild.rebuild(
            base: generation.appendingPathComponent("nand"),
            overlay: newOverlay,
            into: root.appendingPathComponent("verify")
        )[0]
        let v = try HFSPlusVolume(rebuilt.image)
        #expect(try v.contents(v.record(at: "private/var/root/user.txt")) == Data("saved".utf8))
        let services = try PropertyListSerialization.propertyList(
            from: v.contents(v.record(at: SystemEdits.lockdownServices)),
            format: nil
        )
        #expect((services as? [String: Any])?["com.apple.afc2"] != nil)
        let installer = try v.record(at: SystemEdits.InstallerApp.path + "/Installer")
        #expect(installer.uid == 0 && installer.mode & 0o777 == 0o755)
        await #expect(throws: FirmwareError.self, "once only") {
            try await StoppedVolumeEdit.jailbreak(
                device: device, bootstrap: URL(fileURLWithPath: "/"), guestTools: { tools })
        }
    }
}
