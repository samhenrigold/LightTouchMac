import CoreGraphics
import Foundation
import ImageIO
import Testing

@testable import LightTouchCore

/// iPhone OS 1.0's Camera Roll draws a photo's grid cell from its DCF group's THM, which PhotoLibrary reads as a JPEG of
/// MLPhotoLibrary's format 1095 (75 by 75, cropped): FirstGenLibrary.cameraRollThumbnail writes that, the photo's
/// centered square. Fails with the size changed or the crop left out (a wide photo's red middle with blue ends).
struct CameraRollThumbnailTests {
    @Test func aWidePhotosThumbnailIsItsCenteredSquareAt75() async throws {
        try await withTemporaryState { work in
            let photo = work.appendingPathComponent("wide.jpg")
            let context = try #require(
                CGContext(
                    data: nil,
                    width: 300,
                    height: 100,
                    bitsPerComponent: 8,
                    bytesPerRow: 0,
                    space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
                )
            )
            context.setFillColor(red: 0, green: 0, blue: 1, alpha: 1)
            context.fill(CGRect(x: 0, y: 0, width: 300, height: 100))
            context.setFillColor(red: 1, green: 0, blue: 0, alpha: 1)
            context.fill(CGRect(x: 100, y: 0, width: 100, height: 100))
            let destination = try #require(
                CGImageDestinationCreateWithURL(photo as CFURL, "public.jpeg" as CFString, 1, nil))
            CGImageDestinationAddImage(destination, try #require(context.makeImage()), nil)
            #expect(CGImageDestinationFinalize(destination))

            let data = try FirstGenLibrary.cameraRollThumbnail(of: photo)
            let source = try #require(CGImageSourceCreateWithData(data as CFData, nil))
            #expect(CGImageSourceGetType(source) as String? == "public.jpeg")
            let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
            #expect(image.width == 75 && image.height == 75)
            // every pixel red, the edges included: none of the blue ends got in
            let pixels = try #require(
                CGContext(
                    data: nil,
                    width: 75,
                    height: 75,
                    bitsPerComponent: 8,
                    bytesPerRow: 75 * 4,
                    space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
                )
            )
            pixels.draw(image, in: CGRect(x: 0, y: 0, width: 75, height: 75))
            let bytes = try #require(pixels.data).assumingMemoryBound(to: UInt8.self)
            let blue = (0..<75 * 75).filter { bytes[$0 * 4 + 2] > 128 || bytes[$0 * 4] < 128 }.count
            #expect(blue == 0, "\(blue) of the thumbnail's pixels aren't the photo's red middle")
        }
    }
}
