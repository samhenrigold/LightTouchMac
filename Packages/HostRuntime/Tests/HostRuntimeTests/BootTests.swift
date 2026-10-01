import Foundation
import Testing
import HostRuntime

struct BootTests {
    @Test func legacyWireDefaults() throws {
        let boot = try JSONDecoder().decode(BootConfig.self, from: Data(#"{"argv":["LightTouchMac"],"machine":"ipad1"}"#.utf8))
        #expect(boot.environment == [:])
        #expect(boot.webProxy == nil)
    }
}

private final class Fixture {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    var base: URL { root.appendingPathComponent("base, with spaces") }
    var overlay: URL { root.appendingPathComponent("overlay") }
    var nor: URL { root.appendingPathComponent("private-nor") }
    init(board: PreparedDeviceBoot.Board, strategy: String?) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: base.appendingPathComponent("nand"), withIntermediateDirectories: true)
        for name in ["iBoot.bin", "kboot.bin", "SecureROM.bin", "gid-blobs.bin"] {
            try Data(name.utf8).write(to: base.appendingPathComponent(name))
        }
        try Data(repeating: 0x55, count: 1_048_576).write(to: base.appendingPathComponent("nor.bin"))
        var lock: [String: Any] = ["board": board.rawValue, "machine": ["aes-uid": "engine"]]
        if let strategy { lock["boot_strategy"] = strategy }
        try JSONSerialization.data(withJSONObject: lock).write(to: base.appendingPathComponent("device.lock.json"))
        try JSONSerialization.data(withJSONObject: ["die-id": ["0x123", "0x456"], "unique-chip-id": "0x234", "wifi-mac": "02:11:22:33:44:66"])
            .write(to: base.appendingPathComponent("identity.json"))
    }
    deinit { try? FileManager.default.removeItem(at: root) }
    func prepare(_ board: PreparedDeviceBoot.Board, key: String? = "base-A") throws -> PreparedDeviceBoot {
        try .prepare(board: board, base: base, overlay: overlay, writableNOR: nor, storageKey: key, bootrom: "rom")
    }
}

extension BootTests {
    @Test(arguments: [PreparedDeviceBoot.Board.n45, .n72, .k48])
    func sharedAssembly(board: PreparedDeviceBoot.Board) throws {
        let f = try Fixture(board: board, strategy: "iboot")
        let prepared = try f.prepare(board)
        let config = try prepared.configuration(bootArgs: "args", usbAddress: "127.0.0.1:1234", wifi: true,
            guestPackage: "offer", serial: "null", audio: ["-audio", "driver=none"], netdev: "user,id=wifi0")
        let machine = config.argv[2]
        #expect(machine.contains(BootRecipe.escape(f.overlay.path)))
        #expect(config.argv.joined(separator: " ").contains(BootRecipe.escape(f.nor.path)))
        #expect(machine.contains("aes-uid=engine"))
        #expect(machine.contains("usb-tcp-addr=127.0.0.1:1234"))
        #expect(config.argv.contains("driver=none"))
        if board == .n72 { #expect(machine.contains("ecid=0x234")) }
        if board == .k48 { #expect(machine.contains("die-id=0x123:0x456")) }
        // Freeze the pre-extraction recipe output with matching caller dependencies.
        let expected: BootConfig
        switch board {
        case .n45:
            expected = BootRecipe.iPod1G(.init(bootrom: "rom", iBoot: f.base.appendingPathComponent("iBoot.bin").path,
                nand: f.base.appendingPathComponent("nand").path, writableNOR: f.nor.path, overlay: f.overlay.path,
                usbAddress: "127.0.0.1:1234", guestPackage: "offer", machineOptions: ["aes-uid": "engine"]),
                serial: "null", audio: ["-audio", "driver=none"], netdev: "user,id=wifi0")
        case .n72:
            expected = BootRecipe.iPod(.init(bootArgs: "args", iBoot: f.base.appendingPathComponent("iBoot.bin").path,
                bootrom: "rom", nand: f.base.appendingPathComponent("nand").path, nor: f.base.appendingPathComponent("nor.bin").path,
                writableNOR: f.nor.path, overlay: f.overlay.path, usbAddress: "127.0.0.1:1234", wifi: true,
                gidBlobs: f.base.appendingPathComponent("gid-blobs.bin").path, guestPackage: "offer",
                machineOptions: ["aes-uid": "engine", "ecid": "0x234", "wifi-mac": "02:11:22:33:44:66"]),
                serial: "null", audio: ["-audio", "driver=none"], netdev: "user,id=wifi0", restore: [])
        case .k48:
            expected = BootRecipe.iPad(.init(boot: .iBoot(image: f.base.appendingPathComponent("iBoot.bin").path,
                writableNOR: f.nor.path, gidBlobs: f.base.appendingPathComponent("gid-blobs.bin").path),
                nand: f.base.appendingPathComponent("nand").path, overlay: f.overlay.path, dieID: "0x123:0x456",
                usbAddress: "127.0.0.1:1234", wifi: true, guestPackage: "offer", machineOptions: ["aes-uid": "engine"]),
                serial: "null", audio: ["-audio", "driver=none"], netdev: "user,id=wifi0", restore: [])
        }
        #expect(config == expected)
    }

    @Test func privateNORKeepsGuestWritesAndBaseImmutable() throws {
        let f = try Fixture(board: .n72, strategy: "iboot")
        let source = f.base.appendingPathComponent("nor.bin")
        let before = try Data(contentsOf: source)
        try FileManager.default.setAttributes([.posixPermissions: 0o444], ofItemAtPath: source.path)
        _ = try f.prepare(.n72)
        #expect(try Data(contentsOf: f.nor) == before)
        let mode = try FileManager.default.attributesOfItem(atPath: f.nor.path)[.posixPermissions] as? NSNumber
        #expect((mode?.intValue ?? 0) & 0o200 != 0)
        let handle = try FileHandle(forWritingTo: f.nor)
        try handle.seek(toOffset: 0x1200)
        try handle.write(contentsOf: Data([0xa1, 0xb2, 0xc3, 0xd4]))
        try handle.synchronize()
        try handle.close()
        var edited = before
        edited.replaceSubrange(0x1200..<0x1204, with: [0xa1, 0xb2, 0xc3, 0xd4])
        _ = try f.prepare(.n72)
        #expect(try Data(contentsOf: f.nor) == edited)
        #expect(try Data(contentsOf: f.nor).count == 1_048_576)
        #expect(try Data(contentsOf: source) == before)
        #expect(try String(contentsOf: f.overlay.appendingPathComponent(".base-identity"), encoding: .utf8) == "base-A")
        #expect(throws: PreparedDeviceBoot.Failure.baseMismatch) { _ = try f.prepare(.n72, key: "base-B") }
        #expect(try Data(contentsOf: f.nor) == edited)
    }

    @Test(arguments: ["bootrom", "iboot", "kboot"])
    func iPadStrategies(strategy: String) throws {
        let f = try Fixture(board: .k48, strategy: strategy)
        let c = try f.prepare(.k48).configuration(bootArgs: "", usbAddress: nil, wifi: false,
            guestPackage: nil, serial: "null", audio: [], netdev: nil)
        let option = strategy == "kboot" ? "kboot=" : strategy == "iboot" ? "iboot=" : "bootrom="
        #expect(c.argv[2].contains(option))
        if strategy == "bootrom" { #expect(c.argv[2].contains("development-fuses=off")) }
    }

    @Test(arguments: PreparedDeviceBoot.Board.allCases)
    func unknownStrategyRejectedBeforeStorage(board: PreparedDeviceBoot.Board) throws {
        let f = try Fixture(board: board, strategy: "typo")
        #expect(throws: CocoaError.self) { _ = try f.prepare(board) }
        #expect(FileManager.default.fileExists(atPath: f.overlay.path) == false)
        #expect(FileManager.default.fileExists(atPath: f.nor.path) == false)
    }

    @Test func missingBootInputAndLegacyOverlayRefused() throws {
        let f = try Fixture(board: .k48, strategy: "iboot")
        try FileManager.default.removeItem(at: f.base.appendingPathComponent("gid-blobs.bin"))
        do { _ = try f.prepare(.k48); Issue.record("accepted missing key data") }
        catch let error as CocoaError { #expect((error.userInfo[NSFilePathErrorKey] as? String)?.hasSuffix("gid-blobs.bin") == true) }
        try FileManager.default.createDirectory(at: f.overlay, withIntermediateDirectories: true)
        try Data([1]).write(to: f.overlay.appendingPathComponent("dirty-page"))
        #expect(try PreparedDeviceBoot.pinOverlay(f.overlay, toBase: "base-A") == false)
    }

    @Test func wireRoundTripAndExactKeys() throws {
        var boot = BootConfig(argv: ["LightTouchMac", "-netdev", "user,id=wifi0,restrict=on"], environment: ["KEY": "value"], machine: "ipad1")
        boot.webProxy = .init(config: "routing", socket: "socket")
        let data = try JSONEncoder().encode(boot)
        #expect(try JSONDecoder().decode(BootConfig.self, from: data) == boot)
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(Set(object.keys) == Set(["argv", "environment", "machine", "webProxy"]))
        #expect(boot.wifiRestricted)
    }
}

extension BootTests {
    @Test func n72ROMDoesNotRequireDirectIBoot() throws {
        let f = try Fixture(board: .n72, strategy: "bootrom")
        try FileManager.default.removeItem(at: f.base.appendingPathComponent("iBoot.bin"))
        let config = try f.prepare(.n72).configuration(bootArgs: "", usbAddress: nil, wifi: false,
            guestPackage: nil, serial: "null", audio: [], netdev: nil)
        #expect(config.argv[2].contains(",direct-iboot=,direct-llb="))
        #expect(config.argv[2].contains("gid-blobs="))
    }

    @Test func legacyIPadStrategyAndRecordIdentityPrecedence() throws {
        let f = try Fixture(board: .k48, strategy: nil)
        let prepared = try PreparedDeviceBoot.prepare(board: .k48, base: f.base, overlay: f.overlay,
            writableNOR: f.nor, storageKey: "base-A", bootrom: "rom", dieID: "record:identity")
        let config = try prepared.configuration(bootArgs: "", usbAddress: nil, wifi: false,
            guestPackage: nil, serial: "null", audio: [], netdev: nil)
        #expect(config.argv[2].contains("kboot="))
        #expect(config.argv[2].contains("iboot=") == false)
        #expect(config.argv[2].contains("die-id=record:identity"))
    }
}


extension BootTests {
    @Test func explicitPathsDoNotImplyManagedOwnership() throws {
        let f = try Fixture(board: .n72, strategy: "iboot")
        let outside = f.root.appendingPathComponent("caller-selected-storage")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        let link = f.root.appendingPathComponent("storage-link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
        let overlay = link.appendingPathComponent("overlay")
        let nor = link.appendingPathComponent("nor.bin")
        _ = try PreparedDeviceBoot.prepare(board: .n72, base: f.base, overlay: overlay,
            writableNOR: nor, storageKey: "base-A", bootrom: "rom")
        #expect(FileManager.default.fileExists(atPath: outside.appendingPathComponent("overlay/.base-identity").path))
        #expect(try Data(contentsOf: outside.appendingPathComponent("nor.bin")).count == 1_048_576)
        // Runtime supports explicit URLs; application managed-record authorization
        // and maintenance path containment remain separate caller responsibilities.
    }
}
