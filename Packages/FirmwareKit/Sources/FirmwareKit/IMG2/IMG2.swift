// iPhone OS 1.x containers: every IPSW component is an 8900 container, and the all_flash images inside are IMG2.
//
//   try Apple8900.body(data)      // 8900 v1.0: format 3 is AES-128-CBC under the public key 0x837, format 4 plaintext
//   try IMG2.Header(body)         // "2gmI": type, load address, data length; body[0x400...] is the payload
//   try IMG2.payload(body)        // the plaintext image (iBoot-204 as the machine runs it)
//
// 2.0 moved to IMG3, so FirmwareDecryptor tells the two apart by the first four bytes.

import Foundation

public enum Apple8900 {
    static let magic = Data("8900".utf8), headerSize = 0x800
    /// The S5L8900's key 0x837, what the bootrom's 8900 engine decrypts format-3 containers with.
    static let key837 = Data(hex: "188458A6D15034DFE386F23B61D43774")!

    public static func isContainer(_ d: Data) -> Bool { d.prefix(4) == magic }

    /// The payload, decrypted when the container says so. A final partial block is stored in the clear.
    public static func body(_ d: Data) throws -> Data {
        let b = [UInt8](d.prefix(headerSize))
        guard b.count == headerSize, isContainer(d), b[4..<7].elementsEqual("1.0".utf8) else { throw FirmwareError(.unsupported, "not an 8900 v1.0 container") }
        let size = Int(b.u32(0xC)), start = d.startIndex + headerSize
        guard start + size <= d.endIndex else { throw FirmwareError(.unsupported, "8900 payload runs past the file") }
        let body = d[start..<start + size]
        switch b[7] {
        case 4: return Data(body)
        case 3:
            let n = size & ~15
            return try AESCBC.crypt(body.prefix(n), iv: Data(count: 16), key: key837) + body.dropFirst(n)
        default: throw FirmwareError(.unsupported, "8900 format \(b[7]) (only 3, encrypted, and 4, plain, are known)")
        }
    }
}

public enum IMG2 {
    public static let headerSize = 0x400

    public struct Header: Equatable, Sendable {
        /// "ibot", "dtre", "logo", ... (stored reversed, as IMG3 types are).
        public var type: String
        public var loadAddress: UInt32
        public var paddedLength: Int, dataLength: Int
        public init(_ body: Data) throws {
            let b = [UInt8](body.prefix(headerSize))
            guard b.count == headerSize, b[0..<4].elementsEqual("2gmI".utf8) else { throw FirmwareError(.unsupported, "not an IMG2 image") }
            type = String(decoding: b[4..<8].reversed(), as: UTF8.self)
            loadAddress = b.u32(0xC); paddedLength = Int(b.u32(0x10)); dataLength = Int(b.u32(0x14))
            guard dataLength <= paddedLength, headerSize + paddedLength <= body.count else { throw FirmwareError(.unsupported, "IMG2 \(type) data runs past the image") }
        }
    }

    public static func payload(_ body: Data) throws -> Data {
        let h = try Header(body), s = body.startIndex + headerSize
        return Data(body[s..<s + h.dataLength])
    }
}
