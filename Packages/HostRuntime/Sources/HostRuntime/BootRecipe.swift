// argv and environment for one boot, from paths alone (DeviceSession.swift's helper section fills it from
// the device record). Foundation only; the offline checks and tests/drivers/session-driver compile it whole.

import Foundation

/// argv and environment for one boot, from paths alone. EmulatorController
/// fills it from the device record; tests from fixtures.
public nonisolated enum BootRecipe {
    public static func escape(_ value: String) -> String { value.replacingOccurrences(of: ",", with: ",,") }

    public struct IPod {
        public init(
            bootArgs: String,
            iBoot: String,
            bootrom: String,
            nand: String,
            nor: String,
            writableNOR: String,
            overlay: String,
            usbAddress: String?,
            wifi: Bool,
            memory: String = "128M",
            gidBlobs: String? = nil,
            guestPackage: String? = nil,
            machineOptions: [String: String] = [:]
        ) {
            self.bootArgs = bootArgs
            self.iBoot = iBoot
            self.bootrom = bootrom
            self.nand = nand
            self.nor = nor
            self.writableNOR = writableNOR
            self.overlay = overlay
            self.usbAddress = usbAddress
            self.wifi = wifi
            self.memory = memory
            self.gidBlobs = gidBlobs
            self.guestPackage = guestPackage
            self.machineOptions = machineOptions
        }
        public var bootArgs: String
        /// The machine's direct-iboot; "" boots the SecureROM -> NOR LLB -> iBoot chain (2.x).
        public var iBoot: String
        public var bootrom: String
        public var nand: String
        public var nor: String
        public var writableNOR: String
        /// The NAND page overlay (nandrw); empty for an image store, which the emulator writes in place.
        public var overlay: String
        public var usbAddress: String?
        public var wifi: Bool
        public var memory = "128M"
        /// A device.py/prepared device's KBAG table (the emulated AES has no GID key).
        public var gidBlobs: String? = nil
        /// This boot's guest-package offer directory (GuestPackage).
        public var guestPackage: String? = nil
        /// The -machine options the device was made for (device.lock.json "machine", e.g. aes-uid=engine).
        public var machineOptions: [String: String] = [:]
    }

    public enum IPadBoot: Equatable {
        case kernel(image: String, writableNOR: String?)
        case iBoot(image: String, writableNOR: String, gidBlobs: String)
        case secureROM(image: String, writableNOR: String, gidBlobs: String, developmentFuses: Bool)
    }

    /// Legacy locks with no strategy retain the explicit direct-kernel fallback.
    /// New boot paths cannot be inferred from whether a key file happens to exist.
    /// The value of the -M line's usb-tcp-addr (usbmuxd's guest socket), nil without one.
    public static func usbAddress(in argv: [String]) -> String? {
        for value in argv {
            guard let range = value.range(of: "usb-tcp-addr=") else { continue }
            return String(value[range.upperBound...].prefix { $0 != "," })
        }
        return nil
    }

    /// `argv` with its web proxy's guestfwd (guestForward's unix-connect:PATH) handed to QEMU as fdpass:`fd` instead: each
    /// guest connection comes over that socket, with no path (a sandboxed helper's web proxy).
    public static func replacingGuestForward(in argv: [String], withSocket fd: Int32) -> [String] {
        argv.map { value in
            guard let range = value.range(of: "-unix-connect:") else { return value }
            // the path ends at a lone comma (",," is an escaped one)
            var end = range.upperBound
            while end < value.endIndex {
                if value[end] == "," {
                    let next = value.index(after: end)
                    if next < value.endIndex, value[next] == "," {
                        end = value.index(after: next)
                        continue
                    }
                    break
                }
                end = value.index(after: end)
            }
            return value.replacingCharacters(in: range.lowerBound..<end, with: "-fdpass:\(fd)")
        }
    }

    /// `argv` with its usb-tcp-addr's value replaced by `address` (a sandboxed helper's USB bridge).
    public static func replacingUSBAddress(in argv: [String], with address: String) -> [String] {
        argv.map { value in
            guard let range = value.range(of: "usb-tcp-addr=") else { return value }
            let end = value[range.upperBound...].firstIndex(of: ",") ?? value.endIndex
            return value.replacingCharacters(in: range.upperBound..<end, with: address)
        }
    }

    public static func preparedIPadBoot(strategy: String?, image: String, writableNOR: String?, gidBlobs: String?)
        throws -> IPadBoot
    {
        switch strategy {
        case nil, "kboot": return .kernel(image: image, writableNOR: writableNOR)
        case "iboot", "bootrom":
            guard let writableNOR, !writableNOR.isEmpty, let gidBlobs, !gidBlobs.isEmpty else {
                throw CocoaError(
                    .fileNoSuchFile,
                    userInfo: [
                        NSLocalizedDescriptionKey: "The \(strategy ?? "none") boot needs writable NOR and GID key data."
                    ]
                )
            }
            if strategy == "iboot" { return .iBoot(image: image, writableNOR: writableNOR, gidBlobs: gidBlobs) }
            return .secureROM(image: image, writableNOR: writableNOR, gidBlobs: gidBlobs, developmentFuses: false)
        default:
            throw CocoaError(
                .fileReadCorruptFile,
                userInfo: [NSLocalizedDescriptionKey: "Unknown iPad boot strategy: \(strategy ?? "none")"]
            )
        }
    }

    public struct IPad {
        public init(
            boot: IPadBoot,
            nand: String,
            overlay: String?,
            dieID: String?,
            usbAddress: String?,
            wifi: Bool,
            guestPackage: String? = nil,
            machineOptions: [String: String] = [:],
            oneShot: Bool = false
        ) {
            self.oneShot = oneShot
            self.boot = boot
            self.nand = nand
            self.overlay = overlay
            self.dieID = dieID
            self.usbAddress = usbAddress
            self.wifi = wifi
            self.guestPackage = guestPackage
            self.machineOptions = machineOptions
        }
        public var boot: IPadBoot
        public var nand: String
        /// The page overlay; nil writes the store itself (FirmwareKit's seal and keybag one-shots).
        public var overlay: String?
        /// FirmwareKit's seal and keybag boots: no keyboard, no monitor, and QEMU exits when the guest halts or
        /// restarts (-no-reboot) instead of stopping (-no-shutdown).
        public var oneShot = false
        /// "0xWORD2:0xWORD3" (identity.json); the machine uses zeros without it.
        public var dieID: String?
        public var usbAddress: String?
        public var wifi: Bool
        public var guestPackage: String? = nil
        public var machineOptions: [String: String] = [:]
        /// The radio boards' (-M iPhone-4, n88) modem: always attached, as on a real iPhone (its IMEI is in the UDID);
        /// `.noSIM` and `.noService` keep it answering without a SIM or a network.
        public var cellular: Cellular = .on
        /// The iPhone 5's (BootRecipe.iPhone5): its Wi-Fi's MAC (identity.json wifi-mac, the device tree's) and the
        /// IMEI its modem reports (the lock's imei), which the other machines take as -M options.
        public var wifiMAC: String?
        public var imei: String?
    }

    /// What the modem of a radio board offers: a registered SIM, no SIM, or a SIM with no network.
    public enum Cellular: String, Sendable, CaseIterable {
        case on, noSIM, noService

        var globals: [String] {
            switch self {
            case .on: []
            case .noSIM: ["-global", "ios-baseband.sim-present=off"]
            case .noService: ["-global", "ios-baseband.registered=off"]
            }
        }
    }

    /// The iPod touch 1G (qemu-ios `-M iPod-Touch-1G`): the S5L8900 bootrom and the base's iBoot-204 (IMG2 payload),
    /// the device's NAND (an image store's live clone, or the base's page directory under a page overlay), and the NOR as a pflash drive on the private writable copy (iBoot and
    /// the kernel write it). Wi-Fi is the machine's Marvell 88W8686 (default on; `wifi: false` removes the card).
    /// No GID blobs on this machine. The original iPhone is the same machine (qemu-ios `-M iPhone-2G`, its subtype).
    public struct IPod1G {
        public init(
            bootrom: String,
            iBoot: String,
            nand: String,
            writableNOR: String,
            overlay: String,
            usbAddress: String? = nil,
            wifi: Bool = true,
            guestPackage: String? = nil,
            machineOptions: [String: String] = [:]
        ) {
            self.bootrom = bootrom
            self.iBoot = iBoot
            self.nand = nand
            self.writableNOR = writableNOR
            self.overlay = overlay
            self.usbAddress = usbAddress
            self.wifi = wifi
            self.guestPackage = guestPackage
            self.machineOptions = machineOptions
        }
        public var bootrom: String
        public var iBoot: String
        public var nand: String
        public var writableNOR: String
        /// The NAND page overlay (nand-overlay); empty for an image store, which the emulator writes in place.
        public var overlay: String
        public var usbAddress: String? = nil
        public var wifi = true
        /// This boot's guest-package offer directory (GuestPackage; n45-ios1 has it_boot since qemu-ios ff2f139cf9).
        public var guestPackage: String? = nil
        public var machineOptions: [String: String] = [:]
    }

    /// A board's SecureROM image (Board.bootrom) under the device assets: `root/<name>` (the bundle's
    /// Resources/Device, LTM_FILES), else a qemu-ios-files checkout's `root/ipod1g/<name>` (devos50's n45ap set).
    public static func bootrom(_ name: String, filesRoot root: String) -> String {
        let flat = "\(root)/\(name)"
        let set = "\(root)/ipod1g/\(name)"
        return !FileManager.default.fileExists(atPath: flat) && FileManager.default.fileExists(atPath: set) ? set : flat
    }

    /// 5.x Setup phones home: with live internet it fetches the software-update catalog and then its
    /// Apple-ID page ignores "Skip This Step" for minutes (smoke #54). Such a boot runs Setup with slirp
    /// restrict=on (its no-network path) and opens networking once Setup finishes. 3.x/4.x Setup has
    /// no Apple-ID page and boots unrestricted.

    public static func setupPhonesHome(iosVersion: String) -> Bool {
        iosVersion.compare("5.0", options: .numeric) != .orderedAscending
    }

    /// The wifi0 user netdev: the web proxy's guestfwd (a host-side chardev, reachable restricted or
    /// not) and restrict=on while Setup runs offline.
    /// `localNetwork` false (the default, the device's "Attach to Local Network" off): slirp refuses the guest's
    /// traffic to private, link-local and multicast addresses, so the guest can't make macOS ask for Local
    /// Network access on its own. DNS still works (the emulator asks the system resolver, never a LAN DNS server)
    /// and the app's loopback guestfwds stay reachable.
    public static func wifiNetdev(guestForward: String, restricted: Bool, localNetwork: Bool = false) -> String {
        "user,id=wifi0" + guestForward + (restricted ? ",restrict=on" : "") + (localNetwork ? "" : ",lan=off")
    }

    /// When a restricted boot's Setup is over, from it_agent's frontmost polls: an unlocked screen that
    /// isn't purplebuddy. Locked reads "com.apple.springboard" / "Lock Screen" (agent-sbs.h), and a fresh
    /// 5.x shows exactly that before Setup starts, so SpringBoard alone is not the signal. Two polls in a
    /// row, so a transient unlocked state while the slide hands over to purplebuddy can't lift it early.
    /// `observe` answers true once: the moment to call qemu_ios_ui_net_restrict(off).
    public struct SetupNetworkGate {
        public init() {}
        private var streak = 0
        public private(set) var lifted = false
        public mutating func observe(bundleID: String?, name: String?) -> Bool {
            guard !lifted else { return false }
            let unlockedOutsideSetup =
                bundleID.map { !$0.isEmpty && $0 != "com.apple.purplebuddy" } == true
                && name != "Lock Screen"
            streak = unlockedOutsideSetup ? streak + 1 : 0
            lifted = streak >= 2
            return lifted
        }
    }

    /// The overlay has been through Setup (the app lifted restrict after it). Erase deletes the
    /// overlay and the mark with it, so the next boot runs Setup offline again.
    public static func setupDoneMark(overlay: URL) -> URL { overlay.appendingPathComponent(".setup-done") }

    /// A prepared iPod base's direct-iBoot, or empty for a bootrom lock. Invalid present locks propagate.
    public static func iPodIBoot(base: URL) throws -> String {
        try DeviceLock.read(base: base)?.bootStrategy == "bootrom" ? "" : base.appendingPathComponent("iBoot.bin").path
    }

    public static func options(_ machine: [String: String]) -> String {
        machine.sorted { $0.key < $1.key }.map { ",\($0.key)=\(escape($0.value))" }.joined()
    }

    /// `audio`: the app's CoreAudio arguments, or `-audio driver=none` in tests.
    /// `netdev`: the explicit wifi0 (with the web proxy's guestfwd), if any.
    /// `hardware`: the emulator's facts about the board (DeviceInfo): the -M machine.
    public static func iPod(
        _ d: IPod,
        hardware: DeviceInfo,
        serial: String,
        audio: [String],
        netdev: String?,
        restore: [String]
    ) -> BootConfig {
        var machine =
            "\(hardware.machine),boot-args=\(escape(d.bootArgs))"
            + ",direct-iboot=\(escape(d.iBoot)),direct-llb="
            + ",bootrom=\(escape(d.bootrom)),nand=\(escape(d.nand)),nor=\(escape(d.nor))"
            + ",nor-rw=\(escape(d.writableNOR))" + (d.overlay.isEmpty ? "" : ",nandrw=\(escape(d.overlay))")
        if let usb = d.usbAddress { machine += ",usb-tcp-addr=\(usb),osk=on" }
        if d.wifi { machine += ",wifi=on" }  // brings up the emulated BCM4325
        if let blobs = d.gidBlobs { machine += ",gid-blobs=\(escape(blobs))" }
        if let offer = d.guestPackage { machine += ",guest-package=\(escape(offer))" }
        machine += options(d.machineOptions)
        let argv =
            ["LightTouchMac", "-M", machine, "-m", d.memory, "-display", "none", "-no-shutdown"]
            + audio + ["-serial", serial] + (netdev.map { ["-netdev", $0] } ?? []) + restore
        // The setting 3.1.3 will not boot without. No IT_LCD_BRIGHT: the guest's own
        // backlight is what makes Lock visible.
        return BootConfig(argv: argv, environment: ["IT_TVOUT_READY": "1"], machine: hardware.machine)
    }

    /// `-drive` takes its own comma escaping (as -M does). No -m: the machine's 128 MiB.
    /// `netdev`: the explicit wifi0 (with the web proxy's guestfwd), if any; without one the machine makes its own.
    public static func iPod1G(_ d: IPod1G, hardware: DeviceInfo, serial: String, audio: [String], netdev: String?)
        -> BootConfig
    {
        let machine =
            "\(hardware.machine),bootrom=\(escape(d.bootrom)),iboot=\(escape(d.iBoot))"
            + ",nand=\(escape(d.nand))" + (d.overlay.isEmpty ? "" : ",nand-overlay=\(escape(d.overlay))")
            + (d.usbAddress.map { ",usb-tcp-addr=\($0)" } ?? "") + (d.wifi ? "" : ",wifi=off")
            + (d.guestPackage.map { ",guest-package=\(escape($0))" } ?? "") + options(d.machineOptions)
        let argv =
            [
                "LightTouchMac", "-M", machine, "-drive", "if=pflash,format=raw,file=\(escape(d.writableNOR))",
                "-display", "none", "-no-shutdown"
            ] + audio + ["-serial", serial] + (netdev.map { ["-netdev", $0] } ?? [])
            // The iPhone's modem carries its EDGE data (raw IP over a mux DLCI) to its own slirp, cell0, with the web
            // proxy's guestfwd as Wi-Fi's (the image routes cellular through the proxy too) and its lan= setting; with
            // no wifi0 given, off the LAN like the machine's own default wifi0.
            + (hardware.hasCellular
                ? [
                    "-netdev",
                    netdev.map { $0.replacingOccurrences(of: "id=wifi0", with: "id=cell0") } ?? "user,id=cell0,lan=off"
                ] : [])
        return BootConfig(argv: argv, machine: hardware.machine)
    }

    /// Wi-Fi is the machine's default (a BCM4329 on its own slirp wifi0); an
    /// explicit `netdev` replaces it. No -m: the machine's default is the board's (256 MiB on K48 and N81).
    /// `hardware`: the emulator's facts about the board (DeviceInfo): the -M machine (ipad1, iPod-Touch-4G, iPhone-4,
    /// n88, n18; Board.machineOptions lists what each takes), its modem (baseband=on and the cell0 netdev) and USB
    /// host (the keyboard).
    public static func iPad(
        _ d: IPad,
        hardware: DeviceInfo,
        serial: String,
        audio: [String],
        netdev: String?,
        restore: [String]
    ) -> BootConfig {
        let board = hardware.machine
        var machine: String
        switch d.boot {
        case .kernel(let image, let nor):
            machine = "\(board),kboot=\(escape(image))"
            if let nor { machine += ",nor-rw=\(escape(nor))" }
        case .iBoot(let image, let nor, let gid):
            machine = "\(board),iboot=\(escape(image)),nor-rw=\(escape(nor)),gid-blobs=\(escape(gid))"
        case .secureROM(let image, let nor, let gid, let developmentFuses):
            machine =
                "\(board),bootrom=\(escape(image)),nor-rw=\(escape(nor)),gid-blobs=\(escape(gid)),development-fuses=\(developmentFuses ? "on" : "off")"
        }
        machine += ",nand=\(escape(d.nand))" + (d.overlay.map { ",nand-overlay=\(escape($0))" } ?? "")
        if let dieID = d.dieID { machine += ",die-id=\(escape(dieID))" }
        // Without a bridge the machine's built-in USB host keeps it charging.
        if let usb = d.usbAddress { machine += ",usb-tcp-addr=\(usb)" }
        if !d.wifi { machine += ",wifi=off" }
        if let offer = d.guestPackage { machine += ",guest-package=\(escape(offer))" }
        let radio = hardware.hasCellular
        if radio { machine += ",baseband=on" }
        machine += options(d.machineOptions)
        // The modem's packet data goes to its own slirp, cell0: Wi-Fi's (the web proxy's guestfwd, the Setup
        // restriction) under that id, so a PAC answer cached on Wi-Fi still reaches the proxy over cellular.
        let cellular =
            radio
            ? (netdev.map { ["-netdev", $0.replacingOccurrences(of: "id=wifi0", with: "id=cell0")] } ?? [])
                + d.cellular.globals : []
        // usb-kbd on the always-on EHCI becomes the active keyboard for key_mac. 20 mA: 4.x gives the
        // dock's host side AAPL,power-supply 50 and refuses the default 100 mA device ("not enough power").
        let argv =
            ["LightTouchMac", "-M", machine, "-display", "none"]
            + (d.oneShot ? ["-monitor", "none", "-no-reboot"] : ["-no-shutdown"])
            + audio + ["-serial", serial]
            + (hardware.hasUSBHost && !d.oneShot ? ["-device", "usb-kbd,bus=usb-bus.0,max-power=20"] : [])
            + (netdev.map { ["-netdev", $0] } ?? []) + cellular + restore
        return BootConfig(argv: argv, machine: board)
    }

    /// The iPhone 5 (-M iPhone-5, the S5L8950): kboot on its PPN store (the lock's ppn, camera and quiet-boot options),
    /// the modem always (baseband=on, its cell0 netdev and IMEI), Wi-Fi a BCM4334 on the HSIC port (the machine has no
    /// wifi=) with the unit's MAC, and no die-id or USB keyboard. Its four cores run multi-threaded TCG, the A6
    /// machine's qualified configuration.
    public static func iPhone5(
        _ d: IPad,
        hardware: DeviceInfo,
        serial: String,
        audio: [String],
        netdev: String?,
        restore: [String]
    ) -> BootConfig {
        var machine = hardware.machine
        if case .kernel(let image, _) = d.boot { machine += ",kboot=\(escape(image))" }
        // no nand-overlay: its store is an image store, which a boot writes as a live clone (PreparedDeviceBoot)
        machine += ",nand=\(escape(d.nand))"
        if let usb = d.usbAddress { machine += ",usb-tcp-addr=\(usb)" }
        if let offer = d.guestPackage { machine += ",guest-package=\(escape(offer))" }
        machine += ",baseband=on" + options(d.machineOptions)
        let wifi =
            d.wifi
            ? ["-device", "usb-bcm-hsic,bus=usb-bus.0,port=4" + (d.wifiMAC.map { ",mac=\($0)" } ?? "")] : []
        // Without an explicit wifi0 the machine makes none (the iPad's makes its own): one off the LAN, as theirs.
        let wifi0 = netdev ?? "user,id=wifi0,lan=off"
        let cellular =
            ["-netdev", wifi0.replacingOccurrences(of: "id=wifi0", with: "id=cell0")]
            + (d.imei.map { ["-global", "ios-baseband.imei=\($0)"] } ?? []) + d.cellular.globals
        let argv =
            ["LightTouchMac", "-M", machine, "-accel", "tcg,thread=multi", "-display", "none"]
            + (d.oneShot ? ["-monitor", "none", "-no-reboot"] : ["-no-shutdown"])
            + audio + ["-serial", serial] + wifi + ["-netdev", wifi0] + cellular + restore
        return BootConfig(argv: argv, machine: hardware.machine)
    }

    /// A prepared device's boot files (W5/W6): the board's boot file (the iPad's
    /// kboot.bin, the iPod's iBoot.bin), nand/ and any `also` files from base, and
    /// on first boot the overlay directory and the writable NOR, cloned from
    /// base/nor.bin (cp -c) and made owner-writable. Nothing is written inside
    /// base/, which is read-only. usbmuxd-conf is created (and seeded) by USBMux.
    public static func preparedFiles(
        base: URL,
        overlay: URL,
        writableNOR: URL?,
        boot: String = "kboot.bin",
        also: [String] = []
    ) throws -> (boot: URL, nand: URL, writableNOR: URL?) {
        let fm = FileManager.default
        let kboot = base.appendingPathComponent(boot)
        let nand = base.appendingPathComponent("nand", isDirectory: true)
        for file in [kboot, nand] + also.map(base.appendingPathComponent) where !fm.fileExists(atPath: file.path) {
            throw CocoaError(.fileNoSuchFile, userInfo: [NSFilePathErrorKey: file.path])
        }
        try fm.createDirectory(at: overlay, withIntermediateDirectories: true)
        if let writableNOR, !fm.fileExists(atPath: writableNOR.path) {
            let source = base.appendingPathComponent("nor.bin")
            let staged = writableNOR.deletingLastPathComponent()
                .appendingPathComponent(".\(writableNOR.lastPathComponent)-\(UUID().uuidString).tmp")
            defer { try? fm.removeItem(at: staged) }
            try fm.createDirectory(at: writableNOR.deletingLastPathComponent(), withIntermediateDirectories: true)
            guard copyfile(source.path, staged.path, nil, copyfile_flags_t(COPYFILE_CLONE)) == 0 else {
                throw CocoaError(
                    .fileWriteUnknown,
                    userInfo: [
                        NSFilePathErrorKey: source.path,
                        NSUnderlyingErrorKey: POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                    ]
                )
            }
            let mode =
                (try fm.attributesOfItem(atPath: staged.path)[.posixPermissions] as? NSNumber)?.int16Value ?? 0o444
            try fm.setAttributes([.posixPermissions: mode | 0o200], ofItemAtPath: staged.path)
            try fm.moveItem(at: staged, to: writableNOR)
        }
        return (kboot, nand, writableNOR)
    }
}
