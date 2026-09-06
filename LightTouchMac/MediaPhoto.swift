import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

/// A small, upright baseline JPEG for the guest's native Saved Photos API.
struct MediaPhoto: Sendable {
    let id: String
    let directory: URL
    let image: URL
    let title: String

    nonisolated static let extensions: Set<String> = ["jpg", "jpeg", "png", "heic", "heif"]

    nonisolated static func prepare(_ source: URL) async throws -> MediaPhoto {
        let worker = Task.detached {
            try Task.checkCancellation()
            guard extensions.contains(source.pathExtension.lowercased()) else {
                throw DeviceToolsError.failed("Choose a JPEG, PNG or HEIC photo.")
            }
            let values = try source.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            guard values.isRegularFile == true, let size = values.fileSize,
                  size > 0, size <= 64 << 20,
                  let imageSource = CGImageSourceCreateWithURL(source as CFURL, nil),
                  let properties = CGImageSourceCopyPropertiesAtIndex(imageSource, 0, nil) as? [CFString: Any],
                  let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
                  let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue,
                  width > 0, height > 0, width <= 100000, height <= 100000,
                  width * height <= 100_000_000 else {
                throw DeviceToolsError.failed("The photo must be a readable image of at most 64 MB and 100 megapixels.")
            }
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 2048,
                kCGImageSourceShouldCacheImmediately: true,
            ]
            guard let thumbnail = CGImageSourceCreateThumbnailAtIndex(imageSource, 0, options as CFDictionary),
                  CGImageSourceGetStatusAtIndex(imageSource, 0) == .statusComplete,
                  let context = CGContext(data: nil, width: thumbnail.width, height: thumbnail.height,
                    bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else {
                throw DeviceToolsError.failed("The photo could not be decoded.")
            }
            try Task.checkCancellation()
            // JPEG has no alpha. Flatten transparent images against white.
            let bounds = CGRect(x: 0, y: 0, width: thumbnail.width, height: thumbnail.height)
            context.setFillColor(red: 1, green: 1, blue: 1, alpha: 1)
            context.fill(bounds)
            context.draw(thumbnail, in: bounds)
            guard let image = context.makeImage() else {
                throw DeviceToolsError.failed("The photo could not be prepared.")
            }
            let id = UUID().uuidString.lowercased()
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("ltm-photo-" + id, isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
            var complete = false
            defer { if !complete { try? FileManager.default.removeItem(at: directory) } }
            let output = directory.appendingPathComponent("image.jpg")
            guard let destination = CGImageDestinationCreateWithURL(output as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else {
                throw DeviceToolsError.failed("Could not create the prepared photo.")
            }
            let encoding: [CFString: Any] = [
                kCGImageDestinationLossyCompressionQuality: 0.9,
                kCGImagePropertyOrientation: 1,
                kCGImagePropertyJFIFDictionary: [kCGImagePropertyJFIFIsProgressive: false],
            ]
            CGImageDestinationAddImage(destination, image, encoding as CFDictionary)
            guard CGImageDestinationFinalize(destination) else {
                throw DeviceToolsError.failed("Could not finish the prepared photo.")
            }
            try Task.checkCancellation()
            let result = MediaPhoto(id: id, directory: directory, image: output,
                                    title: source.deletingPathExtension().lastPathComponent)
            complete = true
            return result
        }
        return try await withTaskCancellationHandler {
            let photo = try await worker.value
            if Task.isCancelled {
                try? FileManager.default.removeItem(at: photo.directory)
                throw CancellationError()
            }
            return photo
        } onCancel: { worker.cancel() }
    }
}
