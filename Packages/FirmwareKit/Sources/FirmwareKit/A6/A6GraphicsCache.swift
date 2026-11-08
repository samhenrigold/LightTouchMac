import Foundation

/// Later dyld requires a development cache as well as the existing override
/// marker before selecting the installed OpenGLES support framework.
public enum A6GraphicsCache {
    public static func prepare(_ original: Data, build: String) throws -> Data {
        guard build == "14G61" else { return original }
        let uuid = Data([0xe2, 0x55, 0x3b, 0x54, 0x10, 0x5e, 0x3d, 0x2e,
                         0xbf, 0xec, 0x9f, 0x01, 0x56, 0xd9, 0x6c, 0x11])
        guard original.count >= 112, original.subdata(in: 88..<104) == uuid,
              original[104] <= 1, original[105..<112].allSatisfy({ $0 == 0 }) else {
            throw FirmwareError(.unsupported, "N42 graphics: unrecognized 14G61 shared cache")
        }
        if original[104] == 0 { return original }
        var result = original
        result.replaceSubrange(104..<112, with: Data(count: 8))
        // Retain every framework instruction and refresh only existing signed
        // page hashes. A6GuestAssets admits the resulting exact cache identity.
        return try DyldSharedCache(data: result).rehashingCodeSignature()
    }
}
