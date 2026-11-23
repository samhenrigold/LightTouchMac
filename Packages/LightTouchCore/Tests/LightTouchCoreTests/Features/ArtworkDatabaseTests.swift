import Foundation
import Testing

@testable import LightTouchCore

/// iPhone OS 1.x's Music finds a song's cover through its iTunesDB track (libgpod's artwork_count at 0x7C,
/// has_artwork 1 at 0xA4, mhii_link at 0x160) and the ArtworkDB image of that ID whose song ID is the track's persistent
/// ID (MusicLibrary's FindITImageInfoForTrack, by record ID or by source ID). Both round-trip, the ArtworkDB has no
/// album, and its formats are the covers' plain ones at GetPurplePredefinediTunesFormat's sizes. Fails with a field
/// moved or left out.
struct ArtworkDatabaseTests {
    @Test func aTracksCoverRoundTripsAtLibgpodsOffsets() throws {
        let track = ITunesDB.Track(
            id: 100,
            persistentID: 0x1122_3344_5566_7788,
            title: "Prism Song",
            location: ":iTunes_Control:Music:F00:LT1.mp3",
            fileType: "MP3 ",
            kind: "MPEG audio file",
            bytes: 1,
            milliseconds: 1,
            artwork: 0x65
        )
        var plain = track
        plain.artwork = nil
        let database = ITunesDB.make([track, plain], databaseID: 1)
        #expect(try ITunesDB.tracks(in: database) == [track, plain])
        let bytes = [UInt8](database)
        let mhit = try #require(
            (0..<bytes.count - 4).first { String(decoding: bytes[$0..<$0 + 4], as: UTF8.self) == "mhit" })
        #expect(bytes[mhit + 0x7C] == 1 && bytes[mhit + 0xA4] == 1)
        #expect(Array(bytes[mhit + 0x160..<mhit + 0x164]) == [0x65, 0, 0, 0])
    }

    @Test func theArtworkDatabaseHasTheCoversAndNoAlbum() throws {
        let thumbnail = PhotoDatabase.Thumbnail(
            format: 3005,
            file: ":F3005_100.ithmb",
            offset: 0,
            size: 640 * 320,
            verticalPadding: 0,
            horizontalPadding: 0,
            height: 320,
            width: 320
        )
        let cover = PhotoDatabase.Image(id: 0x64, songID: 0x1122_3344_5566_7788, thumbnails: [thumbnail])
        let database = PhotoDatabase.make([cover], formats: PhotoDatabase.artworkFormats, album: false)
        #expect(try PhotoDatabase.images(in: database) == [cover])
        let bytes = [UInt8](database)
        func at(_ tag: String) -> [Int] {
            (0..<bytes.count - 4).filter { String(decoding: bytes[$0..<$0 + 4], as: UTF8.self) == tag }
        }
        func word(_ at: Int) -> Int { (0..<4).reduce(0) { $0 | Int(bytes[at + $1]) << ($1 * 8) } }
        #expect(at("mhba").isEmpty && word(at("mhla")[0] + 8) == 0)
        #expect(
            Array(bytes[at("mhii")[0] + 20..<at("mhii")[0] + 28]) == [0x88, 0x77, 0x66, 0x55, 0x44, 0x33, 0x22, 0x11])
        let sizes = Dictionary(uniqueKeysWithValues: at("mhif").map { (word($0 + 16), word($0 + 20)) })
        #expect(sizes == [3005: 640 * 320, 3006: 112 * 55, 3007: 176 * 88])
    }
}
