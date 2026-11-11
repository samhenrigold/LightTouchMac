// Media import on one running device: the prepared file (PreparedMedia) staged
// over AFC into /LightTouch/<id>/, then committed into the library by the
// guest's itmedia (Music, Videos) or itphoto (Saved Photos) through the agent.

import Foundation
import HostServiceWire

public struct MediaImport: Sendable {
    public init(services: DeviceServices, guest: GuestServices) {
        self.services = services
        self.guest = guest
    }
    public let services: DeviceServices
    public let guest: GuestServices

    public func stage(_ media: PreparedMedia, progress: @escaping @Sendable (Double) -> Void) async throws {
        switch media {
        case .song(let song): try await services.stageSong(song, progress: progress)
        case .photo(let photo): try await services.stagePhoto(photo, progress: progress)
        case .video(let video): try await services.stageVideo(video, progress: progress)
        }
    }

    public func commit(_ media: PreparedMedia) async throws {
        do {
            switch media {
            case .song(let song): try await commitSong(song)
            case .photo(let photo): try await commitPhoto(photo)
            case .video(let video):
                try await commitLibraryMedia(id: video.id, metadata: video.metadata, destination: "Videos")
            }
        } catch let error as GuestAgentError {
            // The helper refused (its reason is in app.log through failureText); the row gets plain words.
            logEvent("media: \(error)")
            AppReports.failed("Media.commitFailed", error, ["destination": media.destination])
            throw DeviceToolsError.failed("\(media.destination) couldn’t add “\(media.title)”.")
        }
    }

    private func commitPhoto(_ photo: MediaPhoto) async throws {
        guard
            try await guest.commitMedia(
                id: photo.id,
                helper: "itphoto",
                localHelper: { try Self.guestTool("itphoto") },
                metadata: nil
            )
        else {
            throw DeviceToolsError.failed(
                "Photos didn’t confirm the import. Check Saved Photos before importing it again."
            )
        }
    }

    /// Once this starts, keep the staged audio even on an uncertain outcome.
    /// The guest service owns database mutations and reconciles the same path.
    private func commitSong(_ song: MediaSong) async throws {
        try await commitLibraryMedia(id: song.id, metadata: song.metadata, destination: "Music")
    }

    private func commitLibraryMedia(id: String, metadata: URL, destination: String) async throws {
        guard
            try await guest.commitMedia(
                id: id,
                helper: "itmedia",
                localHelper: { try Self.guestTool("itmedia") },
                metadata: metadata
            )
        else {
            throw DeviceToolsError.failed(
                "\(destination) didn’t confirm the import. The copied media has been retained."
            )
        }
    }

    /// The helper shipped with this app's media metadata contract.
    private static func guestTool(_ name: String) throws -> URL {
        guard let path = Bundled.resolve(name, fallbacks: ["\(Bundled.filesRoot)/../qemu-ios/contrib/it-media/\(name)"])
        else {
            throw DeviceToolsError.toolMissing(name)
        }
        return URL(fileURLWithPath: path)
    }
}
