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

import Foundation

public nonisolated struct CatalogApp: Codable, Sendable {
    public init(
        bundleID: String? = nil,
        name: String,
        developer: String? = nil,
        version: String? = nil,
        minOS: String? = nil,
        size: Int64? = nil,
        ipaID: Int,
        iconURL: URL? = nil,
        downloadURL: URL,
        appURL: URL? = nil,
        md5: String? = nil,
        compat: Compat? = nil
    ) {
        self.bundleID = bundleID
        self.name = name
        self.developer = developer
        self.version = version
        self.minOS = minOS
        self.size = size
        self.ipaID = ipaID
        self.iconURL = iconURL
        self.downloadURL = downloadURL
        self.appURL = appURL
        self.md5 = md5
        self.compat = compat
    }
    public let bundleID: String?
    public let name: String
    public let developer: String?
    public let version: String?
    public let minOS: String?
    public let size: Int64?
    public let ipaID: Int
    public let iconURL: URL?
    public let downloadURL: URL
    public let appURL: URL?
    /// API 2.1: the .ipa's own md5 (the archive's, the one IPALibrary keeps),
    /// and the server's verdict for the requested device. Absent before 2.1.
    public var md5: String? = nil
    public var compat: Compat? = nil

    public struct Compat: Codable, Sendable {
        public init(compatible: Bool, reasons: [String], deviceFamily: [String]? = nil) {
            self.compatible = compatible
            self.reasons = reasons
            self.deviceFamily = deviceFamily
        }
        public let compatible: Bool
        public let reasons: [String]
        /// UIDeviceFamily: "1" iPhone/iPod touch, "2" iPad.
        public var deviceFamily: [String]? = nil

        public enum CodingKeys: String, CodingKey {
            case compatible
            case reasons
            case deviceFamily = "device_family"
        }
    }

    public enum CodingKeys: String, CodingKey {
        case bundleID = "bundle_id"
        case name
        case developer
        case version
        case minOS = "min_os"
        case size
        case ipaID = "ipa_id"
        case iconURL = "icon_url"
        case downloadURL = "download_url"
        case appURL = "app_url"
        case md5
        case compat
    }

    /// Why the server excluded this app for the device, in user words; nil
    /// when it runs or the server didn't say. The first reason is the one shown.
    public var incompatibility: String? {
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

    /// "SEGA, 66 MB" — whichever parts the catalog knows; for an app the
    /// server excluded, its reason instead. The min-OS stayed out on purpose:
    /// the server already filtered to what runs here, so it was noise on
    /// every row.
    public var subtitle: String {
        if let incompatibility { return incompatibility }
        var parts: [String] = []
        if let developer { parts.append(developer) }
        if let size {
            parts.append(ByteCountFormatter.string(fromByteCount: size, countStyle: .file))
        }
        return parts.joined(separator: ", ")
    }
}

public nonisolated enum CatalogError: LocalizedError {
    case badStatus(Int)
    case invalidCopy(String)
    /// A response that didn't decode; the DecodingError (its coding path) is in app.log.
    case unreadable
    /// A 400 naming the devices the server takes ("device must be one of …"): it doesn't know this one yet. `name` is
    /// the device's marketing name, filled in by whoever knows it (AppsInspectorViewController).
    case unsupportedDevice(name: String?)

    /// The error for a non-200 answer and its body.
    public static func status(_ code: Int, body: Data) -> CatalogError {
        code == 400 && String(decoding: body, as: UTF8.self).contains("device must be one of")
            ? .unsupportedDevice(name: nil) : .badStatus(code)
    }

    public var errorDescription: String? {
        switch self {
        case .unsupportedDevice(let name): "Legacy Store doesn’t support \(name ?? "this device") yet."
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
public enum CatalogClient {
    /// Tests may inject a local service; production always uses Legacy Store.
    public static var baseURL: URL = {
        guard let url = URL(string: "https://legacystore.app") else {
            preconditionFailure("Legacy Store's address is a constant, valid URL")
        }
        return url
    }()
    /// Where downloads are staged; nil is Bundled.workDirectory. Tests point it at a temporary directory.
    public static var scratchDirectory: URL?
    /// Where the client's diagnostics go (HTTP statuses, undecodable responses): app.log, or a test's own record.
    public static var log: (String) -> Void = { logEvent($0) }

    private static let userAgent: String = {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
        return "LightTouchMac/\(version) (+https://legacystore.app)"
    }()

    /// A request carrying the app's identifying User-Agent (the catalog icons use it too).
    public static func request(_ url: URL) -> URLRequest {
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

    /// The emulator apps endpoint with `queryItems`.
    private static func appsURL(_ queryItems: [URLQueryItem]) throws -> URL {
        var components = URLComponents(
            url: baseURL.appendingPathComponent("api/emulator/apps"),
            resolvingAgainstBaseURL: false
        )
        components?.queryItems = queryItems
        guard let url = components?.url else { throw URLError(.badURL) }
        return url
    }

    /// Apps matching `query` for this device, best copy each, server-ranked.
    /// An empty query is the storefront's default view: the server's
    /// suggested (most-archived compatible) list, compatible apps only. A
    /// query also lists the apps the device can't run (API 2.1), grayed with
    /// the reason, so searching for one says why instead of nothing.
    public static func search(_ query: String, device: String? = nil, os: String = "3.1.3") async throws -> [CatalogApp]
    {
        let url = try appsURL(
            [URLQueryItem(name: "limit", value: "50")]
                + (query.isEmpty
                    ? []
                    : [
                        URLQueryItem(name: "q", value: query),
                        URLQueryItem(name: "incompatible", value: "include")
                    ])
                + target(device: device, os: os)
        )
        let (data, response) = try await URLSession.shared.data(for: request(url))
        if let code = (response as? HTTPURLResponse)?.statusCode, code != 200 {
            log("Legacy Store: HTTP \(code) for \(url.path)?\(url.query ?? "")")
            throw CatalogError.status(code, body: data)
        }
        struct Envelope: Decodable { let apps: [CatalogApp] }
        return try decode(Envelope.self, data, from: url).apps
    }

    /// The copy, if it runs on this device (a 2.1 server 404s it otherwise).
    public static func compatibleCopy(_ id: Int, device: String? = nil, os: String = "3.1.3") async throws -> CatalogApp
    {
        let url = try appsURL([URLQueryItem(name: "ipa_id", value: String(id))] + target(device: device, os: os))
        struct Envelope: Decodable { let apps: [CatalogApp] }
        let result: Envelope = try await get(url)
        guard result.apps.count == 1, let app = result.apps.first, app.ipaID == id,
            app.compat?.compatible != false
        else {
            throw CatalogError.invalidCopy("This copy is no longer available.")
        }
        return app
    }

    public static func copyDetails(_ id: Int) async throws -> CatalogCopy {
        let copy: CatalogCopy = try await get(baseURL.appendingPathComponent("api/v1/copies/\(id)"))
        guard copy.ipaID == String(id) else {
            throw CatalogError.invalidCopy("Legacy Store returned a different archived copy.")
        }
        return copy
    }

    public static func versions(for app: CatalogApp) async throws -> [CatalogVersion] {
        guard let key = app.bundleID ?? app.appURL?.lastPathComponent, !key.isEmpty else {
            throw CatalogError.invalidCopy("This app has no catalog identifier.")
        }
        struct Envelope: Decodable { let data: [CatalogVersion] }
        let result: Envelope = try await get(
            baseURL.appendingPathComponent("api/v1/apps")
                .appendingPathComponent(key).appendingPathComponent("versions")
        )
        return result.data
    }

    private static func get<T: Decodable>(_ url: URL) async throws -> T {
        let (data, response) = try await URLSession.shared.data(for: request(url))
        guard let response = response as? HTTPURLResponse, response.statusCode == 200 else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            log("Legacy Store: HTTP \(code) for \(url.path)?\(url.query ?? "")")
            throw CatalogError.status(code, body: data)
        }
        try Task.checkCancellation()
        return try decode(T.self, data, from: url)
    }

    /// A DecodingError goes to app.log whole (type, coding path, the decoder's words) and reaches
    /// the user as CatalogError.unreadable, not Foundation's "isn't in the correct format".
    private static func decode<T: Decodable>(_ type: T.Type, _ data: Data, from url: URL) throws -> T {
        do { return try JSONDecoder().decode(type, from: data) } catch let error as DecodingError {
            log(
                "Legacy Store: couldn’t read \(url.path)?\(url.query ?? "") (\(data.count) bytes) as \(T.self): \(String(reflecting: error))"
            )
            throw CatalogError.unreadable
        }
    }

    /// Where an archived copy may come from: Legacy Store itself (baseURL's scheme and host) or the Internet Archive
    /// it links to, over https. Anything else the catalog names (another scheme, another host) is refused.
    static func acceptsDownload(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(), let host = url.host?.lowercased() else { return false }
        if scheme == baseURL.scheme?.lowercased(), host == baseURL.host?.lowercased() { return true }
        return scheme == "https" && (host == "archive.org" || host.hasSuffix(".archive.org"))
    }

    /// Revalidate each selection, then let URLSession stream the transfer to
    /// disk — unless the library already holds the copy (its checksum), in
    /// which case the file is a clone of that, with no transfer. A failed or
    /// cancelled transfer owns no permanent scratch directory.
    public static func download(
        _ app: CatalogApp,
        device: String? = nil,
        deviceOS: String = "3.1.3",
        arch: String = "armv6",
        progress: @escaping @MainActor @Sendable (Double) -> Void
    ) async throws -> URL {
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
            guard copy.bundleID == current.bundleID else {
                throw CatalogError.invalidCopy("The archived copy no longer matches this app.")
            }
            if let reason = copy.unavailableReason(minimumOS: current.minOS, deviceOS: deviceOS, arch: arch) {
                throw CatalogError.invalidCopy(reason)
            }
            details = copy
        }
        let dir = (scratchDirectory ?? Bundled.workDirectory).appendingPathComponent(
            "catalog-\(app.ipaID)-\(UUID().uuidString)",
            isDirectory: true
        )
        let safeName = String(app.name.map { "/:\0".contains($0) ? "-" : $0 }.prefix(120))
        let file = dir.appendingPathComponent("\(safeName.isEmpty ? "App" : safeName).ipa")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        do {
            if let stored = known ?? details?.md5.flatMap(IPALibrary.stored(md5:)) {
                try IPALibrary.clone(stored, to: file)
            } else if let details {
                guard acceptsDownload(current.downloadURL) else {
                    log("Legacy Store: refused download_url \(current.downloadURL.absoluteString)")
                    throw CatalogError.invalidCopy("Legacy Store named a download Light Touch doesn’t accept.")
                }
                let delegate = CatalogDownloadProgress(report: progress)
                let temporary: URL
                let response: URLResponse
                do {
                    (temporary, response) = try await URLSession.shared.download(
                        for: request(current.downloadURL),
                        delegate: delegate
                    )
                } catch let error where delegate.refusedRedirect != nil {
                    log(
                        "Legacy Store: refused a redirect to \(delegate.refusedRedirect?.absoluteString ?? "") (\(error))"
                    )
                    throw CatalogError.invalidCopy("Legacy Store named a download Light Touch doesn’t accept.")
                }
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
}

/// URLSession calls it off the main actor; the one thing it keeps is a refused redirect, under its lock.
nonisolated private final class CatalogDownloadProgress: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    let report: @MainActor @Sendable (Double) -> Void
    private let lock = NSLock()
    private var refused: URL?
    init(report: @escaping @MainActor @Sendable (Double) -> Void) { self.report = report }
    /// Where a redirect the download was cancelled at would have gone.
    var refusedRedirect: URL? { lock.withLock { refused } }
    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {}
    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        let fraction =
            totalBytesExpectedToWrite > 0
            ? min(1, Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)) : -1
        Task { @MainActor [report] in report(fraction) }
    }
    /// Every hop is held to acceptsDownload, as the download_url was: the store's 302 to archive.org passes, a
    /// redirect anywhere else cancels the transfer, which download() reports as the copy refused. (Answering nil
    /// alone made download(for:) trap in the tests' stub, which sends nothing after a refused redirect; and the
    /// completion handler, not the async variant, whose thunk crashes Swift 6.4.2's SILGen.)
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        Task { @MainActor in
            if let url = request.url, CatalogClient.acceptsDownload(url) { return completionHandler(request) }
            lock.withLock { refused = request.url ?? URL(fileURLWithPath: "/") }
            task.cancel()
            completionHandler(nil)
        }
    }
}
