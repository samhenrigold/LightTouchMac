import Foundation
enum DeviceToolsError: Error { case failed(String) }
/// Prepare one song with the production MediaSong and keep what AFC would stage: the
/// metadata plist and whatever sits beside the audio. Prints the staging ID.
@main struct Check {
    static func main() async throws {
        let song = try await MediaSong.prepare(URL(fileURLWithPath: CommandLine.arguments[1]))
        defer { try? FileManager.default.removeItem(at: song.directory) }
        let unchanged = try Data(contentsOf: song.audio) == Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))
        precondition(unchanged, "audio bytes changed")
        let repeated = try await MediaSong.prepare(URL(fileURLWithPath: CommandLine.arguments[1]))
        defer { try? FileManager.default.removeItem(at: repeated.directory) }
        precondition(repeated.id == song.id && repeated.directory != song.directory)
        if let art = song.artwork, let repeatedArt = repeated.artwork {
            let artUnchanged = try Data(contentsOf: art) == Data(contentsOf: repeatedArt)
            precondition(artUnchanged, "cover changed on repeat")
        }
        let out = URL(fileURLWithPath: CommandLine.arguments[2])
        try FileManager.default.copyItem(at: song.audio, to: out.appendingPathComponent(song.audio.lastPathComponent))
        try FileManager.default.copyItem(at: song.metadata, to: out.appendingPathComponent("metadata.plist"))
        let artwork = song.directory.appendingPathComponent("artwork.jpg")
        if FileManager.default.fileExists(atPath: artwork.path) {
            try FileManager.default.copyItem(at: artwork, to: out.appendingPathComponent("artwork.jpg"))
        }
        print(song.id)
    }
}
