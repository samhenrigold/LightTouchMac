// SpringBoard 1.1 to 1.1.2's allowlist, turned off for the 1.x jailbreak (SystemEdits.installJailbreak1x).
//
// -[SBIconModel _addItemsToIconList:fromPath:withTags:] asks -[SBPlatformController allowedDisplayIdentifiers] for a
// list compiled in per platform (M68, N82 and the simulator: the iPhone's apps; N45: its own) and skips every bundle
// in /Applications whose display identifier the list doesn't contain:
//
//     ldr r1, =@selector(allowedDisplayIdentifiers); ldr r1, [r1]; bl objc_msgSend; str r0, [sp, #N]
//     …
//     ldr r1, =@selector(containsObject:); ldr r0, [sp, #N]; mov r2, r4; ldr r1, [r1]; bl objc_msgSend
//     tst r0, #255; beq <next bundle>
//
// The patch makes that beq a nop, so every app is listed, as the 1.1 jailbreaks' SpringBoard patch did. Found by the
// two selectors (__OBJC,__message_refs), not by offset: 1.1 (3A101a) and 1.1.2 (3B48b, the iPod touch's and the
// iPhone's SpringBoard the same binary) put it at different addresses. 1.0 has no such list (it appends the apps
// DisplayOrder.plist doesn't name), and 1.1.3 on asks disallowedDisplayIdentifiers instead (the January apps not yet
// bought): `patch` returns nil for both.

import Foundation

enum SpringBoardAllowlist {
    static let nop: UInt32 = 0xE1A0_0000  // mov r0, r0
    static let tstByte: UInt32 = 0xE310_00FF  // tst r0, #255

    /// `springBoard` with the allowlist check off and the patched instruction's file offset; nil when it has no
    /// allowlist. Throws when it names the selector but the check isn't found exactly once.
    static func patch(_ springBoard: [UInt8]) throws -> (bytes: [UInt8], offset: Int)? {
        let img = try Image(springBoard)
        let refs = selectorRefs(img)
        guard let allowed = refs["allowedDisplayIdentifiers"] else { return nil }
        guard let contains = refs["containsObject:"],
            let text = img.segs.flatMap(\.sections).first(where: { $0.segment == "__TEXT" && $0.name == "__text" })
        else { throw FirmwareError(.unsupported, "SpringBoard: no containsObject: or __text") }
        let start = Int(text.offset)
        let end = min(start + Int(text.size), springBoard.count) & ~3
        /// The selector reference an `ldr rT, [pc, #imm]` at `o` loads, if it is one.
        func literal(_ o: Int, rt: UInt32) -> UInt32? {
            let i = img.u32(o)
            guard i & 0x0F7F_F000 == 0x051F_0000 | rt << 12 else { return nil }
            let imm = Int(i & 0xFFF)
            let at = o + 8 + (i & 0x0080_0000 != 0 ? imm : -imm)
            return at >= 0 && at + 4 <= springBoard.count ? img.u32(at) : nil
        }
        var sites: [Int] = []
        for o in stride(from: start, to: end - 16, by: 4) where literal(o, rt: 1) == allowed {
            // the result stored to a stack slot within the next few instructions: str r0, [sp, #N]
            guard
                let slot = (1...4).lazy.map({ img.u32(o + 4 * $0) }).first(where: { $0 & 0xFFFF_F000 == 0xE58D_0000 })
            else { continue }
            let reload = 0xE59D_0000 | slot & 0xFFF  // ldr r0, [sp, #N]
            for p in stride(from: o, to: min(o + 0x1000, end - 32), by: 4) where img.u32(p) == reload {
                guard (1...3).contains(where: { p >= 4 * $0 && literal(p - 4 * $0, rt: 1) == contains }) else {
                    continue
                }
                guard
                    let call = (1...4).first(where: {
                        img.u32(p + 4 * $0) >> 24 == 0xEB && img.u32(p + 4 * $0 + 4) == tstByte
                    })
                else { continue }
                let branch = p + 4 * call + 8
                if img.u32(branch) >> 24 == 0x0A { sites.append(branch) }  // beq
            }
        }
        guard sites.count == 1, let site = sites.first else {
            throw FirmwareError(.unsupported, "SpringBoard: the allowlist check found \(sites.count) times, not once")
        }
        var out = springBoard
        for k in 0..<4 { out[site + k] = UInt8(truncatingIfNeeded: nop >> (8 * k)) }
        return (out, site)
    }

    /// Each selector name __OBJC,__message_refs references, and the reference's address.
    static func selectorRefs(_ img: Image) -> [String: UInt32] {
        guard
            let refs = img.segs.flatMap(\.sections).first(where: {
                $0.segment == "__OBJC" && $0.name == "__message_refs"
            })
        else { return [:] }
        var out: [String: UInt32] = [:]
        for k in stride(from: 0, to: Int(refs.size) & ~3, by: 4) {
            let o = Int(refs.offset) + k
            guard o + 4 <= img.bytes.count, let name = img.addrToOff(img.u32(o)) else { continue }
            let end = img.bytes[name...].firstIndex(of: 0) ?? name
            out[String(decoding: img.bytes[name..<end], as: UTF8.self)] = refs.addr + UInt32(k)
        }
        return out
    }
}
