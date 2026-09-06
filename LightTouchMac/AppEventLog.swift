import Foundation

/// Keep app events alongside device logs without doing file I/O on the caller.
nonisolated func logEvent(_ message: String, _ arguments: CVarArg...) {
    let value = arguments.isEmpty ? message : String(format: message, arguments: arguments)
    NSLog("%@", value)
    AppEventLog.shared.append(value)
}

nonisolated final class AppEventLog: @unchecked Sendable {
    static let shared = AppEventLog(directory: Bundled.stateDirectory)
    private let directory: URL
    private let queue = DispatchQueue(label: "LightTouch.app-events", qos: .utility)
    // Access only on queue; one current and one previous 1 MB log.
    private var failed = false

    init(directory: URL) { self.directory = directory }

    func append(_ message: String) {
        let bounded = String(decoding: message.utf8.prefix(32_000), as: UTF8.self)
        let line = "\(Date().ISO8601Format()) \(bounded)\n"
        queue.async { [self] in
            guard !failed else { return }
            let url = directory.appendingPathComponent("app.log")
            do {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.intValue ?? 0
                let data = Data(line.utf8)
                if size + data.count > 1_000_000 {
                    Bundled.rotateLog(at: url)
                    guard !FileManager.default.fileExists(atPath: url.path) else { throw POSIXError(.EIO) }
                }
                let fd = open(url.path, O_WRONLY | O_APPEND | O_CREAT | O_CLOEXEC, 0o600)
                guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
                let file = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
                defer { try? file.close() }
                try file.write(contentsOf: data)
            } catch {
                failed = true
                NSLog("Cannot write app events: %@", error.localizedDescription)
            }
        }
    }

    func flush() async {
        await withCheckedContinuation { continuation in
            queue.async { continuation.resume() }
        }
    }
}


