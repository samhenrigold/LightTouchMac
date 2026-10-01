import Foundation
import AVFoundation
import AudioToolbox
import ImageIO

/// Immutable host staging copy. Metadata and uploaded bytes always describe
/// the same file, even if the selected source is edited while a job waits.
struct MediaSong: Sendable {
    let id: String
    let directory: URL
    let audio: URL
    let metadata: URL
    let title: String
    /// Cover art from the file's tags as a baseline JPEG, staged beside the audio.
    var artwork: URL? = nil

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
                throw DeviceToolsError.failed("Audio files must be smaller than 1 GB.")
            }
            let id = UUID().uuidString.lowercased()
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("ltm-music-" + id, isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
            var complete = false
            defer { if !complete { try? FileManager.default.removeItem(at: directory) } }
            var audio = directory.appendingPathComponent("audio." + ext)
            guard FileManager.default.createFile(atPath: audio.path, contents: nil) else {
                throw DeviceToolsError.failed("Couldn’t prepare the audio file.")
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
                    throw DeviceToolsError.failed("The converted audio must be smaller than 1 GB.")
                }
                try MediaIdentity.normalizeGeneratedMovie(converted)
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
            var (properties, cover) = try await tags(of: asset)
            properties["filename"] = audio.lastPathComponent
            properties["duration_ms"] = duration * 1000
            if properties["title"] == nil { properties["title"] = source.deletingPathExtension().lastPathComponent }
            var artwork: URL?
            if let cover, cover.count <= 16 << 20, let image = CGImageSourceCreateWithData(cover as CFData, nil),
               CGImageSourceGetCount(image) > 0,
               let dimensions = CGImageSourceCopyPropertiesAtIndex(image, 0, nil) as? [CFString: Any],
               let width = dimensions[kCGImagePropertyPixelWidth] as? Int,
               let height = dimensions[kCGImagePropertyPixelHeight] as? Int,
               width > 0, height > 0, width <= 16384, height <= 16384,
               width * height <= 32_000_000 {
                let url = directory.appendingPathComponent("artwork.jpg")
                // Unreadable art is dropped, never the song.
                if (try? MediaPhoto.writeBaselineJPEG(image, maxPixelSize: 640, to: url)) != nil {
                    artwork = url
                    properties["artwork"] = url.lastPathComponent
                }
            }
            let metadata = directory.appendingPathComponent("metadata.plist")
            try PropertyListSerialization.data(fromPropertyList: properties, format: .xml, options: 0)
                .write(to: metadata, options: .atomic)
            try Task.checkCancellation()
            let result = MediaSong(id: try MediaIdentity.identifier(for: audio), directory: directory, audio: audio,
                                   metadata: metadata, title: properties["title"] as! String, artwork: artwork)
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

    /// Every tag the device's Music library keeps, from iTunes (MP4) or ID3 (MP3) metadata, with
    /// the common keyspace as the fallback for other containers. Keys are the metadata plist's
    /// (itmedia maps them onto MusicLibrary's item properties). Returns the front cover's bytes too.
    nonisolated static func tags(of asset: AVAsset) async throws -> ([String: Any], Data?) {
        var properties: [String: Any] = [:]
        var cover: Data?
        func text(_ item: AVMetadataItem) async throws -> String? {
            guard let value = try await item.load(.stringValue)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !value.isEmpty, value.utf8.count <= 4096 else { return nil }
            return value
        }
        /// "3/12", or iTunes' binary trkn/disk atom: 2 pad bytes, UInt16 number, UInt16 count.
        func pair(_ item: AVMetadataItem) async throws -> (Int, Int)? {
            guard let value = try await text(item) else {
                guard let data = try await item.load(.dataValue), data.count >= 6 else { return nil }
                let bytes = [UInt8](data)
                return (Int(bytes[2]) << 8 | Int(bytes[3]), Int(bytes[4]) << 8 | Int(bytes[5]))
            }
            let parts = value.split(separator: "/", maxSplits: 1).map { Int($0.trimmingCharacters(in: .whitespaces)) ?? 0 }
            return (parts[0], parts.count > 1 ? parts[1] : 0)
        }
        func set(_ key: String, _ value: Any?) { if let value, properties[key] == nil { properties[key] = value } }
        func setPair(_ keys: (String, String), _ value: (Int, Int)?) {
            guard let (number, count) = value else { return }
            if (1...65535).contains(number) { set(keys.0, number) }
            if (1...65535).contains(count) { set(keys.1, count) }
        }
        for item in try await asset.load(.metadata) {
            guard let identifier = item.identifier else { continue }
            switch identifier {
            case .iTunesMetadataSongName, .id3MetadataTitleDescription: set("title", try await text(item))
            case .iTunesMetadataArtist, .id3MetadataLeadPerformer: set("artist", try await text(item))
            case .iTunesMetadataAlbum, .id3MetadataAlbumTitle: set("album", try await text(item))
            case .iTunesMetadataAlbumArtist, .id3MetadataBand: set("album_artist", try await text(item))
            case .iTunesMetadataComposer, .id3MetadataComposer: set("composer", try await text(item))
            case .iTunesMetadataUserGenre, .id3MetadataContentType: set("genre", (try await text(item)).map(genreName))
            case .iTunesMetadataPredefinedGenre:
                // gnre: a UInt16 ID3v1 genre index plus one.
                if let data = try await item.load(.dataValue), data.count >= 2 {
                    set("genre", id3Genres.indices.contains(Int(data[1]) - 1) ? id3Genres[Int(data[1]) - 1] : nil)
                }
            case .iTunesMetadataTrackNumber, .id3MetadataTrackNumber: setPair(("track_number", "track_count"), try await pair(item))
            case .iTunesMetadataDiscNumber, .id3MetadataPartOfASet: setPair(("disc_number", "disc_count"), try await pair(item))
            case .iTunesMetadataReleaseDate, .id3MetadataYear, .id3MetadataRecordingTime, .id3MetadataOriginalReleaseYear:
                if let value = try await text(item), let year = Int(value.prefix(4)), (1...9999).contains(year) { set("year", year) }
            case .iTunesMetadataDiscCompilation, AVMetadataIdentifier("id3/TCMP"):
                var flag = try await item.load(.numberValue)?.intValue
                if flag == nil, let value = try await text(item) { flag = Int(value) }
                if let flag { set("compilation", flag != 0) }
            case .iTunesMetadataCoverArt, .id3MetadataAttachedPicture:
                if cover == nil { cover = try await item.load(.dataValue) }
            default: break
            }
        }
        for item in try await asset.load(.commonMetadata) {
            switch item.commonKey {
            case .commonKeyTitle: set("title", try await text(item))
            case .commonKeyArtist: set("artist", try await text(item))
            case .commonKeyAlbumName: set("album", try await text(item))
            case .commonKeyArtwork: if cover == nil { cover = try await item.load(.dataValue) }
            default: break
            }
        }
        return (properties, cover)
    }

    /// ID3 genres may be "(13)", "13" or "(13)Refinement"; resolve the ID3v1 index to its name.
    nonisolated private static func genreName(_ value: String) -> String {
        let digits = value.hasPrefix("(") ? value.dropFirst().prefix { $0 != ")" } : Substring(value)
        guard let index = Int(digits), id3Genres.indices.contains(index) else { return value }
        return id3Genres[index]
    }

    // ponytail: the 80 standard ID3v1 genres; Winamp's extensions (80+) pass through as numbers.
    nonisolated private static let id3Genres = [
        "Blues", "Classic Rock", "Country", "Dance", "Disco", "Funk", "Grunge", "Hip-Hop", "Jazz", "Metal",
        "New Age", "Oldies", "Other", "Pop", "R&B", "Rap", "Reggae", "Rock", "Techno", "Industrial",
        "Alternative", "Ska", "Death Metal", "Pranks", "Soundtrack", "Euro-Techno", "Ambient", "Trip-Hop", "Vocal", "Jazz+Funk",
        "Fusion", "Trance", "Classical", "Instrumental", "Acid", "House", "Game", "Sound Clip", "Gospel", "Noise",
        "AlternRock", "Bass", "Soul", "Punk", "Space", "Meditative", "Instrumental Pop", "Instrumental Rock", "Ethnic", "Gothic",
        "Darkwave", "Techno-Industrial", "Electronic", "Pop-Folk", "Eurodance", "Dream", "Southern Rock", "Comedy", "Cult", "Gangsta",
        "Top 40", "Christian Rap", "Pop/Funk", "Jungle", "Native American", "Cabaret", "New Wave", "Psychadelic", "Rave", "Showtunes",
        "Trailer", "Lo-Fi", "Tribal", "Acid Punk", "Acid Jazz", "Polka", "Retro", "Musical", "Rock & Roll", "Hard Rock",
    ]

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
