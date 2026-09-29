// Run: swiftc -module-cache-path /tmp/ltm-module-cache LightTouchMac/Library/DeviceStateStorage.swift tests/fixtures/device-state-storage.swift -o /tmp/device-state-check && /tmp/device-state-check
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
        let eraseRoot = root.appendingPathComponent("erase-device")
        let eraseOverlay = eraseRoot.appendingPathComponent("nandrw")
        let eraseSnapshot = eraseRoot.appendingPathComponent("snapshot")
        try fm.createDirectory(at: eraseOverlay, withIntermediateDirectories: true)
        for url in [eraseOverlay.appendingPathComponent("nor.bin"), eraseSnapshot,
                    eraseSnapshot.appendingPathExtension("meta")] {
            try Data("device".utf8).write(to: url)
        }
        let base = eraseRoot.appendingPathComponent("base-image")
        try Data("base".utf8).write(to: base)
        try DeviceStateStorage.erase(overlay: eraseOverlay, snapshots: [eraseSnapshot], state: root, owner: nil)
        precondition(!fm.fileExists(atPath: eraseOverlay.path) && !fm.fileExists(atPath: eraseSnapshot.path))
        precondition(tryData(base)=="base")
        try DeviceStateStorage.erase(overlay: eraseOverlay, snapshots: [eraseSnapshot], state: root, owner: nil)
        print("device state checks passed")
    }
    static func tryData(_ url: URL) -> String { try! String(contentsOf: url, encoding: .utf8) }
}
