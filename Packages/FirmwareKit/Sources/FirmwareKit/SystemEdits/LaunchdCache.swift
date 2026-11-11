import Foundation

/// iOS 8's release launchd reads daemon definitions from xpcd_cache, including
/// definitions for files present on System. Mirror only the jobs edited by the
/// shared preparation path into a standalone metadata image. The original dyld
/// cache and launchd executable remain intact; dyld's existing override switch
/// selects the same kind of on-disk override used for OpenGLES.
enum LaunchdCache {
    static let path = "System/Library/Caches/com.apple.xpcd/xpcd_cache.dylib"

    static func refresh(_ v: any VolumeFiles, jobs: [String], helpers: URL) throws {
        if v.plist(at: "System/Library/CoreServices/SystemVersion.plist")?["ProductBuildVersion"] as? String == "13A344"
        {
            var replacements: [String: Data] = [:]
            var removals: [String] = []
            for job in jobs {
                guard job.hasPrefix("System/Library/LaunchDaemons/"), job.hasSuffix(".plist") else {
                    throw FirmwareError(.unsupported, "not a System daemon job: \(job)")
                }
                if v.exists(job) {
                    replacements["/" + job] = try v.contents(at: job)
                } else {
                    removals.append("/" + job)
                }
            }
            let cachePath = "System/Library/Caches/com.apple.dyld/dyld_shared_cache_armv7s"
            try v.put(updatingCached(v.contents(at: cachePath), jobs: replacements, removing: removals), at: cachePath)
            if v.exists(path) { try v.remove(path) }
            return
        }
        // iOS 10 ships this metadata as an on-disk universal image, rather
        // than an image in the dyld cache. Preserve its native architecture
        // slices and signing allocation instead of substituting the iOS 8
        // template. Only the 32-bit ARM jobs used by these guests are edited.
        if v.exists(path) {
            let bytes = try v.contents(at: path)
            if let images = MachOSignature.images(bytes), images.fat {
                var replacements: [String: Data] = [:]
                var removals: [String] = []
                for job in jobs {
                    guard job.hasPrefix("System/Library/LaunchDaemons/"), job.hasSuffix(".plist") else {
                        throw FirmwareError(.unsupported, "not a System daemon job: \(job)")
                    }
                    if v.exists(job) {
                        replacements["/" + job] = try v.contents(at: job)
                    } else {
                        removals.append("/" + job)
                    }
                }
                try v.put(updatingStandalone(bytes, jobs: replacements, removing: removals), at: path, mode: 0o755)
                return
            }
        }
        let cachePath = "System/Library/Caches/com.apple.dyld/dyld_shared_cache_armv7s"
        guard v.exists(cachePath) else { return }
        let cache = try DyldSharedCache(data: v.contents(at: cachePath))
        guard let image = cache.image("/" + path) else { return }
        var original: Data?
        // Prefer an earlier prepared override so independent preparation steps
        // preserve one another's explicitly updated jobs.
        if v.exists(path) {
            let bytes = try v.contents(at: path)
            if let s = try MachO(bytes).segments.flatMap(\.sections).first(where: { $0.name == "__xpcd_cache" }) {
                let start = Int(s.offset)
                let end = start + Int(s.size)
                guard end <= bytes.count else { throw FirmwareError(.unsupported, "truncated xpcd override") }
                original = bytes.subdata(in: start..<end)
            }
        } else {
            guard image.headerOffset >= 0, image.headerOffset <= cache.data.count - 4096 else {
                throw FirmwareError(.unsupported, "truncated cached xpcd image header")
            }
            let header = cache.data.subdata(in: image.headerOffset..<(image.headerOffset + 4096))
            if let s = try MachO(header).segments.flatMap(\.sections).first(where: { $0.name == "__xpcd_cache" }),
                let start = cache.fileOffset(of: UInt64(s.addr)), start + Int(s.size) <= cache.data.count
            {
                original = cache.data.subdata(in: start..<(start + Int(s.size)))
            }
        }
        guard let original,
            var plist = try PropertyListSerialization.propertyList(from: original, format: nil) as? [String: Any],
            plist["VersionNumber"] as? Int == 4,
            var daemons = plist["LaunchDaemons"] as? [String: Any]
        else {
            throw FirmwareError(.unsupported, "unsupported native launchd service cache")
        }
        for job in jobs {
            guard job.hasPrefix("System/Library/LaunchDaemons/"), job.hasSuffix(".plist") else {
                throw FirmwareError(.unsupported, "not a System daemon job: \(job)")
            }
            if v.exists(job) {
                daemons["/" + job] = try PropertyListSerialization.propertyList(from: v.contents(at: job), format: nil)
            } else {
                daemons.removeValue(forKey: "/" + job)
            }
        }
        plist["LaunchDaemons"] = daemons
        let payload = try PropertyListSerialization.data(fromPropertyList: plist, format: .binary, options: 0)
        var template = try Data(contentsOf: helpers.appendingPathComponent("launchd-cache-template"))
        guard
            let section = try MachO(template).segments.flatMap(\.sections).first(where: { $0.name == "__xpcd_cache" }),
            payload.count <= Int(section.size), Int(section.offset) + Int(section.size) <= template.count
        else {
            throw FirmwareError(.unsupported, "launchd cache template capacity exceeded")
        }
        let start = Int(section.offset)
        // Binary plist trailers must be at the section's end: shrink the section
        // size, retaining the segment's reserved space and all other offsets.
        var command = 28
        while command + 8 <= template.count {
            func word(_ at: Int) -> Int {
                (0..<4).reduce(0) { $0 | Int(template[at + $1]) << (8 * $1) }
            }
            let type = word(command)
            let size = word(command + 4)
            guard size >= 8, command + size <= template.count else { break }
            if type == 1 {
                guard size >= 56, word(command + 48) <= (size - 56) / 68 else {
                    throw FirmwareError(.unsupported, "invalid launchd cache template segment")
                }
                for index in 0..<word(command + 48) {
                    let s = command + 56 + 68 * index
                    if word(s + 40) == start {
                        for i in 0..<4 { template[s + 36 + i] = UInt8(truncatingIfNeeded: payload.count >> (8 * i)) }
                    }
                }
            }
            command += size
            if command >= 28 + word(20) { break }
        }
        template.replaceSubrange(start..<(start + payload.count), with: payload)
        template = try Activation.signed(template)
        try v.makeDirectory((path as NSString).deletingLastPathComponent, mode: 0o755)
        try v.put(template, at: path, mode: 0o755)
        try SystemEdits.setOverrideSwitch(v, image: path)
    }
}
