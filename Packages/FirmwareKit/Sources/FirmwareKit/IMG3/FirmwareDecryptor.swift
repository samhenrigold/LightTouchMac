// FirmwareDecryptor: ipad1_fw.main. Decrypts an IPSW's boot chain, kernelcache, ramdisks and rootfs into a
// directory laid out like the Python decrypt cache:
//   iBSS.bin iBEC.bin iBoot.bin LLB.bin DeviceTree.bin AppleLogo.bin kernelcache.mach
//   <RestoreRamDisk>-ramdisk.dmg <UpdateRamDisk>-ramdisk.dmg rootfs.dmg (vfdecrypted UDIF)
//
//   let r = try FirmwareDecryptor.decrypt(ipsw: ipsw, entry: entry, into: dir)   // r.plainTail: 2.x img3s
//   try FirmwareDecryptor.decrypt(ipsw: ipsw, entry: entry, into: dir, rootfs: false)
//
// The tail convention (3.x+: the final partial AES block is encrypted into the tag padding; 2.x: left in
// plaintext) is decided on the kernelcache, the one component with a checksum: if its complzss length or
// Adler-32 fails with the padded decrypt, every img3 of the IPSW is decrypted with a plaintext tail.

import Foundation

public enum FirmwareDecryptor {
    /// Output name -> BuildManifest component.
    public static let components = [("iBSS", "iBSS"), ("iBEC", "iBEC"), ("iBoot", "iBoot"), ("LLB", "LLB"),
                                    ("DeviceTree", "DeviceTree"), ("AppleLogo", "AppleLogo"), ("Kernelcache", "KernelCache")]

    public struct Result: Sendable {
        public var plainTail: Bool
        /// Component -> IPSW path.
        public var paths: [String: String]
        /// Output file names written, in order.
        public var files: [String]
    }

    public static func decrypt(ipsw url: URL, entry: FirmwareEntry, into dir: URL, rootfs: Bool = true) throws -> Result {
        let ipsw = IPSWArchive(url)
        let comp = try BuildComponents.load(ipsw)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        func path(_ c: String) throws -> String {
            guard let p = comp[c] else { throw FirmwareError(.unsupported, "\(entry.id): the IPSW names no \(c)") }
            return p
        }
        func img3Key(_ p: String) throws -> (iv: Data, key: Data) {
            let k = try entry.key(forPath: p)
            guard let ivHex = k.iv, let iv = Data(hex: ivHex), let key = Data(hex: k.key) else {
                throw FirmwareError(.keyMissing, "\(entry.id): no IV/key for \(k.file)")
            }
            return (iv, key)
        }
        func dec(_ p: String, plainTail: Bool) throws -> Data {
            let (iv, key) = try img3Key(p)
            return try IMG3.decrypt(ipsw.read(p), iv: iv, key: key, plainTail: plainTail)
        }

        let kcPath = try path("KernelCache")
        let kcRaw = try ipsw.read(kcPath), (kcIV, kcKey) = try img3Key(kcPath)
        var plainTail = false
        var kernel: Data
        do {
            kernel = try LZSS.complzss(IMG3.decrypt(kcRaw, iv: kcIV, key: kcKey))
        } catch {
            plainTail = true
            kernel = try LZSS.complzss(IMG3.decrypt(kcRaw, iv: kcIV, key: kcKey, plainTail: true))
        }

        var files: [String] = []
        for (name, c) in components {
            if c == "KernelCache" {
                try kernel.write(to: dir.appendingPathComponent("kernelcache.mach"))
                files.append("kernelcache.mach")
            } else {
                try dec(try path(c), plainTail: plainTail).write(to: dir.appendingPathComponent("\(name).bin"))
                files.append("\(name).bin")
            }
        }
        for c in ["RestoreRamDisk", "UpdateRamDisk"] {
            guard let p = comp[c] else { continue }
            let out = String(p.dropLast(4)) + "-ramdisk.dmg"
            try dec(p, plainTail: plainTail).write(to: dir.appendingPathComponent(out))
            files.append(out)
        }
        if rootfs {
            let os = try path("OS")
            let k = try entry.key(forPath: os)
            guard let key = Data(hex: k.key), key.count == 36 else { throw FirmwareError(.keyMissing, "\(entry.id): no key for the root filesystem \(os)") }
            let out = dir.appendingPathComponent("rootfs.dmg")
            try ipsw.stream(os) { try VFDecrypt.decrypt(from: $0.fileDescriptor, output: out, key: key) }
            files.append("rootfs.dmg")
        }
        return Result(plainTail: plainTail, paths: comp, files: files)
    }
}
