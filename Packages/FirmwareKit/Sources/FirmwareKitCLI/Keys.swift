// firmwarekit verify-keys --entry ENTRY.json --ipsw IPSW
//
// Decrypts every keyed component of the entry from the IPSW and judges the plaintext: an img3 with the wrong key
// decrypts to noise, so each kind is checked for what it must contain (the kernelcache's complzss checksum, an
// HFS+ ramdisk, an iBootIm image, the device tree's first property, a boot stage's own name; the root
// filesystem's UDIF trailer). One JSON line per key: {component, file, ok, why}; exit 1 if any is not ok.
// This is how a key gets into the catalog (docs/matrix.md).

import FirmwareKit
import Foundation

func verifyKeysCommand(_ argv: [String]) -> Never {
    var flags: [String: String] = [:]
    var rest = argv[...]
    while let a = rest.popFirst() {
        guard ["--entry", "--ipsw"].contains(a), let v = rest.popFirst() else { FileHandle.standardError.write(Data("bad argument \(a)\n".utf8)); exit(64) }
        flags[a] = v
    }
    guard let entryPath = flags["--entry"], let ipswPath = flags["--ipsw"] else {
        FileHandle.standardError.write(Data("verify-keys: --entry and --ipsw are required\n".utf8)); exit(64)
    }
    let url = { (p: String) in URL(fileURLWithPath: (p as NSString).expandingTildeInPath).standardizedFileURL }
    func line(_ o: [String: Any]) {
        FileHandle.standardOutput.write(try! JSONSerialization.data(withJSONObject: o, options: [.sortedKeys]) + Data("\n".utf8))
    }
    var allOK = true
    do {
        let entry = try FirmwareEntry.load(from: url(entryPath))
        let ipsw = IPSWArchive(url(ipswPath))
        let names = try ipsw.names()
        // 2.x img3s leave the last partial AES block in plaintext; decided once on the kernelcache as the decryptor does.
        var plainTail = false
        if let kc = entry.keys["kernelcache"], let m = names.first(where: { ($0 as NSString).lastPathComponent == kc.file }),
           let iv = kc.iv.flatMap({ Data(hex: $0) }), let key = Data(hex: kc.key) {
            let raw = try ipsw.read(m)
            if (try? LZSS.complzss(IMG3.decrypt(raw, iv: iv, key: key))) == nil,
               (try? LZSS.complzss(IMG3.decrypt(raw, iv: iv, key: key, plainTail: true))) != nil { plainTail = true }
        }
        for (component, k) in entry.keys.sorted(by: { $0.key.lowercased() < $1.key.lowercased() }) {
            var ok = false, why = ""
            do {
                guard let member = names.first(where: { ($0 as NSString).lastPathComponent == k.file }) else {
                    throw FirmwareError(.unsupported, "not in the IPSW")
                }
                if component == "rootfs" {
                    guard let key = Data(hex: k.key), key.count == 36 else { throw FirmwareError(.keyMissing, "not a 36-byte VFDecrypt key") }
                    let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("verify-keys-\(getpid()).dmg")
                    defer { try? FileManager.default.removeItem(at: tmp) }
                    try ipsw.stream(member) { try VFDecrypt.decrypt(from: $0.fileDescriptor, output: tmp, key: key) }
                    let h = try FileHandle(forReadingFrom: tmp)
                    defer { try? h.close() }
                    let size = try h.seekToEnd()
                    try h.seek(toOffset: size >= 512 ? size - 512 : 0)
                    let trailer = try h.readToEnd() ?? Data()
                    ok = trailer.prefix(4) == Data("koly".utf8) || String(decoding: trailer, as: UTF8.self).contains("koly")
                    why = ok ? "UDIF trailer" : "no UDIF trailer after VFDecrypt"
                } else if try IMG3.tags(ipsw.read(member))["KBAG"] == nil {
                    // 2.x DFU stages ship in the clear: a key page has none and the preparer copies the payload.
                    ok = true; why = "not encrypted (no KBAG); key unused"
                } else {
                    guard let iv = k.iv.flatMap({ Data(hex: $0) }), let key = Data(hex: k.key) else { throw FirmwareError(.keyMissing, "iv/key not hex") }
                    let plain = try IMG3.decrypt(ipsw.read(member), iv: iv, key: key, plainTail: plainTail)
                    let head = plain.prefix(4096)
                    let text = String(decoding: head, as: UTF8.self)
                    switch component {
                    case "kernelcache":
                        ok = (try? LZSS.complzss(plain)) != nil; why = ok ? "complzss checksum" : "complzss failed"
                    case "RestoreRamDisk", "UpdateRamDisk":
                        let sig = plain.count > 0x402 ? plain[plain.startIndex + 0x400..<plain.startIndex + 0x402] : Data()
                        ok = sig == Data("H+".utf8) || sig == Data("HX".utf8); why = ok ? "HFS+ volume" : "no HFS+ signature at 0x400"
                    case "DeviceTree":
                        // A flattened tree: u32 property count, u32 child count, then the first property's
                        // 32-byte NUL-padded ASCII name.
                        let props = plain.count > 40 ? plain.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 0, as: UInt32.self) } : 0
                        let name = plain.count > 40 ? [UInt8](plain[plain.startIndex + 8..<plain.startIndex + 40]) : []
                        let label = name.prefix { $0 != 0 }
                        ok = (1...4096).contains(props) && !label.isEmpty && label.allSatisfy { (0x21...0x7E).contains($0) }
                            && name.dropFirst(label.count).allSatisfy { $0 == 0 }
                        why = ok ? "flattened device tree (\(String(decoding: label, as: UTF8.self)))" : "no property header"
                    case "iBoot", "LLB", "iBSS", "iBEC":
                        let whole = String(decoding: plain, as: UTF8.self)
                        ok = whole.contains("iBoot-") || whole.contains(component) || whole.contains("Apple")
                        why = ok ? "boot stage strings" : "no iBoot strings in the plaintext"
                    default:   // AppleLogo, Battery*, Glyph*, NeedService, RecoveryMode
                        ok = head.prefix(7) == Data("iBootIm".utf8) || text.hasPrefix("iBootIm")
                        why = ok ? "iBootIm image" : "no iBootIm header"
                    }
                }
            } catch {
                why = "\(error)"
            }
            allOK = allOK && ok
            line(["component": component, "file": k.file, "ok": ok, "why": why])
        }
    } catch {
        line(["error": "\(error)"]); exit(1)
    }
    exit(allOK ? 0 : 1)
}
