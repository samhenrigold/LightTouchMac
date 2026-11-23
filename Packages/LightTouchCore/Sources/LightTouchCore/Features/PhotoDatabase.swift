// iTunes' image database ("mhfd"), which iPhone OS 1.x's MusicLibrary reads (ReadITImageDB) for Photos (Media's
// Photos/Photo Database, MLPhotoLibrary) and for Music's covers (iTunes_Control/Artwork/ArtworkDB): each image's
// thumbnails as raw pixels in .ithmb files beside it, one per format, in the layout libgpod documents
// (src/db-artwork-writer.c, db-itunes-parser.h, ithumb-writer.c). 1.1's Photos lists only this library, not DCIM.

import BinaryParsing
import CoreGraphics
import Foundation
import HostServiceWire
import ImageIO

public nonisolated enum PhotoDatabase {
    /// One of the device's image formats (Checkpoint.xml's ImageSpecifications, MLPhotoLibrary's table): 16-bit
    /// "L555" pixels, little-endian RGB 5-5-5 with the top bit set, each row padded to 16 bytes.
    public struct Format: Sendable, Equatable {
        public let id: UInt32
        public let width: Int
        public let height: Int
        /// Filled, cut to the format's shape; otherwise fitted inside it with white about it.
        public let cropped: Bool
        public var rowBytes: Int { (width * 2 + 15) / 16 * 16 }
        public var imageSize: Int { rowBytes * height }
    }

    /// The iPod touch's and iPhone's photo formats on 1.1 (Checkpoint.xml, and libgpod's ipod_touch_1_photo_info):
    /// the album's poster, the grid, the list and the full screen.
    public static let photoFormats = [
        Format(id: 3004, width: 55, height: 55, cropped: true),
        Format(id: 3011, width: 79, height: 79, cropped: true),
        Format(id: 3009, width: 160, height: 120, cropped: false),
        Format(id: 3008, width: 640, height: 480, cropped: false)
    ]

    /// The cover formats MusicLibrary's GetPurplePredefinediTunesFormat lays out plainly (libgpod's
    /// ipod_touch_1_cover_art_info; 3001 to 3003 are stored in its recursive tiling and left out): Now Playing's 320,
    /// the lists' 55 and 88. Music takes the best of those a cover has (bestImageInstance).
    public static let artworkFormats = [
        Format(id: 3005, width: 320, height: 320, cropped: true),
        Format(id: 3006, width: 55, height: 55, cropped: true),
        Format(id: 3007, width: 88, height: 88, cropped: true)
    ]

    /// One image's copy in one format: where in which .ithmb (`file` as the database names it, ":Thumbs:F3004_1.ithmb")
    /// and the picture's size inside the format's, padding included.
    public struct Thumbnail: Sendable, Equatable {
        public var format: UInt32
        public var file: String
        public var offset: UInt32
        public var size: UInt32
        public var verticalPadding: Int16
        public var horizontalPadding: Int16
        public var height: Int16
        public var width: Int16
    }

    public struct Image: Sendable, Equatable {
        public init(id: UInt32, songID: UInt64? = nil, thumbnails: [Thumbnail]) {
            self.id = id
            self.songID = songID ?? UInt64(id) + 2
            self.thumbnails = thumbnails
        }
        public var id: UInt32
        /// A cover's track (its persistent ID); a photo's is libgpod's ID + 2.
        public var songID: UInt64
        public var thumbnails: [Thumbnail]
    }

    /// libgpod's first photo ID (itdb_photodb_write); albums are numbered from 0x64 past the photos.
    public static let firstID: UInt32 = 0x40

    /// libgpod's first cover ID (ipod_artwork_db_set_ids).
    public static let firstArtworkID: UInt32 = 0x64

    /// The database: every image (mhsd 1), the master album "Photo Library" holding them all (2; none in an
    /// ArtworkDB, `album` false), the formats (3).
    public static func make(_ images: [Image], formats: [Format] = photoFormats, album hasAlbum: Bool = true) -> Data {
        let items = images.map(mhii).reduce(Data(), +)
        let list = chunk("mhsd", 0x60, [1], body: chunk("mhli", 0x5C, [UInt32(images.count)], hasTotal: false) + items)
        // mhba: mhods, members, its ID, two unknowns, type 1 (the master), the slideshow's settings, previous album
        var album = le(UInt32(1)) + le(UInt32(images.count)) + le(0x64 + UInt32(images.count)) + Data(count: 6)
        album += Data([1, 0, 0, 0, 0, 0]) + Data(count: 24) + le(UInt32(0x64))
        let members = images.map { chunk("mhia", 40, [0, $0.id]) }.reduce(Data(), +)
        let master = chunk("mhba", 0x94, raw: album, body: name("Photo Library") + members)
        let albums = chunk(
            "mhsd", 0x60, [2],
            body: chunk("mhla", 0x5C, [hasAlbum ? 1 : 0], hasTotal: false) + (hasAlbum ? master : Data()))
        let files = formats.map { chunk("mhif", 0x7C, [0, $0.id, UInt32($0.imageSize)]) }.reduce(Data(), +)
        let list3 = chunk(
            "mhsd", 0x60, [3], body: chunk("mhlf", 0x5C, [UInt32(formats.count)], hasTotal: false) + files)
        // past every record ID, the album's too: MLPhotoLibrary looks up only albums below it
        let next = max((images.map(\.id).max() ?? firstID - 1) + 1, hasAlbum ? 0x65 + UInt32(images.count) : 0)
        // mhfd: unknown, 2 (iTunes 4.9 on), three lists, unknown, the next ID, then 2 in the first flag byte (0x30)
        let header = le(UInt32(0)) + le(UInt32(2)) + le(UInt32(3)) + le(UInt32(0)) + le(next) + Data(count: 16)
        return chunk("mhfd", 0x84, raw: header + Data([2]), body: list + albums + list3)
    }

    /// The images of a database `make` wrote, or one iTunes did.
    public static func images(in database: Data) throws -> [Image] {
        try database.withParserSpan { s throws(ParsingError) in
            let (tag, header, _) = try head(&s)
            guard tag == "mhfd" else { throw invalid }
            try s.seek(toAbsoluteOffset: 0x14)
            let lists = try Int(parsing: &s, storedAsLittleEndian: UInt32.self)
            try s.seek(toAbsoluteOffset: header)
            var images: [Image] = []
            for _ in 0..<lists {
                let start = s.startPosition
                let (tag, header, total) = try head(&s)
                guard tag == "mhsd", total >= header else { throw invalid }
                if try UInt16(parsingLittleEndian: &s) == 1 {
                    try s.seek(toAbsoluteOffset: start + header)
                    let listStart = s.startPosition
                    let (list, listHeader, count) = try head(&s)
                    guard list == "mhli" else { throw invalid }
                    try s.seek(toAbsoluteOffset: listStart + listHeader)
                    for _ in 0..<count { images.append(try mhii(&s)) }
                }
                try s.seek(toAbsoluteOffset: start + total)
            }
            return images
        }
    }

    /// `image` drawn in `format` as the .ithmb holds it, with the thumbnail record for it at `offset` in `file`:
    /// filled and centered where the format is cropped, fitted and centered on white where it isn't.
    public static func pixels(of image: CGImage, in format: Format, file: String, offset: UInt32) throws -> (
        Data, Thumbnail
    ) {
        let (width, height) = (image.width, image.height)
        let fill = Double(format.width) / Double(width) > Double(format.height) / Double(height)
        let scale =
            format.cropped == fill
            ? Double(format.width) / Double(width) : Double(format.height) / Double(height)
        let drawn = (
            width: min(format.width, Int((Double(width) * scale).rounded())),
            height: min(format.height, Int((Double(height) * scale).rounded()))
        )
        let padding = (horizontal: (format.width - drawn.width) / 2, vertical: (format.height - drawn.height) / 2)
        guard
            let context = CGContext(
                data: nil,
                width: format.width,
                height: format.height,
                bitsPerComponent: 8,
                bytesPerRow: format.width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
            )
        else { throw DeviceToolsError.failed("The photo couldn’t be prepared.") }
        context.setFillColor(red: 1, green: 1, blue: 1, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: format.width, height: format.height))
        context.interpolationQuality = .high
        // centered: a cropped format's overhang is cut equally from both sides
        let size = (width: Double(width) * scale, height: Double(height) * scale)
        context.draw(
            image,
            in: CGRect(
                x: (Double(format.width) - size.width) / 2,
                y: (Double(format.height) - size.height) / 2,
                width: size.width,
                height: size.height
            )
        )
        guard let rgbx = context.data?.assumingMemoryBound(to: UInt8.self) else {
            throw DeviceToolsError.failed("The photo couldn’t be prepared.")
        }
        var data = Data(count: format.imageSize)
        data.withUnsafeMutableBytes { raw in
            let out = raw.bindMemory(to: UInt16.self)
            for y in 0..<format.height {
                for x in 0..<format.rowBytes / 2 {
                    // the row's padding white, as libgpod's back color
                    let p = x < format.width ? rgbx + (y * format.width + x) * 4 : nil
                    let (r, g, b) = p.map { (UInt16($0[0]), UInt16($0[1]), UInt16($0[2])) } ?? (255, 255, 255)
                    out[y * format.rowBytes / 2 + x] = (0x8000 | (r >> 3) << 10 | (g >> 3) << 5 | b >> 3).littleEndian
                }
            }
        }
        let thumbnail = Thumbnail(
            format: format.id,
            file: file,
            offset: offset,
            size: UInt32(format.imageSize),
            verticalPadding: Int16(padding.vertical),
            horizontalPadding: Int16(padding.horizontal),
            height: Int16(padding.vertical + drawn.height),
            width: Int16(padding.horizontal + drawn.width)
        )
        return (data, thumbnail)
    }

    // MARK: - Reading

    private static var invalid: ParsingError { ParsingError(userError: CocoaError(.fileReadCorruptFile)) }

    private static func head(_ s: inout ParserSpan) throws(ParsingError) -> (String, Int, Int) {
        let tag = String(decoding: try [UInt8](parsing: &s, byteCount: 4), as: UTF8.self)
        let header = try Int(parsing: &s, storedAsLittleEndian: UInt32.self)
        let third = try Int(parsing: &s, storedAsLittleEndian: UInt32.self)
        guard header >= 12 else { throw invalid }
        return (tag, header, third)
    }

    private static func mhii(_ s: inout ParserSpan) throws(ParsingError) -> Image {
        let start = s.startPosition
        let (tag, header, total) = try head(&s)
        guard tag == "mhii", total >= header else { throw invalid }
        let children = try Int(parsing: &s, storedAsLittleEndian: UInt32.self)
        let id = try UInt32(parsingLittleEndian: &s)
        let songID = try UInt64(parsingLittleEndian: &s)
        var thumbnails: [Thumbnail] = []
        try s.seek(toAbsoluteOffset: start + header)
        for _ in 0..<children {
            let at = s.startPosition
            let (tag, header, length) = try head(&s)
            guard tag == "mhod", length >= header else { throw invalid }
            if try UInt16(parsingLittleEndian: &s) == 2 {
                try s.seek(toAbsoluteOffset: at + header)
                thumbnails.append(try mhni(&s))
            }
            try s.seek(toAbsoluteOffset: at + length)
        }
        try s.seek(toAbsoluteOffset: start + total)
        return Image(id: id, songID: songID, thumbnails: thumbnails)
    }

    private static func mhni(_ s: inout ParserSpan) throws(ParsingError) -> Thumbnail {
        let start = s.startPosition
        let (tag, header, _) = try head(&s)
        guard tag == "mhni", header >= 0x24 else { throw invalid }
        _ = try UInt32(parsingLittleEndian: &s)  // children: the file name's mhod
        let format = try UInt32(parsingLittleEndian: &s)
        let offset = try UInt32(parsingLittleEndian: &s)
        let size = try UInt32(parsingLittleEndian: &s)
        let vertical = try Int16(parsingLittleEndian: &s)
        let horizontal = try Int16(parsingLittleEndian: &s)
        let height = try Int16(parsingLittleEndian: &s)
        let width = try Int16(parsingLittleEndian: &s)
        try s.seek(toAbsoluteOffset: start + header)
        // the file name: an mhod type 3, UTF-16LE (encoding 2) or UTF-8
        let at = s.startPosition
        let (name, _, length) = try head(&s)
        guard name == "mhod", length >= 36 else { throw invalid }
        try s.seek(toAbsoluteOffset: at + 24)
        let count = try Int(parsing: &s, storedAsLittleEndian: UInt32.self)
        let encoding = try UInt8(parsing: &s)
        try s.seek(toAbsoluteOffset: at + 36)
        let bytes = try [UInt8](parsing: &s, byteCount: min(count, length - 36))
        let file =
            encoding == 2
            ? String(
                decoding: stride(from: 0, to: bytes.count - 1, by: 2).map {
                    UInt16(bytes[$0]) | UInt16(bytes[$0 + 1]) << 8
                },
                as: UTF16.self
            )
            : String(decoding: bytes, as: UTF8.self)
        try s.seek(toAbsoluteOffset: at + length)
        return Thumbnail(
            format: format,
            file: file,
            offset: offset,
            size: size,
            verticalPadding: vertical,
            horizontalPadding: horizontal,
            height: height,
            width: width
        )
    }

    // MARK: - Writing

    private static func mhii(_ image: Image) -> Data {
        // children, its ID, its song ID, then rating, dates and size, all 0
        let fields = le(UInt32(image.thumbnails.count)) + le(image.id) + le(image.songID)
        let thumbnails = image.thumbnails.map { thumbnail in
            var fields = le(UInt32(1)) + le(thumbnail.format) + le(thumbnail.offset) + le(thumbnail.size)
            fields += le(thumbnail.verticalPadding) + le(thumbnail.horizontalPadding)
            fields += le(thumbnail.height) + le(thumbnail.width)
            let mhni = chunk("mhni", 0x4C, raw: fields, body: fileName(thumbnail.file))
            return container(mhni)
        }
        return chunk("mhii", 0x98, raw: fields, body: thumbnails.reduce(Data(), +))
    }

    /// An mhod type 2, holding one mhni.
    private static func container(_ mhni: Data) -> Data {
        Data("mhod".utf8) + le(UInt32(24)) + le(UInt32(24 + mhni.count)) + le(UInt16(2)) + Data(count: 10) + mhni
    }

    /// An mhod type 3, a file name: UTF-16LE, as libgpod writes them for little-endian devices.
    private static func fileName(_ text: String) -> Data {
        string(3, Data(text.utf16.flatMap { le($0) }), encoding: 2)
    }

    /// An mhod type 1, an album's name: UTF-8.
    private static func name(_ text: String) -> Data { string(1, Data(text.utf8), encoding: 1) }

    /// libgpod's ArtworkDB_MhodHeaderString: header length 24, the type's 16 bits, its padding's length, the string's
    /// length at 24, its encoding at 28, the string at 36, padded to 4 bytes.
    private static func string(_ type: UInt16, _ bytes: Data, encoding: UInt8) -> Data {
        let padding = (4 - (36 + bytes.count) % 4) % 4
        var mhod = Data("mhod".utf8) + le(UInt32(24)) + le(UInt32(36 + bytes.count + padding)) + le(type)
        mhod += Data([0, UInt8(padding)]) + Data(count: 8) + le(UInt32(bytes.count)) + Data([encoding, 0, 0, 0])
        return mhod + Data(count: 4) + bytes + Data(count: padding)
    }

    /// A chunk: tag, header length, its total length (or, `hasTotal` false, the first word), the rest of the header
    /// (`words` or `raw`, from offset 12) zero-padded to `header`, then `body`.
    private static func chunk(
        _ tag: String,
        _ header: Int,
        _ words: [UInt32] = [],
        raw: Data? = nil,
        body: Data = Data(),
        hasTotal: Bool = true
    ) -> Data {
        var rest = raw ?? words.reduce(Data()) { $0 + le($1) }
        if !hasTotal {
            return Data(tag.utf8) + le(UInt32(header)) + rest + Data(count: header - 8 - rest.count) + body
        }
        rest += Data(count: max(0, header - 12 - rest.count))
        return Data(tag.utf8) + le(UInt32(header)) + le(UInt32(header + body.count)) + rest + body
    }

    private static func le<T: FixedWidthInteger>(_ value: T) -> Data {
        withUnsafeBytes(of: value.littleEndian) { Data($0) }
    }
}
