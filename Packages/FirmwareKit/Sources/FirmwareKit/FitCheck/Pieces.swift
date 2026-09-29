// The per-piece fit checks (FitCheck.swift has the core and the Mach-O load check). Each reads the firmware and
// returns a Fit; the recipes decide what a misfit means for their board.

import Foundation

extension FitCheck {
    /// The C string `s` as it sits in a binary's string section: NUL on both sides.
    static func cString(_ s: String) -> Data { Data(("\0" + s + "\0").utf8) }

    /// Undefined external symbols a Mach-O imports.
    static func imports(_ m: MachO32) -> Set<String> {
        Set(m.symbols().filter { $0.type & 0xE0 == 0 && $0.type & 0x01 != 0 && $0.type & 0x0E == 0 }.map(\.name))
    }

    // MARK: it_msmquiet

    /// The keys MobileStorageMounter's "USB device is not supported" notice uses (contrib/it-msmquiet keys[]:
    /// 3.2.x UNSUPPORTED_FAILURE, 4.x UNSUPPORTED_FAILURE_BODY) and the calls it_msmquiet interposes.
    static let msmKeys = ["UNSUPPORTED_FAILURE", "UNSUPPORTED_FAILURE_BODY"]
    static let msmCalls = ["_CFUserNotificationDisplayNotice", "_CFUserNotificationCreate"]

    /// it_msmquiet fits when the mounter (`program`, the stock job's) raises the notice it recognises: its binary
    /// names one of the notice's keys and imports one of the calls it interposes, and the dylib loads in it.
    public static func msmQuiet(_ fw: Firmware, program: String, dylib: Data) -> Fit {
        let piece = "it_msmquiet (storage_mounter's USB \"not supported\" notice)", name = (program as NSString).lastPathComponent
        guard let bin = fw.data(program), let m = MachO32.slice(bin, arch: fw.arch)?.image else {
            return Fit(piece, fits: false, "no \(program) on this firmware")
        }
        let keys = msmKeys.filter { bin.range(of: cString($0)) != nil }, calls = msmCalls.filter(imports(m).contains)
        guard !keys.isEmpty else {
            return Fit(piece, fits: false, "\(name) names neither \(msmKeys.joined(separator: " nor ")): whatever raises this firmware's notice, it_msmquiet cannot recognise it")
        }
        guard !calls.isEmpty else { return Fit(piece, fits: false, "\(name) imports neither \(msmCalls.joined(separator: " nor ")), the calls it_msmquiet interposes") }
        let l = loads(piece, dylib, on: fw, host: program)
        guard l.fits else { return l }
        return Fit(piece, fits: true, "\(name) raises \(keys.joined(separator: ", ")) through \(calls.map { String($0.dropFirst()) }.joined(separator: ", ")); \(l.proof)")
    }

    // MARK: USB Ethernet

    /// it_ethlink and the USB Ethernet interface pinned to en1 (usb_net) fit when the kernel has every class the
    /// pinned IOPathMatch names (it_ethlink's AppleUSBEthernetDevice among them) and names LinkStatus, the property
    /// it_ethlink sets.
    public static func usbEthernet(_ fw: Firmware, path: String) -> Fit {
        let piece = "USB Ethernet (it_ethlink, en1 pinned by IOPathMatch)"
        guard let k = fw.kernelcache else { return Fit(piece, fits: false, "no decrypted kernelcache to check the classes against") }
        let classes = path.split(separator: ":", maxSplits: 1).last.map(String.init)?.split(separator: "/")
            .map { String($0.prefix { $0 != "@" }) }.filter { $0.first?.isUppercase == true } ?? []
        let missing = classes.filter { k.range(of: cString($0)) == nil }
        guard !classes.isEmpty else { return Fit(piece, fits: false, "no classes in \(path)") }
        guard missing.isEmpty else { return Fit(piece, fits: false, "the kernel has no \(missing.joined(separator: ", ")), which the en1 IOPathMatch names") }
        guard k.range(of: cString("LinkStatus")) != nil else { return Fit(piece, fits: false, "the kernel names no LinkStatus property (it_ethlink raises the link through it)") }
        return Fit(piece, fits: true, "the kernel has \(classes.joined(separator: ", ")) and names LinkStatus")
    }

    // MARK: it_prefs

    /// it_prefs' settings (contrib/it-prefs SETTINGS): the key and the binary that reads it. The iPod build
    /// (IT_PREFS_TIP_ONLY), and the bake that stands in for it on 2.x/3.0, set only the first.
    public static let itPrefs = [("SBDidShowReorderText", "System/Library/CoreServices/SpringBoard.app/SpringBoard"),
                                 ("AppleLocationServer", "usr/libexec/locationd"), ("AppleLocationServerRequiresCert", "usr/libexec/locationd")]

    /// One Fit per setting: the reader names the key, by it_prefs' own rule (the key and its NUL anywhere in the
    /// file), so the prepare knows what it_prefs will set at boot instead of finding out on the guest console.
    public static func prefs(_ fw: Firmware, _ settings: [(String, String)]) -> [Fit] {
        settings.map { key, reader in
            let piece = "it_prefs \(key)", name = (reader as NSString).lastPathComponent
            guard fw.resolve(reader) != nil else { return Fit(piece, fits: false, "no \(reader) on this firmware") }
            return fw.file(reader, contains: Data((key + "\0").utf8)) ? Fit(piece, fits: true, "\(name) names \(key)")
                : Fit(piece, fits: false, "\(name) does not name \(key): the setting reaches nothing")
        }
    }
}
