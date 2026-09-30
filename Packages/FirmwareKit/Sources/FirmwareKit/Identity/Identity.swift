// Identity: a synthetic unit identity (serial, MLB, ECID, die-id, MACs) as a pure function of a seed, and
// lockdownd's UDID. Ports ipad1_kboot.synth_identity/udid and ipod2g_device.identity.
//
//   let id = UnitIdentity.synthesize(seed: "ipad1-7B500-default", storage: "16g")    // iPad 1 (k48ap)
//   let pod = UnitIdentity.synthesizeIPod(seed: s, modelNumber: "MC086", regionInfo: "LL/A")   // n72ap
//   id["udid"], id.udid                         // SHA1(serial + Wi-Fi MAC + BT MAC), MACs lowercase
//   UnitIdentity.udid(serial:wifiMAC:btMAC:)
//   id.json()                                   // byte-identical to Python's json.dump(ident, f, indent=1)
//   try id.write(to: url)                       // O_EXCL, mode 600
//   try UnitIdentity.load(from: url)            // an identity.json (keys sorted), e.g. to build kboot.bin
//
// Fields keep Python's insertion order, which is what makes json() match. A value is a string or a list
// of strings (die-id).

import CryptoKit
import Foundation

public struct UnitIdentity: Equatable, Sendable {
    public enum Value: Equatable, Sendable { case string(String), list([String]) }
    public private(set) var fields: [(key: String, value: Value)]

    public init(fields: [(key: String, value: Value)]) { self.fields = fields }

    public static func == (a: UnitIdentity, b: UnitIdentity) -> Bool {
        a.fields.map(\.key) == b.fields.map(\.key) && a.fields.map(\.value) == b.fields.map(\.value)
    }

    public subscript(key: String) -> String? {
        guard case .string(let s)? = fields.first(where: { $0.key == key })?.value else { return nil }
        return s
    }

    public var dieID: [String]? {
        guard case .list(let l)? = fields.first(where: { $0.key == "die-id" })?.value else { return nil }
        return l
    }

    public var udid: String? { self["udid"] }

    static let serialChars = Array("0123456789ABCDEFGHJKLMNPQRSTUVWXYZ")   // no I or O, as Apple serials
    /// Wi-Fi iPad 1 model numbers by storage (the only NAND geometry modelled is 16 GB).
    public static let iPadModels = ["16g": "MB292"]
    public static let iPadRegion = "LL/A"

    public static func udid(serial: String, wifiMAC: String, btMAC: String) -> String {
        Data(Insecure.SHA1.hash(data: Data((serial + wifiMAC.lowercased() + btMAC.lowercased()).utf8))).hexString
    }

    /// A made-up but well-formed iPad 1 identity: 11-character serial, 13-character MLB, 40-bit ECID, two
    /// die-id words, a locally administered Wi-Fi MAC (02:...) and Bluetooth = Wi-Fi + 1.
    public static func synthesize(seed: String, storage: String = "16g") throws -> UnitIdentity {
        guard let model = iPadModels[storage] else { throw FirmwareError(.unsupported, "no iPad 1 model for storage \(storage)") }
        let h = Array(SHA256.hash(data: Data(seed.utf8)))
        let chars = { (from: Int, n: Int) in String(h[from..<from + n].map { serialChars[Int($0) % serialChars.count] }) }
        let wifi = [0x02] + h[28..<32] + [h[27] & 0xFE]          // even last byte: BT = +1 never carries
        let bt = Array(wifi[0..<5]) + [wifi[5] + 1]
        let beInt = { (b: [UInt8]) in b.reduce(UInt64(0)) { $0 << 8 | UInt64($1) } }
        let ecid = beInt(Array(h[20..<25])) | 1
        // SecureROM builds ECID from CHIPID words 2/3 and CPRV from bits 10..15 of word 3 (revision 0x11);
        // derive the die-id words from the ECID so the ROM-advertised identity agrees (ipad1_kboot.synth_identity,
        // qemu-ios ff331e1ef9). die-id[1]'s high 16 bits keep the original h[2:6] value.
        let dieLo = beInt(Array(h[2..<6]))
        let word2 = ((ecid >> 21) & 0x1FFFFF) | (((ecid >> 16) & 31) << 21) | (((ecid >> 2) & 63) << 26)
        let word3 = (dieLo & 0xFFFF_0000) | 0x2400 | (((ecid >> 8) & 255) << 2) | (ecid & 3)
        var id = UnitIdentity(fields: [
            ("serial-number", .string(chars(0, 11))), ("mlb-serial-number", .string(chars(11, 13))),
            ("unique-chip-id", .string(String(format: "0x%010llx", ecid))),
            ("die-id", .list([String(format: "0x%08llx", word2), String(format: "0x%08llx", word3)])),
            ("wifi-mac", .string(mac(wifi))), ("bt-mac", .string(mac(bt))),
            ("model-number", .string(model)), ("region-info", .string(iPadRegion)), ("seed", .string(seed)),
        ])
        id.fields.append(("udid", .string(udid(serial: id["serial-number"]!, wifiMAC: id["wifi-mac"]!, btMAC: id["bt-mac"]!))))
        return id
    }

    /// The iPod touch 2G identity: the iPad's serial and MACs plus a 12-digit battery serial; model and
    /// region are the recipe's. `bluetooth: false` is the 1G, which has no Bluetooth: no bt-mac, and lockdownd's
    /// UDID hashes an empty BT address (SHA1(serial + Wi-Fi MAC)).
    public static func synthesizeIPod(seed: String, modelNumber: String, regionInfo: String, bluetooth: Bool = true) throws -> UnitIdentity {
        let base = try synthesize(seed: seed)
        let h = Array(SHA256.hash(data: Data(("battery:" + seed).utf8)))
        var id = UnitIdentity(fields: [("serial-number", .string(base["serial-number"]!)), ("wifi-mac", .string(base["wifi-mac"]!))]
            + (bluetooth ? [("bt-mac", .string(base["bt-mac"]!))] : []) + [
            ("battery-serial", .string(h[0..<12].map { String($0 % 10) }.joined())),
            ("model-number", .string(modelNumber)), ("region-info", .string(regionInfo)), ("seed", .string(seed)),
        ])
        id.fields.append(("udid", .string(bluetooth ? base["udid"]! : udid(serial: base["serial-number"]!, wifiMAC: base["wifi-mac"]!, btMAC: ""))))
        return id
    }

    static func mac(_ b: [UInt8]) -> String { b.map { String(format: "%02x", $0) }.joined(separator: ":") }

    /// Python's json.dump(obj, f, indent=1) (ensure_ascii, no trailing newline).
    public func json() -> Data {
        func q(_ s: String) -> String {
            var o = "\""
            for u in s.utf16 {
                switch u {
                case 0x22: o += "\\\""
                case 0x5C: o += "\\\\"
                case 0x0A: o += "\\n"
                case 0x0D: o += "\\r"
                case 0x09: o += "\\t"
                case 0x08: o += "\\b"
                case 0x0C: o += "\\f"
                case 0x20...0x7E: o.unicodeScalars.append(Unicode.Scalar(u)!)
                default: o += String(format: "\\u%04x", u)
                }
            }
            return o + "\""
        }
        let body = fields.map { k, v -> String in
            switch v {
            case .string(let s): return " \(q(k)): \(q(s))"
            case .list(let l): return l.isEmpty ? " \(q(k)): []" : " \(q(k)): [\n" + l.map { "  " + q($0) }.joined(separator: ",\n") + "\n ]"
            }
        }
        return Data((fields.isEmpty ? "{}" : "{\n" + body.joined(separator: ",\n") + "\n}").utf8)
    }

    public func write(to url: URL) throws {
        let fd = open(url.path, O_WRONLY | O_CREAT | O_EXCL, 0o600)
        guard fd >= 0 else { throw FirmwareError(.internal, "create \(url.path): \(String(cString: strerror(errno)))") }
        let h = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        try h.write(contentsOf: json())
        try h.close()
    }

    /// An identity.json (any key order; strings and string lists only).
    public static func load(from url: URL) throws -> UnitIdentity {
        let data = try Data(contentsOf: url)
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw FirmwareError(.unsupported, "\(url.lastPathComponent) is not a JSON object")
        }
        return UnitIdentity(fields: try obj.keys.sorted().map { k in
            switch obj[k] {
            case let s as String: return (k, .string(s))
            case let l as [String]: return (k, .list(l))
            default: throw FirmwareError(.unsupported, "\(url.lastPathComponent): \(k) is not a string or a list of strings")
            }
        })
    }
}
