import Cocoa
import VisionKit

@MainActor
final class LiveTextWindowController: NSWindowController, ImageAnalysisOverlayViewDelegate {
    private let analyzer = ImageAnalyzer()
    private let overlay = ImageAnalysisOverlayView()
    private var analysisTask: Task<Void, Never>?

    init(image: NSImage) {
        let size = image.size
        let window = NSWindow(contentRect: CGRect(origin: .zero, size: size),
                              styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        window.title = "Live Text — Device Capture"
        window.isReleasedWhenClosed = false
        super.init(window: window)
        let imageView = NSImageView(frame: CGRect(origin: .zero, size: size))
        imageView.image = image
        imageView.imageScaling = .scaleAxesIndependently
        window.contentView = imageView
        overlay.frame = imageView.bounds
        overlay.autoresizingMask = [.width, .height]
        overlay.delegate = self
        overlay.preferredInteractionTypes = [.textSelection, .dataDetectors]
        imageView.addSubview(overlay)
        window.center()
        analysisTask = Task { [weak self] in
            guard let self else { return }
            do {
                let analysis = try await analyzer.analyze(image, orientation: .up,
                                                        configuration: ImageAnalyzer.Configuration([.text]))
                try Task.checkCancellation()
                overlay.analysis = analysis
                overlay.selectableItemsHighlighted = true
                window.makeFirstResponder(overlay)
            } catch {
                if !Task.isCancelled { window.subtitle = "Text recognition unavailable" }
            }
        }
    }
    required init?(coder: NSCoder) { fatalError("not used") }
    override func close() { analysisTask?.cancel(); super.close() }
    func contentsRect(for overlayView: ImageAnalysisOverlayView) -> CGRect {
        CGRect(x: 0, y: 0, width: 1, height: 1)
    }
}
