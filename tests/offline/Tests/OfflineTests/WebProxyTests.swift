import Foundation
import Testing

@testable import HelperProxy

extension SharedState {
    /// The helper's web proxy upstream, against an origin on this Mac's loopback (which URLSession reaches past the
    /// proxy's egress, as it does any loopback literal; the guest side's NetworkPolicy screen is not what is tested).
    @Suite struct WebProxyTests {
        /// A guest's conditional GET reaches the origin as it sent it and the origin's 304 reaches the guest: with a
        /// URLCache on the upstream session, URLSession answered the second request from what the first had stored,
        /// a 200 with the whole body, though the origin had said 304.
        @Test func aConditionalRequestGetsTheOrigins304() throws {
            let work = FileManager.default.temporaryDirectory.appendingPathComponent(
                "ltm-web-proxy-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: work) }
            let origin = try Origin()
            defer { origin.stop() }
            let proxy = WebProxy(config: work.appendingPathComponent("web-proxy.conf"))
            let url = try #require(URL(string: "http://127.0.0.1:\(origin.port)/catalog.xml"))

            let first = try fetch(proxy, URLRequest(url: url))
            #expect(first.hasPrefix("HTTP/1.0 200 OK\r\n") && first.hasSuffix("\r\n\r\n" + Origin.body), "\(first)")

            var conditional = URLRequest(url: url)
            conditional.setValue(Origin.lastModified, forHTTPHeaderField: "If-Modified-Since")
            let second = try fetch(proxy, conditional)
            #expect(second.hasPrefix("HTTP/1.0 304 Not Modified\r\n") && second.hasSuffix("\r\n\r\n"), "\(second)")
            #expect(
                origin.requests.last?.lowercased().contains("if-modified-since: \(Origin.lastModified.lowercased())")
                    == true)
        }

        /// What the guest's end of a socket pair reads once the proxy has streamed `request` to the other.
        private func fetch(_ proxy: WebProxy, _ request: URLRequest) throws -> String {
            var pair: [Int32] = [-1, -1]
            try #require(socketpair(AF_UNIX, SOCK_STREAM, 0, &pair) == 0)
            let guest = Guest(fd: pair[0])
            try proxy.stream(request, to: guest)
            guest.finish()
            defer { close(pair[1]) }
            return String(decoding: try FileHandle(fileDescriptor: pair[1]).readToEnd() ?? Data(), as: UTF8.self)
        }
    }
}

/// An origin on 127.0.0.1: 304 to a request with If-Modified-Since, else 200 with a body and its Last-Modified.
private final class Origin: @unchecked Sendable {
    static let lastModified = "Mon, 01 Jan 2024 00:00:00 GMT", body = "<catalog/>"
    let port: UInt16
    private let fd: Int32
    private let lock = NSLock()
    private var received: [String] = []
    var requests: [String] { lock.withLock { received } }

    init() throws {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        var size = socklen_t(MemoryLayout<sockaddr_in>.size)
        let bound = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, size) == 0 && listen(fd, 8) == 0 && getsockname(fd, $0, &size) == 0
            }
        }
        self.fd = fd
        port = UInt16(bigEndian: address.sin_port)
        try #require(fd >= 0 && bound)
        Thread.detachNewThread { [self] in serve() }
    }

    func stop() { close(fd) }

    private func serve() {
        while true {
            let connection = accept(fd, nil, nil)
            guard connection >= 0 else { return }
            var head = Data()
            var byte: UInt8 = 0
            while !head.suffix(4).elementsEqual([13, 10, 13, 10]), read(connection, &byte, 1) == 1 { head.append(byte) }
            let text = String(decoding: head, as: UTF8.self)
            lock.withLock { received.append(text) }
            let reply =
                text.lowercased().contains("\r\nif-modified-since:")
                ? "HTTP/1.1 304 Not Modified\r\nLast-Modified: \(Self.lastModified)\r\nConnection: close\r\n\r\n"
                : "HTTP/1.1 200 OK\r\nLast-Modified: \(Self.lastModified)\r\nCache-Control: max-age=0\r\n"
                    + "Content-Type: text/xml\r\nContent-Length: \(Self.body.utf8.count)\r\nConnection: close\r\n\r\n"
                    + Self.body
            _ = Guest.writeAll(connection, Data(reply.utf8))
            close(connection)
        }
    }
}
