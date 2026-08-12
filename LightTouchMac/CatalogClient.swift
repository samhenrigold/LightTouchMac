// Created by Sam on 2026-08-06.
//
// The Legacy Store catalog (legacystore.app): search for apps the emulator can
// run and download an archived copy to install. The server owns the
// compatibility policy (armv6 slice, min-OS ≤ 3, installable, not
// quarantined) — /api/emulator/apps only returns copies that should run here,
// so this client is deliberately dumb: search, decode, download.
//
// Downloads follow the site's own posture: legacystore is a link, not a proxy.
// download_url 302s to archive.org, which asks for politeness — an identifying
// User-Agent and one transfer at a time (the install queue is serial anyway).

import Cocoa

extension NSPasteboard.PasteboardType {
    /// A JSON-encoded CatalogApp riding a drag out of the Store list, so the
    /// device view can offer drag-to-install for catalog rows.
    static let ltmCatalogApp = NSPasteboard.PasteboardType("app.lighttouch.catalog-app")
}

struct CatalogApp: Codable, Sendable {
    let bundleID: String?
    let name: String
    let developer: String?
    let version: String?
    let minOS: String?
    let size: Int64?
    let ipaID: Int
    let iconURL: URL?
    let downloadURL: URL
    let appURL: URL?

    enum CodingKeys: String, CodingKey {
        case bundleID = "bundle_id", name, developer, version, minOS = "min_os"
        case size, ipaID = "ipa_id", iconURL = "icon_url"
        case downloadURL = "download_url", appURL = "app_url"
    }

    /// "SEGA · 66 MB" — whichever parts the catalog knows. The min-OS stayed
    /// out on purpose: the server already filtered to what runs here, so it
    /// was noise on every row.
    var subtitle: String {
        var parts: [String] = []
        if let developer { parts.append(developer) }
        if let size {
            parts.append(ByteCountFormatter.string(fromByteCount: size, countStyle: .file))
        }
        return parts.joined(separator: " · ")
    }
}

enum CatalogError: LocalizedError {
    case badStatus(Int)
    var errorDescription: String? {
        switch self {
        case .badStatus(503): "The Internet Archive is busy — try again in a minute."
        case .badStatus(let code): "Legacy Store returned an error (HTTP \(code))."
        }
    }
}

@MainActor
enum CatalogClient {

    /// Overridable so a local jangle dev server can stand in for the real site.
    static var baseURL: URL {
        UserDefaults.standard.string(forKey: "LTMCatalogBaseURL").flatMap(URL.init(string:))
            ?? URL(string: "https://legacystore.app")!
    }

    private static let userAgent: String = {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
        return "LightTouchMac/\(version) (+https://legacystore.app)"
    }()

    private static func request(_ url: URL) -> URLRequest {
        var req = URLRequest(url: url)
        req.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        return req
    }

    /// Compatible apps matching `query`, best copy each, server-ranked. An
    /// empty query is the storefront's default view: the server's suggested
    /// (most-archived compatible) list.
    static func search(_ query: String) async throws -> [CatalogApp] {
        var components = URLComponents(url: baseURL.appendingPathComponent("api/emulator/apps"),
                                       resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "limit", value: "50")]
            + (query.isEmpty ? [] : [URLQueryItem(name: "q", value: query)])
        let (data, response) = try await URLSession.shared.data(for: request(components.url!))
        if let code = (response as? HTTPURLResponse)?.statusCode, code != 200 {
            throw CatalogError.badStatus(code)
        }
        struct Envelope: Decodable { let apps: [CatalogApp] }
        return try JSONDecoder().decode(Envelope.self, from: data).apps
    }

    /// Download the copy to scratch, reporting the completed fraction (0…1,
    /// or a negative value when the total size is unknown) as bytes arrive.
    /// Returns the local .ipa; the caller owns deleting it once the install
    /// is done. Named after the app (sanitized) so the install row's initial
    /// title — the filename — reads right.
    static func download(_ app: CatalogApp,
                         progress: @escaping @MainActor (Double) -> Void) async throws -> URL {
        let dir = Bundled.workDirectory
            .appendingPathComponent("catalog-\(app.ipaID)-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let safeName = app.name.map { "/:".contains($0) ? "-" : $0 }
        let file = dir.appendingPathComponent("\(String(safeName)).ipa")

        let (bytes, response) = try await URLSession.shared.bytes(for: request(app.downloadURL))
        if let code = (response as? HTTPURLResponse)?.statusCode, code != 200 {
            throw CatalogError.badStatus(code)
        }
        let total = response.expectedContentLength > 0 ? response.expectedContentLength : (app.size ?? 0)

        FileManager.default.createFile(atPath: file.path, contents: nil)
        let handle = try FileHandle(forWritingTo: file)
        defer { try? handle.close() }
        var buffer = Data(capacity: 1 << 16)
        var written: Int64 = 0
        var lastReported = -1
        for try await byte in bytes {
            buffer.append(byte)
            if buffer.count >= 1 << 16 {
                try handle.write(contentsOf: buffer)
                written += Int64(buffer.count)
                buffer.removeAll(keepingCapacity: true)
                // Only when the whole percent changes — this closure repaints a
                // table row, and a 100 MB .ipa arrives in ~1600 chunks.
                let percent = total > 0 ? Int(written * 100 / total) : -1
                if percent != lastReported {
                    lastReported = percent
                    progress(percent >= 0 ? Double(percent) / 100 : -1)
                }
            }
        }
        try handle.write(contentsOf: buffer)
        return file
    }

    /// One shared memo for catalog row icons; they're 57–512 px PNGs keyed by
    /// their content-addressed URL, so entries never go stale.
    static let iconMemo = NSCache<NSString, NSImage>()

    static func icon(for app: CatalogApp) async -> NSImage? {
        guard let url = app.iconURL else { return nil }
        if let memo = iconMemo.object(forKey: url.absoluteString as NSString) { return memo }
        guard let (data, response) = try? await URLSession.shared.data(for: request(url)),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let image = NSImage(data: data) else { return nil }
        iconMemo.setObject(image, forKey: url.absoluteString as NSString)
        return image
    }
}
