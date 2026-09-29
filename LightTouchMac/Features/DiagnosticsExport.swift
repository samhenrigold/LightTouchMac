// Help > Export Diagnostics: the logs, device records and a summary zipped atomically into a scratch
// directory. Foundation only; tests/offline/check-storage-lifecycle.py compiles it whole.

import Foundation

// MARK: - Diagnostics storage

/// Each export owns its scratch and publishes one complete archive. Kept apart
/// from the window so the failure/cancellation paths can run without a device.
nonisolated enum DiagnosticsExport {
    @concurrent
    static func write(to destination: URL, logs: [URL], info: String,
                      temporaryRoot: URL = FileManager.default.temporaryDirectory,
                      archiver: URL = URL(fileURLWithPath: "/usr/bin/ditto")) async throws {
        try Task.checkCancellation()
        let fm = FileManager.default
        let scratch = temporaryRoot.appendingPathComponent("LightTouch-diagnostics-" + UUID().uuidString,
                                                          isDirectory: true)
        try fm.createDirectory(at: scratch, withIntermediateDirectories: false,
                               attributes: [.posixPermissions: 0o700])
        defer { try? fm.removeItem(at: scratch) }
        let staging = scratch.appendingPathComponent("LightTouchMac-diagnostics", isDirectory: true)
        try fm.createDirectory(at: staging, withIntermediateDirectories: false)
        for source in logs where fm.fileExists(atPath: source.path) {
            try Task.checkCancellation()
            try fm.copyItem(at: source, to: staging.appendingPathComponent(source.lastPathComponent))
        }
        try info.write(to: staging.appendingPathComponent("info.txt"), atomically: true, encoding: .utf8)

        // Keep the final rename on the destination volume. Failure or cancellation
        // leaves an existing user-selected archive untouched.
        let archive = destination.deletingLastPathComponent()
            .appendingPathComponent(".LightTouch-diagnostics-" + UUID().uuidString + ".zip")
        defer { try? fm.removeItem(at: archive) }
        try await runArchiver(archiver, staging: staging, archive: archive)
        let attributes = try fm.attributesOfItem(atPath: archive.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular,
              (attributes[.size] as? NSNumber)?.uint64Value ?? 0 > 0 else {
            throw CocoaError(.fileReadCorruptFile)
        }
        try Task.checkCancellation()
        guard rename(archive.path, destination.path) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }

    private static func runArchiver(_ executable: URL, staging: URL, archive: URL) async throws {
        let process = Process()
        process.executableURL = executable
        process.arguments = ["-c", "-k", "--sequesterRsrc", "--keepParent", staging.path, archive.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        let status: Int32 = try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                process.terminationHandler = { child in
                    continuation.resume(returning: child.terminationStatus)
                }
                do {
                    try process.run()
                    // Cancellation may have arrived before the process was live.
                    if Task.isCancelled, process.isRunning { process.terminate() }
                } catch {
                    process.terminationHandler = nil
                    continuation.resume(throwing: error)
                }
            }
        } onCancel: {
            if process.isRunning { process.terminate() }
        }
        try Task.checkCancellation()
        guard status == 0 else {
            throw NSError(domain: "LightTouch.Diagnostics", code: Int(status), userInfo: [
                NSLocalizedDescriptionKey: "Couldn’t create the diagnostics archive (exit \(status))."
            ])
        }
    }
}
