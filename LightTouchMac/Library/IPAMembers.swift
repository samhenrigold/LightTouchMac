// Which members of an .ipa (a zip) are the app: its one root Payload bundle and
// the icon to show, and how to name a member to unzip. Pure; AppMetadataCache
// lists and extracts, tests/offline/check-extracted.py compiles this whole.

import Foundation

nonisolated enum IPAMembers {
    /// Exactly one root Payload app. Nested bundles and ambiguous archives
    /// cannot supply the identity used by the installer and library.
    static func appRoot(_ members: [String]) -> String? {
        let roots = members.filter {
            let parts = $0.split(separator: "/", omittingEmptySubsequences: false)
            return parts.count == 3 && parts[0] == "Payload"
                && parts[1].hasSuffix(".app") && parts[2] == "Info.plist"
        }
        guard roots.count == 1 else { return nil }
        return String(roots[0].dropLast("Info.plist".count))
    }

    /// The icon PNG to cache: whatever the Info.plist declares, else Icon.png.
    /// Only PNGs sitting directly in the .app count, so a framework's artwork
    /// can't win, and @2x is preferred — same picture, twice the resolution.
    static func iconMember(_ members: [String], root: String, info: [String: Any]) -> String? {
        var names: [String] = []
        if let icons = info["CFBundleIcons"] as? [String: Any],
           let primary = icons["CFBundlePrimaryIcon"] as? [String: Any],
           let files = primary["CFBundleIconFiles"] as? [String] { names += files }
        if let files = info["CFBundleIconFiles"] as? [String] { names += files }
        if let file = info["CFBundleIconFile"] as? String { names.append(file) }
        names.append("Icon")

        let pngs = members.filter {
            $0.hasPrefix(root) && $0.hasSuffix(".png") && !$0.dropFirst(root.count).contains("/")
        }
        for name in names {
            let base = root + (name.hasSuffix(".png") ? String(name.dropLast(4)) : name)
            if let hit = pngs.first(where: { $0 == "\(base)@2x.png" })
                ?? pngs.first(where: { $0 == "\(base).png" })
                ?? pngs.first(where: { $0.hasPrefix(base) }) { return hit }
        }
        return nil
    }

    /// unzip reads `*`, `?` and `[]` in a member name as wildcards, so the name
    /// has to be escaped even though it came from unzip's own listing.
    static func escapedForUnzip(_ member: String) -> String {
        member.reduce(into: "") { out, c in
            if "*?[]\\".contains(c) { out.append("\\") }
            out.append(c)
        }
    }
}
