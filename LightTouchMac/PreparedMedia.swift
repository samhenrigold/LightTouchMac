import Foundation

enum PreparedMedia: Sendable {
    case song(MediaSong)
    case photo(MediaPhoto)

    nonisolated static let extensions = MediaSong.extensions.union(MediaPhoto.extensions)

    var directory: URL {
        switch self {
        case .song(let song): song.directory
        case .photo(let photo): photo.directory
        }
    }

    var title: String {
        switch self {
        case .song(let song): song.title
        case .photo(let photo): photo.title
        }
    }

    var destination: String {
        switch self {
        case .song: "Music"
        case .photo: "Photos"
        }
    }

    nonisolated static func prepare(_ source: URL) async throws -> PreparedMedia {
        if MediaSong.extensions.contains(source.pathExtension.lowercased()) {
            return .song(try await MediaSong.prepare(source))
        }
        return .photo(try await MediaPhoto.prepare(source))
    }
}
