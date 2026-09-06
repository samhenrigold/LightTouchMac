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

    nonisolated static let extensions: Set<String> = ["mp3", "m4a", "aac", "wav"]

    nonisolated static func prepare(_ source: URL) async throws -> MediaSong {
        let worker = Task.detached {
            try Task.checkCancellation()
            let ext = source.pathExtension.lowercased()
            guard extensions.contains(ext) else {
                throw DeviceToolsError.failed("Choose an MP3, M4A, AAC or WAV audio file.")
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
            var audio = directory.appendingPathComponent("audio." + ext)
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
            if ext == "aac" {
                let converted = directory.appendingPathComponent("audio.m4a")
                try convertAAC(audio, to: converted)
                let size = try converted.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                guard size > 0, size <= 1 << 30 else {
                    throw DeviceToolsError.failed("The prepared audio must be nonempty and no larger than 1 GB.")
                }
                try MediaIdentity.normalizeGeneratedM4A(converted)
                try FileManager.default.removeItem(at: audio)
                audio = converted
            }
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
            let result = MediaSong(id: try MediaIdentity.identifier(for: audio), directory: directory, audio: audio,
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

    /// Stream raw ADTS AAC into an M4A file using macOS audio codecs. The
    /// legacy Music library expects a container; no external converter is needed.
    nonisolated private static func convertAAC(_ source: URL, to destination: URL) throws {
        try autoreleasepool {
            let input = try AVAudioFile(forReading: source)
            let format = input.processingFormat
            let codec = input.fileFormat.streamDescription.pointee.mFormatID
            guard [kAudioFormatMPEG4AAC, kAudioFormatMPEG4AAC_HE].contains(codec),
                  (1...2).contains(format.channelCount),
                  (8000...48000).contains(format.sampleRate),
                  let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4096) else {
                throw DeviceToolsError.failed("Use mono or stereo AAC audio at 8–48 kHz.")
            }
            let settings: [String: Any] = [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: format.sampleRate,
                AVNumberOfChannelsKey: format.channelCount,
                AVEncoderBitRateKey: 96000 * Int(format.channelCount),
            ]
            let output = try AVAudioFile(forWriting: destination, settings: settings,
                                        commonFormat: format.commonFormat, interleaved: format.isInterleaved)
            var frames: AVAudioFramePosition = 0
            while input.framePosition < input.length {
                try Task.checkCancellation()
                let remaining = input.length - input.framePosition
                try input.read(into: buffer, frameCount: AVAudioFrameCount(min(4096, remaining)))
                guard buffer.frameLength > 0 else {
                    throw DeviceToolsError.failed("The AAC file ended before all of its audio could be read.")
                }
                frames += AVAudioFramePosition(buffer.frameLength)
                guard Double(frames) / format.sampleRate <= 86400 else {
                    throw DeviceToolsError.failed("Audio files must be no longer than one day.")
                }
                try output.write(from: buffer)
                // Bound encoded output too; a day of stereo audio can exceed 1 GB.
                if frames % (4096 * 64) == 0 {
                    let size = try destination.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                    guard size <= 1 << 30 else {
                        throw DeviceToolsError.failed("The prepared audio is larger than 1 GB.")
                    }
                }
            }
            guard frames > 0 else { throw DeviceToolsError.failed("The AAC file contains no audio.") }
        } // Release the audio file and finalize its M4A headers before inspection/upload.
    }

}
