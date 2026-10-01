// argv and environment for one boot, from paths alone (DeviceSession.swift's helper section fills it from
// the device record). Foundation only; the offline checks and tests/drivers/session-driver compile it whole.

import CryptoKit
import Foundation

/// argv and environment for one boot, from paths alone. EmulatorController
/// fills it from the device record; tests from fixtures.
public nonisolated enum BootRecipe {
    public static func escape(_ value: String) -> String { value.replacingOccurrences(of: ",", with: ",,") }

    public struct IPod {
        public init(bootArgs: String, iBoot: String, bootrom: String, nand: String, nor: String, writableNOR: String, overlay: String, usbAddress: String?, wifi: Bool, memory: String = "128M", gidBlobs: String? = nil, guestPackage: String? = nil, machineOptions: [String: String] = [:]) {
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
    public static func preparedIPadBoot(strategy: String?, image: String, writableNOR: String?, gidBlobs: String?) throws -> IPadBoot {
        switch strategy {
        case nil, "kboot": return .kernel(image: image, writableNOR: writableNOR)
        case "iboot", "bootrom":
            guard let writableNOR, !writableNOR.isEmpty, let gidBlobs, !gidBlobs.isEmpty else {
                throw CocoaError(.fileNoSuchFile, userInfo: [NSLocalizedDescriptionKey: "The \(strategy!) boot needs writable NOR and GID key data."])
            }
            if strategy == "iboot" { return .iBoot(image: image, writableNOR: writableNOR, gidBlobs: gidBlobs) }
            return .secureROM(image: image, writableNOR: writableNOR, gidBlobs: gidBlobs, developmentFuses: false)
        default:
            throw CocoaError(.fileReadCorruptFile, userInfo: [NSLocalizedDescriptionKey: "Unknown iPad boot strategy: \(strategy!)"])
        }
    }

    public struct IPad {
        public init(boot: IPadBoot, nand: String, overlay: String, dieID: String?, usbAddress: String?, wifi: Bool, guestPackage: String? = nil, machineOptions: [String: String] = [:]) {
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
        public var overlay: String
        /// "0xWORD2:0xWORD3" (identity.json); the machine uses zeros without it.
        public var dieID: String?
        public var usbAddress: String?
        public var wifi: Bool
        public var guestPackage: String? = nil
        public var machineOptions: [String: String] = [:]
    }

    /// The iPod touch 1G (qemu-ios `-M iPod-Touch-1G`): the S5L8900 bootrom and the base's iBoot-204 (IMG2 payload),
    /// the base's NAND under a page overlay, and the NOR as a pflash drive on the private writable copy (iBoot and
    /// the kernel write it). Wi-Fi is the machine's Marvell 88W8686 (default on; `wifi: false` removes the card).
    /// No GID blobs on this machine.
    public struct IPod1G {
        public init(bootrom: String, iBoot: String, nand: String, writableNOR: String, overlay: String, usbAddress: String? = nil, wifi: Bool = true, guestPackage: String? = nil, machineOptions: [String: String] = [:]) {
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
        public var overlay: String
        public var usbAddress: String? = nil
        public var wifi = true
        /// This boot's guest-package offer directory (GuestPackage; n45-ios1 has it_boot since qemu-ios ff2f139cf9).
        public var guestPackage: String? = nil
        public var machineOptions: [String: String] = [:]
    }

    /// A board's SecureROM image (DeviceProfile.bootromName) under the device assets: `root/<name>` (the bundle's
    /// Resources/device, LTM_FILES), else a qemu-ios-files checkout's `root/ipod1g/<name>` (devos50's n45ap set).
    public static func bootrom(_ name: String, filesRoot root: String) -> String {
        let flat = "\(root)/\(name)", set = "\(root)/ipod1g/\(name)"
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
    public static func wifiNetdev(guestForward: String, restricted: Bool) -> String {
        "user,id=wifi0" + guestForward + (restricted ? ",restrict=on" : "")
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
            let unlockedOutsideSetup = bundleID.map { !$0.isEmpty && $0 != "com.apple.purplebuddy" } == true
                && name != "Lock Screen"
            streak = unlockedOutsideSetup ? streak + 1 : 0
            lifted = streak >= 2
            return lifted
        }
    }

    /// The overlay has been through Setup (the app lifted restrict after it). Erase deletes the
    /// overlay and the mark with it, so the next boot runs Setup offline again.
    public static func setupDoneMark(overlay: URL) -> URL { overlay.appendingPathComponent(".setup-done") }

    /// A prepared base's device.lock.json "machine" options; none for a missing lock or field.
    public static func lockMachine(_ lock: URL) -> [String: String] {
        guard let data = try? Data(contentsOf: lock),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        var machine = (object["machine"] as? [String: Any] ?? [:]).mapValues { "\($0)" }
        // Prepared N72 bases predating card provisioning already have the unit's
        // identity beside the lock. Use it without changing the immutable base.
        if object["board"] as? String == "n72ap",
           let data = try? Data(contentsOf: lock.deletingLastPathComponent().appendingPathComponent("identity.json")),
           let identity = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            for key in ["wifi-mac", "bt-mac"] where machine[key] == nil {
                if let mac = identity[key] as? String, !mac.isEmpty { machine[key] = mac }
            }
            if machine["ecid"] == nil {
                if let ecid = identity["unique-chip-id"] as? String {
                    machine["ecid"] = ecid
                } else if let seed = identity["seed"] as? String {
                    // Legacy N72 identities omitted ECID. Recover the same
                    // 40-bit seed value UnitIdentity uses, without rewriting
                    // the immutable base or changing its serial/MAC/UDID.
                    let hash = Array(SHA256.hash(data: Data(seed.utf8)))
                    let ecid = hash[20..<25].reduce(UInt64(0)) { ($0 << 8) | UInt64($1) } | 1
                    machine["ecid"] = String(format: "0x%010llx", ecid)
                }
            }
        }
        return machine
    }

    /// A prepared base's boot_strategy ("iboot"/"kboot"); nil for a missing lock or field (the two older prepared
    /// iPads are kboot and carry no boot_strategy).
    public static func bootStrategy(_ lock: URL) -> String? {
        guard let data = try? Data(contentsOf: lock),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return object["boot_strategy"] as? String
    }

    /// A prepared iPod base's direct-iboot: its iBoot.bin, or "" for a "bootrom" (2.x) lock.
    public static func iPodIBoot(base: URL) -> String {
        bootStrategy(base.appendingPathComponent("device.lock.json")) == "bootrom" ? "" : base.appendingPathComponent("iBoot.bin").path
    }

    public static func options(_ machine: [String: String]) -> String {
        machine.sorted { $0.key < $1.key }.map { ",\($0.key)=\(escape($0.value))" }.joined()
    }

    /// `audio`: the app's CoreAudio arguments, or `-audio driver=none` in tests.
    /// `netdev`: the explicit wifi0 (with the web proxy's guestfwd), if any.
    public static func iPod(_ d: IPod, serial: String, audio: [String], netdev: String?, restore: [String]) -> BootConfig {
        var machine = "iPod-Touch,h264-decode=on,scaler-decode=on,mpvd-decode=on,amc-mode=decode,lcd-planes=on"
            + ",boot-args=\(escape(d.bootArgs))"
            + ",boot-args-delay-ms=0,boot-args-repeat=200,boot-args-interval-ms=250"
            + ",direct-iboot=\(escape(d.iBoot)),direct-llb="
            + ",bootrom=\(escape(d.bootrom)),nand=\(escape(d.nand)),nor=\(escape(d.nor))"
            + ",nor-rw=\(escape(d.writableNOR)),nandrw=\(escape(d.overlay))"
        if let usb = d.usbAddress { machine += ",usb-tcp-addr=\(usb),osk=on" }
        if d.wifi { machine += ",wifi=on" }          // brings up the emulated BCM4325
        if let blobs = d.gidBlobs { machine += ",gid-blobs=\(escape(blobs))" }
        if let offer = d.guestPackage { machine += ",guest-package=\(escape(offer))" }
        machine += options(d.machineOptions)
        let argv = ["LightTouchMac", "-M", machine, "-m", d.memory, "-display", "none", "-no-shutdown"]
            + audio + ["-serial", serial] + (netdev.map { ["-netdev", $0] } ?? []) + restore
        // The settings 3.1.3 will not boot without (contrib/run-ipod-touch.sh). No
        // IT_LCD_BRIGHT: the guest's own backlight is what makes Lock visible.
        return BootConfig(argv: argv, environment: ["IT_TVOUT_READY": "1"], machine: "iPod-Touch")
    }

    /// `-drive` takes its own comma escaping (as -M does). No -m: the machine's 128 MiB.
    /// `netdev`: the explicit wifi0 (with the web proxy's guestfwd), if any; without one the machine makes its own.
    public static func iPod1G(_ d: IPod1G, serial: String, audio: [String], netdev: String?) -> BootConfig {
        let machine = "iPod-Touch-1G,bootrom=\(escape(d.bootrom)),iboot=\(escape(d.iBoot))"
            + ",nand=\(escape(d.nand)),nand-overlay=\(escape(d.overlay))"
            + (d.usbAddress.map { ",usb-tcp-addr=\($0)" } ?? "") + (d.wifi ? "" : ",wifi=off")
            + (d.guestPackage.map { ",guest-package=\(escape($0))" } ?? "") + options(d.machineOptions)
        let argv = ["LightTouchMac", "-M", machine, "-drive", "if=pflash,format=raw,file=\(escape(d.writableNOR))",
                    "-display", "none", "-no-shutdown"] + audio + ["-serial", serial] + (netdev.map { ["-netdev", $0] } ?? [])
        return BootConfig(argv: argv, machine: "iPod-Touch-1G")
    }

    /// Wi-Fi is the machine's default (a BCM4329 on its own slirp wifi0); an
    /// explicit `netdev` replaces it. No -m: the machine's default is the K48's 256 MiB.
    public static func iPad(_ d: IPad, serial: String, audio: [String], netdev: String?, restore: [String]) -> BootConfig {
        var machine: String
        switch d.boot {
        case let .kernel(image, nor):
            machine = "ipad1,kboot=\(escape(image))"
            if let nor { machine += ",nor-rw=\(escape(nor))" }
        case let .iBoot(image, nor, gid):
            machine = "ipad1,iboot=\(escape(image)),nor-rw=\(escape(nor)),gid-blobs=\(escape(gid))"
        case let .secureROM(image, nor, gid, developmentFuses):
            machine = "ipad1,bootrom=\(escape(image)),nor-rw=\(escape(nor)),gid-blobs=\(escape(gid)),development-fuses=\(developmentFuses ? "on" : "off")"
        }
        machine += ",nand=\(escape(d.nand)),nand-overlay=\(escape(d.overlay))"
        if let dieID = d.dieID { machine += ",die-id=\(escape(dieID))" }
        // Without a bridge the machine's built-in USB host keeps it charging.
        if let usb = d.usbAddress { machine += ",usb-tcp-addr=\(usb)" }
        if !d.wifi { machine += ",wifi=off" }
        if let offer = d.guestPackage { machine += ",guest-package=\(escape(offer))" }
        machine += options(d.machineOptions)
        // usb-kbd on the always-on EHCI becomes the active keyboard for key_mac. 20 mA: 4.x gives the
        // dock's host side AAPL,power-supply 50 and refuses the default 100 mA device ("not enough power").
        let argv = ["LightTouchMac", "-M", machine, "-display", "none", "-no-shutdown"] + audio
            + ["-serial", serial, "-device", "usb-kbd,bus=usb-bus.0,max-power=20"] + (netdev.map { ["-netdev", $0] } ?? []) + restore
        return BootConfig(argv: argv, machine: "ipad1")
    }

    /// A prepared device's boot files (W5/W6): the board's boot file (the iPad's
    /// kboot.bin, the iPod's iBoot.bin), nand/ and any `also` files from base, and
    /// on first boot the overlay directory and the writable NOR, cloned from
    /// base/nor.bin (cp -c) and made owner-writable. Nothing is written inside
    /// base/, which is read-only. usbmuxd-conf is created (and seeded) by USBMux.
    public static func preparedFiles(base: URL, overlay: URL, writableNOR: URL?, boot: String = "kboot.bin",
                              also: [String] = []) throws -> (boot: URL, nand: URL, writableNOR: URL?) {
        let fm = FileManager.default
        let kboot = base.appendingPathComponent(boot), nand = base.appendingPathComponent("nand", isDirectory: true)
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
                throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: source.path,
                                                              NSUnderlyingErrorKey: POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)])
            }
            let mode = (try fm.attributesOfItem(atPath: staged.path)[.posixPermissions] as? NSNumber)?.int16Value ?? 0o444
            try fm.setAttributes([.posixPermissions: mode | 0o200], ofItemAtPath: staged.path)
            try fm.moveItem(at: staged, to: writableNOR)
        }
        return (kboot, nand, writableNOR)
    }
}
