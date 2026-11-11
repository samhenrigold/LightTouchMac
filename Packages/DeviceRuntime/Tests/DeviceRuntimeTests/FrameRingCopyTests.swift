import Accelerate
import Foundation
import IOSurface
import Testing

@testable import DeviceRuntime

struct FrameRingCopyTests {
    /// An iPad frame (768x1024) is copied in well under a 60 Hz frame as these tests build it, unoptimized, as the
    /// Debug helper runs: the copy is on the publishing queue's one thread, so its time caps the frame rate.
    @Test func anIPadFrameCopiesWithinAFrame() {
        let (width, height) = (768, 1024)
        let pixels = UnsafeMutableRawPointer.allocate(byteCount: width * height * 4, alignment: 16)
        defer { pixels.deallocate() }
        let surface = makeSurface(width: width, height: height)
        surface.lock(options: [], seed: nil)
        defer { surface.unlock(options: [], seed: nil) }
        let clock = ContinuousClock()
        let fastest =
            (0..<5).map { _ in
                clock.measure { FrameRingWriter.copy(pixels, width: width, height: height, into: surface) }
            }.min() ?? .zero
        #expect(fastest < .milliseconds(8), "\(fastest)")
    }

    /// The copy forces each pixel's 4th byte to 255 and leaves the rest, as vImageOverwriteChannelsWithScalar did,
    /// on a surface whose rows are padded and on one whose rows are not.
    @Test(arguments: [(37, 5), (64, 3)]) func theCopyIsOpaqueAsVImageMadeIt(width: Int, height: Int) {
        let pixels = (0..<width * height * 4).map { UInt8(truncatingIfNeeded: ($0 &* 2_654_435_761) >> 13) }
        let surface = makeSurface(width: width, height: height)
        #expect((surface.bytesPerRow == width * 4) == (width == 64))
        let expected = makeSurface(width: width, height: height)
        surface.lock(options: [], seed: nil)
        expected.lock(options: [], seed: nil)
        defer {
            surface.unlock(options: [], seed: nil)
            expected.unlock(options: [], seed: nil)
        }
        pixels.withUnsafeBytes { FrameRingWriter.copy($0.baseAddress!, width: width, height: height, into: surface) }
        for y in 0..<height {
            _ = pixels.withUnsafeBytes {
                memcpy(expected.baseAddress + y * expected.bytesPerRow, $0.baseAddress! + y * width * 4, width * 4)
            }
        }
        var buffer = vImage_Buffer(
            data: expected.baseAddress,
            height: vImagePixelCount(height),
            width: vImagePixelCount(width),
            rowBytes: expected.bytesPerRow
        )
        _ = vImageOverwriteChannelsWithScalar_ARGB8888(255, &buffer, &buffer, 0x1, vImage_Flags(kvImageNoFlags))
        for y in 0..<height {
            #expect(
                memcmp(
                    surface.baseAddress + y * surface.bytesPerRow,
                    expected.baseAddress + y * expected.bytesPerRow,
                    width * 4
                ) == 0
            )
        }
    }
}
