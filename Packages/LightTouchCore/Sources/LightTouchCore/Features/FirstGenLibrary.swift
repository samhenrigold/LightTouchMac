// Media import on iPhone OS 1.x, which has no guest agent to commit through: everything goes over AFC into the Media
// folder while the device runs. A song or video is copied under iTunes_Control/Music and added to the iTunesDB
// (ITunesDB, signed with hash58 for the device, which 1.1.x checks); a photo becomes the next DCIM/100APPLE/IMG_NNNN.JPG,
// the DCF group 1.x's Photos scans.

import Foundation
import HostServiceClient
import HostServiceWire

public struct FirstGenLibrary: Sendable {
    public init(services: DeviceServices) { self.services = services }
    public let services: DeviceServices

    static let database = "iTunes_Control/iTunes/iTunesDB"
    static let photos = "DCIM/100APPLE"

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
            try await addPhoto(photo.image, progress: progress)
            willCommit()
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
        let local = FileManager.default.temporaryDirectory.appendingPathComponent("ltm-itunesdb-" + UUID().uuidString)
        try database.write(to: local)
        defer { try? FileManager.default.removeItem(at: local) }
        try await services.syncLibraryFile(local, remote: Self.database)
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
        let remote = Self.photos + "/" + String(format: "IMG_%04d.JPG", number)
        _ = try await services.stageFile(image, remote: remote, progress: progress)
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
