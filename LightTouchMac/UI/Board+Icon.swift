// The device's icon in the sidebar and the Add Device sheet: macOS's own artwork for the model (Finder's),
// found by its product type through AppleDeviceType; an SF Symbol where this macOS doesn't declare the model.
// Text keeps the app's names (marketingName): macOS calls both iPods just "iPod touch".

import AppKit
import HostRuntime

extension Board {
    /// macOS's declared type for the board: its product type is the com.apple.device-model-code tag.
    var deviceType: AppleDeviceType? { AppleDeviceType(productType) }

    var icon: NSImage {
        Self.icon(
            modelCode: productType,
            // FIXME: ugly code
            fallbackSymbol: [.iPad: "ipad", .iPhone: "iphone"][facts.kind] ?? "ipodtouch"
        )
    }

    /// Made once per model: reading the icns and looking for a plate in every image took the Add Device sheet, which
    /// shows every board, 200 ms each time it opened, and the iPhone 4's lift 3 s in a Debug build (prepareIcons).
    static func icon(modelCode: String, fallbackSymbol: String) -> NSImage {
        if let cached = icons[modelCode] {
            return cached
        }
        guard let icon = artwork(modelCode) else {
            return NSImage(systemSymbolName: fallbackSymbol, accessibilityDescription: nil) ?? NSImage()
        }
        icons[modelCode] = icon
        return icon
    }

    private static var icons: [String: NSImage] = [:]

    /// At launch: every board's artwork, made off the main thread, so the sidebar and Add Device find them ready.
    static func prepareIcons() {
        let codes = allCases.map(\.productType)
        Task {
            for (code, icon) in await artwork(codes) where icons[code] == nil {
                icons[code] = icon
            }
        }
    }

    @concurrent private nonisolated static func artwork(_ codes: [String]) async -> sending [String: NSImage] {
        var made: [String: NSImage] = [:]
        for code in codes {
            made[code] = artwork(code)
        }
        return made
    }

    /// macOS's icon for the model with any plate lifted; nil where this macOS doesn't declare the model.
    private nonisolated static func artwork(_ modelCode: String) -> NSImage? {
        guard let icon = AppleDeviceType(modelCode)?.icon else {
            return nil
        }
        return liftingPlate(icon) ?? icon
    }

    /// macOS's iPhone 4 icon (CoreTypes' com.apple.iphone-4-*.icns) lays its 256-1024 px images on a square of 12%
    /// white, which shows as a lighter square in dark mode (issue 44). Where an image's four corners are one
    /// translucent color, that uniform backing is composited out of every pixel (shadow included); nil when no image
    /// has one.
    private nonisolated static func liftingPlate(_ icon: NSImage) -> NSImage? {
        var lifted = false
        let image = NSImage(size: icon.size)
        var sizes: Set<[CGFloat]> = []
        // One image per size (the icon has a light and a dark one, alike).
        for rep in icon.representations
        where rep.pixelsWide > 0 && rep.pixelsHigh > 0
            && sizes.insert([CGFloat(rep.pixelsWide), rep.size.width]).inserted
        {
            guard
                let bitmap = NSBitmapImageRep(
                    bitmapDataPlanes: nil,
                    pixelsWide: rep.pixelsWide,
                    pixelsHigh: rep.pixelsHigh,
                    bitsPerSample: 8,
                    samplesPerPixel: 4,
                    hasAlpha: true,
                    isPlanar: false,
                    colorSpaceName: .deviceRGB,
                    bytesPerRow: rep.pixelsWide * 4,
                    bitsPerPixel: 32
                ), let data = bitmap.bitmapData
            else { return nil }
            bitmap.size = rep.size
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
            rep.draw(in: NSRect(origin: .zero, size: rep.size))
            NSGraphicsContext.restoreGraphicsState()
            // Premultiplied RGBA: out = icon + plate × (1 − iconAlpha), and outAlpha = iconAlpha + plateAlpha × (1 −
            // iconAlpha), so icon = out − plate × (1 − outAlpha) / (1 − plateAlpha).
            let w = bitmap.pixelsWide
            let h = bitmap.pixelsHigh
            let corners = [0, w - 1, (h - 1) * w, h * w - 1].map {
                Array(UnsafeBufferPointer(start: data + $0 * 4, count: 4))
            }
            let plate = corners[0].map { Double($0) / 255 }
            if corners.allSatisfy({ $0 == corners[0] }), plate[3] > 0, plate[3] < 1 {
                lifted = true
                for pixel in stride(from: 0, to: w * h * 4, by: 4) {
                    let under = (1 - Double(data[pixel + 3]) / 255) / (1 - plate[3])
                    for channel in 0..<4 {
                        let value = Double(data[pixel + channel]) - 255 * plate[channel] * under
                        data[pixel + channel] = UInt8(max(0, min(255, value.rounded())))
                    }
                }
            }
            image.addRepresentation(bitmap)
        }
        return lifted ? image : nil
    }
}
