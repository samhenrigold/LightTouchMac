// Created by Sam on 2026-08-05.
//
// Installed apps are always files we already have on disk (the .ipa passed to
// Add). ideviceinstaller's own "list" text is a lossy, format-fragile source
// of truth for the display name (e.g. it reports Starbucks by bundle ID), so
// on install we read the real CFBundleDisplayName/icon straight out of the
// .ipa via /usr/bin/unzip (shipped with macOS, no new dependency) and cache
// it to disk keyed by bundle ID. The live device list still drives *which*
// bundle IDs are installed; this only supplies the name/icon for them, so an
// app installed inside the guest simply falls back to the reported name.

import Cocoa
import Subprocess
import System

@MainActor
final class AppMetadataCache {
    static let shared = AppMetadataCache()
    
    private struct Entry: Codable {
        let name: String
        let hasIcon: Bool
    }
    
    private let dir: URL
    private var entries: [String: Entry] = [:]
    /// Decoded icons, so the sidebar's `viewFor:` doesn't hit the disk on every
    /// visible row on every reload. NSCache evicts under memory pressure on its
    /// own; a few dozen 57px PNGs never will.
    private let iconMemo = NSCache<NSString, NSImage>()
    
    private init() {
        dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("LightTouchMac/AppCache", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if let data = try? Data(contentsOf: indexURL) {
            entries = (try? JSONDecoder().decode([String: Entry].self, from: data)) ?? [:]
        }
        #if DEBUG
        Self.selfCheck()
        #endif
    }

    #if DEBUG
    /// The member-picking rules are the whole reason names and icons went
    /// missing, so they assert against the shapes that broke them.
    static func selfCheck() {
        let members = [
            "Payload/Super Monkey Ball [SEGA].app/Info.plist",
            "Payload/Super Monkey Ball [SEGA].app/Icon.png",
            "Payload/Super Monkey Ball [SEGA].app/Icon@2x.png",
            "Payload/Super Monkey Ball [SEGA].app/Settings.bundle/Nested.app/Info.plist",
            "Payload/Super Monkey Ball [SEGA].app/Frameworks/Foo.framework/Icon.png",
        ]
        let root = appRoot(members)
        assert(root == "Payload/Super Monkey Ball [SEGA].app/", "nested .app won: \(root ?? "nil")")
        assert(iconMember(members, root: root!, info: [:]) == "\(root!)Icon@2x.png")
        assert(iconMember(members, root: root!, info: ["CFBundleIconFile": "Icon.png"]) == "\(root!)Icon@2x.png")
        assert(escapedForUnzip("a [b]*?.png") == "a \\[b\\]\\*\\?.png")
    }
    #endif
    
    private var indexURL: URL { dir.appendingPathComponent("index.json") }
    private func iconURL(_ bundleID: String) -> URL { dir.appendingPathComponent("\(bundleID).png") }
    
    /// nil if we never learned this bundle ID.
    ///
    /// Entries used to also carry the version and be discarded when it didn't
    /// match the live list — but ideviceinstaller reports CFBundleVersion while
    /// we read CFBundleShortVersionString, so for any app where those differ
    /// (most of them) every entry was rejected on read AND deleted by prune,
    /// which is what made the sidebar fall back to bundle IDs at random. A name
    /// and icon barely change between versions; a stale one is not worth that.
    func name(for bundleID: String) -> String? { entries[bundleID]?.name }

    func icon(for bundleID: String) -> NSImage? {
        guard entries[bundleID]?.hasIcon == true else { return nil }
        if let memo = iconMemo.object(forKey: bundleID as NSString) { return memo }
        guard let image = NSImage(contentsOf: iconURL(bundleID)) else { return nil }
        iconMemo.setObject(image, forKey: bundleID as NSString)
        return image
    }

    /// Drop the cached name/icon for one bundle ID (uninstalled via our button).
    func forget(_ bundleID: String) {
        guard entries.removeValue(forKey: bundleID) != nil else { return }
        iconMemo.removeObject(forKey: bundleID as NSString)
        try? FileManager.default.removeItem(at: iconURL(bundleID))
        save()
    }
    
    // There is deliberately no prune-against-the-live-list. It existed, and it
    // was what threw the name and icon away moments after learning them: the
    // sidebar polls every 3 s, an install takes far longer than that, and the
    // app being installed is not in the live list for any of those ticks — so
    // the entry written at the start of the install was deleted before installd
    // ever registered the app. An entry for an app that is gone costs a few KB
    // and is never read (lookups only happen for bundle IDs the device
    // reports); an entry deleted by mistake costs the icon and the name.

    /// Best-effort: read the display name and icon out of a decrypted .ipa and
    /// cache them, returning the name. Silently does nothing on any failure —
    /// the sidebar just falls back to whatever ideviceinstaller reports.
    @discardableResult
    func learn(from ipa: URL) async -> String? {
        let members = await Self.members(ipa)
        guard let root = Self.appRoot(members),
              let plist = try? await Self.unzip(ipa, member: root + "Info.plist"),
              let info = try? PropertyListSerialization.propertyList(from: plist, format: nil) as? [String: Any],
              let bundleID = info["CFBundleIdentifier"] as? String else { return nil }
        let name = (info["CFBundleDisplayName"] as? String)
        ?? (info["CFBundleName"] as? String)
        ?? ipa.deletingPathExtension().lastPathComponent
        var hasIcon = false
        if let member = Self.iconMember(members, root: root, info: info),
           let data = try? await Self.unzip(ipa, member: member) {
            hasIcon = (try? data.write(to: iconURL(bundleID))) != nil
            // A reinstall may ship a new icon; drop any decoded copy of the old.
            iconMemo.removeObject(forKey: bundleID as NSString)
        }
        entries[bundleID] = Entry(name: name, hasIcon: hasIcon)
        save()
        return name
    }
    
    private func save() {
        guard let data = try? JSONEncoder().encode(entries) else { return }
        try? data.write(to: indexURL, options: .atomic)
    }
    
    // MARK: - .ipa reading (Payload/<something>.app is the app bundle)
    //
    // Every member is looked up in the archive's own listing and then extracted
    // by its exact name, rather than handing unzip a `Payload/*.app/Info.plist`
    // pattern. Two reasons that pattern misfired: unzip's `*` matches `/` too,
    // so a nested .app inside a bundle could win and the two matches would be
    // concatenated into unparseable plist data; and `[`, `]`, `?` in a real
    // bundle name (Super Monkey Ball [SEGA].app) are wildcard syntax to unzip,
    // so those apps matched nothing at all and learned no name or icon.

    /// Every path in the archive.
    private static func members(_ ipa: URL) async -> [String] {
        let result = try? await run(
            .path(FilePath("/usr/bin/unzip")),
            arguments: ["-Z1", ipa.path],
            output: .string(limit: 1 << 22), error: .discarded
        )
        guard let text = result?.standardOutput else { return [] }
        return text.split(separator: "\n").map(String.init)
    }

    /// "Payload/Foo.app/" — the shallowest bundle holding an Info.plist, so a
    /// nested .app can never be mistaken for the app itself.
    static func appRoot(_ members: [String]) -> String? {
        members
            .filter { $0.hasSuffix(".app/Info.plist") }
            .min { $0.count < $1.count }
            .map { String($0.dropLast("Info.plist".count)) }
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

    private static func unzip(_ ipa: URL, member: String) async throws -> Data {
        let result = try await run(
            .path(FilePath("/usr/bin/unzip")),
            arguments: ["-p", ipa.path, escapedForUnzip(member)],
            output: .data(limit: 1 << 22), error: .discarded
        )
        guard result.terminationStatus.isSuccess, !result.standardOutput.isEmpty else {
            throw DeviceToolsError.failed("no such member: \(member)")
        }
        return result.standardOutput
    }
}
