import AppKit
import CoreImage
import ScreenCaptureKit

/// A crop of this process's device window. Never requests desktop permission.
@MainActor
final class CanvasCapture {
    private weak var view: NSView?
    private var stream: SCStream?
    private let frames = CanvasFrames()
    private var installedCrop: CGRect = .zero
    private var installedSize = CGSize.zero
    private var refresh: Task<Void, Never>?
    private var windowID: CGWindowID?
    private var filter: SCContentFilter?
    private(set) var outputSize = CGSize.zero

    init(view: NSView) { self.view = view }

    private func configuration() throws -> SCStreamConfiguration {
        guard let view, let window = view.window, window.isVisible, !window.isMiniaturized,
              view.bounds.width > 1, view.bounds.height > 1 else {
            throw CaptureError.failed("Open the \(DeviceProfile.current.shortName) window to capture it.")
        }
        let rect = view.convert(view.safeAreaRect, to: nil)
        // SCK's independent-window crop is top-left based, in window points.
        let geometry = CGRect(x: rect.minX, y: window.frame.height - rect.maxY,
                          width: rect.width, height: rect.height)
        let config = SCStreamConfiguration()
        config.sourceRect = geometry
        config.width = max(2, Int(rect.width * window.backingScaleFactor) / 2 * 2)
        config.height = max(2, Int(rect.height * window.backingScaleFactor) / 2 * 2)
        config.showsCursor = false
        config.capturesAudio = false
        config.ignoreShadowsSingleWindow = true
        config.includeChildWindows = false
        config.queueDepth = 3
        config.minimumFrameInterval = CMTime(value: 1, timescale: 60)
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.colorSpaceName = CGColorSpace.sRGB
        return config
    }

    private func contentFilter() async throws -> SCContentFilter {
        guard let window = view?.window else { throw CaptureError.failed("The \(DeviceProfile.current.shortName) window is unavailable.") }
        let id = CGWindowID(window.windowNumber)
        if windowID == id, let filter { return filter }
        let content = try await SCShareableContent.currentProcess
        guard let ownWindow = content.windows.first(where: { $0.windowID == id && $0.owningApplication?.processID == getpid() }) else {
            throw CaptureError.failed("The \(DeviceProfile.current.shortName) window is unavailable for capture.")
        }
        let filter = SCContentFilter(desktopIndependentWindow: ownWindow)
        self.filter = filter
        windowID = id
        return filter
    }

    func screenshot() async throws -> CGImage {
        let filter = try await contentFilter()
        let config = try configuration()
        return try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
    }

    func start() async throws {
        let filter = try await contentFilter()
        let config = try configuration()
        outputSize = CGSize(width: config.width, height: config.height)
        installedCrop = config.sourceRect
        installedSize = outputSize
        frames.clear()
        let stream = SCStream(filter: filter, configuration: config, delegate: frames)
        try stream.addStreamOutput(frames, type: .screen, sampleHandlerQueue: frames.queue)
        self.stream = stream
        try await stream.startCapture()
        // Wait for an actual rendered frame; a first black frame isn't a recording.
        for _ in 0..<120 {
            try Task.checkCancellation()
            if frames.image != nil { break }
            if let error = frames.failure { throw error }
            try await Task.sleep(for: .milliseconds(16))
        }
        guard frames.image != nil else { await stop(); throw CaptureError.failed("No canvas frames arrived.") }
        refresh = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .milliseconds(50)) } catch { return }
                guard let self, let stream = self.stream else { return }
                do {
                    let config = try configuration()
                    let size = CGSize(width: config.width, height: config.height)
                    if installedCrop != config.sourceRect || installedSize != size {
                        // Until the new crop is installed, don't publish a stale crop containing chrome.
                        frames.suspend()
                        try await stream.updateConfiguration(config)
                        installedCrop = config.sourceRect
                        installedSize = size
                        frames.resume()
                    }
                } catch { frames.fail(error); return }
            }
        }
    }

    func frame() throws -> CGImage? {
        if let error = frames.failure { throw error }
        let config = try configuration()
        if installedCrop != config.sourceRect || installedSize != CGSize(width: config.width, height: config.height) {
            frames.suspend()
        }
        return frames.image
    }

    func stop() async {
        refresh?.cancel(); refresh = nil
        let old = stream; stream = nil
        try? await old?.stopCapture()
        frames.clear()
    }
}

/// Delegate delivery is confined to the SCK queue; consumers copy an immutable image.
private nonisolated final class CanvasFrames: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    let queue = DispatchQueue(label: "app.lighttouch.canvas-capture", qos: .userInitiated)
    private let lock = NSLock()
    private let context = CIContext(options: [.cacheIntermediates: false])
    private var latest: CGImage?
    private var error: Error?
    private var suspended = false
    private var earliestFrame = CMTime.zero
    var image: CGImage? { lock.withLock { latest } }
    var failure: Error? { lock.withLock { error } }
    func clear() { lock.withLock { latest = nil; error = nil; suspended = false; earliestFrame = .zero } }
    func suspend() { lock.withLock { suspended = true } }
    func resume() { lock.withLock {
        earliestFrame = CMClockGetTime(CMClockGetHostTimeClock())
        suspended = false
    } }
    func fail(_ error: Error) { lock.withLock { self.error = error } }
    func stream(_ stream: SCStream, didStopWithError error: Error) { fail(error) }
    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, !lock.withLock({ suspended }), sampleBuffer.isValid,
              let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let raw = attachments.first?[.status] as? Int, SCFrameStatus(rawValue: raw) == .complete,
              let buffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let ci = CIImage(cvPixelBuffer: buffer)
        guard let image = context.createCGImage(ci, from: ci.extent, format: .BGRA8,
                                               colorSpace: CGColorSpace(name: CGColorSpace.sRGB)) else { return }
        lock.withLock { if !suspended && CMSampleBufferGetPresentationTimeStamp(sampleBuffer) >= earliestFrame { latest = image } }
    }
}
