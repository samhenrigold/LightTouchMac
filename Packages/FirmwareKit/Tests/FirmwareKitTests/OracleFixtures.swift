// Oracle fixtures. Inputs are read from ~/Downloads, ~/Developer and ~/Developer/qemu-ios-files and a test
// skips when its input is absent; outputs go to temp dirs only. Expected values are sha256 digests of the
// Python oracle's outputs (qemu-ios imgtools: ipad1_fw.py at ipod-ipsw e6de24c7fa, ipad1_kboot.py and
// ipad1_rootfs.extract_rootfs at ipad1 5f365778a4), never the Apple-derived bytes themselves.

import CryptoKit
import Foundation
import Testing
@testable import FirmwareKit

enum Oracle {
    static let home = FileManager.default.homeDirectoryForCurrentUser
    static func path(_ p: String) -> URL { home.appendingPathComponent(p) }
    static func exists(_ u: URL) -> Bool { FileManager.default.fileExists(atPath: u.path) }
    /// The qemu-ios checkout whose imgtools and guest builds are the oracle (FIRMWAREKIT_QEMU_IOS overrides).
    static let qemuIOS = ProcessInfo.processInfo.environment["FIRMWAREKIT_QEMU_IOS"].map { URL(fileURLWithPath: $0) }
        ?? path("Developer/qemu-ios-ipad1")
    /// Where armv6.itpack / armv7.itpack are: FIRMWAREKIT_GUEST_TOOLS (an export's ipad-guest-tools), else the
    /// checkout's contrib/guest-package/build.sh output.
    static let guestPackages = ProcessInfo.processInfo.environment["FIRMWAREKIT_GUEST_TOOLS"].map { URL(fileURLWithPath: $0) }
        ?? qemuIOS.appendingPathComponent("build/guest-package")

    /// The app's catalog, in this repo.
    static let catalog = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("LightTouchMac/Resources/firmware-catalog.json")

    static func entry(_ id: String) throws -> FirmwareEntry {
        struct Catalog: Decodable { var entries: [FirmwareEntry] }
        let c = try JSONDecoder().decode(Catalog.self, from: Data(contentsOf: catalog))
        guard let e = c.entries.first(where: { $0.id == id }) else { throw FirmwareError(.unsupported, "no catalog entry \(id)") }
        return e
    }

    struct Firmware: Sendable, CustomTestStringConvertible {
        var entryID: String
        var ipsw: URL
        /// The Python decrypt cache for this IPSW, when there is one.
        var cache: URL?
        /// sha256 of each ipad1_fw.py output file.
        var components: [String: String]
        var rootfsDMG: String
        var rawVolume: String
        var testDescription: String { entryID }
        var available: Bool { Oracle.exists(ipsw) }
    }

    static let ipadCache = path("Developer/qemu-ios-files/ipad1/repro/cache")
    static let ipodCache = path("Developer/qemu-ios-files/ipod-ipsw/cache")
    static let feasibility = "Downloads/ipad1-ios32-feasibility/"

    static let firmwares: [Firmware] = [
        Firmware(entryID: "k48ap-7B500", ipsw: path(feasibility + "iPad1,1_3.2.2_7B500_Restore.ipsw"),
                 cache: ipadCache.appendingPathComponent("68b613f78581d36eab96aa5a007001dff142baa3"), components: [
                    "018-8374-001-ramdisk.dmg": "1c8f4fbea68287093350cc5b749116289bc7927ed420035408ce73afbf0a8b04",
                    "018-8375-001-ramdisk.dmg": "521e5fa0039c3162f0ada3eccac0676cab9c80dcba82d7ea7892445616eefc7e",
                    "AppleLogo.bin": "877fb296ed1c61497c97f8b4b4f3ab1b027841668bd694f5fa18016d20787cb8",
                    "DeviceTree.bin": "9de2afd0a9b4fafac86402c2a2b65cfb126ac14d5f6472eef1136b6557300dc2",
                    "iBEC.bin": "49f1ac84f65ff7010423f3df4df2af6ad54ecf4b9463aef98ac6d6a507a39a51",
                    "iBoot.bin": "77451ef5efb8ba35f210b5d57fb68660156678c9d57194428dfb43c293d7f04c",
                    "iBSS.bin": "058cf81fe887245a9443df47eb9da4db1265d43b626642de1687b269f315bac7",
                    "kernelcache.mach": "bb3e9f016de957509ea19550d7812c37a7951f2699afad88de253501a54bf317",
                    "LLB.bin": "8356b7f064504b8beca865d8a109541d1b3ebbc741461db5f128d9cd16701ece"],
                 rootfsDMG: "72b73e6e01d700be9c7444c3f706c5f55a6fadbbc88bc6ab2c1bbc9717a92537",
                 rawVolume: "21e9fd48be0aca57a26fc794d1df8d86a06b32f538f6aa938481a1c38ce3645c"),
        Firmware(entryID: "k48ap-7B367", ipsw: path(feasibility + "iPad1,1_3.2_7B367_Restore.ipsw"), cache: nil, components: [
                    "018-7225-009-ramdisk.dmg": "b52c6ceb58d3f89fd1bc330bc0c79b603fcb71c5ba9b6ec95e5bd6dab0163f5e",
                    "018-7226-009-ramdisk.dmg": "9697baa025239109d3bb3319033144bce031f98d22ccc4eda1d2a418b724477d",
                    "AppleLogo.bin": "877fb296ed1c61497c97f8b4b4f3ab1b027841668bd694f5fa18016d20787cb8",
                    "DeviceTree.bin": "ea8bbc2029ced9dbbaa297a9264c0af4da86e9065b7192c73fd7702018f82038",
                    "iBEC.bin": "ddd3785bc18929d523f8947c7b8b1d6fe3a62a202d23c5d98ee3d246430ee2e3",
                    "iBoot.bin": "e705c34b9ebcb1245cdd431b9245fbe0317c66a6994bf579ffc29cfc2483a2f8",
                    "iBSS.bin": "be4fef1685d6345f7dfc59e2fdbec4a78f62144d133313c2aed6b6414b243e66",
                    "kernelcache.mach": "fd951a7787020ecbb90b1ce216da3e68564468aa2e2822ba84749b3871e354b6",
                    "LLB.bin": "b39ef1ed9b2c4316e8ebeb2b2602cacb729ed7c10ce0d1a598fd1eca1ac6654b"],
                 rootfsDMG: "4755c36c859956e438658e2021b1e1df16d3756a055d153f9c4bb957f6dc91c6",
                 rawVolume: "12acac9e9845f442bfe77a8f7f7916b65948a0bd2b2ae03c51f314b549817198"),
        Firmware(entryID: "k48ap-8C148", ipsw: path(feasibility + "iPad1,1_4.2.1_8C148_Restore.ipsw"),
                 cache: ipadCache.appendingPathComponent("8717b3bedc925b587566442ad375aa65d857e79a"), components: [
                    "038-0024-002-ramdisk.dmg": "1c6d6abb43a72a673d9467489fb2a5723ec82566f0acb8b15ed1de86afd9e124",
                    "038-0032-002-ramdisk.dmg": "67abcbe1a97d0248e64ba61103456ac55b78ee092462d2c09857be0ef1c5eb01",
                    "AppleLogo.bin": "72bca0a6353de33cfde3b23b3ee2a112a37fac6e2af659082b1b33c2d86e9c1d",
                    "DeviceTree.bin": "f2edd564dd5180dbad323154333be461467c7d5364dc59adea752cb0ef8d008d",
                    "iBEC.bin": "187e41710db7726cdc1b62fa37801370f32c328f935c32944d227ef68ae58b31",
                    "iBoot.bin": "727a74a9777de646aa043dc9b1c6929543213f10c8a5e957ffb88ad644a47e56",
                    "iBSS.bin": "f326f29088ce83eef0fe716322c948312abd7b552d15978e1b5f8702cd3ae171",
                    "kernelcache.mach": "de990d9ced571b5a75c07e6cc277fe04d7f87bb279a607f267591500391c9026",
                    "LLB.bin": "365b422c7ee4d990fea4f45f6238b7a1a063a3d9b369553b8e8c925254342a3b"],
                 rootfsDMG: "bb7ab7cc2d545669021627d6779eb6d6448d8529d32a965f965dd67c1fdc4697",
                 rawVolume: "c111624aaf85bc627ee55111dd3cac8dd7a05152cd47fb7e2ac2cdcdc58a1ab6"),
        Firmware(entryID: "n72ap-8C148", ipsw: path("Downloads/ios4/iPod2,1_4.2.1_8C148_Restore.ipsw"),
                 cache: ipodCache.appendingPathComponent("b9efddc7bb4350c237a8d3846af61bbfc8a2f647"), components: [
                    "038-0049-002-ramdisk.dmg": "fff4d7c41babe5b4e38c4cd3371b6a6b08da18309c3cc0bbe6a206e0e9413598",
                    "038-0050-002-ramdisk.dmg": "015bc6a526a7d52aae22fe7c134c8bf1dd2722c5eb9966eb5fd58b700a2aab68",
                    "AppleLogo.bin": "72bca0a6353de33cfde3b23b3ee2a112a37fac6e2af659082b1b33c2d86e9c1d",
                    "DeviceTree.bin": "40d07f28c28f979a28f620335948784350110c81892ac5dd8b51c161265d97c1",
                    "iBEC.bin": "206d0e493258a23003a6ccc4f0dbbd684a73159c93cc46a8bfe5a3ddb2f315a4",
                    "iBoot.bin": "a0da587db8c16dbe523b0d458cdd9a631ba99c3e93dba3a1480afa81f19e4e91",
                    "iBSS.bin": "1b73bfb59d818fcd1622735abeb5c154cc5355b756b9313c9b8229408838ec95",
                    "kernelcache.mach": "93ccc8e1da0ea65201859627693b5100f4e659554b37e63a3c6988602153d42f",
                    "LLB.bin": "1c0e6ffbfd29c793d928a21e962eaf8748061c73cc29949f084db50e330216a9"],
                 rootfsDMG: "2ffb29128ad6c5a72fffca5b603fa5e393fb806928e51431b11ca7d84b01ff93",
                 rawVolume: "7a34c1a30cb24188c258dc9f041db290af9a41332c57e322f3b16ef6f94b0969"),
        Firmware(entryID: "n72ap-7E18", ipsw: path("Developer/ipod2g-re/OldSDK/iPod2,1_3.1.3_7E18_Restore.ipsw"),
                 cache: ipodCache.appendingPathComponent("5f4f5c01eda2f811f73167e7d1f82dbeed82367b"), components: [
                    "018-6508-014-ramdisk.dmg": "6c74426d3c74c9d800d83ff493387312206733bf1c369d42bf6da2b99a5d223e",
                    "018-6509-015-ramdisk.dmg": "594914824ffb2caa25d4a6469e99d469fa0a575639cd883938df7b3a462ad130",
                    "AppleLogo.bin": "3e3d4095a241e83f651ed5c71ad40410bda936ffccb5a2448aa8ef099473b1b5",
                    "DeviceTree.bin": "da37ebd94bea4ea2d944cf512b2e7ee3168b21d3847e1bf0a8efaa0d4d402d09",
                    "iBEC.bin": "3ad9abaf169dedf1f3f91e20e4e63cfab15d81bb927425736d21497398d49690",
                    "iBoot.bin": "9337ac9381669f29dc7086244c6e63e1714c3c37457947602734d4446ff21f8b",
                    "iBSS.bin": "f65852f107c6f1a678f77144d75d750df1c2affaf7e62ed2194dda9e1e204004",
                    "kernelcache.mach": "8caf1738b15fe4df99ddebb1f976b8582364af27ef738b93dcac60be1b26c63e",
                    "LLB.bin": "132f2213afb9e817e080684e6453c00352a9541f7ff6aee1436481f01c5f7d38"],
                 rootfsDMG: "8ec6d1c00a4b360e1d62d99e393253d50e74a8603bd36284a929bf5863ec03c4",
                 rawVolume: "7cfde0d4192c7b32490c16267bf0497b8ce82dbf277283a8da9aa3924ded2786"),
        Firmware(entryID: "n72ap-5F138", ipsw: path("Downloads/ios2/iPod2,1_2.1.1_5F138_Restore.ipsw"),
                 cache: ipodCache.appendingPathComponent("c3c700be49ad227d1152188e7c1e46b8958fd1e4"), components: [
                    "018-4166-1-ramdisk.dmg": "c1a982ea93dd6315cac91c45f55c61b360913196265ee4c9f146d3527f15734f",
                    "018-4177-1-ramdisk.dmg": "05795d76755420f7b5e60cfe0ff777dbc409f6c28d950efc85d1a70d98b6d6b6",
                    "AppleLogo.bin": "3e3d4095a241e83f651ed5c71ad40410bda936ffccb5a2448aa8ef099473b1b5",
                    "DeviceTree.bin": "ffefdaa6f0cfdb433204b9e9314fdbb3dc1d64888d9f2ae54351a4aab3fc0a38",
                    // 2.x DFU stages carry no KBAG: the payload is copied as-is (Python "decrypted" it with a
                    // placeholder key into noise); these are the plaintext payloads' hashes (docs/matrix.md).
                    "iBEC.bin": "b9c74d685bc8c3340ef1e8fe16895d991387f06a478a5497d98d61e1d25ed86b",
                    "iBoot.bin": "4c2ec4ea8b8c9ef93548275bfc0f44b447315b8b9631bfeeb147721a2f834b3d",
                    "iBSS.bin": "ffa508c1e88dc353ab331d1af990174ac9ed0543074cc04f6dce302648acda27",
                    "kernelcache.mach": "20fa129653ad4094ce4fd885ddd1477e0ee175137c48898277c8ca7bfc3dd33f",
                    "LLB.bin": "8657a7601ddf867549632b3a2744caab8f154d5c569cc38626cc2fd944d19c61"],
                 rootfsDMG: "e5eea56355c191df9e539fd2957a026325590fca393361c99e551d3fabf5fbd1",
                 rawVolume: "25876ecc24259028d67978b04ea4baf446d305f7f56790565f637671c3bbf796"),
    ]

    static func firmware(_ id: String) -> Firmware { firmwares.first { $0.entryID == id }! }

    /// A fresh temp dir, removed after `body`.
    static func withTemp<T>(_ body: (URL) throws -> T) throws -> T {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("FirmwareKitTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        return try body(dir)
    }

    nonisolated(nonsending) static func withTemp<T>(_ body: (URL) async throws -> T) async throws -> T {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("FirmwareKitTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        return try await body(dir)
    }

    static func sha256(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }

    static func sha256(file: URL) throws -> String {
        let h = try FileHandle(forReadingFrom: file)
        defer { try? h.close() }
        var sha = SHA256()
        while let chunk = try h.read(upToCount: 1 << 22), !chunk.isEmpty { sha.update(data: chunk) }
        return sha.finalize().map { String(format: "%02x", $0) }.joined()
    }

    static func time<T>(_ label: String, _ body: () throws -> T) rethrows -> T {
        let t0 = ContinuousClock.now
        defer { print("timing: \(label) \(ContinuousClock.now - t0)") }
        return try body()
    }
    nonisolated(nonsending) static func time<T>(_ label: String, _ body: () async throws -> T) async rethrows -> T {
        let t0 = ContinuousClock.now
        defer { print("timing: \(label) \(ContinuousClock.now - t0)") }
        return try await body()
    }

}
