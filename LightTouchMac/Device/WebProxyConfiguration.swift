import HostRuntime
import Foundation

enum WebProxyStatus: Equatable {
    case waiting, applying, ready, failed
    /// No guest agent to trust the proxy certificate silently: the profile was offered instead.
    case needsTap

    func message(for profile: DeviceProfile) -> String? {
        switch self {
        case .waiting: "Waiting for \(profile.shortName)…"
        case .applying: "Updating proxy…"
        case .ready: nil
        case .failed: "Couldn’t update the proxy. Try again."
        case .needsTap: "Tap Install on the \(profile.shortName) to trust the proxy certificate."
        }
    }

    var isWorking: Bool { self == .waiting || self == .applying }
}

/// Host routing is read once per guest connection. Changes need no VM restart.
struct WebProxyConfiguration: Codable, Equatable {
    enum Mode: String, Codable {
        case off, direct, archive
    }
    var mode: Mode = .off
    var archiveDate = "20090909"
    static var dateFormatter: DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMdd"
        formatter.isLenient = false
        return formatter
    }
    var dateValue: Date { Self.dateFormatter.date(from: archiveDate) ?? Date() }
    /// Where a device's routing (web-proxy.conf), preferences (web-proxy.json)
    /// and proxy CA (web-proxy.conf.ca.*) live. The device that kept the
    /// legacy pairing conf keeps the legacy state-directory files too, so the
    /// CA its guest already trusts is unchanged; every other device has its own.
    static func directory(for instance: DeviceInstance) -> URL {
        instance.storage.usbmuxConf == "work/usbmuxd-conf" ? Bundled.stateDirectory : instance.paths.directory
    }
    static func file(in directory: URL) -> URL { directory.appendingPathComponent("web-proxy.conf") }
    static func preferencesFile(in directory: URL) -> URL { directory.appendingPathComponent("web-proxy.json") }
    static func load(from directory: URL) -> Self {
        guard let data = try? Data(contentsOf: preferencesFile(in: directory)),
              let value = try? JSONDecoder().decode(Self.self, from: data) else { return Self() }
        return value
    }
    func validate() throws {
        if mode == .archive {
            guard archiveDate.count == 8, let date = Self.dateFormatter.date(from: archiveDate),
                  Self.dateFormatter.string(from: date) == archiveDate else {
                throw DeviceToolsError.failed("Choose a valid archive date.")
            }
        }
    }
    func writeRouting(in directory: URL) throws {
        try validate()
        let text = mode == .archive ? "archive\n\(archiveDate)\n" : "\(mode.rawValue)\n"
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data(text.utf8).write(to: Self.file(in: directory), options: .atomic)
    }
    func save(in directory: URL) throws {
        try writeRouting(in: directory)
        try JSONEncoder().encode(self).write(to: Self.preferencesFile(in: directory), options: .atomic)
    }
    /// What the helper serves (BootConfig.webProxy): this directory's routing, and a socket in the temporary
    /// directory named for it (a Unix socket path stays under 104 bytes; the device directory may not).
    static func endpoint(directory: URL) -> WebProxyEndpoint {
        let config = file(in: directory).path
        let hash = config.utf8.reduce(UInt64(14695981039346656037)) { ($0 ^ UInt64($1)) &* 1099511628211 }
        return WebProxyEndpoint(config: config, socket: NSTemporaryDirectory() + "ltm-proxy-" + String(hash, radix: 16) + ".sock")
    }
    /// The guest's 10.0.2.100:3128: slirp runs one `nc` per connection into the helper's proxy (WebProxy.swift).
    static func guestForward(socket: String) -> String {
        func quote(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\"'\"'") + "'" }
        return ",guestfwd=tcp:10.0.2.100:3128-cmd:" + ("/usr/bin/nc -U " + quote(socket)).replacingOccurrences(of: ",", with: ",,")
    }
}
