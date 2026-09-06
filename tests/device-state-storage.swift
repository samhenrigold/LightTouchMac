// Run: swiftc -module-cache-path /tmp/ltm-module-cache LightTouchMac/DeviceStateStorage.swift tests/device-state-storage.swift -o /tmp/device-state-check && /tmp/device-state-check
import Foundation

@main
struct Check {
    @MainActor
    static func main() async throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        let identity = DeviceStateStorage.SnapshotIdentity(emulatorBuild: "build-a", nand: "nand-a")
        let saved = root.appendingPathComponent("snapshot")
        let tmp = root.appendingPathComponent("snapshot.tmp")
        try Data("old".utf8).write(to: saved)
        do {
            try DeviceStateStorage.promoteSnapshot(from: tmp, to: saved, identity: identity)
            preconditionFailure("missing snapshot accepted")
        } catch {}
        precondition(tryData(saved) == "old")
        try Data().write(to: tmp)
        do {
            try DeviceStateStorage.promoteSnapshot(from: tmp, to: saved, identity: identity)
            preconditionFailure("empty snapshot accepted")
        } catch {}
        try Data("new".utf8).write(to: tmp)
        try DeviceStateStorage.promoteSnapshot(from: tmp, to: saved, identity: identity)
        precondition(tryData(saved) == "new")
        precondition(DeviceStateStorage.snapshotMatches(saved, identity: identity))
        precondition(!DeviceStateStorage.snapshotMatches(saved, identity: .init(emulatorBuild: "build-b", nand: "nand-a")))
        precondition(!DeviceStateStorage.snapshotMatches(saved, identity: .init(emulatorBuild: "build-a", nand: "nand-b")))
        let metadata = try Data(contentsOf: saved.appendingPathExtension("meta"))
        try Data("other".utf8).write(to: saved, options: .atomic)
        precondition(!DeviceStateStorage.snapshotMatches(saved, identity: identity))
        try Data("new".utf8).write(to: tmp)
        try DeviceStateStorage.promoteSnapshot(from: tmp, to: saved, identity: identity)
        try Data("broken".utf8).write(to: saved.appendingPathExtension("meta"))
        precondition(!DeviceStateStorage.snapshotMatches(saved, identity: identity))
        try metadata.write(to: saved.appendingPathExtension("meta"))
        precondition(!DeviceStateStorage.snapshotMatches(saved, identity: identity))
        precondition(!fm.fileExists(atPath: tmp.path))
        let overlay = root.appendingPathComponent("overlay")
        let chip = overlay.appendingPathComponent("cs0")
        try fm.createDirectory(at: chip, withIntermediateDirectories: true)
        let page = chip.appendingPathComponent("page")
        try Data("old".utf8).write(to: page)
        let imageBefore = try DeviceStateStorage.developmentImageIdentity(at: overlay, key: "base")
        try Data("changed".utf8).write(to: page, options: .atomic)
        let imageAfter = try DeviceStateStorage.developmentImageIdentity(at: overlay, key: "base")
        precondition(imageBefore != imageAfter)
        let when = Date(timeIntervalSince1970: 1_000)
        try fm.setAttributes([.modificationDate: when], ofItemAtPath: overlay.path)
        try fm.setAttributes([.modificationDate: when], ofItemAtPath: chip.path)
        try fm.setAttributes([.modificationDate: when], ofItemAtPath: saved.path)
        precondition(!DeviceStateStorage.overlayIsNewer(overlay, than: saved))
        try fm.setAttributes([.modificationDate: when.addingTimeInterval(0.01)], ofItemAtPath: chip.path)
        precondition(DeviceStateStorage.overlayIsNewer(overlay, than: saved))
        precondition(DeviceStateStorage.overlayIsNewer(root.appendingPathComponent("missing"), than: saved))

        let manifest = root.appendingPathComponent("nand.itnand.sha256")
        let first = String(repeating: "a", count: 64)
        let second = String(repeating: "b", count: 64)
        try (first + "\n").write(to: manifest, atomically: true, encoding: .utf8)
        let legacy = root.appendingPathComponent("device/nand")
        try fm.createDirectory(at: legacy, withIntermediateDirectories: true)
        func select() throws -> (image: DeviceStateStorage.PackedImage, retained: Bool) {
            try DeviceStateStorage.packedImage(state: root, nand: "nand", legacyKey: "nand-oldroot", manifest: manifest)
        }
        let pinned = try select()
        precondition(pinned.retained && pinned.image.directory == "device/nand")
        // App update still uses the original base, and preserves user state.
        try second.write(to: manifest, atomically: true, encoding: .utf8)
        let stillPinned = try select()
        precondition(stillPinned.image == pinned.image)
        try Data().write(to: root.appendingPathComponent(".reset-nand-oldroot"))
        let reset = try select()
        precondition(!reset.retained && reset.image.key == "nand-\(second)")
        precondition(fm.fileExists(atPath: legacy.path))
        precondition(fm.fileExists(atPath: root.appendingPathComponent(".reset-nand-\(second)").path))
        precondition(!fm.fileExists(atPath: root.appendingPathComponent(".reset-nand-oldroot").path))
        // A freshly extracted content image remains pinned across app updates
        // and installation-path changes.
        try fm.createDirectory(at: root.appendingPathComponent(reset.image.directory), withIntermediateDirectories: true)
        try fm.removeItem(at: root.appendingPathComponent(".reset-nand-\(second)"))
        try first.write(to: manifest, atomically: true, encoding: .utf8)
        let moved = try DeviceStateStorage.packedImage(state: root, nand: "nand", legacyKey: "different-root", manifest: manifest)
        precondition(moved.retained && moved.image == reset.image)
        let invalid = root.appendingPathComponent("directory-target")
        try fm.createDirectory(at: invalid, withIntermediateDirectories: true)
        try Data("valid".utf8).write(to: tmp)
        do {
            try DeviceStateStorage.promoteSnapshot(from: tmp, to: invalid, identity: identity)
            preconditionFailure("rename failure accepted")
        } catch {}
        precondition(tryData(tmp) == "valid")
        // A completed request, timeout, or generic VM stop must never stand in
        // for the PMU's actual guest power-off confirmation.
        let deadline = Date()
        for (confirmed, stopped, expected) in [(true, false, true), (true, true, true),
                                               (false, false, false), (false, true, false)] {
            let result = await DeviceStateStorage.waitForShutdown(until: deadline,
                                                                 confirmed: { confirmed }, stopped: { stopped })
            precondition(result == expected)
        }
        var poweredOff = false
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(20))
            poweredOff = true
        }
        let completed = await DeviceStateStorage.waitForShutdown(until: Date().addingTimeInterval(1),
                                                                 confirmed: { poweredOff }, stopped: { false })
        precondition(completed)
        print("device state checks passed")
    }
    static func tryData(_ url: URL) -> String { try! String(contentsOf: url, encoding: .utf8) }
}
