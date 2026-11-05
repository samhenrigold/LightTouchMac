import Foundation
import Testing

@testable import FirmwareKit

/// The jailbreak sandbox patch (SandboxPatch): sb_evaluate located by the Seatbelt kext's "bad opcode" string, the
/// prologue patched to return allowed. Validated against real decrypted kernelcaches.
struct SandboxPatchTests {
    /// Locating and applying leaves exactly the four patch bytes changed, at a Thumb push{..,lr} prologue, and the
    /// result is stable (re-locating the patched kernel still points at the same prologue, now the patch bytes).
    static func check(_ kernel: [UInt8], _ label: String) throws {
        let found = try SandboxPatch.locate(kernel)
        let (patched, f2) = try SandboxPatch.apply(kernel)
        #expect(f2.address == found.address, "\(label): apply and locate agree")
        let changed = zip(kernel, patched).enumerated().filter { $0.element.0 != $0.element.1 }.map(\.offset)
        let n = SandboxPatch.patchSize
        let img = try Image(patched)
        let o = try #require(img.addrToOff(found.address))
        let bytes = SandboxPatch.patch(switchBit: found.switchBit ?? 0)
        #expect(Array(patched[o..<o + n]) == bytes, "\(label): the patch landed")
        #expect(changed.allSatisfy { (o..<o + n).contains($0) }, "\(label): only the patch site changed")
    }

    /// The verdict lets the execve hook switch profiles: an errno of 0 at +0, the hook's flag in the byte at +4, and
    /// r0 left as the result pointer. An empty action byte killed BTServer at every start on a jailbroken device.
    @Test func theVerdictCarriesTheProfileSwitchFlag() {
        #expect(SandboxPatch.patch(switchBit: 0x10) == [0x00, 0x21, 0x01, 0x60, 0x10, 0x21, 0x01, 0x71, 0x70, 0x47])
        #expect(SandboxPatch.patch(switchBit: 0x08).count == SandboxPatch.patchSize)
    }

    /// The flag is the single-bit test nearest each reference to the hook's message, and every reference must agree.
    @Test func theSwitchFlagIsTheTestBesideTheMessage() {
        let before = (address: UInt32(0x1000), bit: UInt8(0x10))
        let far = (address: UInt32(0x2000), bit: UInt8(0x40))
        #expect(SandboxPatch.switchBit(references: [0x1006], flagTests: [before, far]) == 0x10)  // 4.x/5.x
        #expect(SandboxPatch.switchBit(references: [0x0FFC], flagTests: [before, far]) == 0x10)  // 6.x/7.x
        #expect(SandboxPatch.switchBit(references: [0x1800], flagTests: [before, far]) == nil)  // none near
        #expect(SandboxPatch.switchBit(references: [], flagTests: [before]) == nil)
        #expect(SandboxPatch.switchBit(references: [0x1006, 0x2004], flagTests: [before, far]) == nil)  // disagree
    }

    /// A stopped device's Jailbreak patches the kernel inside kboot.bin as preparing it jailbroken does: for a stock
    /// base and the same row prepared jailbroken (LTM_SANDBOX_KBOOTS="stock.bin:jailbroken.bin"), the bytes match but
    /// for the boot-args. Opt-in, as no kernel is in the repository.
    @Test func aStoppedDevicesKBootMatchesAPreparedOne() throws {
        guard let pair = ProcessInfo.processInfo.environment["LTM_SANDBOX_KBOOTS"]?.split(separator: ":"),
            pair.count == 2
        else { return }
        var stock = [UInt8](try Data(contentsOf: URL(fileURLWithPath: String(pair[0]))))
        let jailbroken = [UInt8](try Data(contentsOf: URL(fileURLWithPath: String(pair[1]))))
        let t = stock.count - 24
        let bytes = Int(try le32(stock, t + 20))
        let args = Int(try le32(stock, t + 16)) - Int(try le32(stock, t + 8)) + 56
        let before = zip(stock, jailbroken).filter { $0 != $1 }.count
        let found = try SandboxPatch.applyLoaded(&stock, imageBytes: bytes)
        let different = zip(stock, jailbroken).enumerated().filter { $0.element.0 != $0.element.1 }.map(\.offset)
        print(
            "kboot: \(before) bytes differed, \(different.count) now; sb_evaluate \(String(found.address, radix: 16))")
        #expect(different.allSatisfy { (args..<args + 256).contains($0) })
    }

    /// A kernel laid out by address maps each address to its place, not the file offset its load commands name.
    @Test func aLoadedImageMapsAddressesByLayout() throws {
        var b = [UInt8](repeating: 0, count: 0x4000)
        func put(_ o: Int, _ v: UInt32) { for k in 0..<4 { b[o + k] = UInt8(truncatingIfNeeded: v >> (8 * k)) } }
        put(0x1000, 0xFEED_FACE)
        put(0x1004, 12)
        put(0x1010, 1)  // ncmds
        put(0x1014, 56)
        put(0x101C, 1)  // LC_SEGMENT
        put(0x1020, 56)
        b.replaceSubrange(0x1024..<0x102A, with: Array("__TEXT".utf8))
        put(0x1034, 0x8000_1000)  // vmaddr
        put(0x1038, 0x2000)  // vmsize
        put(0x103C, 0x77)  // fileoff, which the layout ignores
        put(0x1040, 0x2000)  // filesize
        let image = try Image(loaded: b)
        #expect(image.addrToOff(0x8000_1000) == 0x1000)
        #expect(image.addrToOff(0x8000_2FFF) == 0x2FFF)
        #expect(image.offToAddr(0x2000) == 0x8000_2000)
        #expect(throws: SandboxPatch.Error.self) { try Image(loaded: [UInt8](repeating: 0, count: 0x2000)) }
    }

    /// Every decrypted kernelcache in the app's cache that carries a Seatbelt kext resolves to a prologue. Opt-in:
    /// LTM_SANDBOX_KERNELS points at a directory tree of kernelcache.mach files (the Decrypted cache).
    @Test func locatesAcrossTheCachedKernels() throws {
        guard let root = ProcessInfo.processInfo.environment["LTM_SANDBOX_KERNELS"] else { return }
        let fm = FileManager.default
        var ok = 0
        var noKext = 0
        var unresolved = 0
        let base = URL(fileURLWithPath: root)
        let e = fm.enumerator(at: base, includingPropertiesForKeys: nil)
        while let u = e?.nextObject() as? URL {
            guard u.lastPathComponent == "kernelcache.mach" else { continue }
            let kernel = [UInt8](try Data(contentsOf: u, options: .alwaysMapped))
            let ver =
                String(decoding: kernel, as: UTF8.self).range(of: "Darwin Kernel Version ").map {
                    String(String(decoding: kernel, as: UTF8.self)[$0.upperBound...].prefix(8))
                } ?? "?"
            do {
                let f = try SandboxPatch.locate(kernel)
                try Self.check(kernel, ver)
                print(
                    "  OK   \(ver) sb_evaluate=\(String(f.address, radix: 16)) \(f.original.hexString)"
                        + " switch=\(f.switchBit.map { String($0, radix: 16) } ?? "none")"
                )
                ok += 1
            } catch SandboxPatch.Error.noSandboxKext, SandboxPatch.Error.noString {
                noKext += 1  // iOS before the prelinked Seatbelt kext
            } catch {
                print("  MISS \(ver) \(error)")
                unresolved += 1
            }
        }
        print("SandboxPatch: \(ok) patched, \(noKext) without a Seatbelt kext, \(unresolved) unresolved")
        #expect(ok > 0)
    }

    /// The real-iBoot re-wrap round-trips: rewrapping the k48 kernelcache and decrypting it back (as iBoot and the
    /// decryptor do) yields exactly the sandbox-patched kernel.
    @Test func rewrapRoundTripsForK48() throws {
        guard FixtureRequirements.corpusEnabled else { return }
        let id = "k48ap-9B206"
        guard let sha1 = try Oracle.entry(id).source.sha1 else { try FixtureRequirements.missing("\(id): no sha1") }
        let ipswURL = Oracle.path("Library/Caches/gold.samhenri.LightTouchMac/IPSW/\(sha1).ipsw")
        guard Oracle.exists(ipswURL) else { try FixtureRequirements.missing("\(id): IPSW not cached") }
        let entry = try Oracle.entry(id)
        let ipsw = IPSWArchive(ipswURL)
        guard let kcPath = try BuildComponents.load(ipsw, board: entry.board)["KernelCache"] else {
            try FixtureRequirements.missing("\(id): no KernelCache")
        }
        let raw = try ipsw.read(kcPath)
        let k = try entry.key(forPath: kcPath)
        let iv = try #require(k.iv.flatMap { Data(hex: $0) })
        let key = try #require(Data(hex: k.key))
        let plain = [UInt8](try LZSS.complzss(IMG3.decrypt(raw, iv: iv, key: key)))
        let want = try SandboxPatch.apply(plain).kernel
        let (img3, _) = try SandboxPatch.rewrapKernelcache(original: raw, plaintextKernel: plain, iv: iv, key: key)
        let back = [UInt8](try LZSS.complzss(IMG3.decrypt(img3, iv: iv, key: key)))
        #expect(back == want, "the re-wrapped kernelcache decrypts back to the patched kernel")
    }

    /// Corpus: the two reported bases plus a board of each kboot kind resolve from a fresh decrypt. k48ap-8J3 is
    /// iOS 4.3.3 (xnu-1735), where _PrelinkExecutableLoadAddr follows the bundle id in the prelink dict.
    @Test(arguments: ["n81ap-10B500", "k48ap-9B206", "n88ap-10B500", "n18ap-9B206", "k48ap-8J3"])
    func locatesForABoard(_ id: String) throws {
        guard FixtureRequirements.corpusEnabled else { return }
        guard let sha1 = try Oracle.entry(id).source.sha1 else { try FixtureRequirements.missing("\(id): no sha1") }
        let ipsw = Oracle.path("Library/Caches/gold.samhenri.LightTouchMac/IPSW/\(sha1).ipsw")
        guard Oracle.exists(ipsw) else { try FixtureRequirements.missing("\(id): IPSW not cached") }
        try Oracle.withTemp { dir in
            _ = try FirmwareDecryptor.decrypt(ipsw: ipsw, entry: try Oracle.entry(id), into: dir, rootfs: false)
            let kernel = [UInt8](try Data(contentsOf: dir.appendingPathComponent("kernelcache.mach")))
            try Self.check(kernel, id)
        }
    }
}
