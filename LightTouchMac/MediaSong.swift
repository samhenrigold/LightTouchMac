import Foundation
import AVFoundation
import AudioToolbox

/// Immutable host staging copy. Metadata and uploaded bytes always describe
/// the same file, even if the selected source is edited while a job waits.
struct MediaSong: Sendable {
    let id: String
    let directory: URL
    let audio: URL
    let metadata: URL
    let title: String

    nonisolated static let extensions: Set<String> = ["mp3", "m4a", "wav"]

    nonisolated static func prepare(_ source: URL) async throws -> MediaSong {
        let worker = Task.detached {
            try Task.checkCancellation()
            let ext = source.pathExtension.lowercased()
            guard extensions.contains(ext) else {
                throw DeviceToolsError.failed("Choose an MP3, M4A or WAV audio file.")
            }
            let values = try source.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            guard values.isRegularFile == true, let size = values.fileSize,
                  size > 0, size <= 1 << 30 else {
                throw DeviceToolsError.failed("Audio files must be nonempty and no larger than 1 GB.")
            }
            let id = UUID().uuidString.lowercased()
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("ltm-music-" + id, isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
            var complete = false
            defer { if !complete { try? FileManager.default.removeItem(at: directory) } }
            let audio = directory.appendingPathComponent("audio." + ext)
            guard FileManager.default.createFile(atPath: audio.path, contents: nil) else {
                throw DeviceToolsError.failed("Could not prepare the audio file.")
            }
            let input = try FileHandle(forReadingFrom: source)
            defer { try? input.close() }
            let output = try FileHandle(forWritingTo: audio)
            defer { try? output.close() }
            var copied = 0
            while copied < size {
                try Task.checkCancellation()
                guard let bytes = try input.read(upToCount: min(65536, size - copied)), !bytes.isEmpty else {
                    throw DeviceToolsError.failed("The audio file changed while it was being prepared.")
                }
                try output.write(contentsOf: bytes)
                copied += bytes.count
            }
            guard try input.read(upToCount: 1)?.isEmpty != false else {
                throw DeviceToolsError.failed("The audio file changed while it was being prepared.")
            }
            try output.close()
            let asset = AVURLAsset(url: audio)
            let duration = try await asset.load(.duration).seconds
            guard duration.isFinite, duration > 0, duration <= 86400,
                  try await !asset.load(.hasProtectedContent) else {
                throw DeviceToolsError.failed("This audio file is protected or has an unsupported duration.")
            }
            let tracks = try await asset.loadTracks(withMediaType: .audio)
            guard tracks.count == 1, let track = tracks.first else {
                throw DeviceToolsError.failed("The file must contain one audio track.")
            }
            let formats = try await track.load(.formatDescriptions)
            let supported: Set<AudioFormatID> = [
                kAudioFormatMPEG4AAC, kAudioFormatMPEG4AAC_HE,
                kAudioFormatMPEGLayer3, kAudioFormatAppleLossless, kAudioFormatLinearPCM,
            ]
            guard !formats.isEmpty, formats.allSatisfy({ format in
                guard let stream = CMAudioFormatDescriptionGetStreamBasicDescription(format)?.pointee else { return false }
                return supported.contains(stream.mFormatID)
                    && (1...2).contains(stream.mChannelsPerFrame)
                    && (8000...48000).contains(stream.mSampleRate)
            }) else {
                throw DeviceToolsError.failed("Use AAC, MP3, Apple Lossless or PCM audio, with one or two channels at 8–48 kHz.")
            }
            var properties: [String: Any] = [
                "filename": audio.lastPathComponent,
                "title": source.deletingPathExtension().lastPathComponent,
                "duration_ms": duration * 1000,
            ]
            for item in try await asset.load(.commonMetadata) {
                let key: String?
                switch item.commonKey {
                case .commonKeyTitle: key = "title"
                case .commonKeyArtist: key = "artist"
                case .commonKeyAlbumName: key = "album"
                default: key = nil
                }
                if let key, let value = try await item.load(.stringValue),
                   !value.isEmpty, value.utf8.count <= 4096 {
                    properties[key] = value
                }
            }
            let metadata = directory.appendingPathComponent("metadata.plist")
            try PropertyListSerialization.data(fromPropertyList: properties, format: .xml, options: 0)
                .write(to: metadata, options: .atomic)
            try Task.checkCancellation()
            let result = MediaSong(id: id, directory: directory, audio: audio,
                                   metadata: metadata, title: properties["title"] as! String)
            complete = true
            return result
        }
        return try await withTaskCancellationHandler {
            let song = try await worker.value
            if Task.isCancelled {
                try? FileManager.default.removeItem(at: song.directory)
                throw CancellationError()
            }
            return song
        } onCancel: { worker.cancel() }
    }
}
