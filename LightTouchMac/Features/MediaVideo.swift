import Foundation
import AVFoundation

/// A private, iPod-compatible movie prepared before it joins the device queue.
struct MediaVideo: Sendable {
    let id: String
    let directory: URL
    let video: URL
    let metadata: URL
    let title: String

    nonisolated static let extensions: Set<String> = ["mp4", "m4v", "mov"]

    nonisolated static func prepare(_ source: URL, cacheDirectory: URL? = nil, profile: DeviceProfile) async throws -> MediaVideo {
        let worker = Task.detached {
            try Task.checkCancellation()
            guard extensions.contains(source.pathExtension.lowercased()) else {
                throw DeviceToolsError.failed("Choose an MP4, M4V or QuickTime video.")
            }
            let values = try source.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            guard values.isRegularFile == true, let size = values.fileSize, size > 0, size <= 1 << 30 else {
                throw DeviceToolsError.failed("Videos must be smaller than 1 GB.")
            }
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("ltm-video-" + UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                                    attributes: [.posixPermissions: 0o700])
            var complete = false
            defer { if !complete { try? FileManager.default.removeItem(at: directory) } }
            // The original can be renamed or edited after the drop. Keep a
            // snapshot so the exported movie and its metadata stay together.
            let snapshot = directory.appendingPathComponent("source." + source.pathExtension.lowercased())
            let input = try FileHandle(forReadingFrom: source)
            defer { try? input.close() }
            guard FileManager.default.createFile(atPath: snapshot.path, contents: nil,
                                                  attributes: [.posixPermissions: 0o600]) else {
                throw DeviceToolsError.failed("Couldn’t prepare the video.")
            }
            let copy = try FileHandle(forWritingTo: snapshot)
            defer { try? copy.close() }
            var copied = 0
            while copied < size {
                try Task.checkCancellation()
                guard let bytes = try input.read(upToCount: min(65536, size - copied)), !bytes.isEmpty else {
                    throw DeviceToolsError.failed("The video changed while it was being prepared.")
                }
                try copy.write(contentsOf: bytes)
                copied += bytes.count
            }
            guard try input.read(upToCount: 1)?.isEmpty != false else {
                throw DeviceToolsError.failed("The video changed while it was being prepared.")
            }
            try copy.close()
            let asset = AVURLAsset(url: snapshot)
            let duration = try await asset.load(.duration).seconds
            guard duration.isFinite, duration > 0, duration <= 86400,
                  try await !asset.load(.hasProtectedContent),
                  try await asset.loadTracks(withMediaType: .video).count == 1,
                  try await asset.loadTracks(withMediaType: .audio).count <= 1 else {
                throw DeviceToolsError.failed("Choose an unprotected video with one video track and no more than one audio track.")
            }
            var title = source.deletingPathExtension().lastPathComponent
            for item in try await asset.load(.commonMetadata) where item.commonKey == .commonKeyTitle {
                if let value = try await item.load(.stringValue), !value.isEmpty, value.utf8.count <= 4096 { title = value }
            }
            let output = directory.appendingPathComponent("video.m4v")
            let cache = cacheDirectory ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("gold.samhenri.LightTouchMac/Converted Videos", isDirectory: true)
            try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: cache.path)
            let cached = cache.appendingPathComponent(try MediaIdentity.identifier(for: snapshot) + ".m4v")
            var reused = false
            if FileManager.default.fileExists(atPath: cached.path) {
                do {
                    try FileManager.default.copyItem(at: cached, to: output)
                    _ = try await validatedDuration(of: output, expected: duration, profile: profile)
                    reused = true
                } catch {
                    try Task.checkCancellation()
                    try? FileManager.default.removeItem(at: output)
                    try? FileManager.default.removeItem(at: cached)
                }
            }
            if !reused {
                let export = await MediaVideoExport(source: snapshot, destination: output, profile: profile)
                try await withTaskCancellationHandler {
                    try await export.run()
                } onCancel: {
                    Task { await export.cancel() }
                }
                try Task.checkCancellation()
                _ = try await validatedDuration(of: output, expected: duration, profile: profile)
                try MediaIdentity.normalizeGeneratedMovie(output)
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: output.path)
                // H.264 encoding can vary by a byte between identical runs.
                // Reuse the completed conversion so Retry after an uncertain
                // guest reply reconciles one library entry, not a second movie.
                // Publish atomically; simultaneous imports adopt the winner.
                // FileManager.moveItem checks for the destination and then
                // renames, so two racing exports both "win" and the second
                // silently replaces the first. RENAME_EXCL fails in the kernel.
                let publishing = cache.appendingPathComponent(".\(UUID().uuidString).m4v")
                defer { try? FileManager.default.removeItem(at: publishing) }
                try FileManager.default.copyItem(at: output, to: publishing)
                if renamex_np(publishing.path, cached.path, UInt32(RENAME_EXCL)) != 0 {
                    guard errno == EEXIST else {
                        throw DeviceToolsError.failed("Couldn’t save the converted video (\(String(cString: strerror(errno)))).")
                    }
                    try FileManager.default.removeItem(at: output)
                    try FileManager.default.copyItem(at: cached, to: output)
                }
            }
            try Task.checkCancellation()
            let exportedDuration = try await validatedDuration(of: output, expected: duration, profile: profile)
            let metadata = directory.appendingPathComponent("metadata.plist")
            let properties: [String: Any] = [
                "filename": output.lastPathComponent,
                "kind": "feature-movie",
                "title": title,
                "duration_ms": exportedDuration * 1000,
            ]
            try PropertyListSerialization.data(fromPropertyList: properties, format: .xml, options: 0)
                .write(to: metadata, options: .atomic)
            let result = MediaVideo(id: try MediaIdentity.identifier(for: output), directory: directory,
                                    video: output, metadata: metadata, title: title)
            try FileManager.default.removeItem(at: snapshot)
            complete = true
            return result
        }
        return try await withTaskCancellationHandler {
            let video = try await worker.value
            if Task.isCancelled {
                try? FileManager.default.removeItem(at: video.directory)
                throw CancellationError()
            }
            return video
        } onCancel: { worker.cancel() }
    }

    nonisolated private static func validatedDuration(of file: URL, expected duration: Double, profile: DeviceProfile) async throws -> Double {
        let values = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        let asset = AVURLAsset(url: file)
        let exportedDuration = try await asset.load(.duration).seconds
        guard values.isRegularFile == true, values.isSymbolicLink != true,
              let size = values.fileSize, size > 0 else {
            throw DeviceToolsError.failed("The prepared video couldn’t be read.")
        }
        guard size <= 1 << 30 else {
            throw DeviceToolsError.failed("The prepared video is too large. Choose a shorter video.")
        }
        guard exportedDuration.isFinite, abs(exportedDuration - duration) < 0.2,
              try await asset.loadTracks(withMediaType: .video).count == 1 else {
            throw DeviceToolsError.failed("The whole video couldn’t be converted for the \(profile.shortName). Try a shorter video.")
        }
        return exportedDuration
    }
}

/// Keep the non-Sendable exporter on one actor, including cancellation on
/// macOS 14, where the newer throwing export API is unavailable.
@MainActor
private final class MediaVideoExport {
    private let source: URL
    private let destination: URL
    private let profile: DeviceProfile
    private var session: AVAssetExportSession?

    init(source: URL, destination: URL, profile: DeviceProfile) {
        self.source = source; self.destination = destination; self.profile = profile
    }

    func run() async throws {
        try Task.checkCancellation()
        // Apple's device preset produces the H.264/AAC profile, dimensions
        // and frame rate supported by the original iPod hardware.
        guard let session = AVAssetExportSession(asset: AVURLAsset(url: source), presetName: AVAssetExportPresetAppleM4ViPod) else {
            throw DeviceToolsError.failed("This video couldn’t be converted for the \(profile.shortName).")
        }
        self.session = session
        defer { self.session = nil }
        session.metadata = []
        session.fileLengthLimit = 1 << 30
        if #available(macOS 15.0, *) {
            try await session.export(to: destination, as: .m4v)
        } else {
            session.outputURL = destination
            session.outputFileType = .m4v
            await session.export()
            try Task.checkCancellation()
            guard session.status == .completed else {
                throw session.error ?? DeviceToolsError.failed("This video couldn’t be converted for the \(profile.shortName).")
            }
        }
    }

    func cancel() {
        if #unavailable(macOS 15.0) { session?.cancelExport() }
    }
}
