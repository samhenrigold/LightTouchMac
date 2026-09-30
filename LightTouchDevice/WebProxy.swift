// The web proxy for one device, in its helper (the process whose QEMU owns the
// guest's sockets). The guest's PAC or itproxy setting sends every request to
// 10.0.2.100:3128; that guestfwd runs `/usr/bin/nc -U SOCKET`
// (WebProxyConfiguration.guestForward), so each guest connection arrives here.
//
// Routing is CONFIG (web-proxy.conf), read per connection: `direct`, `off`, or
// `archive` and a yyyyMMdd date. Upstream is URLSession (HTTP/2, the Mac's
// trust store and proxy settings, a 128 MiB per-device URLCache beside CONFIG);
// the guest side speaks what a 2009-2010 client does: HTTP/1.0 replies with
// Connection: close, and TLS 1.0 (SecureTransport, still able to) terminated
// with a leaf per host from the device's own CA (WebProxyCA).
//
// direct   HTTP and HTTPS (CONNECT, terminated) through URLSession; the adapters
//          (WebProxyAdapters): Weather, Wi-Fi location, 410 for retired hosts.
// archive  GET/HEAD replayed from the Wayback Machine's closest capture,
//          redirects resolved here, text links kept on http, no guest cookies or
//          credentials sent, one fetch a second, a Retry-After cooldown, a day's cache.
// off      Pass-through while the guest switches its proxy off: CONNECT is a raw
//          tunnel (the origin's own certificate), HTTP forwarded uncached.
// The location answer (origin-form /clls/wloc) is served in every mode.

import Foundation
import Security

final class WebProxy: @unchecked Sendable {
    let config: URL
    let session: URLSession
    let archiveOrigin: String
    /// Extra upstream roots (tests: a loopback HTTPS origin); the Mac's trust store otherwise.
    let anchors: [SecCertificate]
    private let lock = NSLock()
    private var leafKey: SecKey?
    private var leaves: [String: (identity: SecIdentity, made: Date)] = [:]
    /// One archive fetch at a time, a second apart, none while the archive asked us to wait.
    private let archiveGate = NSLock()
    private var archiveNext = Date.distantPast, cooldownUntil = Date.distantPast
    /// Follows wifi0's slirp restrict (5.x Setup runs offline, smoke #54): the image's PAC routes every
    /// public host here, and slirp's restrict lets guestfwd traffic through, so while this is set each
    /// connection is closed without a byte. Any reply, even a 503, answers iOS's captive-network probe
    /// and Setup shows a "Log In" sheet; a dead proxy reads as no internet, as a real unit offline.
    var offline: Bool {
        get { lock.lock(); defer { lock.unlock() }; return _offline }
        set { lock.lock(); _offline = newValue; lock.unlock() }
    }
    private var _offline = false

    /// LTM_WEB_PROXY_TRACE set: one stderr line per request (tests/sessions/check-proxy-trust.py: did Safari's page come here).
    static let trace = ProcessInfo.processInfo.environment["LTM_WEB_PROXY_TRACE"] != nil
    static let headMax = 65536, bodyMax = 8 << 20, archiveBodyMax = 32 << 20

    init(config: URL, archiveOrigin: String = "https://web.archive.org", anchors: [SecCertificate] = []) {
        self.config = config
        self.archiveOrigin = archiveOrigin
        self.anchors = anchors
        let configuration = URLSessionConfiguration.default
        configuration.urlCache = URLCache(memoryCapacity: 8 << 20, diskCapacity: 128 << 20,
                                          directory: URL(fileURLWithPath: config.path + ".cache"))
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil
        configuration.timeoutIntervalForRequest = 60
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        session = URLSession(configuration: configuration, delegate: nil, delegateQueue: queue)
        // The C helper's archive cache and gate files (64 slots of up to 2 MiB) are the URLCache's job now.
        let directory = config.deletingLastPathComponent()
        for name in (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        where name.hasPrefix(config.lastPathComponent + ".archive-") {
            try? FileManager.default.removeItem(at: directory.appendingPathComponent(name))
        }
    }

    /// Serves `path` (a Unix socket, owner-only) on a thread of its own; one thread per connection.
    func listen(socket path: String) throws {
        var address = sockaddr_un()
        guard path.utf8.count < MemoryLayout.size(ofValue: address.sun_path) else { throw Reply(503, "Socket path too long") }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        unlink(path)
        address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: path.utf8) }
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard fd >= 0, bound == 0, chmod(path, 0o600) == 0, Darwin.listen(fd, 64) == 0 else {
            close(fd)
            throw Reply(503, "Can't listen on \(path): \(String(cString: strerror(errno)))")
        }
        let accepting = Thread { [self] in
            while true {
                let connection = accept(fd, nil, nil)
                if connection < 0 { if errno == EINTR || errno == ECONNABORTED { continue } else { return } }
                Thread.detachNewThread { self.serve(connection) }
            }
        }
        accepting.name = "web-proxy"
        accepting.start()
    }

    // MARK: - One connection

    /// A reply that ends the connection: the status and a one-line explanation.
    struct Reply: Error { let status: Int; let message: String; init(_ status: Int, _ message: String) { self.status = status; self.message = message } }

    enum Mode: Equatable { case off, direct, archive(String) }

    /// Fails closed: a missing or unreadable file is "disabled", anything unknown invalid.
    static func mode(_ config: URL) throws -> Mode {
        guard let text = try? String(contentsOf: config, encoding: .utf8) else { throw Reply(503, "Proxy is disabled") }
        let words = text.split(whereSeparator: \.isWhitespace).map(String.init)
        switch words.first {
        case "direct": return .direct
        case "off": return .off
        case "archive":
            guard words.count == 2, words[1].count == 8, words[1].allSatisfy(\.isASCIIDigit) else { throw Reply(503, "Invalid archive date") }
            return .archive(words[1])
        default: throw Reply(503, "Invalid proxy configuration")
        }
    }

    func serve(_ fd: Int32) {
        var timeout = timeval(tv_sec: 60, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        timeout.tv_sec = 30
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        let guest = Guest(fd: fd)
        defer { guest.finish() }
        if offline { return }
        do {
            try handle(guest, mode: Self.mode(config))
        } catch let reply as Reply {
            _ = guest.write("HTTP/1.0 \(reply.status) \(reply.message)\r\nConnection: close\r\nContent-Type: text/plain\r\n\r\n\(reply.message)\n")
        } catch {
            _ = guest.write("HTTP/1.0 502 Destination unavailable\r\nConnection: close\r\nContent-Type: text/plain\r\n\r\nDestination unavailable\n")
        }
    }

    private func handle(_ guest: Guest, mode: Mode) throws {
        var tunnel: String?
        while true {
            let (method, target, headers) = try readHead(guest)
            if Self.trace { FileHandle.standardError.write(Data("web-proxy: \(method) \(tunnel.map { "https://" + $0 } ?? "")\(target)\n".utf8)) }
            if method == "CONNECT" {
                guard tunnel == nil else { throw Reply(400, "Nested TLS tunnels are unsupported") }
                guard target.utf8.count < 300 else { throw Reply(400, "Tunnel destination too long") }
                guard let colon = target.lastIndex(of: ":"), colon != target.startIndex else { throw Reply(400, "Invalid tunnel destination") }
                guard let port = Int(target[target.index(after: colon)...]), (1...65535).contains(port) else { throw Reply(400, "Invalid tunnel port") }
                var host = String(target[..<colon])
                if host.count > 2, host.hasPrefix("["), host.hasSuffix("]") { host = String(host.dropFirst().dropLast()) }
                if mode == .direct, WebProxyAdapters.retired(host: host) { throw Reply(410, "This online service has been retired") }
                if mode != .off, FileManager.default.fileExists(atPath: config.path + ".ca.pem") {
                    guard let identity = try? leaf(host) else { throw Reply(503, "Local TLS certificate unavailable") }
                    guard guest.write("HTTP/1.0 200 Connection established\r\n\r\n"), guest.startTLS(identity) else { return }
                    tunnel = target
                    continue
                }
                if case .archive = mode { throw Reply(405, "Dated HTTPS needs the local TLS bridge") }
                guard let remote = Self.connect(host, port) else { throw Reply(502, "Destination unavailable") }
                if guest.write("HTTP/1.0 200 Connection established\r\n\r\n") { Self.relay(guest.fd, remote) }
                close(remote)
                return
            }
            // iOS 3.2's locationd, pointed straight at the proxy's address, sends an origin-form request;
            // it is answered in every mode (location is not browsing, and the guest's preference is baked).
            let localLocation = tunnel == nil && target == "/clls/wloc"
            var url = target
            if case .archive = mode, !localLocation, method != "GET", method != "HEAD" { throw Reply(405, "Archive browsing supports HTTP GET and HEAD") }
            if let tunnel {
                guard target.hasPrefix("/") else { throw Reply(400, "TLS request needs an origin-form path") }
                url = "https://\(tunnel)\(target)"
            }
            guard method.allSatisfy({ $0.isASCII && $0.isUppercase }) else { throw Reply(400, "Invalid method") }
            if localLocation { url = "http://iphone-services.apple.com/clls/wloc" }
            guard tunnel != nil || url.hasPrefix("http://") else { throw Reply(400, "An absolute HTTP URL is required") }
            guard let components = URLComponents(string: url), let host = components.host, components.url != nil else { throw Reply(400, "Invalid URL") }
            if mode == .direct, WebProxyAdapters.retired(host: host) { throw Reply(410, "This online service has been retired") }
            if case .archive(let date) = mode, !localLocation {
                guard components.user == nil, components.password == nil else { throw Reply(400, "Archive URLs cannot contain credentials") }
                _ = guest.write(try archived(url, date: date, head: method == "HEAD"))
                return
            }
            var forwarded: [(String, String)] = [], length: Int?
            for (name, value) in headers {
                switch name.lowercased() {
                case "transfer-encoding": throw Reply(501, "Chunked request bodies are unsupported")
                case "expect": throw Reply(417, "Expect is unsupported")
                case "content-length":
                    guard length == nil, value.first?.isASCIIDigit == true, value.allSatisfy(\.isASCIIDigit) else { throw Reply(400, "Invalid content length") }
                    guard let n = Int(value), n <= Self.bodyMax else { throw Reply(413, "Invalid or oversized body") }
                    length = n
                // Hop-by-hop, Host (the URL's), and Accept-Encoding: URLSession asks for and decodes gzip/deflate/br itself.
                case "connection", "proxy-connection", "keep-alive", "te", "trailer", "upgrade", "proxy-authorization",
                     "proxy-authenticate", "host", "accept-encoding": break
                default: forwarded.append((name, value))
                }
            }
            var body = Data()
            while body.count < length ?? 0 {
                let part = guest.read(max: (length ?? 0) - body.count)
                guard !part.isEmpty else { throw Reply(400, "Incomplete body") }
                body += part
            }
            if localLocation || mode == .direct,
               let (status, answer) = WebProxyAdapters.location(target: url, method: method, body: body,
                                                                 position: WebProxyAdapters.position(URL(fileURLWithPath: config.path + ".location"))) {
                guard status == 200 else { throw Reply(status, "Invalid location request") }
                _ = guest.write(Self.head(200, "OK", ["Content-Type: application/x-protobuf", "Content-Length: \(answer.count)"]) + answer)
                return
            }
            if mode == .direct, let (status, answer) = WebProxyAdapters.weather(target: url, method: method, body: body, fetch: fetchJSON) {
                guard status == 200 else { throw Reply(status, status == 422 ? "Please remove this old Weather city and add it again" : "Weather service unavailable") }
                _ = guest.write(Self.head(200, "OK", ["Content-Type: text/xml; charset=utf-8", "Content-Length: \(answer.count)"]) + answer)
                return
            }
            var request = URLRequest(url: components.url!)
            request.httpMethod = method
            request.httpShouldHandleCookies = false
            for (name, value) in forwarded { request.addValue(value, forHTTPHeaderField: name) }
            if length != nil { request.httpBody = body }
            let reload = mode == .off || forwarded.contains { ["pragma", "cache-control"].contains($0.0.lowercased()) && $0.1.lowercased().contains("no-cache") }
            if reload { request.cachePolicy = .reloadIgnoringLocalCacheData }
            try stream(request, store: mode != .off, to: guest)
            return
        }
    }

    /// Request line and headers, a byte at a time (nothing past the blank line is consumed: TLS may follow a CONNECT).
    private func readHead(_ guest: Guest) throws -> (String, String, [(String, String)]) {
        var head = [UInt8]()
        while !head.suffix(4).elementsEqual([13, 10, 13, 10]) {
            guard head.count < Self.headMax - 1 else { throw Reply(431, "Request headers too large") }
            let byte = guest.read(max: 1)
            guard let b = byte.first else { throw Reply(400, "Incomplete request") }
            guard b != 0 else { throw Reply(400, "Invalid request byte") }
            head.append(b)
        }
        let lines = String(decoding: head.dropLast(4), as: UTF8.self).components(separatedBy: "\r\n")
        let parts = lines[0].split(separator: " ", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 3, !parts[0].isEmpty, parts[1].utf8.count < 16384, parts[0].utf8.count < 32,
              parts[2] == "HTTP/1.0" || parts[2] == "HTTP/1.1" else { throw Reply(400, "Invalid request") }
        var headers: [(String, String)] = []
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":"), !line.hasPrefix(" "), !line.hasPrefix("\t") else { throw Reply(400, "Invalid header") }
            headers.append((String(line[..<colon]), line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)))
        }
        return (parts[0], parts[1], headers)
    }

    static func head(_ status: Int, _ reason: String, _ lines: [String]) -> Data {
        Data(("HTTP/1.0 \(status) \(reason)\r\n" + lines.map { $0 + "\r\n" }.joined() + "Connection: close\r\n\r\n").utf8)
    }

    // MARK: - Upstream (URLSession)

    /// The origin's response, streamed as it arrives; its status and headers as they were, less the hop-by-hop
    /// ones and what URLSession consumed (Content-Encoding it decoded, with that length; Set-Cookie re-split).
    private func stream(_ request: URLRequest, store: Bool, to guest: Guest) throws {
        let upstream = Upstream(anchors: anchors, store: store)
        let task = session.dataTask(with: request)
        upstream.task = task
        task.delegate = upstream
        task.resume()
        defer { task.cancel() }
        var started = false
        while true {
            switch upstream.next() {
            case .response(let response):
                started = true
                guard guest.write(Self.head(response.statusCode, Self.reason(response.statusCode), Self.headerLines(response))) else { return }
            case .data(let data):
                guard guest.write(data) else { return }
            case .done(let error):
                if error != nil, !started { throw Reply(502, "Destination unavailable") }
                return
            }
        }
    }

    static func headerLines(_ response: HTTPURLResponse, dropping extra: Set<String> = []) -> [String] {
        let encoding = (response.value(forHTTPHeaderField: "Content-Encoding") ?? "").lowercased()
        let decoded = ["gzip", "deflate", "br", "zstd"].contains(encoding)
        var skip: Set<String> = ["connection", "proxy-connection", "keep-alive", "transfer-encoding", "te", "trailer", "upgrade",
                                 "proxy-authorization", "proxy-authenticate", "set-cookie"]
        if decoded { skip.formUnion(["content-encoding", "content-length"]) }
        skip.formUnion(extra)
        let lines = response.allHeaderFields.compactMap { key, value -> String? in
            guard let name = key as? String, !skip.contains(name.lowercased()) else { return nil }
            return "\(name): \(value)"
        }.sorted()
        return lines + (extra.contains("set-cookie") ? [] : WebProxyAdapters.setCookieLines(response).map { "Set-Cookie: " + $0 })
    }

    static func reason(_ status: Int) -> String {
        [200: "OK", 201: "Created", 204: "No Content", 206: "Partial Content", 301: "Moved Permanently", 302: "Found",
         303: "See Other", 304: "Not Modified", 307: "Temporary Redirect", 308: "Permanent Redirect", 400: "Bad Request",
         401: "Unauthorized", 403: "Forbidden", 404: "Not Found", 405: "Method Not Allowed", 410: "Gone", 429: "Too Many Requests",
         500: "Internal Server Error", 502: "Bad Gateway", 503: "Service Unavailable"][status] ?? "Status"
    }

    /// A whole response, at most `limit` bytes (nil past it or on an error).
    private func fetch(_ request: URLRequest, limit: Int) -> (HTTPURLResponse, Data)? {
        let upstream = Upstream(anchors: anchors, store: false)
        let task = session.dataTask(with: request)
        upstream.task = task
        task.delegate = upstream
        task.resume()
        defer { task.cancel() }
        var response: HTTPURLResponse?, body = Data()
        while true {
            switch upstream.next() {
            case .response(let r): response = r
            case .data(let data):
                body += data
                if body.count > limit { return nil }
            case .done(let error): return error == nil ? response.map { ($0, body) } : nil
            }
        }
    }

    private func fetchJSON(_ host: String, _ path: String, _ query: [String: String]) -> Any? {
        var url = URLComponents()
        url.scheme = "https"; url.host = host; url.path = path
        url.queryItems = query.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        var request = URLRequest(url: url.url!, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
        request.setValue("LightTouch/1.0 (Weather)", forHTTPHeaderField: "User-Agent")
        guard let (response, body) = fetch(request, limit: 1 << 20), response.statusCode == 200 else { return nil }
        return try? JSONSerialization.jsonObject(with: body)
    }

    // MARK: - Archive

    /// The capture closest to `date` of `target`, over verified host TLS: the archive's own and the original site's
    /// redirects followed here (an http-to-https one stays in dated browsing), no guest header sent.
    private func archived(_ target: String, date: String, head: Bool) throws -> Data {
        let key = URLRequest(url: URL(string: "\(archiveOrigin)/web/\(date)id_/\(target)")!)
        if !head, let cached = session.configuration.urlCache?.cachedResponse(for: key),
           let stored = cached.userInfo?["stored"] as? Date, Date().timeIntervalSince(stored) < 86400 {
            return cached.data
        }
        archiveGate.lock()
        defer { archiveGate.unlock() }
        var url = key.url!.absoluteString
        for _ in 0..<8 {
            let wait = cooldownUntil.timeIntervalSinceNow
            if wait > 0 { return Self.archiveLimited(Int(wait.rounded(.up))) }
            Thread.sleep(until: archiveNext)
            archiveNext = Date() + 1
            guard let address = URL(string: url) else { throw Reply(502, "The archive returned an invalid address") }
            var request = URLRequest(url: address, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 60)
            request.httpMethod = head ? "HEAD" : "GET"
            request.httpShouldHandleCookies = false
            request.setValue("LightTouch/1.0 (archive replay)", forHTTPHeaderField: "User-Agent")
            guard let (response, fetched) = fetch(request, limit: Self.archiveBodyMax) else {
                throw Reply(502, "The archive could not be reached or its response was too large")
            }
            let status = response.statusCode
            if status == 429 || status == 503 {
                let seconds = Self.retryAfter(response.value(forHTTPHeaderField: "Retry-After"))
                cooldownUntil = Date() + Double(seconds)
                return Self.archiveLimited(seconds)
            }
            let location = response.value(forHTTPHeaderField: "Location") ?? ""
            if (300..<400).contains(status), !location.isEmpty {
                if location.hasPrefix(archiveOrigin + "/") { url = location; continue }
                if location.hasPrefix("/"), !location.hasPrefix("//") { url = archiveOrigin + location; continue }
                if location.hasPrefix("http://") || location.hasPrefix("https://") { url = "\(archiveOrigin)/web/\(date)id_/\(location)"; continue }
            }
            let body = WebProxyAdapters.textual(response.value(forHTTPHeaderField: "Content-Type")) ? WebProxyAdapters.httpLinks(fetched) : fetched
            var lines = Self.headerLines(response, dropping: ["content-length", "content-encoding", "etag", "content-md5", "set-cookie"])
            if !head { lines.append("Content-Length: \(body.count)") }
            let reply = Self.head(status, "Archive response", lines) + (head ? Data() : body)
            if !head, status == 200 {
                session.configuration.urlCache?.storeCachedResponse(
                    CachedURLResponse(response: response, data: reply, userInfo: ["stored": Date()], storagePolicy: .allowed), for: key)
            }
            return reply
        }
        throw Reply(502, "The archive returned too many redirects")
    }

    static func retryAfter(_ value: String?) -> Int {
        guard let value = value?.trimmingCharacters(in: .whitespaces) else { return 60 }
        var seconds = Int(value)
        if seconds == nil {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
            seconds = formatter.date(from: value).map { Int($0.timeIntervalSinceNow) }
        }
        return seconds.flatMap { $0 > 0 && $0 < 31_536_000 ? $0 : nil } ?? 60
    }

    static func archiveLimited(_ seconds: Int) -> Data {
        head(429, "Too Many Requests", ["Content-Type: text/html; charset=utf-8", "Retry-After: \(seconds)", "Cache-Control: no-store"])
            + Data(("<html><head><title>Archive temporarily busy</title></head><body><h2>Wayback Machine is temporarily limiting requests</h2>"
                    + "<p>Light Touch has paused archive requests. Please wait \(seconds) seconds, then reload this page.</p></body></html>").utf8)
    }

    // MARK: - TLS toward the guest

    /// A week-long leaf for `host`, one key for them all; made again after six days.
    private func leaf(_ host: String) throws -> SecIdentity {
        lock.lock()
        defer { lock.unlock() }
        if let cached = leaves[host], Date().timeIntervalSince(cached.made) < 6 * 86400 { return cached.identity }
        let key = try leafKey ?? WebProxyCA.newKey()
        leafKey = key
        let identity = try WebProxyCA.load(config: config).identity(for: host, key: key)
        leaves[host] = (identity, Date())
        return identity
    }

    // MARK: - Raw tunnel (off, or no CA)

    static func connect(_ host: String, _ port: Int) -> Int32? {
        var hints = addrinfo(), list: UnsafeMutablePointer<addrinfo>?
        hints.ai_socktype = SOCK_STREAM
        guard getaddrinfo(host, String(port), &hints, &list) == 0 else { return nil }
        defer { freeaddrinfo(list) }
        var entry = list
        while let a = entry?.pointee {
            entry = a.ai_next
            let fd = socket(a.ai_family, a.ai_socktype, a.ai_protocol)
            guard fd >= 0 else { continue }
            var timeout = timeval(tv_sec: 10, tv_usec: 0), on: Int32 = 1
            setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
            setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
            if Darwin.connect(fd, a.ai_addr, a.ai_addrlen) == 0 { return fd }
            close(fd)
        }
        return nil
    }

    /// Both directions until the remote closes; the guest's end of input is passed on as a half-close.
    static func relay(_ guest: Int32, _ remote: Int32) {
        var input = true
        var buffer = [UInt8](repeating: 0, count: 16384)
        while true {
            var fds = [pollfd(fd: input ? guest : -1, events: Int16(POLLIN), revents: 0), pollfd(fd: remote, events: Int16(POLLIN), revents: 0)]
            guard poll(&fds, 2, 60_000) > 0 else { return }
            for (i, p) in fds.enumerated() where p.revents & Int16(POLLIN | POLLHUP | POLLERR) != 0 {
                let n = read(p.fd, &buffer, buffer.count)
                if n < 0, errno == EINTR || errno == EAGAIN { continue }
                if n <= 0 {
                    if i == 0 { input = false; shutdown(remote, SHUT_WR) } else { return }
                } else if !Guest.writeAll(i == 0 ? remote : guest, buffer[..<n]) { return }
            }
        }
    }
}

/// URLSession's side of one request: its events queued for the connection's thread, the task suspended
/// while the guest is more than 8 MiB behind.
final class Upstream: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    enum Event { case response(HTTPURLResponse), data(Data), done(Error?) }
    weak var task: URLSessionDataTask?
    private let anchors: [SecCertificate], store: Bool
    private let condition = NSCondition()
    private var events: [Event] = [], buffered = 0, suspended = false
    private static let limit = 8 << 20

    init(anchors: [SecCertificate], store: Bool) { self.anchors = anchors; self.store = store }

    func next() -> Event {
        condition.lock()
        defer { condition.unlock() }
        while events.isEmpty { condition.wait() }
        let event = events.removeFirst()
        if case .data(let data) = event {
            buffered -= data.count
            if suspended, buffered < Self.limit / 4 { suspended = false; task?.resume() }
        }
        return event
    }
    private func push(_ event: Event) {
        condition.lock()
        events.append(event)
        if case .data(let data) = event {
            buffered += data.count
            if !suspended, buffered > Self.limit { suspended = true; task?.suspend() }
        }
        condition.signal()
        condition.unlock()
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard let response = response as? HTTPURLResponse else { completionHandler(.cancel); return }
        push(.response(response))
        completionHandler(.allow)
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) { push(.data(data)) }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) { push(.done(error)) }
    /// The guest follows redirects itself.
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, willCacheResponse proposedResponse: CachedURLResponse,
                    completionHandler: @escaping (CachedURLResponse?) -> Void) { completionHandler(store ? proposedResponse : nil) }
    func urlSession(_ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        guard !anchors.isEmpty, challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let trust = challenge.protectionSpace.serverTrust else { completionHandler(.performDefaultHandling, nil); return }
        SecTrustSetAnchorCertificates(trust, anchors as CFArray)
        SecTrustSetAnchorCertificatesOnly(trust, false)
        let trusted = SecTrustEvaluateWithError(trust, nil)
        completionHandler(trusted ? .useCredential : .cancelAuthenticationChallenge, trusted ? URLCredential(trust: trust) : nil)
    }
}

/// The guest's end: plain, or TLS 1.0+ once a CONNECT is accepted (SecureTransport over the socket).
final class Guest {
    let fd: Int32
    private var tls: SSLContext?
    init(fd: Int32) { self.fd = fd }

    func startTLS(_ identity: SecIdentity) -> Bool {
        guard let context = SSLCreateContext(nil, .serverSide, .streamType) else { return false }
        tls = context
        SSLSetIOFuncs(context, { connection, data, length in
            let fd = Int32(Int(bitPattern: connection) - 1)
            var done = 0
            while done < length.pointee {
                let n = Darwin.read(fd, data + done, length.pointee - done)
                if n < 0, errno == EINTR { continue }
                if n <= 0 { length.pointee = done; return n == 0 ? errSSLClosedGraceful : errSSLClosedAbort }
                done += n
            }
            return noErr
        }, { connection, data, length in
            let fd = Int32(Int(bitPattern: connection) - 1)
            let ok = Guest.writeAll(fd, UnsafeRawBufferPointer(start: data, count: length.pointee))
            return ok ? noErr : errSSLClosedAbort
        })
        SSLSetConnection(context, UnsafeRawPointer(bitPattern: Int(fd) + 1))
        SSLSetProtocolVersionMin(context, .tlsProtocol1)   // iOS 3's Safari and CFNetwork speak TLS 1.0
        SSLSetCertificate(context, [identity] as CFArray)
        var status: OSStatus
        repeat { status = SSLHandshake(context) } while status == errSSLWouldBlock
        return status == noErr
    }

    /// Up to `max` bytes; empty at the end of input or on an error.
    func read(max: Int) -> Data {
        var buffer = [UInt8](repeating: 0, count: max)
        if let tls {
            var processed = 0
            let status = SSLRead(tls, &buffer, max, &processed)
            return status == noErr || processed > 0 ? Data(buffer[..<processed]) : Data()
        }
        while true {
            let n = Darwin.read(fd, &buffer, max)
            if n < 0, errno == EINTR { continue }
            return n > 0 ? Data(buffer[..<n]) : Data()
        }
    }

    func write(_ text: String) -> Bool { write(Data(text.utf8)) }
    func write(_ data: Data) -> Bool {
        guard let tls else { return data.withUnsafeBytes { Self.writeAll(fd, $0) } }
        return data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                var processed = 0
                guard SSLWrite(tls, bytes.baseAddress! + offset, bytes.count - offset, &processed) == noErr || processed > 0 else { return false }
                offset += processed
            }
            return true
        }
    }

    func finish() {
        if let tls { SSLClose(tls) }
        close(fd)
    }

    static func writeAll<C: Collection>(_ fd: Int32, _ bytes: C) -> Bool where C.Element == UInt8 {
        var array = Array(bytes), offset = 0
        while offset < array.count {
            let n = array.withUnsafeMutableBytes { Darwin.write(fd, $0.baseAddress! + offset, $0.count - offset) }
            if n < 0, errno == EINTR { continue }
            guard n > 0 else { return false }
            offset += n
        }
        return true
    }
}

private extension Character { var isASCIIDigit: Bool { ("0"..."9").contains(self) } }
