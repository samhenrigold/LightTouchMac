import Foundation
import Testing

@testable import LightTouchCore

/// iPhone OS 1.x's Music lists a song by what its iTunesDB track holds (FirstGenLibrary.track): a tagged MP3 prepared
/// as Import Media prepares it keeps its title, artist, album and genre through the database and back, and a file
/// without tags is listed under its name. Fails when a tag doesn't reach the track.
struct FirstGenLibraryTests {
    @Test func aSongsTagsReachTheDatabase() async throws {
        try await withTemporaryState { work in
            let mp3 = work.appendingPathComponent("plain.mp3")
            try MediaFixtures.silentMP3(mp3, seconds: 3)
            let source = work.appendingPathComponent("File Name.mp3")
            try (MediaTagsTests.id3(title: "Tagged Tïtle", cover: Data()) + Data(contentsOf: mp3)).write(to: source)
            let song = try await MediaSong.prepare(source)
            defer { try? FileManager.default.removeItem(at: song.directory) }
            let track = try FirstGenLibrary.track(
                song.audio,
                metadata: song.metadata,
                id: 100,
                location: ":iTunes_Control:Music:F00:LT1.mp3",
                movie: false
            )
            let read = try #require(try ITunesDB.tracks(in: ITunesDB.make([track], databaseID: 1)).first)
            #expect(read.title == "Tagged Tïtle")
            #expect(read.artist == "Track Artist")
            #expect(read.album == "The Album")
            #expect(read.genre == "Rock")
            #expect(read.fileType == "MP3 " && read.mediaType == ITunesDB.Track.audio)
            #expect((2900...3100).contains(read.milliseconds), "length \(read.milliseconds) ms")

            let untagged = try await MediaSong.prepare(mp3)
            defer { try? FileManager.default.removeItem(at: untagged.directory) }
            let plain = try FirstGenLibrary.track(
                untagged.audio,
                metadata: untagged.metadata,
                id: 101,
                location: ":a",
                movie: false
            )
            #expect(plain.title == "plain" && plain.artist == nil)
        }
    }
}
