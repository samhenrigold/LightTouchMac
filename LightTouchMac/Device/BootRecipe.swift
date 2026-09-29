// argv and environment for one boot, from paths alone (DeviceSession.swift's helper section fills it from
// the device record). Foundation only; the offline checks and tests/drivers/session-driver compile it whole.

import Foundation

/// argv and environment for one boot, from paths alone. EmulatorController
/// fills it from the device record; tests from fixtures.
nonisolated enum BootRecipe {
    static func escape(_ value: String) -> String { value.replacingOccurrences(of: ",", with: ",,") }

    struct IPod {
        var bootArgs: String
        /// The machine's direct-iboot; "" boots the SecureROM -> NOR LLB -> iBoot chain (2.x).
        var iBoot: String
        var bootrom: String
        var nand: String
        var nor: String
        var writableNOR: String
        var overlay: String
        var usbAddress: String?
        var wifi: Bool
        var memory = "128M"
        /// A device.py/prepared device's KBAG table (the emulated AES has no GID key).
        var gidBlobs: String? = nil
        /// This boot's guest-package offer directory (GuestPackage).
        var guestPackage: String? = nil
        /// The -machine options the device was made for (device.lock.json "machine", e.g. aes-uid=engine).
        var machineOptions: [String: String] = [:]
    }

    struct IPad {
        /// The boot image: kboot.bin (direct-kernel) or, when `gidBlobs` is set, iBoot.bin (real iBoot chain).
        var kboot: String
        var nand: String
        var overlay: String
        /// "0xWORD2:0xWORD3" (identity.json); the machine uses zeros without it.
        var dieID: String?
        var writableNOR: String?
        /// Set for the iboot strategy: the base's gid-blobs.bin (the emulated AES has no GID key). Its presence
        /// picks `iboot=` over `kboot=`.
        var gidBlobs: String? = nil
        var usbAddress: String?
        var wifi: Bool
        var guestPackage: String? = nil
        var machineOptions: [String: String] = [:]
    }

    /// A prepared base's device.lock.json "machine" options; none for a missing lock or field.
    static func lockMachine(_ lock: URL) -> [String: String] {
        guard let data = try? Data(contentsOf: lock),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let machine = object["machine"] as? [String: Any] else { return [:] }
        return machine.mapValues { "\($0)" }
    }

    /// A prepared base's boot_strategy ("iboot"/"kboot"); nil for a missing lock or field (the two older prepared
    /// iPads are kboot and carry no boot_strategy).
    static func bootStrategy(_ lock: URL) -> String? {
        guard let data = try? Data(contentsOf: lock),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return object["boot_strategy"] as? String
    }

    /// A prepared iPod base's direct-iboot: its iBoot.bin, or "" for a "bootrom" (2.x) lock.
    static func iPodIBoot(base: URL) -> String {
        bootStrategy(base.appendingPathComponent("device.lock.json")) == "bootrom" ? "" : base.appendingPathComponent("iBoot.bin").path
    }

    static func options(_ machine: [String: String]) -> String {
        machine.sorted { $0.key < $1.key }.map { ",\($0.key)=\(escape($0.value))" }.joined()
    }

    /// `audio`: the app's CoreAudio arguments, or `-audio driver=none` in tests.
    /// `netdev`: the explicit wifi0 (with the web proxy's guestfwd), if any.
    static func iPod(_ d: IPod, serial: String, audio: [String], netdev: String?, restore: [String]) -> BootConfig {
        var machine = "iPod-Touch,h264-decode=on,scaler-decode=on,mpvd-decode=on,amc-mode=decode,lcd-planes=on"
            + ",boot-args=\(escape(d.bootArgs))"
            + ",boot-args-delay-ms=1500,boot-args-repeat=200,boot-args-interval-ms=250"
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

    /// Wi-Fi is the machine's default (a BCM4329 on its own slirp wifi0); an
    /// explicit `netdev` replaces it. No -m: the machine's default is the K48's 256 MiB.
    static func iPad(_ d: IPad, serial: String, audio: [String], netdev: String?, restore: [String]) -> BootConfig {
        // iboot strategy: enter the pattern-patched iBoot with the catalog keys and boot the kernel from NAND, off a
        // private writable NOR (no base nor=, as ipad1_boot's writable path). kboot: the direct-kernel bundle.
        var machine: String
        if let gid = d.gidBlobs {
            machine = "ipad1,iboot=\(escape(d.kboot)),gid-blobs=\(escape(gid))"
            if let nor = d.writableNOR { machine += ",nor-rw=\(escape(nor))" }
            machine += ",nand=\(escape(d.nand)),nand-overlay=\(escape(d.overlay))"
        } else {
            machine = "ipad1,kboot=\(escape(d.kboot)),nand=\(escape(d.nand)),nand-overlay=\(escape(d.overlay))"
            if let nor = d.writableNOR { machine += ",nor-rw=\(escape(nor))" }
        }
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
    static func preparedFiles(base: URL, overlay: URL, writableNOR: URL?, boot: String = "kboot.bin",
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
