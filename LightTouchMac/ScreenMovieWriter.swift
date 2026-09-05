import AVFoundation
import CoreGraphics

/// The writer and pixel buffers stay on one actor. The producer awaits each
/// append; encoding cannot accumulate an unbounded queue of guest frames.
actor ScreenMovieWriter {
    private var writer: AVAssetWriter?
    private var input: AVAssetWriterInput?
    private var adaptor: AVAssetWriterInputPixelBufferAdaptor?
    private var count = 0

    func start(url: URL) throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let transfer: String
        if #available(macOS 15.0, *) { transfer = AVVideoTransferFunction_IEC_sRGB }
        else { transfer = AVVideoTransferFunction_ITU_R_709_2 }
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: 480, AVVideoHeightKey: 480,
            AVVideoColorPropertiesKey: [
                AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                AVVideoTransferFunctionKey: transfer,
                AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2
            ],
            AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: 3_000_000]
        ])
        input.expectsMediaDataInRealTime = true
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: 480,
                kCVPixelBufferHeightKey as String: 480,
                kCVPixelBufferCGImageCompatibilityKey as String: true,
                kCVPixelBufferCGBitmapContextCompatibilityKey as String: true
            ])
        guard writer.canAdd(input) else { throw CaptureError.failed("Video encoding is unavailable.") }
        writer.add(input)
        guard writer.startWriting() else { throw writer.error ?? CaptureError.failed("Could not start recording.") }
        writer.startSession(atSourceTime: .zero)
        self.writer = writer; self.input = input; self.adaptor = adaptor
        count = 0
    }
    func append(_ image: CGImage, seconds: Double) throws {
        guard let writer, let input, let adaptor else { return }
        if writer.status == .failed { throw writer.error ?? CaptureError.failed("Recording failed.") }
        guard input.isReadyForMoreMediaData, let pool = adaptor.pixelBufferPool else { return }
        var buffer: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer) == kCVReturnSuccess,
              let buffer else { throw CaptureError.failed("Could not allocate a recording frame.") }
        CVBufferSetAttachment(buffer, kCVImageBufferCGColorSpaceKey, CGColorSpace(name: CGColorSpace.sRGB)!, .shouldPropagate)
        CVBufferSetAttachment(buffer, kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_709_2, .shouldPropagate)
        CVBufferSetAttachment(buffer, kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_sRGB, .shouldPropagate)
        CVBufferSetAttachment(buffer, kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_709_2, .shouldPropagate)
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let context = CGContext(data: CVPixelBufferGetBaseAddress(buffer), width: 480, height: 480,
                                      bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.noneSkipFirst.rawValue) else {
            throw CaptureError.failed("Could not draw a recording frame.")
        }
        context.setFillColor(CGColor(gray: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 480, height: 480))
        // Keep native screen pixels through portrait/landscape changes, on a
        // constant canvas so rotating never corrupts the encoded stream.
        context.interpolationQuality = .none
        context.draw(image, in: CGRect(x: (480 - image.width) / 2, y: (480 - image.height) / 2,
                                       width: image.width, height: image.height))
        guard adaptor.append(buffer, withPresentationTime: CMTime(seconds: seconds, preferredTimescale: 600)) else {
            throw writer.error ?? CaptureError.failed("Could not encode a recording frame.")
        }
        count += 1
    }
    func finish(seconds: Double) async throws {
        guard let writer, let input else { throw CaptureError.failed("No recording is active.") }
        guard count > 0 else { writer.cancelWriting(); throw CaptureError.failed("No device frames were recorded.") }
        writer.endSession(atSourceTime: CMTime(seconds: seconds, preferredTimescale: 600))
        input.markAsFinished()
        await writer.finishWriting()
        self.writer = nil; self.input = nil; self.adaptor = nil
        guard writer.status == .completed else { throw writer.error ?? CaptureError.failed("Could not finish recording.") }
    }
}

nonisolated enum CaptureError: LocalizedError {
    case failed(String)
    var errorDescription: String? { if case .failed(let message) = self { message } else { nil } }
}
