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
// User-Agent and the standard URLSession connection limits. Ready files install
// serially, independently of the order downloads finish.

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

nonisolated enum CatalogError: LocalizedError {
    case badStatus(Int)
    case invalidCopy(String)
    var errorDescription: String? {
        switch self {
        case .invalidCopy(let message): message
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

    static func compatibleCopy(_ id: Int) async throws -> CatalogApp {
        var url = URLComponents(url: baseURL.appendingPathComponent("api/emulator/apps"),
                                resolvingAgainstBaseURL: false)!
        url.queryItems = [URLQueryItem(name: "ipa_id", value: String(id))]
        struct Envelope: Decodable { let apps: [CatalogApp] }
        let result: Envelope = try await get(url.url!)
        guard result.apps.count == 1, let app = result.apps.first, app.ipaID == id else {
            throw CatalogError.invalidCopy("This copy is no longer available for the emulator.")
        }
        return app
    }

    static func copyDetails(_ id: Int) async throws -> CatalogCopy {
        let copy: CatalogCopy = try await get(baseURL.appendingPathComponent("api/v1/copies/\(id)"))
        guard copy.ipa_id == String(id) else {
            throw CatalogError.invalidCopy("Legacy Store returned a different archived copy.")
        }
        return copy
    }

    static func versions(for app: CatalogApp) async throws -> [CatalogVersion] {
        guard let key = app.bundleID ?? app.appURL?.lastPathComponent, !key.isEmpty else {
            throw CatalogError.invalidCopy("This app has no catalog identifier.")
        }
        struct Envelope: Decodable { let data: [CatalogVersion] }
        let result: Envelope = try await get(baseURL.appendingPathComponent("api/v1/apps")
            .appendingPathComponent(key).appendingPathComponent("versions"))
        return result.data
    }

    private static func get<T: Decodable>(_ url: URL) async throws -> T {
        let (data, response) = try await URLSession.shared.data(for: request(url))
        guard let response = response as? HTTPURLResponse, response.statusCode == 200 else {
            throw CatalogError.badStatus((response as? HTTPURLResponse)?.statusCode ?? 0)
        }
        try Task.checkCancellation()
        return try JSONDecoder().decode(T.self, from: data)
    }

    /// Revalidate each selection, then let URLSession stream the transfer to disk.
    /// A failed or cancelled transfer owns no permanent scratch directory.
    static func download(_ app: CatalogApp,
                         progress: @escaping @MainActor @Sendable (Double) -> Void) async throws -> URL {
        let current = try await compatibleCopy(app.ipaID)
        let details = try await copyDetails(app.ipaID)
        guard current.bundleID == app.bundleID, details.bundle_id == current.bundleID else {
            throw CatalogError.invalidCopy("The archived copy no longer matches this app.")
        }
        if let reason = details.unavailableReason(minimumOS: current.minOS) {
            throw CatalogError.invalidCopy(reason)
        }
        let delegate = CatalogDownloadProgress(report: progress)
        let (temporary, response) = try await URLSession.shared.download(for: request(current.downloadURL),
                                                                        delegate: delegate)
        defer { try? FileManager.default.removeItem(at: temporary) }
        guard let response = response as? HTTPURLResponse, response.statusCode == 200 else {
            throw CatalogError.badStatus((response as? HTTPURLResponse)?.statusCode ?? 0)
        }
        try await details.verifyDownload(temporary)
        try Task.checkCancellation()
        let dir = Bundled.workDirectory.appendingPathComponent("catalog-\(app.ipaID)-\(UUID().uuidString)",
                                                               isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        do {
            let safeName = String(app.name.map { "/:\0".contains($0) ? "-" : $0 }.prefix(120))
            let file = dir.appendingPathComponent("\(safeName.isEmpty ? "App" : safeName).ipa")
            try FileManager.default.moveItem(at: temporary, to: file)
            progress(1)
            return file
        } catch {
            try? FileManager.default.removeItem(at: dir)
            throw error
        }
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

/// Immutable delegate; URLSession calls it off the main actor.
nonisolated private final class CatalogDownloadProgress: NSObject, URLSessionDownloadDelegate {
    let report: @MainActor @Sendable (Double) -> Void
    init(report: @escaping @MainActor @Sendable (Double) -> Void) { self.report = report }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) {}
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
                    totalBytesExpectedToWrite: Int64) {
        let fraction = totalBytesExpectedToWrite > 0
            ? min(1, Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)) : -1
        Task { @MainActor [report] in report(fraction) }
    }
}
