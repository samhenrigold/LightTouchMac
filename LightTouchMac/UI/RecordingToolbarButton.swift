import Cocoa

/// WireView's single recording action: record, elapsed time and stop, then progress.
final class RecordingToolbarButton: NSButton {
    enum Phase { case idle, recording, saving, recovery }
    private let progress = NSProgressIndicator()

    init(target: AnyObject?, action: Selector) {
        super.init(frame: .zero)
        self.target = target
        self.action = action
        bezelStyle = .texturedRounded
        imagePosition = .imageLeading
        font = .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        progress.style = .spinning
        progress.controlSize = .small
        progress.isDisplayedWhenStopped = false
        progress.translatesAutoresizingMaskIntoConstraints = false
        addSubview(progress)
        NSLayoutConstraint.activate([
            progress.centerXAnchor.constraint(equalTo: centerXAnchor),
            progress.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        update(.idle, elapsed: "0:00", enabled: false)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func update(_ phase: Phase, elapsed: String, enabled: Bool) {
        let label: String
        let symbol: String
        switch phase {
        case .idle: label = "Start Recording"; symbol = "record.circle"
        case .recording: label = "Stop Recording"; symbol = "stop.circle.fill"
        case .saving: label = "Saving Recording…"; symbol = "record.circle"
        case .recovery: label = "Save Recording As…"; symbol = "exclamationmark.circle"
        }
        title = phase == .recording ? elapsed : ""
        image = phase == .saving ? NSImage(size: NSSize(width: 18, height: 18))
            : NSImage(systemSymbolName: symbol, accessibilityDescription: label)
        contentTintColor = nil
        setAccessibilityLabel(label)
        setAccessibilityValue(phase == .recording ? elapsed : nil)
        toolTip = phase == .saving ? label : "\(label) (⌘R)"
        isEnabled = enabled
        if phase == .saving { progress.startAnimation(nil) }
        else { progress.stopAnimation(nil) }
        invalidateIntrinsicContentSize()
        sizeToFit()
    }
}
