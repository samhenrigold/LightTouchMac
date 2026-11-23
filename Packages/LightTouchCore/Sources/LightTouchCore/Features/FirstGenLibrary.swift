// Media import on iPhone OS 1.x, which has no guest agent to commit through: everything goes over AFC into the Media
// folder while the device runs. A song or video is copied under iTunes_Control/Music and added to the iTunesDB
// (ITunesDB, signed with hash58 for the device, which 1.1.x checks). On the iPhone a photo becomes the next
// DCIM/100APPLE/IMG_NNNN.JPG with its IMG_NNNN.THM, the DCF group its Camera Roll scans; the iPod touch's Photos lists
// only iTunes' photo library, so there it goes into Photos/Photo Database (PhotoDatabase) with its thumbnails.

import CoreGraphics
import Foundation
import HostServiceClient
import HostServiceWire
import ImageIO

public struct FirstGenLibrary: Sendable {
    public init(services: DeviceServices) { self.services = services }
    public let services: DeviceServices

    static let database = "iTunes_Control/iTunes/iTunesDB"
    static let photos = "DCIM/100APPLE"
    static let photoDatabase = "Photos/Photo Database"

    /// `willCommit`: the file is on the device, and the library write, which isn't cancelled, starts.
    public func add(
        _ media: PreparedMedia,
        progress: @escaping @Sendable (Double) -> Void,
        willCommit: () -> Void = {}
    ) async throws {
        switch media {
        case .song(let song):
            try await addTrack(song.audio, id: song.id, metadata: song.metadata, movie: false, progress, willCommit)
        case .video(let video):
            try await addTrack(video.video, id: video.id, metadata: video.metadata, movie: true, progress, willCommit)
        case .photo(let photo):
            // the iPhone's camera fills DCIM, which its Camera Roll shows; the iPod touch has neither
            if try await services.lockdownValue("DeviceClass", domain: nil) == "iPod" {
                try await addLibraryPhoto(photo.image, willCommit)
            } else {
                try await addPhoto(photo.image, progress: progress)
                willCommit()
            }
        }
    }

    /// The tracks the device's iTunesDB lists; none where it has no database yet.
    public func tracks() async throws -> [ITunesDB.Track] {
        guard let data = try await download(Self.database) else { return [] }
        return try ITunesDB.tracks(in: data)
    }

    private func addTrack(
        _ file: URL,
        id: String,
        metadata: URL,
        movie: Bool,
        _ progress: @escaping @Sendable (Double) -> Void,
        _ willCommit: () -> Void
    ) async throws {
        let suffix = file.pathExtension.lowercased()
        // The content ID names the file, so a second import of the same song is the same file.
        let name = "LT" + id.replacingOccurrences(of: "-", with: "").prefix(12).uppercased() + "." + suffix
        let remote = "iTunes_Control/Music/F00/" + name
        // A database this can't read is never replaced: that would lose the songs it lists.
        var tracks = try await self.tracks()
        _ = try await services.stageFile(file, remote: remote, reuseIdentical: true, progress: progress)
        let location = ":" + remote.replacingOccurrences(of: "/", with: ":")
        tracks.removeAll { $0.location == location }
        tracks.append(
            try Self.track(
                file,
                metadata: metadata,
                id: (tracks.map(\.id).max() ?? 99) + 1,
                location: location,
                movie: movie
            )
        )
        willCommit()
        try await publish(ITunesDB.make(tracks, databaseID: UInt64.random(in: 1...UInt64.max)))
    }

    /// The database's track for a prepared file: its title, artist, album, genre and length from the metadata
    /// PreparedMedia staged beside it (MediaSong's tags, MediaVideo's title), the file's own name for a title it lacks.
    nonisolated static func track(_ file: URL, metadata: URL, id: UInt32, location: String, movie: Bool) throws
        -> ITunesDB.Track
    {
        let properties =
            try PropertyListSerialization.propertyList(from: Data(contentsOf: metadata), format: nil) as? [String: Any]
            ?? [:]
        let bytes = (try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        let (type, kind): (String, String) =
            switch file.pathExtension.lowercased() {
            case "mp3": ("MP3 ", "MPEG audio file")
            case "wav": ("WAV ", "WAV audio file")
            case "m4v", "mp4", "mov": ("M4V ", "MPEG-4 video file")
            default: ("M4A ", "AAC audio file")
            }
        return ITunesDB.Track(
            id: id,
            persistentID: UInt64.random(in: 1...UInt64.max),
            title: properties["title"] as? String ?? file.deletingPathExtension().lastPathComponent,
            location: location,
            fileType: type,
            kind: kind,
            bytes: UInt32(clamping: bytes),
            milliseconds: UInt32(clamping: Int((properties["duration_ms"] as? Double) ?? 0)),
            mediaType: movie ? ITunesDB.Track.movie : ITunesDB.Track.audio,
            artist: properties["artist"] as? String,
            album: properties["album"] as? String,
            genre: properties["genre"] as? String
        )
    }

    /// Writes the database, signed for this device where lockdown names its FireWire ID (`signing`).
    func publish(_ database: Data, signing: Bool = true) async throws {
        var database = database
        if signing, let id = try await fireWireID() { database = ITunesDB.signed(database, fireWireID: id) }
        try await sync(database, to: Self.database)
    }

    /// `data` written to `remote` as iTunes syncs a library file (syncLibraryFile).
    private func sync(_ data: Data, to remote: String) async throws {
        let local = FileManager.default.temporaryDirectory.appendingPathComponent("ltm-library-" + UUID().uuidString)
        try data.write(to: local)
        defer { try? FileManager.default.removeItem(at: local) }
        try await services.syncLibraryFile(local, remote: remote)
    }

    /// The images the device's Photo Database lists; none where it has none yet.
    public func libraryPhotos() async throws -> [PhotoDatabase.Image] {
        guard let data = try await download(Self.photoDatabase) else { return [] }
        return try PhotoDatabase.images(in: data)
    }

    /// A photo added to iTunes' photo library: its thumbnails in each format, each in its own .ithmb under
    /// Photos/Thumbs, then the database with it added.
    private func addLibraryPhoto(_ image: URL, _ willCommit: () -> Void) async throws {
        // A database this can't read is never replaced: that would lose the photos it lists.
        var images = try await libraryPhotos()
        let id = (images.map(\.id).max() ?? PhotoDatabase.firstID - 1) + 1
        guard let source = CGImageSourceCreateWithURL(image as CFURL, nil),
            let picture = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else { throw DeviceToolsError.failed("This photo couldn’t be read.") }
        var thumbnails: [PhotoDatabase.Thumbnail] = []
        for format in PhotoDatabase.photoFormats {
            let name = "F\(format.id)_\(id).ithmb"
            let (pixels, thumbnail) = try PhotoDatabase.pixels(
                of: picture, in: format, file: ":Thumbs:" + name, offset: 0)
            let local = FileManager.default.temporaryDirectory.appendingPathComponent("ltm-ithmb-" + UUID().uuidString)
            try pixels.write(to: local)
            defer { try? FileManager.default.removeItem(at: local) }
            _ = try await services.stageFile(local, remote: "Photos/Thumbs/" + name, replace: true) { _ in }
            thumbnails.append(thumbnail)
        }
        images.append(PhotoDatabase.Image(id: id, thumbnails: thumbnails))
        willCommit()
        try await sync(PhotoDatabase.make(images), to: Self.photoDatabase)
    }

    /// The FairPlayID lockdown keeps for iTunes, whose first 8 bytes key hash58.
    func fireWireID() async throws -> [UInt8]? {
        try await services.lockdownValue("FairPlayID", domain: "com.apple.mobile.iTunes").flatMap(ITunesDB.fireWireID)
    }

    private func addPhoto(_ image: URL, progress: @escaping @Sendable (Double) -> Void) async throws {
        let names = (try? await services.files(in: Self.photos).map(\.name)) ?? []
        let taken = names.compactMap { name -> Int? in
            guard name.uppercased().hasPrefix("IMG_") else { return nil }
            return Int(name.dropFirst(4).prefix(4))
        }
        let number = (taken.max() ?? 0) + 1
        guard number <= 9999 else { throw DeviceToolsError.failed("Saved Photos is full.") }
        let name = Self.photos + "/" + String(format: "IMG_%04d", number)
        // the thumbnail first: the Camera Roll reads the group as the JPG appears, and keeps a blank cell for one
        // without its THM
        let thumbnail = FileManager.default.temporaryDirectory.appendingPathComponent("ltm-thm-" + UUID().uuidString)
        try Self.cameraRollThumbnail(of: image).write(to: thumbnail)
        defer { try? FileManager.default.removeItem(at: thumbnail) }
        _ = try await services.stageFile(thumbnail, remote: name + ".THM") { _ in }
        _ = try await services.stageFile(image, remote: name + ".JPG", progress: progress)
    }

    /// The Camera Roll's grid cell for a photo, its DCF group's THM: PhotoLibrary writes and reads it as a JPEG of
    /// MLPhotoLibrary's format 1095, 75 by 75, cropped (the image's centered square).
    nonisolated static func cameraRollThumbnail(of image: URL) throws -> Data {
        let side = 75
        guard let source = CGImageSourceCreateWithURL(image as CFURL, nil),
            let full = CGImageSourceCreateImageAtIndex(source, 0, nil),
            let square = full.cropping(
                to: CGRect(
                    x: (full.width - min(full.width, full.height)) / 2,
                    y: (full.height - min(full.width, full.height)) / 2,
                    width: min(full.width, full.height),
                    height: min(full.width, full.height)
                )
            ),
            let context = CGContext(
                data: nil,
                width: side,
                height: side,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
            )
        else { throw DeviceToolsError.failed("This photo couldn’t be read.") }
        context.interpolationQuality = .high
        context.draw(square, in: CGRect(x: 0, y: 0, width: side, height: side))
        let data = NSMutableData()
        guard let thumbnail = context.makeImage(),
            let destination = CGImageDestinationCreateWithData(data, "public.jpeg" as CFString, 1, nil)
        else { throw DeviceToolsError.failed("The photo couldn’t be prepared.") }
        CGImageDestinationAddImage(
            destination, thumbnail, [kCGImageDestinationLossyCompressionQuality: 0.9] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            throw DeviceToolsError.failed("The photo couldn’t be prepared.")
        }
        return data as Data
    }

    /// `path`'s bytes over AFC, or nil where there is no such file.
    private func download(_ path: String) async throws -> Data? {
        let name = (path as NSString).lastPathComponent
        let listing: [DeviceFile]
        do {
            listing = try await services.files(in: (path as NSString).deletingLastPathComponent)
        } catch DeviceError
            .afc(.other(8))
        {
            return nil  // AFC_E_OBJECT_NOT_FOUND: no folder yet; any other failure is not "no database"
        }
        guard let file = listing.first(where: { $0.name == name }), file.isRegular else { return nil }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("ltm-afc-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: folder) }
        let local = folder.appendingPathComponent("file")
        try await services.download(file, to: local) { _ in }
        return try Data(contentsOf: local)
    }
}
