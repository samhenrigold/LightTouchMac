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
        // Overlay pinning: adopted when empty, kept for its base, refused for
        // another base and for an unstamped overlay that already has pages.
        let pinOverlay = root.appendingPathComponent("nandrw-pin")
        let adopted = try DeviceStateStorage.pinOverlay(pinOverlay, toBase: "base-a")
        precondition(adopted)
        try Data([1]).write(to: pinOverlay.appendingPathComponent("bus0-ce0.pages"))
        let kept = try DeviceStateStorage.pinOverlay(pinOverlay, toBase: "base-a")
        let otherBase = try DeviceStateStorage.pinOverlay(pinOverlay, toBase: "base-b")
        precondition(kept && !otherBase)
        try fm.removeItem(at: pinOverlay.appendingPathComponent(".base-identity"))
        let unstamped = try DeviceStateStorage.pinOverlay(pinOverlay, toBase: "base-a")
        precondition(!unstamped)
        let norBase = root.appendingPathComponent("base-nor")
        let norOverlay = root.appendingPathComponent("nor-overlay")
        try Data(repeating: 0xff, count: 1_048_576).write(to: norBase)
        let writableNOR = try DeviceStateStorage.writableNOR(base: norBase, overlay: norOverlay)
        var changedNOR = try Data(contentsOf: writableNOR)
        changedNOR[0] = 0x12
        try changedNOR.write(to: writableNOR)
        let existingNOR = try DeviceStateStorage.writableNOR(base: norBase, overlay: norOverlay)
        precondition(existingNOR == writableNOR)
        precondition((try? Data(contentsOf: existingNOR))?[0] == 0x12 && (try? Data(contentsOf: norBase))?[0] == 0xff)
        try Data([0]).write(to: writableNOR)
        do {
            _ = try DeviceStateStorage.writableNOR(base: norBase, overlay: norOverlay)
            preconditionFailure("corrupt writable NOR replaced")
        } catch {}
        try fm.removeItem(at: norOverlay)
        try Data([0]).write(to: norBase)
        do {
            _ = try DeviceStateStorage.writableNOR(base: norBase, overlay: norOverlay)
            preconditionFailure("short NOR base accepted")
        } catch {}
        let remainingNORFiles = try fm.contentsOfDirectory(atPath: norOverlay.path)
        precondition(remainingNORFiles.isEmpty)
        let overlay = root.appendingPathComponent("overlay")
        let chip = overlay.appendingPathComponent("cs0")
        try fm.createDirectory(at: chip, withIntermediateDirectories: true)
        let page = chip.appendingPathComponent("page")
        try Data("old".utf8).write(to: page)
        let imageBefore = try DeviceStateStorage.developmentImageIdentity(at: overlay, key: "base")
        try Data("changed".utf8).write(to: page, options: .atomic)
        let imageAfter = try DeviceStateStorage.developmentImageIdentity(at: overlay, key: "base")
        precondition(imageBefore != imageAfter)
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
        // A legacy marker must never erase or change the device on launch.
        let unchanged = try select()
        precondition(unchanged.image == pinned.image)
        // Erase repoints, then removes the bases nothing names any more: the
        // old one, a torn .partial unpack. A base another record names stays.
        let torn = root.appendingPathComponent("device/nand-\(second).partial")
        let keptBase = root.appendingPathComponent("device/nand-kept")
        try fm.createDirectory(at: torn, withIntermediateDirectories: true)
        try fm.createDirectory(at: keptBase, withIntermediateDirectories: true)
        let other = root.appendingPathComponent("Devices/\(UUID().uuidString)")
        try fm.createDirectory(at: other, withIntermediateDirectories: true)
        try Data(#"{"base":{"kind":"legacyBundled","path":"device/nand-kept"}}"#.utf8).write(to: other.appendingPathComponent("device.json"))
        try DeviceStateStorage.adoptBundledImageAfterErase(state: root, nand: "nand", manifest: manifest, owner: UUID())
        let reset = try select()
        precondition(!reset.retained && reset.image.key == "nand-\(second)")
        precondition(!fm.fileExists(atPath: legacy.path) && !fm.fileExists(atPath: torn.path) && fm.fileExists(atPath: keptBase.path))
        try fm.removeItem(at: other)
        precondition(!fm.fileExists(atPath: root.appendingPathComponent(".reset-nand-\(second)").path))
        // A freshly extracted content image remains pinned across app updates
        // and installation-path changes.
        try fm.createDirectory(at: root.appendingPathComponent(reset.image.directory), withIntermediateDirectories: true)
        try first.write(to: manifest, atomically: true, encoding: .utf8)
        let moved = try DeviceStateStorage.packedImage(state: root, nand: "nand", legacyKey: "different-root", manifest: manifest)
        precondition(moved.retained && moved.image == reset.image)
        let eraseRoot = root.appendingPathComponent("erase-device")
        let eraseOverlay = eraseRoot.appendingPathComponent("nandrw")
        let eraseSnapshot = eraseRoot.appendingPathComponent("snapshot")
        let eraseMarker = eraseRoot.appendingPathComponent(".reset")
        try fm.createDirectory(at: eraseOverlay, withIntermediateDirectories: true)
        for url in [eraseOverlay.appendingPathComponent("nor.bin"), eraseSnapshot,
                    eraseSnapshot.appendingPathExtension("meta"), eraseMarker] {
            try Data("device".utf8).write(to: url)
        }
        let base = eraseRoot.appendingPathComponent("base-image")
        try Data("base".utf8).write(to: base)
        try DeviceStateStorage.erase(overlay: eraseOverlay, snapshots: [eraseSnapshot], legacyMarker: eraseMarker, state: root, owner: nil)
        precondition(!fm.fileExists(atPath: eraseOverlay.path) && !fm.fileExists(atPath: eraseSnapshot.path))
        precondition(!fm.fileExists(atPath: eraseMarker.path) && tryData(base)=="base")
        try DeviceStateStorage.erase(overlay: eraseOverlay, snapshots: [eraseSnapshot], legacyMarker: eraseMarker, state: root, owner: nil)
        print("device state checks passed")
    }
    static func tryData(_ url: URL) -> String { try! String(contentsOf: url, encoding: .utf8) }
}
