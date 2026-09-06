import Cocoa

/// Status stays above the app list; existing menu actions own configuration.
@MainActor
final class DeviceStatusView: NSStackView {
    private let state = NSTextField(wrappingLabelWithString: "Starting…")
    private let proxy = NSButton()
    private let agent = NSTextField(labelWithString: "Guest agent: Waiting")
    private let typing = NSButton(checkboxWithTitle: "Keyboard input", target: nil,
                                  action: #selector(MainWindowController.toggleKeyboardInput(_:)))

    override init(frame: NSRect) {
        super.init(frame: frame)
        orientation = .vertical
        alignment = .leading
        setClippingResistancePriority(.defaultLow, for: .horizontal)
        spacing = 4
        edgeInsets = NSEdgeInsets(top: 8, left: 12, bottom: 8, right: 12)
        state.font = .systemFont(ofSize: NSFont.smallSystemFontSize, weight: .semibold)
        state.maximumNumberOfLines = 2
        for (button, symbol, action) in [
            (proxy, "network", #selector(MainWindowController.configureWebProxy(_:)))
        ] {
            button.isBordered = false
            button.alignment = .left
            button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
            button.imagePosition = .imageLeading
            button.action = action
            button.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
            button.cell?.lineBreakMode = .byTruncatingTail
        }
        agent.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        agent.lineBreakMode = .byTruncatingTail
        typing.controlSize = .small
        for row in [state, proxy, agent, typing] {
            addArrangedSubview(row)
            row.translatesAutoresizingMaskIntoConstraints = false
            row.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            row.widthAnchor.constraint(equalTo: widthAnchor, constant: -24).isActive = true
        }
        typing.toolTip = "When enabled, type into the device while its screen has focus. Mac shortcuts remain available."
    }
    required init?(coder: NSCoder) { fatalError("not used") }

    func update(status: String, proxyStatus: String,
                agentStatus: String, keyboardInput: Bool,
                canConfigureProxy: Bool) {
        state.stringValue = status
        state.toolTip = status
        proxy.title = "Proxy: \(proxyStatus)"
        proxy.toolTip = proxy.title
        proxy.setAccessibilityLabel(proxy.title)
        proxy.isEnabled = canConfigureProxy
        agent.stringValue = "Guest agent: \(agentStatus)"
        typing.state = keyboardInput ? .on : .off
    }
}
