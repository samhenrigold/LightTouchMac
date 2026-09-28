import Foundation

enum PreparedMedia: Sendable {
    case song(MediaSong)
    case photo(MediaPhoto)
    case video(MediaVideo)

    nonisolated static let extensions = MediaSong.extensions.union(MediaPhoto.extensions).union(MediaVideo.extensions)

    var directory: URL {
        switch self {
        case .song(let song): song.directory
        case .photo(let photo): photo.directory
        case .video(let video): video.directory
        }
    }

    var title: String {
        switch self {
        case .song(let song): song.title
        case .photo(let photo): photo.title
        case .video(let video): video.title
        }
    }

    var destination: String {
        switch self {
        case .song: "Music"
        case .photo: "Photos"
        case .video: "Videos"
        }
    }

    nonisolated static func prepare(_ source: URL, profile: DeviceProfile) async throws -> PreparedMedia {
        if MediaSong.extensions.contains(source.pathExtension.lowercased()) {
            return .song(try await MediaSong.prepare(source))
        }
        if MediaVideo.extensions.contains(source.pathExtension.lowercased()) {
            return .video(try await MediaVideo.prepare(source, profile: profile))
        }
        return .photo(try await MediaPhoto.prepare(source))
    }
}
