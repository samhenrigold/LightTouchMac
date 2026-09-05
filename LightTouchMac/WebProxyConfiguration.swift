import Foundation

/// Host routing is read once per guest connection. Changes need no VM restart.
struct WebProxyConfiguration: Codable, Equatable {
    enum Mode: String, Codable, CaseIterable {
        case off, direct, upstream
        var title: String {
            switch self {
            case .off: "Off"
            case .direct: "Direct HTTP"
            case .upstream: "External Proxy / WaybackProxy"
            }
        }
    }
    var mode: Mode = .off
    var host = "127.0.0.1"
    var port = 8888
    static var file: URL { Bundled.stateDirectory.appendingPathComponent("web-proxy.conf") }
    static var preferencesFile: URL { Bundled.stateDirectory.appendingPathComponent("web-proxy.json") }
    static func load() -> Self {
        guard let data = try? Data(contentsOf: preferencesFile),
              let value = try? JSONDecoder().decode(Self.self, from: data) else { return Self() }
        return value
    }
    func validate() throws {
        if mode == .upstream {
            let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-:")
            guard !host.isEmpty, host.utf8.count <= 253,
                  host.unicodeScalars.allSatisfy({ allowed.contains($0) }), (1...65535).contains(port) else {
                throw DeviceToolsError.failed("Enter a hostname or IP address and a port from 1 to 65535.")
            }
        }
    }
    func writeRouting() throws {
        try validate()
        let text = mode == .upstream ? "upstream\n\(host)\n\(port)\n" : "\(mode.rawValue)\n"
        try Data(text.utf8).write(to: Self.file, options: .atomic)
    }
    func save() throws {
        try writeRouting()
        try JSONEncoder().encode(self).write(to: Self.preferencesFile, options: .atomic)
    }
    static func guestForward(helper: String) -> String {
        func quote(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\"'\"'") + "'" }
        let command = quote(helper) + " " + quote(file.path)
        return ",guestfwd=tcp:10.0.2.100:3128-cmd:" + command.replacingOccurrences(of: ",", with: ",,")
    }
}
