import Foundation
import Testing
@testable import FirmwareKit

/// Required separately from the small synthetic HFS test: leaves a published
/// generation for independent cold-boot/AFC/persistence acceptance.
struct StoppedVolumeEditNativeTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["FK_EDIT_NATIVE_SOURCE"] != nil,
                   "Set FK_EDIT_NATIVE_SOURCE/FK_EDIT_NATIVE_OUT for firmware publication acceptance"))
    func publishedFirmwareCandidate() throws {
        let env = ProcessInfo.processInfo.environment
        let source = URL(fileURLWithPath: try #require(env["FK_EDIT_NATIVE_SOURCE"]))
        let out = URL(fileURLWithPath: try #require(env["FK_EDIT_NATIVE_OUT"]))
        let fm = FileManager.default
        try #require(!fm.fileExists(atPath: out.path))
        let device = out.appendingPathComponent("Devices/\(UUID().uuidString)")
        try fm.createDirectory(at: device, withIntermediateDirectories: true)
        let base = device.appendingPathComponent("base")
        try #require(clonefile(source.path, base.path, 0) == 0)
        let record: [String: Any] = ["id": device.lastPathComponent, "board": "n72ap", "firmware": "7E18",
            "base": ["kind": "prepared", "path": base.path],
            "storage": ["key": "initial", "overlay": device.appendingPathComponent("overlay").path,
                        "snapshot": device.appendingPathComponent("snapshot").path,
                        "writableNOR": device.appendingPathComponent("nor.bin").path,
                        "usbmuxConf": device.appendingPathComponent("conf").path]]
        try JSONSerialization.data(withJSONObject: record).write(to: device.appendingPathComponent("device.json"))
        let edit = try StoppedVolumeEdit.begin(device: device, log: { print($0) })
        let marker = Data("<?xml version=\"1.0\"?><plist version=\"1.0\"><dict><key>probe</key><string>published-storage-generation</string></dict></plist>".utf8)
        try VolumeMount.withMounted(edit.image, at: out.appendingPathComponent("edit")) { root in
            let plist = root.appendingPathComponent("System/Library/CoreServices/SystemVersion.plist")
            var value = try #require(try PropertyListSerialization.propertyList(from: Data(contentsOf: plist), format: nil) as? [String: Any])
            value["LTStorageGenerationProbe"] = edit.id.uuidString
            try PropertyListSerialization.data(fromPropertyList: value, format: .xml, options: 0).write(to: plist, options: .atomic)
            try marker.write(to: root.appendingPathComponent("private/var/mobile/Media/ltm-stopped-edit.plist"), options: .atomic)
        }
        try StoppedVolumeEdit.commit(device: device, id: edit.id, log: { print($0) })
        let published = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: device.appendingPathComponent("device.json"))) as? [String: Any])
        let generation = try #require((published["base"] as? [String: String])?["path"])
        try marker.write(to: out.appendingPathComponent("expected-marker.plist"))
        try Data(generation.utf8).write(to: out.appendingPathComponent("published-base.txt"))
        print("published actual firmware candidate: \(generation); native boot still required")
    }
}
