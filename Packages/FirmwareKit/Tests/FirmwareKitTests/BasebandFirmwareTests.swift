import Foundation
import Testing

@testable import FirmwareKit

struct BasebandFirmwareTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["FIRMWAREKIT_MAV5_IOS7_IPSW"] != nil))
    func folderBackedUpdaterGetsOriginalImages() throws {
        let source = try #require(ProcessInfo.processInfo.environment["FIRMWAREKIT_MAV5_IOS7_IPSW"])
        let ipsw = IPSWArchive(URL(fileURLWithPath: source))
        let members = try BasebandFirmware.mav5Members(
            components: BuildComponents.load(ipsw, board: "n42ap"), board: "n42ap")
        let payloads = try BasebandFirmware.expandedMav5Assets(ipsw.read(members[0]))
        let image = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".hfs")
        defer { try? FileManager.default.removeItem(at: image) }
        try HFSPlusWriter.makeHFS(image, size: 128 << 20, name: "ModemAssets", journaled: false)
        let writer = try HFSPlusWriter(image)
        writer.owner = (0, 0)
        let paths = try BasebandFirmware.installMav5(from: ipsw, board: "n42ap", system: writer)
        #expect(paths.count == 10)
        for (path, bytes) in payloads {
            #expect(try writer.contents(at: path) == bytes)
            #expect(!bytes.isEmpty)
        }
        #expect(try BasebandFirmware.installMav5(from: ipsw, board: "n42ap", system: writer) == paths)
        // A late payload conflict must be detected before any earlier member is written.
        try writer.remove(paths[0])
        try writer.put(Data("conflict".utf8), at: paths.last!)
        #expect(throws: FirmwareError.self) {
            try BasebandFirmware.installMav5(from: ipsw, board: "n42ap", system: writer)
        }
        #expect(!writer.exists(paths[0]))
        try writer.close()
        let volume = try HFSPlusVolume(image)
        for path in paths.dropFirst().dropLast() {
            let record = try volume.record(at: path)
            #expect(record.uid == 0 && record.gid == 0 && record.mode & 0o777 == 0o644)
        }
    }

    @Test func selectsManifestVersionAndRejectsOtherFamilies() throws {
        #expect(
            try BasebandFirmware.mav5Members(
                components: ["BasebandFirmware": "Firmware/Mav5-1.00.16.Release.bbfw"], board: "n42ap") == [
                    "Firmware/Mav5-1.00.16.Release.bbfw", "Firmware/Mav5-1.00.16.Release.plist"
                ])
        for path in [
            "Firmware/Mav7-1.Release.bbfw", "Firmware/Mav5-../bad.Release.bbfw",
            "Firmware/Mav5-\\bad.Release.bbfw", "/Firmware/Mav5-1.Release.bbfw"
        ] {
            #expect(throws: FirmwareError.self) {
                try BasebandFirmware.mav5Members(components: ["BasebandFirmware": path], board: "n42ap")
            }
        }
        #expect(throws: FirmwareError.self) {
            try BasebandFirmware.mav5Members(components: [:], board: "n90ap")
        }
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["FIRMWAREKIT_MAV5_IPSW"] != nil))
    func originalAssetsAndConflictPreflight() throws {
        let source = try #require(ProcessInfo.processInfo.environment["FIRMWAREKIT_MAV5_IPSW"])
        let ipsw = IPSWArchive(URL(fileURLWithPath: source))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let volume = MountedVolume(root: root)
        let paths = try BasebandFirmware.installMav5(from: ipsw, board: "n42ap", system: volume)
        #expect(paths.count == 2)
        for path in paths {
            let member = "Firmware/" + URL(fileURLWithPath: path).lastPathComponent
            #expect(try volume.contents(at: path) == ipsw.read(member))
            #expect((try volume.item(at: path)?.mode ?? 0) & 0o777 == 0o644)
        }
        #expect(try BasebandFirmware.installMav5(from: ipsw, board: "n42ap", system: volume) == paths)
        try volume.remove(paths[0])
        try volume.put(Data("conflict".utf8), at: paths[1])
        #expect(throws: FirmwareError.self) {
            try BasebandFirmware.installMav5(from: ipsw, board: "n42ap", system: volume)
        }
        #expect(!volume.exists(paths[0]))
        #expect(try volume.contents(at: paths[1]) == Data("conflict".utf8))
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["FIRMWAREKIT_MAV5_IPSW"] != nil))
    func offlineHFSKeepsOriginalBytesAndRootOwnership() throws {
        let source = try #require(ProcessInfo.processInfo.environment["FIRMWAREKIT_MAV5_IPSW"])
        let ipsw = IPSWArchive(URL(fileURLWithPath: source))
        let image = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".hfs")
        defer { try? FileManager.default.removeItem(at: image) }
        try HFSPlusWriter.makeHFS(image, size: 64 << 20, name: "ModemAssets", journaled: false)
        let writer = try HFSPlusWriter(image)
        writer.owner = (0, 0)
        let paths = try BasebandFirmware.installMav5(from: ipsw, board: "n42ap", system: writer)
        try writer.close()
        let result = try HFSPlusVolume(image)
        for path in paths {
            let record = try result.record(at: path)
            #expect(record.uid == 0 && record.gid == 0 && record.mode & 0o777 == 0o644)
            #expect(
                try result.contents(record) == ipsw.read("Firmware/" + URL(fileURLWithPath: path).lastPathComponent))
        }
    }
}
