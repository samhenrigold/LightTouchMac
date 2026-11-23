import Foundation
import Testing

@testable import LightTouchCore

/// The iTunesDB iPhone OS 1.x reads (ITunesDB): what `make` writes reads back as the same tracks, and hash58 matches
/// libgpod's own. libgpod publishes no vectors, so these are its itdb_compute_hash (src/itdb_hash58.c at
/// fadingred/libgpod master, the tables and functions compiled unchanged over CommonCrypto's SHA-1) run on a
/// 0x6C-byte header whose byte i is i*7 mod 256 with hashing scheme 1 and 0x18, 0x32 and 0x58 zeroed, as
/// itdb_hash58_write_hash hashes it.
struct ITunesDBTests {
    static let header = Data((0..<0x6C).map { UInt8(truncatingIfNeeded: $0 * 7) })

    @Test(arguments: [
        ("000A27001A2B3C4D", "7055a0c3899c5047d3c06cbd5b16877f2aa6c18b"),
        ("FFFE010080811020", "d81502355614780d7ffb8b64ec4a0bdb05d65cf3")
    ])
    func hash58MatchesLibgpod(id: String, expected: String) throws {
        let signed = ITunesDB.signed(Self.header, fireWireID: try #require(ITunesDB.fireWireID(id)))
        #expect(signed[0x58..<0x6C].map { String(format: "%02x", $0) }.joined() == expected)
        #expect(signed[0x30] == 1 && signed[0x31] == 0, "hashing scheme 1")
        #expect(signed[0x18..<0x20] == Self.header[0x18..<0x20], "the zeroed fields are restored")
        #expect(signed[0x32..<0x46] == Self.header[0x32..<0x46])
    }

    @Test func sBoxesAreLibgpodsTables() {
        #expect(Array(ITunesDB.sBox.prefix(4)) == [0x63, 0x7C, 0x77, 0x7B] && ITunesDB.sBox[255] == 0x16)
        #expect(Array(ITunesDB.inverseSBox.prefix(4)) == [0x52, 0x09, 0x6A, 0xD5] && ITunesDB.inverseSBox[255] == 0x7D)
    }

    @Test func fireWireIDIsTheFirstSixteenHexDigits() {
        #expect(ITunesDB.fireWireID("000a27001a2b3c4d99") == [0x00, 0x0A, 0x27, 0x00, 0x1A, 0x2B, 0x3C, 0x4D])
        #expect(ITunesDB.fireWireID("000a27") == nil)
        #expect(ITunesDB.fireWireID("zz0a27001a2b3c4d") == nil)
    }

    @Test func aDatabaseReadsBackAsItsTracks() throws {
        let tracks = [
            ITunesDB.Track(
                id: 101, persistentID: 0x1122_3344_5566_7788, title: "Sunny Day ☀︎",
                location: ":iTunes_Control:Music:F00:LTM1.mp3",
                fileType: "MP3 ", kind: "MPEG audio file", bytes: 12345, milliseconds: 4000, artist: "Band",
                album: "Album",
                genre: "Pop"
            ),
            ITunesDB.Track(
                id: 102, persistentID: 9, title: "Clip", location: ":iTunes_Control:Music:F00:LTM2.m4v",
                fileType: "M4V ",
                kind: "MPEG-4 video file", bytes: 99, milliseconds: 1000, mediaType: ITunesDB.Track.movie
            )
        ]
        let database = ITunesDB.make(tracks, databaseID: 42)
        #expect(String(decoding: database.prefix(4), as: UTF8.self) == "mhbd")
        #expect(database.count == Int(database[8]) | Int(database[9]) << 8 | Int(database[10]) << 16, "total length")
        #expect(try ITunesDB.tracks(in: database) == tracks)
        #expect(try ITunesDB.tracks(in: ITunesDB.signed(database, fireWireID: [1, 2, 3, 4, 5, 6, 7, 8])) == tracks)
        #expect(try ITunesDB.tracks(in: ITunesDB.make([], databaseID: 1)).isEmpty)
    }

    @Test func aTruncatedDatabaseIsRefused() {
        let database = ITunesDB.make(
            [
                ITunesDB.Track(
                    id: 1, persistentID: 1, title: "T", location: ":a", fileType: "MP3 ", kind: "k", bytes: 1,
                    milliseconds: 1
                )
            ], databaseID: 1)
        #expect(throws: (any Error).self) { try ITunesDB.tracks(in: database.prefix(database.count - 30)) }
        #expect(throws: (any Error).self) { try ITunesDB.tracks(in: Data("mhsd".utf8) + database.dropFirst(4)) }
    }
}
