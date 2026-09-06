import AVFoundation
import CoreGraphics
import Darwin

/// The writer and pixel buffers stay on one actor. The producer awaits each
/// append; encoding cannot accumulate an unbounded queue of guest frames.
actor ScreenMovieWriter {
    private var writer: AVAssetWriter?
    private var input: AVAssetWriterInput?
    private var adaptor: AVAssetWriterInputPixelBufferAdaptor?
    private var count = 0
    private var audioInput: AVAssetWriterInput?
    private var audioFormat: CMAudioFormatDescription?
    private var capture: GuestAudioCapture?
    private var finishing = false
    private var audioFrame: Int64 = 0
    private var firstFrameSize: CGSize?
    private var changedFrameSize = false

    func start(url: URL, recordGuestAudio: Bool = false) throws {
        guard self.writer == nil, !finishing else { throw CaptureError.failed("A recording is already active.") }
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
        let audioInput: AVAssetWriterInput?
        if recordGuestAudio {
            let audio = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 44100,
                AVNumberOfChannelsKey: 2, AVEncoderBitRateKey: 128000
            ])
            audio.expectsMediaDataInRealTime = true
            guard writer.canAdd(audio) else { throw CaptureError.failed("Audio encoding is unavailable.") }
            writer.add(audio)
            audioInput = audio
        } else { audioInput = nil }
        guard writer.startWriting() else { throw writer.error ?? CaptureError.failed("Could not start recording.") }
        writer.startSession(atSourceTime: .zero)
        do { capture = recordGuestAudio ? try GuestAudioCapture() : nil }
        catch { writer.cancelWriting(); throw error }
        self.audioInput = audioInput
        self.writer = writer; self.input = input; self.adaptor = adaptor
        count = 0
        audioFrame = 0
        firstFrameSize = nil
        changedFrameSize = false
    }
    func append(_ image: CGImage?, seconds: Double) async throws {
        guard !finishing else { return }
        _ = try await drainAudio()
        guard let image else { return }
        let seconds = capture?.seconds ?? seconds
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
        let size = CGSize(width: image.width, height: image.height)
        if let firstFrameSize { changedFrameSize = changedFrameSize || firstFrameSize != size }
        else { firstFrameSize = size }
        count += 1
    }
    private func drainAudio(through end: Double? = nil) async throws -> Bool {
        guard let capture, let audioInput else { return true }
        guard let writer, writer.status != .failed else {
            throw self.writer?.error ?? CaptureError.failed("Audio recording failed.")
        }
        while audioInput.isReadyForMoreMediaData {
            guard let packet = try capture.read() else { return true }
            try await appendAudio(packet.data, seconds: packet.seconds, through: end)
            if packet.data.isEmpty { return true }
        }
        return false
    }

    private func appendAudio(_ data: Data, seconds: Double, through end: Double? = nil) async throws {
        guard audioInput != nil else { return }
        guard seconds.isFinite, seconds >= 0, seconds < Double(Int64.max / 44100), data.count % 4 == 0 else {
            throw CaptureError.failed("Invalid guest audio packet.")
        }
        let target = Int64((seconds * 44100).rounded())
        let limit = end.map { Int64(max(0, $0 * 44100)) } ?? Int64.max
        // AAC encoding closes timestamp gaps. Supply silence explicitly, in
        // bounded chunks, so pauses and idle periods retain video alignment.
        while audioFrame < min(target, limit) {
            let frames = Int(min(4410, min(target, limit) - audioFrame))
            try await encodeAudio(Data(count: frames * 4), frames: frames)
        }
        let skipped = Int(min(Int64(data.count / 4), max(0, audioFrame - target)))
        let frames = min(data.count / 4 - skipped, Int(max(0, min(Int64(data.count / 4), limit - audioFrame))))
        guard frames > 0 else { return }
        try await encodeAudio(Data(data.dropFirst(skipped * 4)), frames: frames)
    }

    private func encodeAudio(_ data: Data, frames: Int) async throws {
        guard let audioInput, let writer else { return }
        let deadline = ContinuousClock.now + .seconds(10)
        while !audioInput.isReadyForMoreMediaData {
            guard writer.status == .writing, ContinuousClock.now < deadline else {
                throw writer.error ?? CaptureError.failed("Audio encoder did not become ready.")
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        if audioFormat == nil {
            var format = AudioStreamBasicDescription(mSampleRate: 44100, mFormatID: kAudioFormatLinearPCM,
                mFormatFlags: kLinearPCMFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked,
                mBytesPerPacket: 4, mFramesPerPacket: 1, mBytesPerFrame: 4,
                mChannelsPerFrame: 2, mBitsPerChannel: 16, mReserved: 0)
            guard CMAudioFormatDescriptionCreate(allocator: kCFAllocatorDefault, asbd: &format,
                layoutSize: 0, layout: nil, magicCookieSize: 0, magicCookie: nil,
                extensions: nil, formatDescriptionOut: &audioFormat) == noErr else {
                throw CaptureError.failed("Could not describe guest audio.")
            }
        }
        var block: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault, memoryBlock: nil,
            blockLength: frames * 4, blockAllocator: kCFAllocatorDefault, customBlockSource: nil,
            offsetToData: 0, dataLength: frames * 4, flags: 0, blockBufferOut: &block) == noErr,
            let block else { throw CaptureError.failed("Could not allocate an audio packet.") }
        let copied = data.withUnsafeBytes {
            CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: block,
                offsetIntoDestination: 0, dataLength: frames * 4)
        }
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 44100),
            presentationTimeStamp: CMTime(value: audioFrame, timescale: 44100), decodeTimeStamp: .invalid)
        var size = 4
        var sample: CMSampleBuffer?
        guard copied == noErr, CMSampleBufferCreateReady(allocator: kCFAllocatorDefault,
            dataBuffer: block, formatDescription: audioFormat, sampleCount: frames,
            sampleTimingEntryCount: 1, sampleTimingArray: &timing,
            sampleSizeEntryCount: 1, sampleSizeArray: &size, sampleBufferOut: &sample) == noErr,
            let sample, audioInput.append(sample) else {
            throw writer.error ?? CaptureError.failed("Could not encode guest audio.")
        }
        audioFrame += Int64(frames)
    }

    /// Capture keeps a fixed canvas so rotation never interrupts audio or video.
    /// When every encoded frame has the same geometry, remove only its padding.
    private func cropFinishedMovie(at url: URL, to size: CGSize) async throws {
        guard size != CGSize(width: 480, height: 480) else { return }
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            throw CaptureError.failed("The recording has no video track.")
        }
        let duration = try await asset.load(.duration)
        let layer = AVMutableVideoCompositionLayerInstruction(assetTrack: track)
        layer.setTransform(CGAffineTransform(translationX: -(480 - size.width) / 2,
                                             y: -(480 - size.height) / 2), at: .zero)
        let instruction = AVMutableVideoCompositionInstruction()
        instruction.timeRange = CMTimeRange(start: .zero, duration: duration)
        instruction.layerInstructions = [layer]
        let composition = AVMutableVideoComposition()
        composition.instructions = [instruction]
        composition.renderSize = size
        composition.frameDuration = CMTime(value: 1, timescale: 30)
        composition.colorPrimaries = AVVideoColorPrimaries_ITU_R_709_2
        if #available(macOS 15.0, *) { composition.colorTransferFunction = AVVideoTransferFunction_IEC_sRGB }
        else { composition.colorTransferFunction = AVVideoTransferFunction_ITU_R_709_2 }
        composition.colorYCbCrMatrix = AVVideoYCbCrMatrix_ITU_R_709_2
        guard let export = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetHighestQuality) else {
            throw CaptureError.failed("Could not prepare the recording for export.")
        }
        export.videoComposition = composition
        let cropped = url.deletingLastPathComponent().appendingPathComponent(".capture-\(UUID().uuidString).mov")
        defer { try? FileManager.default.removeItem(at: cropped) }
        if #available(macOS 15.0, *) {
            try await export.export(to: cropped, as: .mov)
        } else {
            export.outputURL = cropped
            export.outputFileType = .mov
            await export.export()
            guard export.status == .completed else {
                throw export.error ?? CaptureError.failed("Could not export the recording.")
            }
        }
        // Keep the complete original until the replacement is ready. The asset
        // includes its audio track, preserving silence and the capture timeline.
        _ = try FileManager.default.replaceItemAt(url, withItemAt: cropped)
    }

    func finish(seconds: Double) async throws {
        guard let writer, let input, !finishing else { throw CaptureError.failed("No recording is active.") }
        finishing = true
        let end = capture?.seconds ?? seconds
        capture?.stop()
        defer {
            capture = nil; audioInput = nil; audioFormat = nil
            self.writer = nil; self.input = nil; self.adaptor = nil
            finishing = false
        }
        do {
            guard count > 0 else { throw CaptureError.failed("No device frames were recorded.") }
            let deadline = ContinuousClock.now + .seconds(10)
            while try await !drainAudio(through: end) {
                guard ContinuousClock.now < deadline else { throw CaptureError.failed("Audio encoder did not finish in time.") }
                try await Task.sleep(for: .milliseconds(10))
            }
            try await appendAudio(Data(), seconds: end, through: end)
            writer.endSession(atSourceTime: CMTime(seconds: end, preferredTimescale: 44100))
            input.markAsFinished()
            audioInput?.markAsFinished()
            await writer.finishWriting()
            guard writer.status == .completed else { throw writer.error ?? CaptureError.failed("Could not finish recording.") }
            if let firstFrameSize, !changedFrameSize {
                try await cropFinishedMovie(at: writer.outputURL, to: firstFrameSize)
            }
        } catch { writer.cancelWriting(); throw error }
    }
}

nonisolated enum CaptureError: LocalizedError {
    case failed(String)
    var errorDescription: String? { if case .failed(let message) = self { message } else { nil } }
}


private nonisolated struct GuestAudioCapture {
    private typealias Start = @convention(c) () -> UInt64
    private typealias Read = @convention(c) (UInt64, UnsafeMutableRawPointer?, Int32, UnsafeMutablePointer<Double>?) -> Int32
    private typealias Time = @convention(c) (UInt64) -> Double
    private typealias Stop = @convention(c) (UInt64) -> Void
    private let token: UInt64
    private let readFunction: Read
    private let timeFunction: Time
    private let stopFunction: Stop
    init() throws {
        func symbol<T>(_ name: String, _ type: T.Type) throws -> T {
            guard let pointer = dlsym(UnsafeMutableRawPointer(bitPattern: -2), name) else {
                throw CaptureError.failed("This emulator build does not support audio recording.")
            }
            return unsafeBitCast(pointer, to: type)
        }
        let start = try symbol("qemu_ios_audio_capture_start", Start.self)
        readFunction = try symbol("qemu_ios_audio_capture_read", Read.self)
        timeFunction = try symbol("qemu_ios_audio_capture_time", Time.self)
        stopFunction = try symbol("qemu_ios_audio_capture_stop", Stop.self)
        token = start()
        guard token != 0 else { throw CaptureError.failed("The device is not ready to record audio.") }
    }
    var seconds: Double { timeFunction(token) }
    func stop() { stopFunction(token) }
    func read() throws -> (data: Data, seconds: Double)? {
        var data = Data(count: 16384)
        var seconds = -1.0
        let count = data.withUnsafeMutableBytes { readFunction(token, $0.baseAddress, 16384, &seconds) }
        guard count >= 0 else { throw CaptureError.failed("Guest audio capture stopped or its buffer overflowed.") }
        guard count > 0 || seconds >= 0 else { return nil }
        data.count = Int(count)
        return (data, seconds)
    }
}
