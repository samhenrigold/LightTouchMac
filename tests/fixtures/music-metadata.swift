import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

enum DeviceToolsError: Error { case failed(String) }

@main struct Check {
    static func main() async throws {
        let root = URL(fileURLWithPath: CommandLine.arguments[1])
        if CommandLine.arguments.last == "cover" {
            let context = CGContext(data: nil, width: 400, height: 400, bitsPerComponent: 8,
                                    bytesPerRow: 1600, space: CGColorSpaceCreateDeviceRGB(),
                                    bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
            context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: 400, height: 400))
            context.setFillColor(CGColor(red: 0, green: 0, blue: 1, alpha: 1))
            context.fill(CGRect(x: 200, y: 0, width: 200, height: 400))
            let destination = CGImageDestinationCreateWithURL(root.appendingPathComponent("cover.jpg") as CFURL,
                                                              UTType.jpeg.identifier as CFString, 1, nil)!
            CGImageDestinationAddImage(destination, context.makeImage()!, nil)
            precondition(CGImageDestinationFinalize(destination))
            return
        }
        for name in ["tagged.m4a", "tagged.mp3", "plain.m4a"] {
            let source = root.appendingPathComponent(name)
            let song = try await MediaSong.prepare(source)
            defer { try? FileManager.default.removeItem(at: song.directory) }
            let audioUnchanged = try Data(contentsOf: song.audio) == Data(contentsOf: source)
            precondition(audioUnchanged, "audio bytes changed")
            let p = try PropertyListSerialization.propertyList(from: Data(contentsOf: song.metadata), format: nil) as! [String: Any]
            if name == "plain.m4a" {
                precondition(song.artwork == nil && p["artwork_filename"] == nil)
                precondition(p["title"] as? String == "plain")
                continue
            }
            for (key, value) in ["title": "Cover Song", "artist": "Track Artist", "album": "Cover Album",
                                 "album_artist": "Album Artist", "composer": "Fixture Composer", "genre": "Jazz"] {
                precondition(p[key] as? String == value, "missing \(key) in \(name): \(p)")
            }
            for (key, value) in ["track_number": 3, "track_count": 12, "disc_number": 2, "disc_count": 3] {
                precondition((p[key] as? NSNumber)?.intValue == value, "missing \(key) in \(name): \(p)")
            }
            precondition(p["artwork_filename"] as? String == "artwork.jpg")
            let artwork = try Data(contentsOf: song.artwork!)
            let image = CGImageSourceCreateWithData(artwork as CFData, nil)!
            let properties = CGImageSourceCopyPropertiesAtIndex(image, 0, nil)! as NSDictionary
            precondition(properties[kCGImagePropertyPixelWidth] as? Int == 400)
            precondition(properties[kCGImagePropertyPixelHeight] as? Int == 400)
            precondition(CGImageSourceGetType(image) == UTType.jpeg.identifier as CFString)
            let repeated = try await MediaSong.prepare(source)
            defer { try? FileManager.default.removeItem(at: repeated.directory) }
            precondition(repeated.id == song.id && repeated.directory != song.directory)
            let artworkUnchanged = try Data(contentsOf: repeated.artwork!) == artwork
            precondition(artworkUnchanged)
        }
        print("PASS: MP3/ID3 and M4A tags, embedded artwork, exact audio bytes, repeat identity and untagged fallback")
    }
}
