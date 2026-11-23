import FirmwareSchema
import Foundation
import HostRuntime
import Testing

@testable import FirmwareKit

/// Boot admission moves a recipe-1 M68 (and a recipe-2 N45) to the SystemConfiguration path 1.x reads.
@Suite(.detachesItsImages) struct N45MigrationTests {
    /// The volume has no SpringBoard job (1.0 to 1.1.2's root SpringBoard): configd's preferences in root's home.
    static let scPrefs = N45Board.rootLibrary + "/Preferences/SystemConfiguration"
    static func record(_ device: URL) throws -> [String: Any] {
        try DeviceRecord.object(Data(contentsOf: device.appendingPathComponent(DeviceRecord.name)))
    }
    static func storage(_ device: URL) throws -> (base: URL, overlay: URL, key: String) {
        let r = try record(device)
        let s = try #require(r["storage"] as? [String: Any])
        return (
            URL(fileURLWithPath: try #require((r["base"] as? [String: Any])?["path"] as? String)),
            URL(fileURLWithPath: try #require(s["overlay"] as? String)), try #require(s["key"] as? String)
        )
    }

    /// A booted M68 prepared at recipe 1 before 8a54efd (root's Preferences, no SystemConfiguration in it).
    /// Admission writes the files through a stopped edit, stamps the overlay, and then leaves the device alone
    /// until Erase takes the overlay away.
    @Test func admissionWritesRootsSystemConfiguration() async throws {
        let fm = FileManager.default
        let root = try Fixtures.tempDir("n45-sc-step")
        defer { TemporaryTrees.remove(root) }
        let device = root.appendingPathComponent("device")
        let base = device.appendingPathComponent("base")
        try fm.createDirectory(at: base, withIntermediateDirectories: true)
        let image = root.appendingPathComponent("volume.img")
        // What 1.x's configd writes there at first boot (measured on 1A543a): its own AirPort service on en0, and
        // no known networks.
        try Fixtures.makeVolume(image, size: 16 << 20, name: "SC step test") { v in
            try v.makeDirectory(Self.scPrefs)
            let service: [String: Any] = [
                "Interface": ["DeviceName": "en0", "Hardware": "AirPort", "Type": "Ethernet"],
                "UserDefinedName": "AirPort"
            ]
            try v.put(
                PropertyListSerialization.data(
                    fromPropertyList: ["NetworkServices": ["CONFIGD": service]],
                    format: .xml,
                    options: 0
                ),
                at: Self.scPrefs + "/preferences.plist"
            )
            try v.put(
                PropertyListSerialization.data(
                    fromPropertyList: ["JoinMode": "Automatic", "List of known networks": [Any]()],
                    format: .xml,
                    options: 0
                ),
                at: Self.scPrefs + "/com.apple.wifi.plist"
            )
        }
        let dirs = [
            "private", "private/var", "private/var/root", N45Board.rootLibrary, N45Board.rootLibrary + "/Preferences",
            Self.scPrefs,
            Self.scPrefs + "/preferences.plist", Self.scPrefs + "/com.apple.wifi.plist"
        ]
        // root's, as the recipe leaves them
        try HFSPlusVolume(image, writable: true).setOwner(dirs, uid: 0, gid: 0, mode: 0o755)
        try N45NAND.write(
            volume: image,
            out: base.appendingPathComponent("nand"),
            filID: 0x4330_3030,
            banks: N45FTLTests.banks
        )
        let overlay = device.appendingPathComponent("overlay")
        try N45FTLTests.booted(overlay, base.appendingPathComponent("nand"), changeData: false)
        // the app pinned it at first boot
        try Data("old".utf8).write(to: overlay.appendingPathComponent(".base-identity"))
        let lock: [String: Any] = [
            "board": "m68ap", "entry": ["id": "m68ap-1A543a", "content": ["recipe": ["name": "m68", "version": 1]]]
        ]
        try JSONSerialization.data(withJSONObject: lock).write(to: base.appendingPathComponent("device.lock.json"))
        let record: [String: Any] = [
            "id": UUID().uuidString, "board": "m68ap", "firmware": "m68ap-1A543a",
            "base": ["kind": "prepared", "path": base.path],
            "storage": ["key": "old", "overlay": overlay.path, "snapshot": "old-snapshot"]
        ]
        try DeviceRecord.data(record).write(to: device.appendingPathComponent(DeviceRecord.name))
        #expect(try N45Migration.pending(device: device, policy: .standalone) == 2)

        #expect(try await FirmwareBootAdmission.admit(device: device).changed)
        let first = try Self.storage(device)
        #expect(first.key != "old")
        #expect(fm.fileExists(atPath: first.overlay.appendingPathComponent(N45Migration.stamp).path))
        // the app can boot the edited storage
        #expect(try PreparedDeviceBoot.pinOverlay(first.overlay, toBase: first.key))
        let marker =
            try JSONSerialization.jsonObject(
                with: Data(contentsOf: device.appendingPathComponent(FirmwareWire.migratedRecipeFile))
            ) as? [String: Any]
        #expect(marker?["recipe"] as? Int == 2)
        let volume = try HFSPlusVolume(
            try VolumeRebuild.rebuild(
                base: first.base.appendingPathComponent("nand"),
                overlay: first.overlay,
                into: root.appendingPathComponent("verify")
            )[0].image
        )
        let prefs =
            try PropertyListSerialization.propertyList(
                from: volume.contents(volume.record(at: Self.scPrefs + "/preferences.plist")),
                format: nil
            ) as? [String: Any]
        let services = try #require(prefs?["NetworkServices"] as? [String: [String: Any]])
        #expect(Array(services.keys) == ["CONFIGD"])  // the PAC on configd's service, not a second en0 one
        #expect(
            (services["CONFIGD"]?["Proxies"] as? [String: Any])?["ProxyAutoConfigURLString"] as? String == "file:///"
                + SystemEdits.pacPath
        )
        // the set's global Proxies: 1.0's run-time cellular service takes them
        let set = String((prefs?["CurrentSet"] as? String ?? "").split(separator: "/").last ?? "")
        let global =
            ((((prefs?["Sets"] as? [String: Any])?[set] as? [String: Any])?["Network"] as? [String: Any])?["Global"]
                as? [String: Any])
        #expect(
            (global?["Proxies"] as? [String: Any])?["ProxyAutoConfigURLString"] as? String == "file:///"
                + SystemEdits.pacPath
        )
        let wifi = try volume.record(at: Self.scPrefs + "/com.apple.wifi.plist")
        let known =
            try PropertyListSerialization.propertyList(from: volume.contents(wifi), format: nil) as? [String: Any]
        #expect(known?["JoinMode"] as? String == "Automatic" && known?["AllowEnable"] as? Bool == true)
        #expect(
            (known?["List of known networks"] as? [[String: Any]])?.map { $0["SSID_STR"] as? String } == ["qemu-ios"]
        )
        #expect(wifi.uid == 0)

        _ = try await FirmwareBootAdmission.admit(device: device)  // stamped: nothing to do
        #expect(try Self.storage(device).key == first.key)

        try fm.removeItem(at: first.overlay)  // Erase
        _ = try await FirmwareBootAdmission.admit(device: device)
        let erased = try Self.storage(device)
        #expect(
            erased.key != first.key
                && fm.fileExists(atPath: erased.overlay.appendingPathComponent(N45Migration.stamp).path)
        )

        // a device the first version stamped (no global Proxies) takes the step again
        try fm.removeItem(at: erased.overlay.appendingPathComponent(N45Migration.stamp))
        try Data().write(to: erased.overlay.appendingPathComponent(".n45-sc-prefs"))
        #expect(try await FirmwareBootAdmission.admit(device: device).changed)
        #expect(fm.fileExists(atPath: try Self.storage(device).overlay.appendingPathComponent(N45Migration.stamp).path))
    }

    /// A 1.1.4 iPod prepared at recipe 3 before 44b92c0b (preparation 14): the recipe put the known network in root's
    /// home, where its configd (SpringBoard runs as mobile) never looks. Admission moves it to
    /// /private/var/preferences/SystemConfiguration; the same base prepared at serial 15, or a 1.1 one, takes nothing.
    @Test func admissionMovesTheMisplacedPreferences() async throws {
        let fm = FileManager.default
        let root = try Fixtures.tempDir("n45-sc-move")
        defer { TemporaryTrees.remove(root) }
        let device = root.appendingPathComponent("device")
        let base = device.appendingPathComponent("base")
        try fm.createDirectory(at: base, withIntermediateDirectories: true)
        let image = root.appendingPathComponent("volume.img")
        let systemSC = "private/var/preferences/SystemConfiguration"
        try Fixtures.makeVolume(image, size: 16 << 20, name: "SC move test") { v in
            try v.makeDirectory(SystemEdits.daemons)
            try v.put(
                PropertyListSerialization.data(
                    fromPropertyList: ["Label": "com.apple.SpringBoard", "UserName": "mobile"],
                    format: .xml,
                    options: 0
                ),
                at: SystemEdits.daemons + "/com.apple.SpringBoard.plist"
            )
            // what the recipe wrote before 44b92c0b
            try v.makeDirectory(Self.scPrefs)
            try v.put(
                PropertyListSerialization.data(fromPropertyList: N45Board.wifiKnownNetwork, format: .xml, options: 0),
                at: Self.scPrefs + "/com.apple.wifi.plist"
            )
            try v.makeDirectory(systemSC)
        }
        try N45NAND.write(
            volume: image,
            out: base.appendingPathComponent("nand"),
            filID: 0x4330_3030,
            banks: N45FTLTests.banks
        )
        let overlay = device.appendingPathComponent("overlay")
        try N45FTLTests.booted(overlay, base.appendingPathComponent("nand"), changeData: false)
        try Data("old".utf8).write(to: overlay.appendingPathComponent(".base-identity"))
        func lock(version: String, serial: Int) throws {
            let lock: [String: Any] = [
                "board": "n45ap", "preparation": serial,
                "entry": [
                    "id": "n45ap-4A102", "content": ["version": version, "recipe": ["name": "n45", "version": 3]]
                ]
            ]
            try JSONSerialization.data(withJSONObject: lock).write(to: base.appendingPathComponent("device.lock.json"))
        }
        let record: [String: Any] = [
            "id": UUID().uuidString, "board": "n45ap", "firmware": "n45ap-4A102",
            "base": ["kind": "prepared", "path": base.path],
            "storage": ["key": "old", "overlay": overlay.path, "snapshot": "old-snapshot"]
        ]
        try DeviceRecord.data(record).write(to: device.appendingPathComponent(DeviceRecord.name))
        try lock(version: "1.1.4", serial: 15)
        #expect(try N45Migration.pending(device: device, policy: .standalone) == nil, "prepared with the fix")
        try lock(version: "1.1", serial: 14)
        #expect(try N45Migration.pending(device: device, policy: .standalone) == nil, "1.1 reads root's home")
        try lock(version: "1.1.4", serial: 14)
        #expect(try N45Migration.pending(device: device, policy: .standalone) == 3)

        #expect(try await FirmwareBootAdmission.admit(device: device).changed)
        let edited = try Self.storage(device)
        #expect(fm.fileExists(atPath: edited.overlay.appendingPathComponent(N45Migration.stamp).path))
        let volume = try HFSPlusVolume(
            try VolumeRebuild.rebuild(
                base: edited.base.appendingPathComponent("nand"),
                overlay: edited.overlay,
                into: root.appendingPathComponent("verify")
            )[0].image
        )
        let known =
            try PropertyListSerialization.propertyList(
                from: volume.contents(volume.record(at: systemSC + "/com.apple.wifi.plist")),
                format: nil
            ) as? [String: Any]
        #expect(
            (known?["List of known networks"] as? [[String: Any]])?.map { $0["SSID_STR"] as? String } == ["qemu-ios"]
        )
        #expect((try? volume.record(at: systemSC + "/preferences.plist")) != nil)
        #expect((try? volume.record(at: Self.scPrefs + "/com.apple.wifi.plist")) == nil, "root's copy removed")
        #expect(try N45Migration.pending(device: device, policy: .standalone) == nil, "stamped")
    }

    /// Only the declared steps: a device prepared at the current recipe, or not 1.x, takes none.
    @Test func declaredSteps() {
        #expect(FirmwareWire.admittedRecipe(2, board: "n45ap") == 3)
        #expect(FirmwareWire.admittedRecipe(1, board: "m68ap") == 2)
        #expect(FirmwareWire.admittedRecipe(1, board: "n45ap") == 1)
        #expect(FirmwareWire.admittedRecipe(2, board: "k48ap") == 2)
    }
}
