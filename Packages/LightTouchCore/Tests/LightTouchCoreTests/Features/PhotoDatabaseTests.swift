import CoreGraphics
import Foundation
import Testing

@testable import LightTouchCore

/// iPhone OS 1.1's Photos reads iTunes' Photo Database (PhotoDatabase): the database round-trips its images'
/// thumbnail records; its chunks have libgpod's header sizes (get_padded_header_size), its formats list
/// ipod_touch_1_photo_info's sizes (width aligned to 16 bytes times height times 2), and the master album holds every
/// image; and a thumbnail's pixels are L555 with the format's padding. Fails with a field moved or a size changed.
struct PhotoDatabaseTests {
    static func thumbnail(_ format: UInt32, _ id: UInt32) -> PhotoDatabase.Thumbnail {
        PhotoDatabase.Thumbnail(
            format: format,
            file: ":Thumbs:F\(format)_\(id).ithmb",
            offset: 0,
            size: 6160,
            verticalPadding: 2,
            horizontalPadding: 1,
            height: 55,
            width: 54
        )
    }

    @Test func imagesRoundTrip() throws {
        let images = [0x40, 0x41].map { id in
            PhotoDatabase.Image(id: UInt32(id), thumbnails: [3004, 3011].map { Self.thumbnail($0, UInt32(id)) })
        }
        #expect(try PhotoDatabase.images(in: PhotoDatabase.make(images)) == images)
        #expect(try PhotoDatabase.images(in: PhotoDatabase.make([])) == [])
    }

    @Test func chunksAreLaidOutAsLibgpodWritesThem() throws {
        let image = PhotoDatabase.Image(id: 0x40, thumbnails: [Self.thumbnail(3004, 0x40)])
        let bytes = [UInt8](PhotoDatabase.make([image]))
        func word(_ at: Int) -> Int {
            Int(bytes[at]) | Int(bytes[at + 1]) << 8 | Int(bytes[at + 2]) << 16 | Int(bytes[at + 3]) << 24
        }
        func tag(_ at: Int) -> String { String(decoding: bytes[at..<at + 4], as: UTF8.self) }
        #expect(tag(0) == "mhfd" && word(4) == 0x84 && word(8) == bytes.count)
        #expect(word(16) == 2 && word(20) == 3 && word(28) == 0x66 && bytes[48] == 2)
        // mhsd 1: mhli, one mhii, its mhod 2, mhni, mhod 3
        var at = 0x84
        #expect(tag(at) == "mhsd" && word(at + 4) == 0x60 && word(at + 12) == 1)
        let second = at + word(at + 8)
        at += 0x60
        #expect(tag(at) == "mhli" && word(at + 4) == 0x5C && word(at + 8) == 1)
        at += 0x5C
        #expect(tag(at) == "mhii" && word(at + 4) == 0x98 && word(at + 12) == 1 && word(at + 16) == 0x40)
        #expect(word(at + 20) == 0x42)  // libgpod's song ID for a photo: its ID + 2
        at += 0x98
        #expect(tag(at) == "mhod" && word(at + 4) == 24 && word(at + 12) == 2)
        at += 24
        #expect(tag(at) == "mhni" && word(at + 4) == 0x4C && word(at + 12) == 1 && word(at + 16) == 3004)
        #expect(word(at + 24) == 6160 && word(at + 28) == 0x0001_0002 && word(at + 32) == 0x0036_0037)
        at += 0x4C
        let name = Array(":Thumbs:F3004_64.ithmb".utf16)
        #expect(tag(at) == "mhod" && word(at + 4) == 24 && bytes[at + 12] == 3 && word(at + 24) == name.count * 2)
        #expect(bytes[at + 28] == 2 && word(at + 8) == 36 + name.count * 2 + Int(bytes[at + 15]))
        #expect(word(at + 8) % 4 == 0)
        // mhsd 2: the master album, type 1, named, holding the image
        at = second
        #expect(tag(at) == "mhsd" && word(at + 12) == 2)
        let third = at + word(at + 8)
        at += 0x60
        #expect(tag(at) == "mhla" && word(at + 8) == 1)
        at += 0x5C
        #expect(tag(at) == "mhba" && word(at + 4) == 0x94 && word(at + 12) == 1 && word(at + 16) == 1)
        #expect(word(at + 20) == 0x65 && bytes[at + 30] == 1 && word(at + 60) == 0x64)
        at += 0x94
        #expect(tag(at) == "mhod" && bytes[at + 12] == 1 && bytes[at + 28] == 1)
        #expect(String(decoding: bytes[at + 36..<at + 36 + word(at + 24)], as: UTF8.self) == "Photo Library")
        at += word(at + 8)
        #expect(tag(at) == "mhia" && word(at + 4) == 40 && word(at + 16) == 0x40)
        // mhsd 3: the formats, libgpod's ipod_touch_1_photo_info sizes
        at = third
        #expect(tag(at) == "mhsd" && bytes[at + 12] == 3 && at + word(at + 8) == bytes.count)
        at += 0x60
        #expect(tag(at) == "mhlf" && word(at + 8) == 4)
        at += 0x5C
        var sizes: [Int: Int] = [:]
        for _ in 0..<4 {
            #expect(tag(at) == "mhif" && word(at + 4) == 0x7C && word(at + 8) == 0x7C)
            sizes[word(at + 16)] = word(at + 20)
            at += 0x7C
        }
        #expect(sizes == [3004: 56 * 55 * 2, 3011: 80 * 79 * 2, 3009: 160 * 120 * 2, 3008: 640 * 480 * 2])
    }

    @Test func aTallPhotoIsFittedAndCroppedInL555() throws {
        // 100 wide, 200 tall, red
        let context = try #require(
            CGContext(
                data: nil,
                width: 100,
                height: 200,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
            )
        )
        context.setFillColor(red: 1, green: 0, blue: 0, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: 100, height: 200))
        let image = try #require(context.makeImage())
        let full = try #require(PhotoDatabase.photoFormats.first { $0.id == 3008 })
        let (pixels, record) = try PhotoDatabase.pixels(of: image, in: full, file: ":Thumbs:F3008_64.ithmb", offset: 0)
        #expect(pixels.count == 1280 * 480 && record.size == 1280 * 480)
        // fitted: 240 by 480, centered between white bars of 200
        #expect(record.horizontalPadding == 200 && record.verticalPadding == 0)
        #expect(record.width == 440 && record.height == 480)
        let words = pixels.withUnsafeBytes { Array($0.bindMemory(to: UInt16.self)).map(UInt16.init(littleEndian:)) }
        #expect(words[240 * 640 + 320] == 0xFC00)  // red, the top bit set
        #expect(words[240 * 640 + 10] == 0xFFFF && words[240 * 640 + 630] == 0xFFFF)  // white
        let small = try #require(PhotoDatabase.photoFormats.first { $0.id == 3004 })
        let (cropped, croppedRecord) = try PhotoDatabase.pixels(of: image, in: small, file: "", offset: 0)
        #expect(cropped.count == 112 * 55 && croppedRecord.horizontalPadding == 0 && croppedRecord.width == 55)
        let row = cropped.withUnsafeBytes { Array($0.bindMemory(to: UInt16.self)).map(UInt16.init(littleEndian:)) }
        #expect(row[0..<55].allSatisfy { $0 == 0xFC00 } && row[55] == 0xFFFF)  // filled; the row's 56th is padding
    }
}
