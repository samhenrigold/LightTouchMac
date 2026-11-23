// The binary iTunesDB ("mhbd") that iPhone OS 1.x's Music and Videos read (MusicLibrary's ReadDulcimerDB), where
// 2.x on have a guest agent to add through MusicLibrary itself: tracks and the master playlist, no artwork, in the
// layout libgpod documents (src/itdb_itunesdb.c, db-itunes-parser.h). 1.1.x's MusicLibrary also checks hash58
// (libgpod's itdb_hash58.c): an HMAC-SHA1 of the database keyed from the device's FireWire ID (lockdown's
// com.apple.mobile.iTunes FairPlayID).

import BinaryParsing
import Crypto
import Foundation

public nonisolated enum ITunesDB {
    /// One song or video as the database lists it.
    public struct Track: Sendable, Equatable {
        public init(
            id: UInt32,
            persistentID: UInt64,
            title: String,
            location: String,
            fileType: String,
            kind: String,
            bytes: UInt32,
            milliseconds: UInt32,
            mediaType: UInt32 = Self.audio,
            artist: String? = nil,
            album: String? = nil,
            genre: String? = nil
        ) {
            self.id = id
            self.persistentID = persistentID
            self.title = title
            self.location = location
            self.fileType = fileType
            self.kind = kind
            self.bytes = bytes
            self.milliseconds = milliseconds
            self.mediaType = mediaType
            self.artist = artist
            self.album = album
            self.genre = genre
        }
        public var id: UInt32
        public var persistentID: UInt64
        public var title: String
        /// Colon-separated under the Media folder: ":iTunes_Control:Music:F00:LTM0001.mp3".
        public var location: String
        /// The four-character marker: "MP3 ", "M4A ", "M4V ".
        public var fileType: String
        /// The file kind's words: "MPEG audio file".
        public var kind: String
        public var bytes: UInt32
        public var milliseconds: UInt32
        /// libgpod's ITDB_MEDIATYPE: 1 audio, 2 movie, 0x20 music video, 0x40 TV show.
        public var mediaType: UInt32
        public var artist: String?
        public var album: String?
        public var genre: String?

        public static let audio: UInt32 = 1
        public static let movie: UInt32 = 2
    }

    /// iTunes 7.4's database version (libgpod mk_mhbd's table).
    public static let defaultVersion: UInt32 = 0x19

    /// The database, unsigned: tracks (mhsd 1), the master playlist as podcasts' list (3) and the playlists' (2).
    public static func make(
        _ tracks: [Track],
        version: UInt32 = defaultVersion,
        databaseID: UInt64,
        playlistName: String = "Light Touch",
        date: Date = Date()
    ) -> Data {
        let stamp = macTime(date)
        var trackList = Data()
        for track in tracks { trackList += mhit(track, stamp: stamp) }
        let songs = chunk("mhsd", 96, [1], body: chunk("mhlt", 92, [UInt32(tracks.count)], hasTotal: false) + trackList)
        var items = Data()
        for (position, track) in tracks.enumerated() {
            let order = chunk("mhod", 24, [100, 0, 0, UInt32(position), 0, 0, 0, 0], headerOnly: true)
            items += chunk("mhip", 76, [1, 0, 0, track.id, stamp, 0], body: order)
        }
        // mhyp: mhods, items; master flag byte; timestamp; its ID; then the string mhod count (1)
        var playlist = le(UInt32(2)) + le(UInt32(tracks.count)) + Data([1, 0, 0, 0]) + le(stamp) + le(databaseID ^ 1)
        playlist += le(UInt32(0)) + le(UInt16(1)) + le(UInt16(0)) + le(UInt32(0))
        let master = chunk("mhyp", 108, raw: playlist, body: string(1, playlistName) + playlistColumns + items)
        func playlists(_ type: UInt32) -> Data {
            chunk("mhsd", 96, [type], body: chunk("mhlp", 92, [1], hasTotal: false) + master)
        }
        let body = songs + playlists(3) + playlists(2)
        var header = le(UInt32(1)) + le(version) + le(UInt32(3)) + le(databaseID)
        header += le(UInt16(1)) + le(UInt16(0)) + le(databaseID) + le(UInt32(0))  // 0x20: Mac, 0x24
        header += Data(count: 0x46 - 0x30) + Data("en".utf8) + le(databaseID)  // 0x46 language, 0x48 persistent ID
        return chunk("mhbd", 0xF4, raw: header, body: body)
    }

    /// `database` signed with hash58 for the device whose FireWire ID starts with these 8 bytes: hashing scheme 1 at
    /// 0x30, the HMAC at 0x58 (taken with 0x18, 0x32 and 0x58 zeroed, which are then restored).
    public static func signed(_ database: Data, fireWireID: [UInt8]) -> Data {
        precondition(fireWireID.count >= 8 && database.count >= 0x6C)
        var bytes = [UInt8](database)
        bytes.replaceSubrange(0x30..<0x32, with: [1, 0])
        var zeroed = bytes
        for range in [0x18..<0x20, 0x32..<0x46, 0x58..<0x6C] {
            zeroed.replaceSubrange(range, with: repeatElement(0, count: range.count))
        }
        let code = HMAC<Insecure.SHA1>.authenticationCode(for: zeroed, using: SymmetricKey(data: key(fireWireID)))
        bytes.replaceSubrange(0x58..<0x6C, with: Array(code))
        return Data(bytes)
    }

    /// The FireWire ID from lockdown's FairPlayID (or a UDID): its first 16 hex digits as 8 bytes; nil if they aren't.
    public static func fireWireID(_ hex: String) -> [UInt8]? {
        let digits = Array(hex.utf8.prefix(16))
        guard digits.count == 16 else { return nil }
        let bytes = stride(from: 0, to: 16, by: 2).compactMap {
            UInt8(String(decoding: digits[$0..<$0 + 2], as: UTF8.self), radix: 16)
        }
        return bytes.count == 8 ? bytes : nil
    }

    /// libgpod's generate_key: the LCM of each pair of ID bytes through AES's S-box and inverse S-box (its table1
    /// and table2), SHA-1'd after 18 fixed bytes.
    static func key(_ id: [UInt8]) -> Data {
        var y: [UInt8] = []
        for i in 0..<4 {
            let (a, b) = (Int(id[i * 2]), Int(id[i * 2 + 1]))
            let lcm = a == 0 || b == 0 ? 1 : a * b / gcd(a, b)
            let (hi, lo) = (lcm >> 8 & 0xFF, lcm & 0xFF)
            y += [sBox[hi], inverseSBox[hi], sBox[lo], inverseSBox[lo]]
        }
        let fixed: [UInt8] = [
            0x67, 0x23, 0xFE, 0x30, 0x45, 0x33, 0xF8, 0x90, 0x99, 0x21, 0x07, 0xC1, 0xD0, 0x12, 0xB2, 0xA1, 0x07, 0x81
        ]
        return Data(Insecure.SHA1.hash(data: fixed + y))
    }

    private static func gcd(_ a: Int, _ b: Int) -> Int { b == 0 ? a : gcd(b, a % b) }

    /// AES's S-box: each byte's inverse in GF(2^8) through the affine map.
    static let sBox: [UInt8] = (0..<256).map { x in
        let v = x == 0 ? 0 : (1..<256).first { gfMultiply(UInt8(x), UInt8($0)) == 1 } ?? 0
        let b = UInt8(v)
        func rotl(_ n: UInt8) -> UInt8 { b << n | b >> (8 - n) }
        return b ^ rotl(1) ^ rotl(2) ^ rotl(3) ^ rotl(4) ^ 0x63
    }

    static let inverseSBox: [UInt8] = {
        var table = [UInt8](repeating: 0, count: 256)
        for (x, s) in sBox.enumerated() { table[Int(s)] = UInt8(x) }
        return table
    }()

    private static func gfMultiply(_ a: UInt8, _ b: UInt8) -> UInt8 {
        var (a, b, product) = (a, b, UInt8(0))
        while b != 0 {
            if b & 1 != 0 { product ^= a }
            a = a << 1 ^ (a & 0x80 != 0 ? 0x1B : 0)
            b >>= 1
        }
        return product
    }

    // MARK: - Reading

    /// The tracks of a database `make` wrote, or one iTunes did (their strings and the fields `Track` keeps).
    public static func tracks(in database: Data) throws -> [Track] {
        try database.withParserSpan { s throws(ParsingError) in
            var tracks: [Track] = []
            guard try [UInt8](parsing: &s, byteCount: 4) == Array("mhbd".utf8) else { throw invalid }
            let headerLength = try Int(parsing: &s, storedAsLittleEndian: UInt32.self)
            try s.seek(toAbsoluteOffset: 0x14)
            let children = try Int(parsing: &s, storedAsLittleEndian: UInt32.self)
            try s.seek(toAbsoluteOffset: headerLength)
            for _ in 0..<children {
                let start = s.startPosition
                let (tag, header, total) = try head(&s)
                guard tag == "mhsd" else { throw invalid }
                let type = try UInt32(parsingLittleEndian: &s)
                if type == 1 {
                    try s.seek(toAbsoluteOffset: start + header)
                    let listStart = s.startPosition
                    let (list, listHeader, count) = try head(&s)
                    guard list == "mhlt" else { throw invalid }
                    try s.seek(toAbsoluteOffset: listStart + listHeader)
                    for _ in 0..<count { tracks.append(try mhit(&s)) }
                }
                try s.seek(toAbsoluteOffset: start + total)
            }
            return tracks
        }
    }

    private static var invalid: ParsingError { ParsingError(userError: CocoaError(.fileReadCorruptFile)) }

    /// A chunk's tag, header length and third word (its total length, or a list's count); `s` after the three.
    private static func head(_ s: inout ParserSpan) throws(ParsingError) -> (String, Int, Int) {
        let tag = String(decoding: try [UInt8](parsing: &s, byteCount: 4), as: UTF8.self)
        let header = try Int(parsing: &s, storedAsLittleEndian: UInt32.self)
        let third = try Int(parsing: &s, storedAsLittleEndian: UInt32.self)
        guard header >= 12 else { throw invalid }
        return (tag, header, third)
    }

    private static func mhit(_ s: inout ParserSpan) throws(ParsingError) -> Track {
        let start = s.startPosition
        let (tag, header, total) = try head(&s)
        guard tag == "mhit", header >= 0xD4, total >= header else { throw invalid }
        let mhods = try Int(parsing: &s, storedAsLittleEndian: UInt32.self)
        let id = try UInt32(parsingLittleEndian: &s)
        try s.seek(toAbsoluteOffset: start + 0x18)
        let marker = try [UInt8](parsing: &s, byteCount: 4).reversed()
        try s.seek(toAbsoluteOffset: start + 0x24)
        let bytes = try UInt32(parsingLittleEndian: &s)
        let milliseconds = try UInt32(parsingLittleEndian: &s)
        try s.seek(toAbsoluteOffset: start + 0x70)
        let persistentID = try UInt64(parsingLittleEndian: &s)
        try s.seek(toAbsoluteOffset: start + 0xD0)
        let mediaType = try UInt32(parsingLittleEndian: &s)
        var strings: [UInt32: String] = [:]
        try s.seek(toAbsoluteOffset: start + header)
        for _ in 0..<mhods {
            let at = s.startPosition
            let (tag, _, length) = try head(&s)
            guard tag == "mhod", length >= 24 else { throw invalid }
            let type = try UInt32(parsingLittleEndian: &s)
            if type < 50, length >= 40 {
                try s.seek(toAbsoluteOffset: at + 28)
                let count = try Int(parsing: &s, storedAsLittleEndian: UInt32.self)
                try s.seek(toAbsoluteOffset: at + 40)
                let units = try [UInt8](parsing: &s, byteCount: min(count, length - 40))
                strings[type] = String(
                    decoding: stride(from: 0, to: units.count - 1, by: 2).map {
                        UInt16(units[$0]) | UInt16(units[$0 + 1]) << 8
                    },
                    as: UTF16.self
                )
            }
            try s.seek(toAbsoluteOffset: at + length)
        }
        try s.seek(toAbsoluteOffset: start + total)
        return Track(
            id: id,
            persistentID: persistentID,
            title: strings[1] ?? "",
            location: strings[2] ?? "",
            fileType: String(decoding: marker, as: UTF8.self),
            kind: strings[6] ?? "",
            bytes: bytes,
            milliseconds: milliseconds,
            mediaType: mediaType,
            artist: strings[4],
            album: strings[3],
            genre: strings[5]
        )
    }

    // MARK: - Writing

    private static func mhit(_ track: Track, stamp: UInt32) -> Data {
        var fields = [UInt8](repeating: 0, count: 0x184 - 12)
        func put<T: FixedWidthInteger>(_ value: T, at offset: Int) {
            fields.replaceSubrange(offset - 12..<offset - 12 + MemoryLayout<T>.size, with: le(value))
        }
        let mhods = [
            (1, track.title), (2, track.location), (3, track.album), (4, track.artist), (5, track.genre),
            (6, track.kind)
        ]
        .compactMap { type, text in text.map { string(UInt32(type), $0) } }
        put(UInt32(mhods.count), at: 0x0C)
        put(track.id, at: 0x10)
        put(UInt32(1), at: 0x14)  // visible
        put(track.fileType.utf8.reduce(UInt32(0)) { $0 << 8 | UInt32($1) }, at: 0x18)
        put(UInt8(track.fileType == "MP3 " ? 1 : 0), at: 0x1D)
        put(stamp, at: 0x20)
        put(track.bytes, at: 0x24)
        put(track.milliseconds, at: 0x28)
        put(UInt32(44100) << 16, at: 0x3C)
        put(stamp, at: 0x68)  // added
        put(track.persistentID, at: 0x70)
        put(track.persistentID, at: 0xA8)
        // libgpod's movie_flag: video before the media type (0xD0) was read
        put(UInt8(track.mediaType == Track.audio ? 0 : 1), at: 0xB1)
        put(track.mediaType, at: 0xD0)
        return chunk("mhit", 0x184, raw: Data(fields), body: mhods.reduce(Data(), +))
    }

    /// A string mhod: UTF-16LE, as iTunes writes them.
    private static func string(_ type: UInt32, _ text: String) -> Data {
        let utf16 = text.utf16.flatMap { le($0) }
        var mhod = Data("mhod".utf8) + le(UInt32(24)) + le(UInt32(40 + utf16.count)) + le(type) + Data(count: 8)
        mhod += le(UInt32(1)) + le(UInt32(utf16.count)) + le(UInt32(1)) + le(UInt32(0))
        return mhod + Data(utf16)
    }

    /// The master playlist's column settings mhod, iTunes' and libgpod's constant (mk_long_mhod_id_playlist).
    private static let playlistColumns: Data = {
        var words: [UInt32] = [100, 0, 0, 0, 0, 0, 0, 0x010084, 5, 9, 3, 0x120001, 0, 0, 0, 0xC80002, 0, 0, 0]
        words += [0x3C000D, 0, 0, 0, 0x7D0004, 0, 0, 0, 0x7D0003, 0, 0, 0, 0x640008, 0, 0, 0, 0x640017, 1, 0, 0]
        words += [0x500014, 1, 0, 0, 0x7D0015, 1] + repeatElement(0, count: 114)
        return Data("mhod".utf8) + le(UInt32(0x18)) + le(UInt32(0x288)) + words.reduce(Data()) { $0 + le($1) }
    }()

    /// A chunk: tag, header length, its total length (or, `hasTotal` false, the first word), the rest of the header
    /// (`words` or `raw`, from offset 12) zero-padded to `header`, then `body`. `headerOnly`: the words are the whole
    /// chunk past the total.
    private static func chunk(
        _ tag: String,
        _ header: Int,
        _ words: [UInt32] = [],
        raw: Data? = nil,
        body: Data = Data(),
        hasTotal: Bool = true,
        headerOnly: Bool = false
    ) -> Data {
        var rest = raw ?? words.reduce(Data()) { $0 + le($1) }
        if !hasTotal {
            return Data(tag.utf8) + le(UInt32(header)) + rest + Data(count: header - 8 - rest.count) + body
        }
        if headerOnly {
            let total = 12 + rest.count
            return Data(tag.utf8) + le(UInt32(header)) + le(UInt32(max(total, header))) + rest
                + Data(count: max(0, header - total))
        }
        rest += Data(count: max(0, header - 12 - rest.count))
        return Data(tag.utf8) + le(UInt32(header)) + le(UInt32(header + body.count)) + rest + body
    }

    private static func le<T: FixedWidthInteger>(_ value: T) -> Data {
        withUnsafeBytes(of: value.littleEndian) { Data($0) }
    }

    private static func macTime(_ date: Date) -> UInt32 {
        UInt32(clamping: Int(date.timeIntervalSince1970) + 2_082_844_800)
    }
}
