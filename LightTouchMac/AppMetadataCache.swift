// Created by Sam on 2026-08-05.
//
// Installed apps are always files we already have on disk (the .ipa passed to
// Add). ideviceinstaller's own "list" text is a lossy, format-fragile source
// of truth for the display name (e.g. it reports Starbucks by bundle ID), so
// on install we read the real CFBundleDisplayName/icon straight out of the
// .ipa via /usr/bin/unzip (shipped with macOS, no new dependency) and cache
// it to disk keyed by bundle ID. The live device list still drives *which*
// bundle IDs are installed; this only supplies the name/icon for them, and
// self-heals for guest-side installs/deletes it never learned about.

import Cocoa
import Subprocess
import System

@MainActor
final class AppMetadataCache {
    static let shared = AppMetadataCache()
    
    private struct Entry: Codable {
        let name: String
        let version: String   // compared against the live list; a mismatch means the
        // app was updated some other way and this entry is stale
        let hasIcon: Bool
    }
    
    private let dir: URL
    private var entries: [String: Entry] = [:]
    
    private init() {
        dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("LightTouchMac/AppCache", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if let data = try? Data(contentsOf: indexURL) {
            entries = (try? JSONDecoder().decode([String: Entry].self, from: data)) ?? [:]
        }
    }
    
    private var indexURL: URL { dir.appendingPathComponent("index.json") }
    private func iconURL(_ bundleID: String) -> URL { dir.appendingPathComponent("\(bundleID).png") }
    
    /// nil if never learned, or if the live version no longer matches what
    /// was cached (the app was updated some way we didn't see).
    func name(for bundleID: String, version: String) -> String? {
        guard let entry = entries[bundleID], entry.version == version else { return nil }
        return entry.name
    }
    
    func icon(for bundleID: String, version: String) -> NSImage? {
        guard let entry = entries[bundleID], entry.version == version, entry.hasIcon else { return nil }
        return NSImage(contentsOf: iconURL(bundleID))
    }
    
    /// Drop the cached name/icon for one bundle ID (uninstalled via our button).
    func forget(_ bundleID: String) {
        guard entries.removeValue(forKey: bundleID) != nil else { return }
        try? FileManager.default.removeItem(at: iconURL(bundleID))
        save()
    }
    
    /// Drop cache entries for anything not in the live list (deleted from the
    /// guest's springboard rather than our Remove button) or whose version no
    /// longer matches (updated some way we didn't learn from).
    func prune(keeping liveVersions: [String: String]) {
        for (id, entry) in entries where liveVersions[id] != entry.version { forget(id) }
    }
    
    /// Best-effort: read the display name and icon out of a decrypted .ipa and
    /// cache them. Silently does nothing on any failure — the sidebar just
    /// falls back to whatever ideviceinstaller reports.
    func learn(from ipa: URL) async {
        guard let info = await Self.readInfoPlist(ipa),
              let bundleID = info["CFBundleIdentifier"] as? String else { return }
        let name = (info["CFBundleDisplayName"] as? String)
        ?? (info["CFBundleName"] as? String)
        ?? ipa.deletingPathExtension().lastPathComponent
        // Same field ideviceinstaller reports in `list`, so it lines up with
        // the live version DeviceTools.parseList hands back.
        let version = (info["CFBundleShortVersionString"] as? String)
        ?? (info["CFBundleVersion"] as? String) ?? ""
        let hasIcon: Bool
        if let iconData = await Self.readIcon(ipa, info: info) {
            hasIcon = (try? iconData.write(to: iconURL(bundleID))) != nil
        } else {
            hasIcon = false
        }
        entries[bundleID] = Entry(name: name, version: version, hasIcon: hasIcon)
        save()
    }
    
    private func save() {
        guard let data = try? JSONEncoder().encode(entries) else { return }
        try? data.write(to: indexURL, options: .atomic)
    }
    
    // MARK: - .ipa reading (Payload/*.app is the app bundle inside the zip)
    
    private static func readInfoPlist(_ ipa: URL) async -> [String: Any]? {
        guard let data = try? await unzip(ipa, "Payload/*.app/Info.plist") else { return nil }
        return try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
    }
    
    private static func readIcon(_ ipa: URL, info: [String: Any]) async -> Data? {
        var candidates: [String] = []
        if let files = info["CFBundleIconFiles"] as? [String], let first = files.first {
            candidates.append(first)
        }
        if let file = info["CFBundleIconFile"] as? String {
            candidates.append(file)
        }
        candidates.append("Icon.png")
        for name in candidates {
            let file = name.hasSuffix(".png") ? name : "\(name).png"
            if let data = try? await unzip(ipa, "Payload/*.app/\(file)") { return data }
        }
        return nil
    }
    
    private static func unzip(_ ipa: URL, _ pattern: String) async throws -> Data {
        let result = try await run(
            .path(FilePath("/usr/bin/unzip")),
            arguments: ["-p", ipa.path, pattern],
            output: .data(limit: 1 << 22), error: .discarded
        )
        guard result.terminationStatus.isSuccess, !result.standardOutput.isEmpty else {
            throw DeviceToolsError.failed("no match")
        }
        return result.standardOutput
    }
}
