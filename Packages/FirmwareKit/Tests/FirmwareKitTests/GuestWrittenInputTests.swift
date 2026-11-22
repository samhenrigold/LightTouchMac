// What a device wrote, read by the unsandboxed preparer at a stopped edit: a guest that controls its own volumes and
// overlay must not crash the edit, size its reads, or steer its reads and writes outside the device's folder.

import Foundation
import HostRuntime
import Testing

@testable import FirmwareKit

struct GuestWrittenInputTests {
    /// A journaled volume whose journal info block says `offset` and `size`.
    static func journaledVolume(offset: UInt64, size: UInt64, in dir: URL) throws -> URL {
        let image = dir.appendingPathComponent("data.hfs")
        try HFSPlusWriter.makeHFS(image, size: 8 << 20)
        let header = try Data(contentsOf: image)[1024 + 12..<1024 + 16]  // journalInfoBlock, in 4 KiB blocks
        let jib = header.reduce(0) { $0 << 8 | UInt64($1) } * 4096
        let handle = try FileHandle(forWritingTo: image)
        defer { try? handle.close() }
        try handle.seek(toOffset: jib + 36)
        try handle.write(contentsOf: [offset, size].flatMap { v in (0..<8).map { UInt8(v >> (56 - 8 * $0) & 0xFF) } })
        return image
    }

    /// A journal offset with its top bit set trapped converting to an Int, and a size past the volume sized the
    /// snapshot's buffer: both are refused, the volume's own journal is still read.
    static let outside: [(UInt64, UInt64)] = [(1 << 63, 512 << 10), (4096, 1 << 40), (8 << 20, 4096)]

    @Test(arguments: outside)
    func aJournalOutsideTheVolumeIsRefused(_ offset: UInt64, _ size: UInt64) throws {
        let dir = try Fixtures.tempDir("guest-journal")
        defer { try? FileManager.default.removeItem(at: dir) }
        let fine = try Self.journaledVolume(offset: 8192, size: 512 << 10, in: dir)
        #expect(try HFSPlusVolume(fine).journal()?.size == 512 << 10)
        let image = try Self.journaledVolume(offset: offset, size: size, in: dir)
        #expect(throws: FirmwareError.self) { try HFSPlusVolume(image).journal() }
        #expect(throws: FirmwareError.self) { try HFSPlusVolume(image).journalSnapshot() }
    }

    /// A booted 1.x device (as N45FTLTests.stoppedEditInPlace makes one) whose overlay is as `plant` leaves it.
    static func legacyDevice(in root: URL, plant: (_ overlay: URL) throws -> Void) async throws -> URL {
        let fm = FileManager.default
        let device = root.appendingPathComponent("device")
        let base = device.appendingPathComponent("base")
        try fm.createDirectory(at: base, withIntermediateDirectories: true)
        let image = root.appendingPathComponent("volume.img")
        try HFSPlusWriter.makeHFS(image, size: 16 << 20, name: "Legacy edit test")
        try N45NAND.write(
            volume: image,
            out: base.appendingPathComponent("nand"),
            filID: 0x4330_3030,
            banks: N45FTLTests.banks
        )
        let overlay = device.appendingPathComponent("overlay")
        try N45FTLTests.booted(overlay, base.appendingPathComponent("nand"), changeData: false)
        try plant(overlay)
        try Data("{}".utf8).write(to: base.appendingPathComponent("device.lock.json"))
        let record: [String: Any] = [
            "id": UUID().uuidString, "board": "m68ap", "firmware": "test",
            "base": ["kind": "prepared", "path": base.path],
            "storage": ["key": "old", "overlay": overlay.path, "snapshot": "old-snapshot"]
        ]
        try DeviceRecord.data(record).write(to: device.appendingPathComponent(DeviceRecord.name))
        return device
    }

    enum Plant: CaseIterable, Sendable { case nothing, linkInTheOverlay, overlayIsALink }

    /// The sandboxed helper writes the overlay, and a stopped edit (unsandboxed) clones it and writes the edit's
    /// pages over the clone's: a link there took the edit's reads and writes to whatever it named. A device with
    /// one is refused before anything reads it.
    @Test(arguments: Plant.allCases)
    func aStoppedEditRefusesALinkInTheOverlay(_ plant: Plant) async throws {
        let fm = FileManager.default
        let root = try Fixtures.tempDir("guest-overlay-link")
        defer { try? fm.removeItem(at: root) }
        let host = root.appendingPathComponent("host-file")
        try Data("the host's".utf8).write(to: host)
        let device = try await Self.legacyDevice(in: root) { overlay in
            switch plant {
            case .nothing: break
            case .linkInTheOverlay:
                try fm.createSymbolicLink(at: overlay.appendingPathComponent("nand/planted"), withDestinationURL: host)
            case .overlayIsALink:
                let moved = root.appendingPathComponent("elsewhere")
                try fm.moveItem(at: overlay, to: moved)
                try fm.createSymbolicLink(at: overlay, withDestinationURL: moved)
            }
        }
        if plant == .nothing {
            _ = try await StoppedVolumeEdit.begin(device: device)
        } else {
            await #expect(throws: FirmwareError.self) { _ = try await StoppedVolumeEdit.begin(device: device) }
        }
        #expect(try Data(contentsOf: host) == Data("the host's".utf8))
    }

    /// Boot admission writes the live overlay's pages and stamps with writeDurably, a temporary renamed over the
    /// target: a link the helper planted at the temporary's name had the page written over the file it named.
    @Test func aDurableWriteGoesNotThroughALinkAtItsTemporary() throws {
        let fm = FileManager.default
        let root = try Fixtures.tempDir("guest-durable-link")
        defer { try? fm.removeItem(at: root) }
        let host = root.appendingPathComponent("host-file")
        try Data("the host's".utf8).write(to: host)
        let page = root.appendingPathComponent("overlay/cs1/512.page")
        try fm.createDirectory(at: page.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fm.createSymbolicLink(
            at: page.deletingLastPathComponent().appendingPathComponent(".512.page.tmp"),
            withDestinationURL: host
        )
        try N72NAND.writeDurably(Data("a page".utf8), to: page)
        #expect(try Data(contentsOf: page) == Data("a page".utf8))
        #expect(try Data(contentsOf: host) == Data("the host's".utf8))
    }
}
