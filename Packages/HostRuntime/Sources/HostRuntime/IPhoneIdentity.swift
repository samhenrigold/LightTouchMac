import CryptoKit
import Foundation

/// An iPhone's IMEI and UDID as pure functions of the unit's identity seed, shared by FirmwareKit (which writes them
/// into identity.json and the lock) and the boot path (which derives them for bases prepared before they were recorded).
///
/// The IMEI: TAC 00000000 (assigned to no manufacturer, so it can't collide with a real phone), six digits from the
/// seed, and the Luhn digit. lockdownd (1.x-4.x) and MobileGestalt (5.x on) hash it into the UDID:
/// SHA1(serial + IMEI + Wi-Fi MAC + BT MAC), MACs lowercase. 5.x reports ffff... when no modem answers with one.
public enum IPhoneIdentity {
    public static let syntheticTAC = "00000000"

    public static func imei(seed: String) -> String {
        let h = Array(SHA256.hash(data: Data(("imei:" + seed).utf8)))
        let body = syntheticTAC + h[0..<6].map { String($0 % 10) }.joined()
        return body + String(luhn(body))
    }

    public static func udid(serial: String, imei: String, wifiMAC: String, btMAC: String) -> String {
        Insecure.SHA1.hash(data: Data((serial + imei + wifiMAC.lowercased() + btMAC.lowercased()).utf8))
            .map { String(format: "%02x", $0) }.joined()
    }

    /// iPhone 5 (n42ap) hashes the decimal ECID instead of the IMEI: SHA1(serial + decimal(ECID) + Wi-Fi MAC + BT MAC).
    public static func ecidUDID(serial: String, ecid: UInt64, wifiMAC: String, btMAC: String) -> String {
        Insecure.SHA1.hash(data: Data((serial + String(ecid) + wifiMAC.lowercased() + btMAC.lowercased()).utf8))
            .map { String(format: "%02x", $0) }.joined()
    }

    /// The ECID-based UDID from a base's identity.json (used for n42ap, including bases prepared before it was recorded).
    public static func ecidUDID(from identity: [String: Any]) -> String? {
        guard let serial = identity["serial-number"] as? String, let wifi = identity["wifi-mac"] as? String,
            let bt = identity["bt-mac"] as? String
        else { return nil }
        let ecid: UInt64? =
            if let hex = identity["unique-chip-id"] as? String {
                UInt64(hex.hasPrefix("0x") ? String(hex.dropFirst(2)) : hex, radix: 16)
            } else {
                (identity["seed"] as? String).map(UnitSeed.ecid(seed:))
            }
        return ecid.map { ecidUDID(serial: serial, ecid: $0, wifiMAC: wifi, btMAC: bt) }
    }

    /// The Luhn check digit of a digit string (an IMEI's fifteenth).
    public static func luhn(_ digits: String) -> Int {
        let sum = digits.reversed().enumerated().reduce(0) { s, e in
            let d = e.element.wholeNumberValue ?? 0
            return s + (e.offset % 2 == 0 ? (d * 2 > 9 ? d * 2 - 9 : d * 2) : d)
        }
        return (10 - sum % 10) % 10
    }

    /// A base's identity.json fields with the IMEI and its UDID filled in when the base predates them (recipe 1);
    /// nil when it lacks what the UDID needs.
    public static func upgraded(_ identity: [String: Any]) -> (imei: String, udid: String)? {
        guard let serial = identity["serial-number"] as? String, let wifi = identity["wifi-mac"] as? String,
            let bt = identity["bt-mac"] as? String
        else { return nil }
        let imei = identity["imei"] as? String ?? (identity["seed"] as? String).map(imei(seed:))
        return imei.map { ($0, udid(serial: serial, imei: $0, wifiMAC: wifi, btMAC: bt)) }
    }
}

/// What a unit's identity seed decides beyond the IMEI, shared by FirmwareKit's UnitIdentity (which writes it into
/// identity.json) and DeviceLock (which derives it for bases whose identity predates the field).
public enum UnitSeed {
    /// The 40-bit ECID: SHA-256(seed) bytes 20..<25, odd.
    public static func ecid(seed: String) -> UInt64 {
        Array(SHA256.hash(data: Data(seed.utf8)))[20..<25].reduce(UInt64(0)) { $0 << 8 | UInt64($1) } | 1
    }
    /// As identity.json and the machine's ecid option write it.
    public static func ecid(seed: String) -> String { String(format: "0x%010llx", ecid(seed: seed) as UInt64) }
}
