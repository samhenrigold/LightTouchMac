import Cocoa

final class SettingsWindowController: NSWindowController, NSTextFieldDelegate {
    private let emulator: EmulatorController
    private let rotate = NSButton(checkboxWithTitle: "Rotate with the device", target: nil, action: nil)
    private let tilt = NSPopUpButton(frame: .zero, pullsDown: false)
    private let catalog = NSTextField(string: "")
    private let controllerEnabled = NSButton(checkboxWithTitle: "Use game controller", target: nil, action: nil)
    private let curve = NSPopUpButton(frame: .zero, pullsDown: false)
    private let tapX = NSTextField(string: "50")
    private let tapY = NSTextField(string: "50")
    private let error = NSTextField(wrappingLabelWithString: "")

    init(emulator: EmulatorController) {
        self.emulator = emulator
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 490, height: 370),
            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        super.init(window: window)
        window.title = "Light Touch Settings"
        window.isReleasedWhenClosed = false
        window.setFrameAutosaveName("Settings")
        rotate.target = self; rotate.action = #selector(changeRotation(_:))
        tilt.addItems(withTitles: ["Slow (45°/s)", "Normal (90°/s)", "Fast (180°/s)"])
        tilt.target = self; tilt.action = #selector(changeTilt(_:))
        tilt.setAccessibilityLabel("Keyboard tilt speed")
        catalog.delegate = self
        catalog.setAccessibilityLabel("Catalog URL")
        error.textColor = .systemRed
        error.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        let hint = NSTextField(wrappingLabelWithString: "Hold Option and use the arrow keys to tilt. Option–Space shakes the device.")
        hint.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        hint.textColor = .secondaryLabelColor
        controllerEnabled.target = self; controllerEnabled.action = #selector(changeController(_:))
        curve.addItems(withTitles: ["Linear", "Gentle near center"])
        curve.target = self; curve.action = #selector(changeController(_:))
        curve.setAccessibilityLabel("Controller stick response")
        for (field, label) in [(tapX, "Controller tap horizontal percent"), (tapY, "Controller tap vertical percent")] {
            let formatter = NumberFormatter(); formatter.minimum = 0; formatter.maximum = 100
            formatter.maximumFractionDigits = 1
            field.formatter = formatter; field.delegate = self
            field.setAccessibilityLabel(label)
            field.widthAnchor.constraint(equalToConstant: 55).isActive = true
        }
        let point = NSStackView(views: [NSTextField(labelWithString: "X:"), tapX, NSTextField(labelWithString: "%  Y:"), tapY, NSTextField(labelWithString: "%")])
        let controllerHint = NSTextField(wrappingLabelWithString: "Left stick tilts up to 45°. A holds the chosen screen point (from top left). Menu is Home; Options shakes.")
        controllerHint.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        controllerHint.textColor = .secondaryLabelColor
        let grid = NSGridView(views: [
            [NSView(), rotate],
            [NSTextField(labelWithString: "Keyboard tilt:"), tilt],
            [NSView(), hint],
            [NSTextField(labelWithString: "Catalog URL:"), catalog],
            [NSView(), error],
            [NSView(), controllerEnabled],
            [NSTextField(labelWithString: "Stick response:"), curve],
            [NSTextField(labelWithString: "A button tap:"), point],
            [NSView(), controllerHint],
        ])
        grid.column(at: 0).xPlacement = .trailing
        grid.column(at: 1).xPlacement = .fill
        grid.column(at: 1).width = 330
        grid.rowSpacing = 12
        grid.translatesAutoresizingMaskIntoConstraints = false
        window.contentView!.addSubview(grid)
        NSLayoutConstraint.activate([
            grid.leadingAnchor.constraint(equalTo: window.contentView!.leadingAnchor, constant: 20),
            grid.trailingAnchor.constraint(equalTo: window.contentView!.trailingAnchor, constant: -20),
            grid.topAnchor.constraint(equalTo: window.contentView!.topAnchor, constant: 20),
        ])
        window.center()
    }
    required init?(coder: NSCoder) { fatalError("not used") }

    override func showWindow(_ sender: Any?) {
        rotate.state = EmulatorController.autoRotateEnabled ? .on : .off
        tilt.selectItem(at: [45.0, 90, 180].firstIndex(of: emulator.keyboardTiltRate) ?? 1)
        catalog.stringValue = CatalogClient.baseURL.absoluteString
        error.stringValue = ""
        controllerEnabled.state = GameControllerInput.enabled ? .on : .off
        curve.selectItem(at: GameControllerInput.curve == 2 ? 1 : 0)
        tapX.doubleValue = GameControllerInput.coordinate("controllerTapX") * 100
        tapY.doubleValue = GameControllerInput.coordinate("controllerTapY") * 100
        super.showWindow(sender)
        window?.makeKeyAndOrderFront(sender)
    }
    @objc private func changeRotation(_ sender: Any?) {
        UserDefaults.standard.set(rotate.state == .on, forKey: EmulatorController.autoRotateDefaultsKey)
    }
    @objc private func changeTilt(_ sender: Any?) {
        guard (0..<3).contains(tilt.indexOfSelectedItem) else { return }
        emulator.setKeyboardTiltRate([45.0, 90, 180][tilt.indexOfSelectedItem])
    }
    @objc private func changeController(_ sender: Any?) {
        UserDefaults.standard.set(controllerEnabled.state == .on, forKey: "controllerEnabled")
        UserDefaults.standard.set(curve.indexOfSelectedItem == 1 ? 2 : 1, forKey: "controllerCurve")
    }
    func controlTextDidEndEditing(_ notification: Notification) {
        if let field = notification.object as? NSTextField, field === tapX || field === tapY {
            let value = field.doubleValue
            guard value.isFinite && (0...100).contains(value) else { return }
            UserDefaults.standard.set(value / 100, forKey: field === tapX ? "controllerTapX" : "controllerTapY")
            return
        }
        let text = catalog.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.isEmpty || Self.catalogURL(text) != nil else {
            error.stringValue = "Enter an HTTP or HTTPS URL without a username or password."
            return
        }
        if text.isEmpty { UserDefaults.standard.removeObject(forKey: "LTMCatalogBaseURL") }
        else { UserDefaults.standard.set(text, forKey: "LTMCatalogBaseURL") }
        catalog.stringValue = CatalogClient.baseURL.absoluteString
        error.stringValue = ""
    }
    static func catalogURL(_ text: String) -> URL? {
        guard let parts = URLComponents(string: text),
              ["http", "https"].contains(parts.scheme?.lowercased() ?? ""),
              let host = parts.host, !host.isEmpty, parts.user == nil, parts.password == nil,
              parts.query == nil, parts.fragment == nil,
              parts.port.map({ (1...65535).contains($0) }) ?? true else { return nil }
        return parts.url
    }
}
