import Foundation
import OSLog

/// Keep app events alongside device logs without doing file I/O on the caller.
private nonisolated let appEventLogger = Logger(subsystem: StorageLocations.bundleIdentifier, category: "app")

nonisolated func logEvent(_ message: String, _ arguments: CVarArg...) {
    let value = arguments.isEmpty ? message : String(format: message, arguments: arguments)
    appEventLogger.info("\(value)")
    AppEventLog.shared.append(value)
}

nonisolated final class AppEventLog: Sendable {
    static let shared = AppEventLog(directory: Bundled.preparedLogsDirectory)
    private let log: RotatingLog?
    private let queue = DispatchQueue(label: "LightTouch.app-events", qos: .utility)
    init(directory: URL?) { log = directory.map { RotatingLog(url: $0.appendingPathComponent("app.log")) } }

    func append(_ message: String) {
        let bounded = String(decoding: message.utf8.prefix(32_000), as: UTF8.self)
        let line = "\(Date().ISO8601Format()) \(bounded)\n"
        queue.async { [log] in log?.append(Data(line.utf8)) }
    }

    func flush() async {
        await withCheckedContinuation { continuation in
            queue.async { continuation.resume() }
        }
    }
}


