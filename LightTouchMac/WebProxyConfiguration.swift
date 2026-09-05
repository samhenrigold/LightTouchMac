import Foundation

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
    static var file: URL { Bundled.stateDirectory.appendingPathComponent("web-proxy.conf") }
    static var preferencesFile: URL { Bundled.stateDirectory.appendingPathComponent("web-proxy.json") }
    static func load() -> Self {
        guard let data = try? Data(contentsOf: preferencesFile),
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
    func writeRouting() throws {
        try validate()
        let text = mode == .archive ? "archive\n\(archiveDate)\n" : "\(mode.rawValue)\n"
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
