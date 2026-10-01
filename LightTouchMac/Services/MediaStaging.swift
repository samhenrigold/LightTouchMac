import Foundation

extension DeviceServices {
    func stageSong(_ song: MediaSong, progress: @escaping @Sendable (Double) -> Void) async throws {
        guard UUID(uuidString: song.id) != nil,
              MediaSong.extensions.contains(song.audio.pathExtension),
              song.audio.lastPathComponent == "audio." + song.audio.pathExtension else {
            throw DeviceError.preflight("Invalid media staging path.")
        }
        _ = try await stageFile(song.audio, remote: "LightTouch/\(song.id)/\(song.audio.lastPathComponent)",
                                reuseIdentical: true, progress: progress)
    }

    func stagePhoto(_ photo: MediaPhoto, progress: @escaping @Sendable (Double) -> Void) async throws {
        guard UUID(uuidString: photo.id) != nil, photo.image.lastPathComponent == "image.jpg" else {
            throw DeviceError.preflight("Invalid photo staging path.")
        }
        _ = try await stageFile(photo.image, remote: "LightTouch/\(photo.id)/image.jpg", reuseIdentical: true, progress: progress)
    }

    func stageVideo(_ video: MediaVideo, progress: @escaping @Sendable (Double) -> Void) async throws {
        guard UUID(uuidString: video.id) != nil, video.video.lastPathComponent == "video.m4v" else {
            throw DeviceError.preflight("Invalid video staging path.")
        }
        _ = try await stageFile(video.video, remote: "LightTouch/\(video.id)/video.m4v", reuseIdentical: true, progress: progress)
    }

}
