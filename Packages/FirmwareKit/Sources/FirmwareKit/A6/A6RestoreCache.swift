import CoreFoundation
import Foundation

/// The restore variant lacks the full system's capability-query support.
/// Admit a temporary source-built worker which runs with the matching System
/// frameworks; never substitute unavailable-result stubs or opaque cache data.
public enum A6RestoreCache {
    static let librarySHA256 = "fc7b1e5943df2119cd1f258c0f197e9795ff62ad3257f0d3d844f17c048cab77"
    static let ios9LibrarySHA256 = "f8946c1cb5178fd031ffaee896355cb7f8cb150d01541312709abc0671a08074"

    public static func validate(plan: Data, originalLibrary: Data, helper: Data) throws {
        func invalid(_ reason: String) -> FirmwareError {
            FirmwareError(.unsupported, "N42 native restore cache: " + reason)
        }
        guard let p = try PropertyListSerialization.propertyList(from: plan, format: nil) as? [String: Any],
            let build = p["Build"] as? String,
            ["12A365", "13A344", "14G61"].contains(build),
            let overrides = p["Overrides"] as? [String: Any], !overrides.isEmpty,
            overrides.count <= 32,
            overrides.values.allSatisfy({ ($0 as? NSNumber).map { CFGetTypeID($0) == CFBooleanGetTypeID() } ?? false })
        else {
            throw invalid("unqualified build or invalid plan")
        }
        let expected =
            build == "12A365"
            ? librarySHA256
            : build == "13A344"
                ? ios9LibrarySHA256
                : "869ca5ca3830a9d67076ff45e593a06362d9e988e3d805ece2cd479944c4f3f2"
        guard Preparer.sha256(originalLibrary) == expected else {
            throw invalid("unrecognized original MobileGestalt library")
        }
        func word(_ n: Int) -> UInt32 {
            (0..<4).reduce(UInt32(0)) { $0 | UInt32(helper[n + $1]) << (8 * $1) }
        }
        guard helper.count >= 28, word(0) == 0xfeed_face, word(4) == 12,
            word(12) == 2,
            helper.range(of: Data("it_mobilegestalt_worker_v1\0".utf8)) != nil
        else {
            throw invalid("expected source-built ARM native cache worker")
        }
        if build != "12A365", !allowsPrivateMapping(helper) {
            throw invalid(
                "iOS 9/10 worker needs get-task-allow=true for native dyld private mapping; rebuild restore tools")
        }
        if build == "14G61", helper.range(of: Data("it_mobilegestalt_container_v1\0".utf8)) == nil {
            throw invalid("iOS 10 worker needs native container bootstrap support; rebuild restore tools")
        }
        if build == "14G61", helper.range(of: Data("it_mobilegestalt_readable_cache_v1\0".utf8)) == nil {
            throw invalid("iOS 10 worker needs a mobile-readable SystemGroup cache; rebuild restore tools")
        }
    }

    /// iOS 9 ignores the private-cache environment setting on an enforced
    /// executable without this normal developer entitlement. Check the actual
    /// signed entitlement blob, so an older prebuilt helper fails before boot.
    private static func allowsPrivateMapping(_ helper: Data) -> Bool {
        guard let signature = MachOSignature.codeSignature(in: helper),
            signature.size >= 12, signature.offset >= 0,
            signature.size <= helper.count,
            signature.offset <= helper.count - signature.size
        else { return false }
        let bytes = helper.subdata(in: signature.offset..<(signature.offset + signature.size))
        func be(_ offset: Int) -> Int {
            (0..<4).reduce(0) { $0 | Int(bytes[offset + $1]) << (24 - 8 * $1) }
        }
        let length = be(4)
        let count = be(8)
        guard be(0) == 0xfade_0cc0, length >= 12, length <= bytes.count,
            count <= (length - 12) / 8
        else { return false }
        for index in 0..<count {
            let entry = 12 + index * 8
            guard be(entry) == 5 else { continue }
            let offset = be(entry + 4)
            guard offset >= 12 + count * 8, offset <= length - 8,
                be(offset) == 0xfade_7171
            else { return false }
            let size = be(offset + 4)
            guard size >= 8, size <= length - offset,
                let entitlements = try? PropertyListSerialization.propertyList(
                    from: bytes.subdata(in: (offset + 8)..<(offset + size)), format: nil) as? [String: Any],
                let allowed = entitlements["get-task-allow"] as? NSNumber
            else { return false }
            return CFGetTypeID(allowed) == CFBooleanGetTypeID() && allowed.boolValue
        }
        return false
    }
}
