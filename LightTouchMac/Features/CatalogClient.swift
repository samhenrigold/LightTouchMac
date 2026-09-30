// Created by Sam on 2026-08-06.
//
// The Legacy Store catalog (legacystore.app): search for apps the emulator can
// run and download an archived copy to install. The server owns the
// compatibility policy: every request names the device (`device`/`os`, API
// 2.1) and /api/emulator/apps judges copies for it — slices, ARMv7 code under
// an armv6 label, min OS, device family, capabilities. A server before 2.1
// ignores the target and judges for an iPod touch 2G on 3.1.3, so the copy
// check before a download stays. This client is deliberately dumb: search,
// decode, download.
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
    /// API 2.1: the .ipa's own md5 (the archive's, the one IPALibrary keeps),
    /// and the server's verdict for the requested device. Absent before 2.1.
    var md5: String? = nil
    var compat: Compat? = nil

    struct Compat: Codable, Sendable {
        let compatible: Bool
        let reasons: [String]
    }

    enum CodingKeys: String, CodingKey {
        case bundleID = "bundle_id", name, developer, version, minOS = "min_os"
        case size, ipaID = "ipa_id", iconURL = "icon_url"
        case downloadURL = "download_url", appURL = "app_url", md5, compat
    }

    /// Why the server excluded this app for the device, in user words; nil
    /// when it runs or the server didn't say. The first reason is the one shown.
    var incompatibility: String? {
        guard let compat, !compat.compatible else { return nil }
        guard let reason = compat.reasons.first else { return "Not compatible with this device" }
        if reason == "armv6_slice_contains_armv7_code" || (reason.hasPrefix("no_") && reason.hasSuffix("_slice")) {
            return "Needs a newer processor"
        }
        if reason.hasPrefix("requires_ios_") { return "Requires iOS \(reason.dropFirst("requires_ios_".count))" }
        if reason.hasPrefix("capability:!") || reason.hasSuffix("device_family") || reason == "family_not_requested" {
            return "Not made for this device"
        }
        if reason.hasPrefix("capability:") { return "Needs hardware this device doesn’t have" }
        return switch reason {
        case "encrypted": "Encrypted — can’t open in Light Touch"
        case "unavailable": "Download no longer available"
        case "not_analyzed": "Not checked for compatibility yet"
        default: "Not compatible with this device"
        }
    }

    /// "SEGA · 66 MB" — whichever parts the catalog knows; for an app the
    /// server excluded, its reason instead. The min-OS stayed out on purpose:
    /// the server already filtered to what runs here, so it was noise on
    /// every row.
    var subtitle: String {
        if let incompatibility { return incompatibility }
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
    /// A response that didn't decode; the DecodingError (its coding path) is in app.log.
    case unreadable
    var errorDescription: String? {
        switch self {
        case .invalidCopy(let message): message
        case .unreadable: "Legacy Store sent a response Light Touch couldn’t read."
        case .badStatus(503): "The Internet Archive is busy — try again in a minute."
        // The code is in app.log (`Legacy Store: HTTP <code> for <path>`).
        case .badStatus(500...): "Legacy Store isn’t responding. Try again in a moment."
        case .badStatus: "Legacy Store couldn’t answer that request. Try again later."
        }
    }
}

@MainActor
enum CatalogClient {

    /// Tests may inject a local service; production always uses Legacy Store.
    static var baseURL = URL(string: "https://legacystore.app")!

    private static let userAgent: String = {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
        return "LightTouchMac/\(version) (+https://legacystore.app)"
    }()

    private static func request(_ url: URL) -> URLRequest {
        var req = URLRequest(url: url)
        req.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        return req
    }

    /// The device the server judges copies for: its model identifier
    /// (catalog `product_type`) and iOS version. No device, no target: the
    /// server's default (iPod touch 2G, 3.1.3). An iPad asks for no `family`,
    /// so it sees iPhone and iPad apps alike.
    private static func target(device: String?, os: String) -> [URLQueryItem] {
        guard let device else { return [] }
        return [URLQueryItem(name: "device", value: device), URLQueryItem(name: "os", value: os)]
    }

    /// Apps matching `query` for this device, best copy each, server-ranked.
    /// An empty query is the storefront's default view: the server's
    /// suggested (most-archived compatible) list, compatible apps only. A
    /// query also lists the apps the device can't run (API 2.1), greyed with
    /// the reason, so searching for one says why instead of nothing.
    static func search(_ query: String, device: String? = nil, os: String = "3.1.3") async throws -> [CatalogApp] {
        var components = URLComponents(url: baseURL.appendingPathComponent("api/emulator/apps"),
                                       resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "limit", value: "50")]
            + (query.isEmpty ? [] : [URLQueryItem(name: "q", value: query),
                                     URLQueryItem(name: "incompatible", value: "include")])
            + target(device: device, os: os)
        let (data, response) = try await URLSession.shared.data(for: request(components.url!))
        if let code = (response as? HTTPURLResponse)?.statusCode, code != 200 {
            logEvent("Legacy Store: HTTP \(code) for \(components.url!.path)?\(components.url!.query ?? "")")
            throw CatalogError.badStatus(code)
        }
        struct Envelope: Decodable { let apps: [CatalogApp] }
        return try decode(Envelope.self, data, from: components.url!).apps
    }

    /// The copy, if it runs on this device (a 2.1 server 404s it otherwise).
    static func compatibleCopy(_ id: Int, device: String? = nil, os: String = "3.1.3") async throws -> CatalogApp {
        var url = URLComponents(url: baseURL.appendingPathComponent("api/emulator/apps"),
                                resolvingAgainstBaseURL: false)!
        url.queryItems = [URLQueryItem(name: "ipa_id", value: String(id))] + target(device: device, os: os)
        struct Envelope: Decodable { let apps: [CatalogApp] }
        let result: Envelope = try await get(url.url!)
        guard result.apps.count == 1, let app = result.apps.first, app.ipaID == id,
              app.compat?.compatible != false else {
            throw CatalogError.invalidCopy("This copy is no longer available.")
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
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            logEvent("Legacy Store: HTTP \(code) for \(url.path)?\(url.query ?? "")")
            throw CatalogError.badStatus(code)
        }
        try Task.checkCancellation()
        return try decode(T.self, data, from: url)
    }

    /// A DecodingError goes to app.log whole (type, coding path, the decoder's words) and reaches
    /// the user as CatalogError.unreadable, not Foundation's "isn't in the correct format".
    private static func decode<T: Decodable>(_ type: T.Type, _ data: Data, from url: URL) throws -> T {
        do { return try JSONDecoder().decode(type, from: data) }
        catch let error as DecodingError {
            logEvent("Legacy Store: couldn’t read \(url.path)?\(url.query ?? "") (\(data.count) bytes) as \(T.self): \(String(reflecting: error))")
            throw CatalogError.unreadable
        }
    }

    /// Revalidate each selection, then let URLSession stream the transfer to
    /// disk — unless the library already holds the copy (its checksum), in
    /// which case the file is a clone of that, with no transfer. A failed or
    /// cancelled transfer owns no permanent scratch directory.
    static func download(_ app: CatalogApp, device: String? = nil, deviceOS: String = "3.1.3", arch: String = "armv6",
                         progress: @escaping @MainActor @Sendable (Double) -> Void) async throws -> URL {
        let current = try await compatibleCopy(app.ipaID, device: device, os: deviceOS)
        guard current.bundleID == app.bundleID else {
            throw CatalogError.invalidCopy("The archived copy no longer matches this app.")
        }
        // A 2.1 server judged this copy for this device and named its bytes:
        // a copy the library already holds needs no second request. Otherwise
        // the copy record is checked here, against this device.
        let known = current.compat?.compatible == true ? current.md5.flatMap(IPALibrary.stored(md5:)) : nil
        var details: CatalogCopy?
        if known == nil {
            let copy = try await copyDetails(app.ipaID)
            guard copy.bundle_id == current.bundleID else {
                throw CatalogError.invalidCopy("The archived copy no longer matches this app.")
            }
            if let reason = copy.unavailableReason(minimumOS: current.minOS, deviceOS: deviceOS, arch: arch) {
                throw CatalogError.invalidCopy(reason)
            }
            details = copy
        }
        let dir = Bundled.workDirectory.appendingPathComponent("catalog-\(app.ipaID)-\(UUID().uuidString)",
                                                               isDirectory: true)
        let safeName = String(app.name.map { "/:\0".contains($0) ? "-" : $0 }.prefix(120))
        let file = dir.appendingPathComponent("\(safeName.isEmpty ? "App" : safeName).ipa")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        do {
            if let stored = known ?? details?.md5.flatMap(IPALibrary.stored(md5:)) {
                try IPALibrary.clone(stored, to: file)
            } else if let details {
                let delegate = CatalogDownloadProgress(report: progress)
                let (temporary, response) = try await URLSession.shared.download(for: request(current.downloadURL),
                                                                                delegate: delegate)
                defer { try? FileManager.default.removeItem(at: temporary) }
                guard let response = response as? HTTPURLResponse, response.statusCode == 200 else {
                    throw CatalogError.badStatus((response as? HTTPURLResponse)?.statusCode ?? 0)
                }
                try await details.verifyDownload(temporary)
                try Task.checkCancellation()
                try FileManager.default.moveItem(at: temporary, to: file)
            }
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
