// Frame helpers for the headless modes and tests/drivers/helper-driver: PNG dumps and a
// "lit" measure, read straight from a ring surface.

import CoreGraphics
import Foundation
import ImageIO
import IOSurface
import UniformTypeIdentifiers

enum FrameTools {
    /// Share of sampled bytes brighter than 60 (the spikes' measure: the iPod's
    /// lock screen reads ~0.03, the iPad's ~0.3).
    static func brightness(_ surface: IOSurface) -> Double {
        // In use: the helper will not write into it while it is read.
        surface.incrementUseCount()
        surface.lock(options: .readOnly, seed: nil)
        defer { surface.unlock(options: .readOnly, seed: nil); surface.decrementUseCount() }
        let base = surface.baseAddress
        let rowBytes = surface.width * 4
        var bright = 0, total = 0
        for y in stride(from: 0, to: surface.height, by: 7) {
            for x in stride(from: 0, to: rowBytes, by: 13) where x % 4 != 3 {
                if base.load(fromByteOffset: y * surface.bytesPerRow + x, as: UInt8.self) > 60 { bright += 1 }
                total += 1
            }
        }
        return total == 0 ? 0 : Double(bright) / Double(total)
    }

    /// BGRA, alpha ignored (the iPod's framebuffer leaves it 0).
    @discardableResult
    static func writePNG(_ surface: IOSurface, to url: URL) -> Bool {
        surface.incrementUseCount()
        surface.lock(options: .readOnly, seed: nil)
        let data = Data(bytes: surface.baseAddress, count: surface.bytesPerRow * surface.height)
        surface.unlock(options: .readOnly, seed: nil)
        surface.decrementUseCount()
        guard let provider = CGDataProvider(data: data as CFData),
              let image = CGImage(width: surface.width, height: surface.height, bitsPerComponent: 8, bitsPerPixel: 32,
                                  bytesPerRow: surface.bytesPerRow, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipFirst.rawValue
                                                           | CGBitmapInfo.byteOrder32Little.rawValue),
                                  provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent),
              let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)
        else { return false }
        CGImageDestinationAddImage(destination, image, nil)
        return CGImageDestinationFinalize(destination)
    }
}
