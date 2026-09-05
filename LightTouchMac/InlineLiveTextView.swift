import Cocoa
import VisionKit

/// A freeze frame stays in the device's LCD cutout while VisionKit handles
/// selection. Unhandled clicks cannot reach the still-running guest behind it.
@MainActor
final class InlineLiveTextView: NSView, ImageAnalysisOverlayViewDelegate {
    private let imageView = NSImageView()
    private let overlay = ImageAnalysisOverlayView()
    private let analyzer = ImageAnalyzer()
    private let doneButton = NSButton(title: "Done", target: nil, action: nil)
    private let statusLabel = NSTextField(labelWithString: "Recognizing text…")
    private var analysisTask: Task<Void, Never>?
    var onClose: (() -> Void)?
    let capturedImage: CGImage
    override var isFlipped: Bool { true }

    init(image: CGImage) {
        capturedImage = image
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        layer?.zPosition = 100
        imageView.image = NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
        imageView.imageScaling = .scaleAxesIndependently
        addSubview(imageView)
        overlay.delegate = self
        overlay.preferredInteractionTypes = [.textSelection, .dataDetectors]
        addSubview(overlay)
        doneButton.target = self
        doneButton.action = #selector(done(_:))
        doneButton.bezelStyle = .rounded
        doneButton.keyEquivalent = "\u{1b}"
        doneButton.wantsLayer = true
        doneButton.layer?.zPosition = 200
        addSubview(doneButton)
        statusLabel.textColor = .white
        statusLabel.backgroundColor = .black
        statusLabel.drawsBackground = true
        statusLabel.font = .systemFont(ofSize: 11)
        statusLabel.wantsLayer = true
        statusLabel.layer?.zPosition = 200
        addSubview(statusLabel)
        analysisTask = Task { [weak self] in
            guard let self else { return }
            do {
                let analysis = try await analyzer.analyze(imageView.image!, orientation: .up,
                                                        configuration: ImageAnalyzer.Configuration([.text]))
                try Task.checkCancellation()
                overlay.analysis = analysis
                overlay.selectableItemsHighlighted = true
                statusLabel.isHidden = true
                window?.makeFirstResponder(overlay)
            } catch {
                if !Task.isCancelled { statusLabel.stringValue = "Text recognition unavailable"; needsLayout = true }
            }
        }
    }
    required init?(coder: NSCoder) { fatalError("not used") }
    override func layout() {
        super.layout()
        imageView.frame = bounds
        overlay.frame = bounds
        doneButton.sizeToFit()
        doneButton.frame.origin = CGPoint(x: bounds.width - doneButton.frame.width - 6, y: 5)
        statusLabel.sizeToFit()
        statusLabel.frame.origin = CGPoint(x: 6, y: bounds.height - statusLabel.frame.height - 6)
    }
    func stop() { analysisTask?.cancel(); removeFromSuperview() }
    @objc private func done(_ sender: Any?) { onClose?() }
    override func mouseDown(with event: NSEvent) {}
    override func mouseDragged(with event: NSEvent) {}
    override func mouseUp(with event: NSEvent) {}
    override func scrollWheel(with event: NSEvent) {}
    override func magnify(with event: NSEvent) {}
    override func rotate(with event: NSEvent) {}
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { onClose?() } else { super.keyDown(with: event) }
    }
    func contentsRect(for overlayView: ImageAnalysisOverlayView) -> CGRect {
        CGRect(x: 0, y: 0, width: 1, height: 1)
    }
}
