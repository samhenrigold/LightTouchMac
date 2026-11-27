import Foundation
import HostRuntime
import Testing

struct BootTests {
    /// The radio boards boot with their modem (baseband=on) reporting the seed's IMEI, and its data netdev is
    /// Wi-Fi's under id=cell0; No SIM and No Service keep the modem. The iPad gets none of it.
    @Test func radioBoardsGetModemIMEIAndCellNetdev() throws {
        let identity: [String: Any] = [
            "serial-number": "ABCDEFGHJKL", "wifi-mac": "02:11:22:33:44:66",
            "bt-mac": "02:11:22:33:44:67", "seed": "iphone4-test"
        ]
        let imei = IPhoneIdentity.imei(seed: "iphone4-test")
        #expect(
            imei.count == 15 && imei.hasPrefix("00000000")
                && IPhoneIdentity.luhn(String(imei.prefix(14))) == Int(String(imei.last!))
        )
        #expect(
            IPhoneIdentity.upgraded(identity)?.udid
                == IPhoneIdentity.udid(
                    serial: "ABCDEFGHJKL",
                    imei: imei,
                    wifiMAC: "02:11:22:33:44:66",
                    btMAC: "02:11:22:33:44:67"
                )
        )
        // iPhone 5 (n42ap) hashes decimal ECID instead of IMEI
        let n42Identity: [String: Any] = [
            "serial-number": "ZVWXKD7XCTJ", "unique-chip-id": "0x38d732dceb",
            "wifi-mac": "02:ea:03:a4:7b:c4", "bt-mac": "02:ea:03:a4:7b:c5"
        ]
        #expect(IPhoneIdentity.ecidUDID(from: n42Identity) == "923f4573c7e2696822e7fe89d75495ea9e61ca18")
        for (board, machine) in [(Board.n90, "iPhone-4"), (.n88, "n88"), (.k48, "ipad1")] {
            let f = try Fixture(board: board, strategy: "kboot", identity: identity)
            defer { try? FileManager.default.removeItem(at: f.root) }
            let config = try f.prepare(board).configuration(
                bootArgs: "",
                usbAddress: nil,
                wifi: true,
                guestPackage: nil,
                serial: "null",
                audio: [],
                netdev: "user,id=wifi0,guestfwd=tcp:10.0.2.100:3128-unix-connect:/p",
                cellular: .noSIM
            )
            let m = config.argv[config.argv.firstIndex(of: "-M")! + 1]
            let radio = board != .k48
            #expect(m.hasPrefix(machine + ","))
            #expect(m.contains(",baseband=on") == radio && m.contains(",imei=\(imei)") == radio)
            #expect(config.argv.contains("user,id=cell0,guestfwd=tcp:10.0.2.100:3128-unix-connect:/p") == radio)
            #expect(config.argv.contains("ios-baseband.sim-present=off") == radio)
        }
    }

    /// The Carrier panel's saved settings start the modem on radio boards only.
    /// Settings ▸ General's experimental 120 Hz: each board's own panel (and, but on the 1G, its touch) gets the rate,
    /// in -global's long form (the type names have dots), the helper reads it back, and 60 adds nothing.
    @Test func refreshReachesEachBoardsPanel() throws {
        let panels: [Board: String] = [
            .m68: "ipodtouch.lcd", .n72: "ipodtouch.lcd", .n88: "s5l8930.display", .k48: "s5l8930.display"
        ]
        for (board, panel) in panels {
            let f = try Fixture(board: board, strategy: board == .m68 ? "iboot" : board == .n72 ? "bootrom" : "kboot")
            defer { try? FileManager.default.removeItem(at: f.root) }
            func boot(_ hz: Int) throws -> BootConfig {
                try f.prepare(board).configuration(
                    bootArgs: "",
                    usbAddress: nil,
                    wifi: true,
                    guestPackage: nil,
                    serial: "null",
                    audio: [],
                    netdev: "user,id=wifi0",
                    refreshHz: hz
                )
            }
            let fast = try boot(120)
            #expect(fast.argv.contains("driver=\(panel),property=refresh-hz,value=120"))
            #expect(fast.argv.contains("driver=ipodtouch.multitouch,property=report-hz,value=120") == (board != .m68))
            #expect(fast.refreshHz == 120)
            let stock = try boot(60)
            #expect(!stock.argv.contains { $0.contains("-hz=") || $0.contains("property=re") })
            #expect(stock.refreshHz == 60)
        }
    }

    /// Settings ▸ General's experimental ANGLE renderer: every board's machine gets gl-renderer=angle; a boot without it,
    /// or one resuming a snapshot, names no renderer (the emulator's default, CGL).
    @Test func angleReachesEachBoardsMachine() throws {
        for board in [Board.m68, .n72, .n88, .k48, .n81, .n90] {
            let f = try Fixture(board: board, strategy: board == .m68 ? "iboot" : board == .n72 ? "bootrom" : "kboot")
            defer { try? FileManager.default.removeItem(at: f.root) }
            func machine(_ angle: Bool, restore: [String] = []) throws -> String {
                let config = try f.prepare(board).configuration(
                    bootArgs: "",
                    usbAddress: nil,
                    wifi: true,
                    guestPackage: nil,
                    serial: "null",
                    audio: [],
                    netdev: "user,id=wifi0",
                    restore: restore,
                    angle: angle
                )
                return config.argv[config.argv.firstIndex(of: "-M")! + 1]
            }
            #expect(try machine(true).contains(",gl-renderer=angle"), "\(board)")
            #expect(try !machine(false).contains("gl-renderer"), "\(board)")
            // a snapshot resumes on CGL, whose GL state it holds
            #expect(try !machine(true, restore: ["-incoming", "file:/s"]).contains("gl-renderer"), "\(board)")
        }
    }

    /// A snapshot's restore reaches every board's command line: the original iPhone's and iPod touch 1G's recipe took
    /// none, so a resume of one cold-booted it.
    @Test func restoreReachesEachBoardsCommandLine() throws {
        for board in [Board.m68, .n72, .n88, .k48, .n81, .n90] {
            let f = try Fixture(board: board, strategy: board == .m68 ? "iboot" : board == .n72 ? "bootrom" : "kboot")
            defer { try? FileManager.default.removeItem(at: f.root) }
            let argv = try f.prepare(board).configuration(
                bootArgs: "",
                usbAddress: nil,
                wifi: true,
                guestPackage: nil,
                serial: "null",
                audio: [],
                netdev: "user,id=wifi0",
                restore: ["-incoming", "file:/s"]
            ).argv
            let at = argv.firstIndex(of: "-incoming")
            #expect(at.map { argv[$0 + 1] } == "file:/s", "\(board)")
        }
    }

    @Test func carrierSettingsReachRadioBoards() throws {
        var carrier = CarrierSettings()
        carrier.carrier = "Panel"
        for board in [Board.n90, .n88, .m68, .k48, .n81] {
            let f = try Fixture(board: board, strategy: board == .m68 ? "iboot" : "kboot")
            defer { try? FileManager.default.removeItem(at: f.root) }
            let config = try f.prepare(board).configuration(
                bootArgs: "",
                usbAddress: nil,
                wifi: true,
                guestPackage: nil,
                serial: "null",
                audio: [],
                netdev: "user,id=wifi0",
                carrier: carrier
            )
            #expect(config.argv.contains("ios-baseband.carrier=Panel") == board.hardware!.hasCellular)
            // The SIM's PIN state lives in the overlay (issue 49).
            #expect(
                config.argv.contains("ios-baseband.sim-file=\(f.overlay.appendingPathComponent("sim").path)")
                    == board.hardware!.hasCellular
            )
        }
    }

    @Test func legacyWireDefaults() throws {
        let boot = try JSONDecoder().decode(
            BootConfig.self,
            from: Data(#"{"argv":["LightTouchMac"],"machine":"ipad1"}"#.utf8)
        )
        #expect(boot.environment == [:])
        #expect(boot.webProxy == nil)
    }

    /// The S5L8920/8930 boards' access point announces the Mac's region as its 802.11d country (issue 102: 5.x and
    /// 6.x Setup guesses the country, and so its Welcome page, from it); the iPods' machines have no such option.
    @Test func theAccessPointsCountryIsTheMacsRegion() throws {
        let region = try #require(Locale.current.region?.identifier)
        for board in Board.allCases {
            let f = try Fixture(board: board, strategy: Self.strategies(board)[0])
            defer { try? FileManager.default.removeItem(at: f.root) }
            let config = try f.prepare(board).configuration(
                bootArgs: "",
                usbAddress: nil,
                wifi: true,
                guestPackage: nil,
                serial: "null",
                audio: [],
                netdev: "user,id=wifi0"
            )
            let machine = try #require(config.argv.firstIndex(of: "-M").map { config.argv[$0 + 1] })
            let declared = board.machineOptions.contains("wifi-country")
            #expect(machine.contains(",wifi-country=\(region)") == (declared && region.count == 2), "\(machine)")
        }
        // The S5L8920 and A4 machines take it (n18's and n88's had none at first, and stopped QEMU at it).
        #expect(Board.allCases.filter { $0.machineOptions.contains("wifi-country") } == [.n18, .n88, .k48, .n81, .n90])
    }

    /// The boot strategies a board's base can have (Board.requiredFiles).
    static func strategies(_ board: Board) -> [String] {
        switch board.soc {
        case .s5l8900: ["iboot"]
        case .s5l8720: ["bootrom", "iboot"]
        case .s5l8920, .s5l8930: board == .k48 ? ["kboot", "iboot", "bootrom"] : ["kboot"]
        case .s5l8950: ["kboot"]
        }
    }

    /// Every option of every board's -machine line is one its machine declares (Board.machineOptions, listed from
    /// qemu-ios by scripts/vendor): QEMU stops at one it lacks before the guest runs, and the device never
    /// lights. Each strategy a base can have, with every option a lock, the device record and the caller can add.
    @Test func everyMachineOptionIsDeclared() throws {
        let lock = [
            "aes-uid": "hardware", "wifi-mac": "02:11:22:33:44:66", "bt-mac": "02:11:22:33:44:67", "ecid": "0x234",
            "imei": "013977000272744", "rtc-epoch": "1300000000"
        ]
        for board in Board.allCases {
            let declared = board.machineOptions
            #expect(declared.contains("nand"), "\(board): no machine options listed")
            for strategy in Self.strategies(board) {
                let f = try Fixture(board: board, strategy: strategy, machine: lock)
                for wifi in [true, false] {
                    let config = try PreparedDeviceBoot.prepare(
                        board: board,
                        base: f.base,
                        overlay: f.overlay,
                        writableNOR: f.nor,
                        storageKey: "base-A",
                        bootrom: "rom",
                        dieID: "0x1:0x2",
                        panel: "320x480",
                        clock: Date(timeIntervalSince1970: 1_300_000_000)
                    ).configuration(
                        bootArgs: "args",
                        usbAddress: "127.0.0.1:1234",
                        wifi: wifi,
                        guestPackage: "offer",
                        serial: "null",
                        audio: [],
                        netdev: "user,id=wifi0"
                    )
                    let line = try #require(config.argv.firstIndex(of: "-M").map { config.argv[$0 + 1] })
                    // QEMU escapes a comma in a value by doubling it.
                    let keys = line.replacingOccurrences(of: ",,", with: "").split(separator: ",").dropFirst()
                        .map { String($0.prefix { $0 != "=" }) }
                    let undeclared = keys.filter { !declared.contains($0) }
                    #expect(undeclared.isEmpty, "\(board) \(strategy): \(undeclared) in \(line)")
                }
            }
        }
    }
}

private final class Fixture {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    var base: URL { root.appendingPathComponent("base, with spaces") }
    var overlay: URL { root.appendingPathComponent("overlay") }
    var nor: URL { root.appendingPathComponent("private-nor") }
    init(
        board: Board,
        strategy: String?,
        identity: [String: Any]? = nil,
        machine: [String: String] = ["aes-uid": "engine"]
    ) throws {
        MachineFixtures.install()
        let fm = FileManager.default
        try fm.createDirectory(at: base.appendingPathComponent("nand"), withIntermediateDirectories: true)
        for name in ["iBoot.bin", "kboot.bin", "SecureROM.bin", "gid-blobs.bin"] {
            try Data(name.utf8).write(to: base.appendingPathComponent(name))
        }
        try Data(repeating: 0x55, count: 1_048_576).write(to: base.appendingPathComponent("nor.bin"))
        var lock: [String: Any] = ["board": board.rawValue, "machine": machine]
        if let strategy { lock["boot_strategy"] = strategy }
        try JSONSerialization.data(withJSONObject: lock).write(to: base.appendingPathComponent("device.lock.json"))
        try JSONSerialization.data(
            withJSONObject: identity ?? [
                "die-id": ["0x123", "0x456"], "unique-chip-id": "0x234", "wifi-mac": "02:11:22:33:44:66"
            ]
        )
        .write(to: base.appendingPathComponent("identity.json"))
    }
    deinit { try? FileManager.default.removeItem(at: root) }
    func prepare(_ board: Board, key: String? = "base-A", panel: String? = nil) throws -> PreparedDeviceBoot {
        try .prepare(
            board: board,
            base: base,
            overlay: overlay,
            writableNOR: nor,
            storageKey: key,
            bootrom: "rom",
            panel: panel
        )
    }
}

extension BootTests {
    @Test(arguments: [Board.n45, .n72, .k48, .m68])
    func sharedAssembly(board: Board) throws {
        let f = try Fixture(board: board, strategy: "iboot")
        let prepared = try f.prepare(board)
        let config = try prepared.configuration(
            bootArgs: "args",
            usbAddress: "127.0.0.1:1234",
            wifi: true,
            guestPackage: "offer",
            serial: "null",
            audio: ["-audio", "driver=none"],
            netdev: "user,id=wifi0"
        )
        let machine = config.argv[2]
        #expect(machine.contains(BootRecipe.escape(f.overlay.path)))
        #expect(config.argv.joined(separator: " ").contains(BootRecipe.escape(f.nor.path)))
        // The lock's aes-uid reaches only the machine that has one (n72's iPod-Touch).
        #expect(machine.contains("aes-uid=engine") == (board == .n72))
        #expect(machine.contains("usb-tcp-addr=127.0.0.1:1234"))
        #expect(config.argv.contains("driver=none"))
        if board == .n72 { #expect(machine.contains("ecid=0x234")) }
        if board == .k48 { #expect(machine.contains("die-id=0x123:0x456")) }
        // A lock without the card address takes the unit's from identity.json.
        // (the 1.x/S5L8900 boards, N45 and M68, put wifi-mac in their lock when prepared; no identity fallback)
        if board != .n45 && board != .m68 { #expect(machine.contains(",wifi-mac=02:11:22:33:44:66")) }
        // Freeze the pre-extraction recipe output with matching caller dependencies.
        var expected: BootConfig
        switch board {
        case .n45, .m68:
            expected = BootRecipe.iPod1G(
                .init(
                    bootrom: "rom",
                    iBoot: f.base.appendingPathComponent("iBoot.bin").path,
                    nand: f.base.appendingPathComponent("nand").path,
                    writableNOR: f.nor.path,
                    overlay: f.overlay.path,
                    usbAddress: "127.0.0.1:1234",
                    guestPackage: "offer"
                ),
                hardware: board.hardware!,
                serial: "null",
                audio: ["-audio", "driver=none"],
                netdev: "user,id=wifi0"
            )
        case .n72:
            expected = BootRecipe.iPod(
                .init(
                    bootArgs: "args",
                    iBoot: f.base.appendingPathComponent("iBoot.bin").path,
                    bootrom: "rom",
                    nand: f.base.appendingPathComponent("nand").path,
                    nor: f.base.appendingPathComponent("nor.bin").path,
                    writableNOR: f.nor.path,
                    overlay: f.overlay.path,
                    usbAddress: "127.0.0.1:1234",
                    wifi: true,
                    gidBlobs: f.base.appendingPathComponent("gid-blobs.bin").path,
                    guestPackage: "offer",
                    machineOptions: ["aes-uid": "engine", "ecid": "0x234", "wifi-mac": "02:11:22:33:44:66"]
                ),
                hardware: board.hardware!,
                serial: "null",
                audio: ["-audio", "driver=none"],
                netdev: "user,id=wifi0",
                restore: []
            )
        case .k48:
            expected = BootRecipe.iPad(
                .init(
                    boot: .iBoot(
                        image: f.base.appendingPathComponent("iBoot.bin").path,
                        writableNOR: f.nor.path,
                        gidBlobs: f.base.appendingPathComponent("gid-blobs.bin").path
                    ),
                    nand: f.base.appendingPathComponent("nand").path,
                    overlay: f.overlay.path,
                    dieID: "0x123:0x456",
                    usbAddress: "127.0.0.1:1234",
                    wifi: true,
                    guestPackage: "offer",
                    machineOptions: ["wifi-mac": "02:11:22:33:44:66"].merging(
                        Locale.current.region.map { ["wifi-country": $0.identifier] } ?? [:]
                    ) { a, _ in a }
                ),
                hardware: board.hardware!,
                serial: "null",
                audio: ["-audio", "driver=none"],
                netdev: "user,id=wifi0",
                restore: []
            )
        case .n81, .n90, .n88, .n18, .n42:
            return  // kboot only: missingLegacyStrategyKeepsBoardDefault covers it
        }
        if board.hardware!.hasCellular {
            expected.argv += ["-global", "ios-baseband.sim-file=\(f.overlay.appendingPathComponent("sim").path)"]
        }
        var assembled = config
        assembled.files = nil  // everyBoardsBootFilesCoverItsArgvAndWriteOnlyTheDevicesOwn
        #expect(assembled == expected)
    }

    /// device.plist `panel` (issue #21) reaches the machine as panel=WxH; unset, the machine line has no panel.
    @Test(arguments: [Board.n72, .k48])
    func panelOption(board: Board) throws {
        let f = try Fixture(board: board, strategy: "iboot")
        func machine(_ panel: String?) throws -> String {
            try f.prepare(board, panel: panel).configuration(
                bootArgs: "",
                usbAddress: nil,
                wifi: false,
                guestPackage: nil,
                serial: "null",
                audio: [],
                netdev: nil
            ).argv[2]
        }
        #expect(!(try machine(nil)).contains("panel="))
        #expect(try machine("320x504").contains(",panel=320x504"))
        #expect(try machine("1280x768").contains("aes-uid=engine") == (board == .n72))
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
        let c = try f.prepare(.k48).configuration(
            bootArgs: "",
            usbAddress: nil,
            wifi: false,
            guestPackage: nil,
            serial: "null",
            audio: [],
            netdev: nil
        )
        let option = strategy == "kboot" ? "kboot=" : strategy == "iboot" ? "iboot=" : "bootrom="
        #expect(c.argv[2].contains(option))
        if strategy == "bootrom" { #expect(c.argv[2].contains("development-fuses=off")) }
    }

    @Test(arguments: Board.allCases)
    func unknownStrategyRejectedBeforeStorage(board: Board) throws {
        let f = try Fixture(board: board, strategy: "typo")
        #expect(throws: CocoaError.self) { _ = try f.prepare(board) }
        #expect(FileManager.default.fileExists(atPath: f.overlay.path) == false)
        #expect(FileManager.default.fileExists(atPath: f.nor.path) == false)
    }

    @Test func missingBootInputAndLegacyOverlayRefused() throws {
        let f = try Fixture(board: .k48, strategy: "iboot")
        try FileManager.default.removeItem(at: f.base.appendingPathComponent("gid-blobs.bin"))
        do {
            _ = try f.prepare(.k48)
            Issue.record("accepted missing key data")
        } catch let error as CocoaError {
            #expect((error.userInfo[NSFilePathErrorKey] as? String)?.hasSuffix("gid-blobs.bin") == true)
        }
        try FileManager.default.createDirectory(at: f.overlay, withIntermediateDirectories: true)
        try Data([1]).write(to: f.overlay.appendingPathComponent("dirty-page"))
        #expect(try PreparedDeviceBoot.pinOverlay(f.overlay, toBase: "base-A") == false)
    }

    @Test func wireRoundTripAndExactKeys() throws {
        var boot = BootConfig(
            argv: ["LightTouchMac", "-netdev", "user,id=wifi0,restrict=on"],
            environment: ["KEY": "value"],
            machine: "ipad1"
        )
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
        let config = try f.prepare(.n72).configuration(
            bootArgs: "",
            usbAddress: nil,
            wifi: false,
            guestPackage: nil,
            serial: "null",
            audio: [],
            netdev: nil
        )
        #expect(config.argv[2].contains(",direct-iboot=,direct-llb="))
        #expect(config.argv[2].contains("gid-blobs="))
    }

    @Test func legacyIPadStrategyAndRecordIdentityPrecedence() throws {
        let f = try Fixture(board: .k48, strategy: nil)
        let prepared = try PreparedDeviceBoot.prepare(
            board: .k48,
            base: f.base,
            overlay: f.overlay,
            writableNOR: f.nor,
            storageKey: "base-A",
            bootrom: "rom",
            dieID: "record:identity"
        )
        let config = try prepared.configuration(
            bootArgs: "",
            usbAddress: nil,
            wifi: false,
            guestPackage: nil,
            serial: "null",
            audio: [],
            netdev: nil
        )
        #expect(config.argv[2].contains("kboot="))
        #expect(config.argv[2].contains("iboot=") == false)
        #expect(config.argv[2].contains("die-id=record:identity"))
    }
}

extension BootTests {
    /// Tweaks' Time Machine: the clock is the machine's rtc-epoch, in whole Unix seconds; no clock, no option.
    @Test func aClockIsTheMachinesRTCEpoch() throws {
        let f = try Fixture(board: .n72, strategy: "iboot")
        func argv(_ clock: Date?) throws -> String {
            try PreparedDeviceBoot.prepare(
                board: .n72,
                base: f.base,
                overlay: f.overlay,
                writableNOR: f.nor,
                storageKey: "base-A",
                bootrom: "rom",
                clock: clock
            )
            .configuration(
                bootArgs: "",
                usbAddress: nil,
                wifi: false,
                guestPackage: nil,
                serial: "null",
                audio: [],
                netdev: nil
            )
            .argv[2]
        }
        #expect(try argv(Date(timeIntervalSince1970: 1_168_364_460.7)).contains(",rtc-epoch=1168364460"))
        #expect(try !argv(nil).contains("rtc-epoch"))
    }

    @Test func explicitPathsDoNotImplyManagedOwnership() throws {
        let f = try Fixture(board: .n72, strategy: "iboot")
        let outside = f.root.appendingPathComponent("caller-selected-storage")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        let link = f.root.appendingPathComponent("storage-link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
        let overlay = link.appendingPathComponent("overlay")
        let nor = link.appendingPathComponent("nor.bin")
        _ = try PreparedDeviceBoot.prepare(
            board: .n72,
            base: f.base,
            overlay: overlay,
            writableNOR: nor,
            storageKey: "base-A",
            bootrom: "rom"
        )
        #expect(FileManager.default.fileExists(atPath: outside.appendingPathComponent("overlay/.base-identity").path))
        #expect(try Data(contentsOf: outside.appendingPathComponent("nor.bin")).count == 1_048_576)
        // Runtime supports explicit URLs; application managed-record authorization
        // and maintenance path containment remain separate caller responsibilities.
    }
}

extension BootTests {
    @Test(
        arguments: Board.allCases,
        [
            "{", "[]", "true", "42", "null", "\"iboot\"",
            "{\"boot_strategy\":null}", "{\"boot_strategy\":true}",
            "{\"boot_strategy\":17}", "{\"boot_strategy\":[]}", "{\"boot_strategy\":{}}"
        ]
    )
    func invalidPresentLockRejectedBeforeStorage(board: Board, json: String) throws {
        let f = try Fixture(board: board, strategy: nil)
        let lock = f.base.appendingPathComponent("device.lock.json")
        let data = Data(json.utf8)
        try data.write(to: lock)
        let norBefore = try Data(contentsOf: f.base.appendingPathComponent("nor.bin"))
        do {
            _ = try f.prepare(board)
            Issue.record("accepted invalid present boot lock: \(json)")
        } catch let error as CocoaError {
            #expect(error.code == .fileReadCorruptFile)
            #expect(error.userInfo[NSFilePathErrorKey] as? String == lock.path)
        }
        #expect(throws: CocoaError.self) { _ = try BootRecipe.iPodIBoot(base: f.base) }
        #expect(try Data(contentsOf: lock) == data)
        #expect(try Data(contentsOf: f.base.appendingPathComponent("nor.bin")) == norBefore)
        #expect(!FileManager.default.fileExists(atPath: f.overlay.path))
        #expect(!FileManager.default.fileExists(atPath: f.nor.path))
    }

    @Test(arguments: Board.allCases, [false, true])
    func missingLegacyStrategyKeepsBoardDefault(board: Board, missingLock: Bool) throws {
        let f = try Fixture(board: board, strategy: nil)
        let lock = f.base.appendingPathComponent("device.lock.json")
        if missingLock { try FileManager.default.removeItem(at: lock) }
        #expect(try DeviceLock.read(lock)?.bootStrategy == nil)
        let c = try f.prepare(board).configuration(
            bootArgs: "",
            usbAddress: nil,
            wifi: false,
            guestPackage: nil,
            serial: "null",
            audio: [],
            netdev: nil
        )
        switch board {
        case .k48: #expect(c.argv[2].hasPrefix("ipad1,kboot="))
        case .n81, .n90:
            let m = board == .n81 ? "iPod-Touch-4G" : "iPhone-4"
            #expect(c.argv[2].hasPrefix(m + ",kboot=") && c.argv[2].contains(",nor-rw=") && c.machine == m)
            #expect(throws: CocoaError.self) { _ = try board.requiredFiles(strategy: "iboot") }
        case .n88, .n18:
            // The S5L8920 machines: kboot + NOR as the A4 boards, but no usb-kbd (no USB host).
            let m = board == .n88 ? "n88" : "n18"
            #expect(c.argv[2].hasPrefix(m + ",kboot=") && c.argv[2].contains(",nor-rw=") && c.machine == m)
            #expect(c.argv[2].contains(",wifi=off") && !c.argv.contains { $0.hasPrefix("usb-kbd") })
        case .n42:
            // The A6 machine: kboot on its PPN store, no NOR, die-id or wifi= (Wi-Fi is the HSIC device, here off),
            // its own Wi-Fi and cell slirps, multi-threaded TCG.
            #expect(c.argv[2].hasPrefix("iPhone-5,kboot=") && c.machine == "iPhone-5", "\(c.argv[2])")
            #expect(!c.argv[2].contains(",nor-rw=") && !c.argv[2].contains(",die-id=") && !c.argv[2].contains("wifi="))
            #expect(c.argv[2].contains(",baseband=on") && !c.argv.contains { $0.hasPrefix("usb-bcm-hsic") })
            #expect(c.argv.contains("user,id=wifi0,lan=off") && c.argv.contains("user,id=cell0,lan=off"))
            #expect(c.argv.contains("tcg,thread=multi"))
        case .n72:
            #expect(
                c.argv[2].contains(
                    ",direct-iboot=" + BootRecipe.escape(f.base.appendingPathComponent("iBoot.bin").path)
                )
            )
        case .n45, .m68:
            #expect(c.argv[2].hasPrefix(board == .m68 ? "iPhone-2G," : "iPod-Touch-1G,"))
            #expect(c.argv[2].contains(",iboot=" + BootRecipe.escape(f.base.appendingPathComponent("iBoot.bin").path)))
            // only the iPhone has a modem, whose cellular data needs its cell0 slirp (off the LAN, like the default wifi0)
            #expect(c.argv.contains("user,id=cell0,lan=off") == (board == .m68))
            // with the web proxy's forward on Wi-Fi, cellular gets the same one
            let proxied = try f.prepare(board).configuration(
                bootArgs: "",
                usbAddress: nil,
                wifi: true,
                guestPackage: nil,
                serial: "null",
                audio: [],
                netdev: "user,id=wifi0,guestfwd=tcp:10.0.2.100:3128-unix-connect:/x"
            )
            #expect(
                proxied.argv.contains("user,id=cell0,guestfwd=tcp:10.0.2.100:3128-unix-connect:/x") == (board == .m68)
            )
        }
    }

    @Test func presentLockReadFailureDoesNotBecomeLegacyDefault() throws {
        let f = try Fixture(board: .k48, strategy: nil)
        let lock = f.base.appendingPathComponent("device.lock.json")
        try FileManager.default.removeItem(at: lock)
        try FileManager.default.createDirectory(at: lock, withIntermediateDirectories: false)
        #expect(throws: CocoaError.self) { _ = try f.prepare(.k48) }
        #expect(!FileManager.default.fileExists(atPath: f.overlay.path))
        #expect(!FileManager.default.fileExists(atPath: f.nor.path))
    }
}

extension BootTests {
    /// An image store boots from its live clone, overlay/nand: made on the first boot from the immutable, read-only
    /// base (the clone writable and unflagged, the base untouched), kept after it, passed as nand= with no
    /// nand-overlay. Format 1 pages over an image base are refused, never dropped.
    @Test func imageStoreBootsItsLiveClone() throws {
        let f = try Fixture(board: .n81, strategy: "kboot")
        let fm = FileManager.default
        let nand = f.base.appendingPathComponent("nand")
        let chip = nand.appendingPathComponent("bus0-ce0.pages")
        try Data(#"{"storage_format": "nand-xor-ff-v2", "layout": "generated"}"#.utf8)
            .write(to: nand.appendingPathComponent("geometry.json"))
        try Data([1, 2, 3]).write(to: chip)
        chmod(chip.path, 0o444)
        chmod(nand.path, 0o555)
        chflags(nand.path, UInt32(UF_IMMUTABLE))
        defer {
            chflags(nand.path, 0)
            chmod(nand.path, 0o755)
        }
        func argv() throws -> String {
            try f.prepare(.n81).configuration(
                bootArgs: "",
                usbAddress: nil,
                wifi: false,
                guestPackage: nil,
                serial: "null",
                audio: [],
                netdev: nil
            ).argv[2]
        }
        let live = PreparedDeviceBoot.liveNAND(overlay: f.overlay)
        let machine = try argv()
        #expect(machine.contains(",nand=\(live.path)") && !machine.contains("nand-overlay"))
        for url in [live, live.appendingPathComponent("bus0-ce0.pages")] {
            var st = stat()
            #expect(lstat(url.path, &st) == 0 && st.st_flags == 0 && access(url.path, W_OK) == 0, "\(url.path)")
        }
        try Data([9]).write(to: live.appendingPathComponent("bus0-ce0.pages"))  // the guest's write
        _ = try argv()
        #expect(try Data(contentsOf: live.appendingPathComponent("bus0-ce0.pages")) == Data([9]))
        #expect(try Data(contentsOf: chip) == Data([1, 2, 3]))
        #expect(try fm.contentsOfDirectory(atPath: f.overlay.path).sorted() == [".base-identity", "nand"])
        try Data().write(to: f.overlay.appendingPathComponent("bus0-ce0.dirty"))
        #expect(throws: CocoaError.self) { _ = try f.prepare(.n81) }
    }

    /// The iPod touch 2G's image store (nand-xor-blank-v2) boots its live clone too: nand= names it and no nandrw
    /// overlay is passed; a format 1 page directory left in the overlay over it is refused.
    @Test func n72ImageStoreBootsItsLiveCloneWithoutAnOverlay() throws {
        let f = try Fixture(board: .n72, strategy: "bootrom")
        let nand = f.base.appendingPathComponent("nand")
        try Data(#"{"storage_format": "nand-xor-blank-v2", "blank": "n72-generated"}"#.utf8)
            .write(to: nand.appendingPathComponent("geometry.json"))
        try Data([1, 2, 3]).write(to: nand.appendingPathComponent("cs0.pages"))
        let machine = try f.prepare(.n72).configuration(
            bootArgs: "",
            usbAddress: nil,
            wifi: false,
            guestPackage: nil,
            serial: "null",
            audio: [],
            netdev: nil
        ).argv[2]
        let live = PreparedDeviceBoot.liveNAND(overlay: f.overlay)
        #expect(machine.contains(",nand=\(BootRecipe.escape(live.path))") && !machine.contains("nandrw"), "\(machine)")
        #expect(try Data(contentsOf: live.appendingPathComponent("cs0.pages")) == Data([1, 2, 3]))
        try FileManager.default.createDirectory(
            at: f.overlay.appendingPathComponent("cs0"),
            withIntermediateDirectories: true
        )
        #expect(throws: CocoaError.self) { _ = try f.prepare(.n72) }
    }

    /// The 1.x boards' image store (nand-xor-blank-v2, blank ff) boots its live clone: nand= names it and no
    /// nand-overlay is passed; a format 1 bank directory left in the overlay over it is refused.
    @Test func m68ImageStoreBootsItsLiveCloneWithoutAnOverlay() throws {
        let f = try Fixture(board: .m68, strategy: "iboot")
        let nand = f.base.appendingPathComponent("nand")
        try Data(#"{"storage_format": "nand-xor-blank-v2", "blank": "ff", "board": "s5l8900"}"#.utf8)
            .write(to: nand.appendingPathComponent("geometry.json"))
        try Data([1, 2, 3]).write(to: nand.appendingPathComponent("cs0.pages"))
        func machine() throws -> String {
            try f.prepare(.m68).configuration(
                bootArgs: "",
                usbAddress: nil,
                wifi: false,
                guestPackage: nil,
                serial: "null",
                audio: [],
                netdev: nil
            ).argv[2]
        }
        let live = PreparedDeviceBoot.liveNAND(overlay: f.overlay)
        let argv = try machine()
        #expect(argv.contains(",nand=\(BootRecipe.escape(live.path))") && !argv.contains("nand-overlay"), "\(argv)")
        #expect(try Data(contentsOf: live.appendingPathComponent("cs0.pages")) == Data([1, 2, 3]))
        try FileManager.default.createDirectory(
            at: f.overlay.appendingPathComponent("bank0"),
            withIntermediateDirectories: true
        )
        #expect(throws: CocoaError.self) { _ = try machine() }
    }
}

extension BootTests {
    /// A 3GS or iPod touch 3G kboot.bin prepared with the IPSW's 0 ncoref-frequency boots an overlay copy with
    /// PLL1's 162 MHz; the base stays as it was, a later boot uses the copy as it is, and a kboot.bin that has the
    /// value, or an A4's, boots from the base.
    @Test func zeroAudioClockBootsARepairedCopy() throws {
        func image(_ hz: UInt32) -> Data {
            Data("dt".utf8) + Data("ncoref-frequency".utf8) + Data(count: 16) + Data([4, 0, 0, 0])
                + withUnsafeBytes(of: hz.littleEndian) { Data($0) } + Data("rest".utf8)
        }
        func boots(_ f: Fixture, _ board: Board, _ kboot: URL) throws -> Bool {
            try f.prepare(board).configuration(
                bootArgs: "",
                usbAddress: nil,
                wifi: false,
                guestPackage: nil,
                serial: "null",
                audio: [],
                netdev: nil
            ).argv[2].contains(",kboot=" + BootRecipe.escape(kboot.path) + ",")
        }
        for board in [Board.n88, .n18] {
            let f = try Fixture(board: board, strategy: "kboot")
            let base = f.base.appendingPathComponent("kboot.bin")
            try image(0).write(to: base)
            let copy = f.overlay.appendingPathComponent("kboot.bin")
            #expect(try boots(f, board, copy))
            #expect(try Data(contentsOf: copy) == image(PreparedDeviceBoot.ncorefHz))
            #expect(try Data(contentsOf: base) == image(0))
            try Data("kept".utf8).write(to: copy)
            #expect(try boots(f, board, copy))
            #expect(try Data(contentsOf: copy) == Data("kept".utf8))
        }
        let fresh = try Fixture(board: .n88, strategy: "kboot")
        try image(PreparedDeviceBoot.ncorefHz).write(to: fresh.base.appendingPathComponent("kboot.bin"))
        #expect(try boots(fresh, .n88, fresh.base.appendingPathComponent("kboot.bin")))
        #expect(!FileManager.default.fileExists(atPath: fresh.overlay.appendingPathComponent("kboot.bin").path))
        let a4 = try Fixture(board: .n90, strategy: "kboot")
        try image(0).write(to: a4.base.appendingPathComponent("kboot.bin"))
        #expect(try boots(a4, .n90, a4.base.appendingPathComponent("kboot.bin")))
        #expect(!FileManager.default.fileExists(atPath: a4.overlay.appendingPathComponent("kboot.bin").path))
    }
}

extension BootTests {
    /// A sandboxed helper is granted exactly what each board's boot opens (BootConfig.files, SandboxExtension): every
    /// path argv names is covered, and only the overlay, the writable NOR and the serial FIFOs are writable, never the
    /// base or the app bundle the SecureROM comes from.
    @Test func everyBoardsBootFilesCoverItsArgvAndWriteOnlyTheDevicesOwn() throws {
        for board in Board.allCases {
            for strategy in Self.strategies(board) {
                let f = try Fixture(board: board, strategy: strategy)
                let rom = f.root.appendingPathComponent("Light Touch.app/Contents/Resources/Device/rom.bin").path
                let offer = f.root.appendingPathComponent("device/work/guest-offer")
                try FileManager.default.createDirectory(at: offer, withIntermediateDirectories: true)
                let serial = f.root.appendingPathComponent("logs/serial").path
                let config = try PreparedDeviceBoot.prepare(
                    board: board,
                    base: f.base,
                    overlay: f.overlay,
                    writableNOR: f.nor,
                    storageKey: "base-A",
                    bootrom: rom
                ).configuration(
                    bootArgs: "args",
                    usbAddress: "/group/1/mux-1-g.sock",
                    wifi: true,
                    guestPackage: offer.path,
                    serial: "pipe:\(serial)",
                    audio: ["-audio", "driver=coreaudio"],
                    netdev: "user,id=wifi0"
                )
                let files = try #require(config.files, "\(board) \(strategy)")
                #expect(
                    Set(files.readWrite) == [f.overlay.path, f.nor.path, serial + ".in", serial + ".out"],
                    "\(board) \(strategy): \(files.readWrite)"
                )
                let granted = files.readWrite + files.readOnly
                for path in Self.argvPaths(config.argv) where !path.hasPrefix("/group/") {
                    // -serial pipe:PATH opens PATH.in and PATH.out
                    #expect(
                        granted.contains { path == $0 || path.hasPrefix($0 + "/") || path + ".in" == $0 },
                        "\(board) \(strategy): \(path) is not granted"
                    )
                }
            }
        }
    }

    /// Every absolute path in a QEMU argv (a value after `=` or `:`, between commas; ",," an escaped comma).
    static func argvPaths(_ argv: [String]) -> [String] {
        argv.flatMap { value in
            value.replacingOccurrences(of: ",,", with: "\u{1}").split(separator: ",").compactMap { field -> String? in
                let text = field.replacingOccurrences(of: "\u{1}", with: ",")
                guard let slash = text.firstIndex(of: "/"),
                    slash == text.startIndex || [":", "="].contains(text[text.index(before: slash)])
                else { return nil }
                return String(text[slash...])
            }
        }
    }
}
