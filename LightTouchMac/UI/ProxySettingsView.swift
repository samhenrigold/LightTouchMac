import Cocoa

final class ProxySettingsView: NSView {
    private let enabled = NSButton(checkboxWithTitle: "Use HTTP proxy", target: nil, action: nil)
    private let useDate = NSButton(checkboxWithTitle: "Browse the Internet Archive", target: nil, action: nil)
    private let date = NSDatePicker()
    private let dateFormatter = WebProxyConfiguration.dateFormatter
    private let archiveNote = NSTextField(wrappingLabelWithString: "Uses the closest available capture.")
    private let statusLabel = NSTextField(wrappingLabelWithString: "")
    private let progress = NSProgressIndicator()
    private let statusRow = NSStackView()
    private let stack = NSStackView()
    var onResize: (() -> Void)?

    private let profile: DeviceProfile

    init(configuration: WebProxyConfiguration, status: WebProxyStatus, profile: DeviceProfile) {
        self.profile = profile
        super.init(frame: .zero)
        enabled.state = configuration.mode == .off ? .off : .on
        enabled.target = self
        enabled.action = #selector(selectionChanged(_:))
        useDate.state = configuration.mode == .archive ? .on : .off
        useDate.target = self
        useDate.action = #selector(selectionChanged(_:))
        date.datePickerStyle = .textFieldAndStepper
        date.datePickerElements = .yearMonthDay
        // Archive dates are calendar days, not instants. Use the same local
        // calendar for editing and serialization so AppKit's accessibility
        // value does not describe the previous evening west of Greenwich.
        let calendar = Calendar(identifier: .gregorian)
        dateFormatter.calendar = calendar
        dateFormatter.timeZone = calendar.timeZone
        date.calendar = calendar
        date.timeZone = calendar.timeZone
        date.dateValue = dateFormatter.date(from: configuration.archiveDate) ?? Date()
        date.maxDate = Date()
        date.setAccessibilityLabel("Archive date")

        let dateRow = NSStackView(views: [NSTextField(labelWithString: "Date:"), date])
        dateRow.spacing = 8
        dateRow.alignment = .firstBaseline
        let archive = NSStackView(views: [useDate, dateRow, archiveNote])
        archive.orientation = .vertical
        archive.alignment = .leading
        archive.spacing = 8
        archive.edgeInsets = NSEdgeInsets(top: 0, left: 18, bottom: 0, right: 0)
        archiveNote.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        archiveNote.textColor = .secondaryLabelColor

        progress.style = .spinning
        progress.controlSize = .small
        progress.isIndeterminate = true
        progress.setContentHuggingPriority(.required, for: .horizontal)
        statusLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        statusLabel.textColor = .secondaryLabelColor
        statusRow.addArrangedSubview(progress)
        statusRow.addArrangedSubview(statusLabel)
        statusRow.spacing = 6
        statusRow.alignment = .centerY

        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.addArrangedSubview(enabled)
        stack.addArrangedSubview(archive)
        stack.addArrangedSubview(statusRow)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.widthAnchor.constraint(equalToConstant: 300),
            archiveNote.widthAnchor.constraint(equalToConstant: 282),
            statusLabel.widthAnchor.constraint(lessThanOrEqualToConstant: 276),
        ])
        selectionChanged(nil)
        updateStatus(status)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    @objc private func selectionChanged(_ sender: Any?) {
        useDate.isEnabled = enabled.state == .on
        date.isEnabled = useDate.isEnabled && useDate.state == .on
        archiveNote.isHidden = !date.isEnabled
        resizeToFit()
    }

    func updateStatus(_ status: WebProxyStatus) {
        statusLabel.stringValue = status.message(for: profile) ?? ""
        statusLabel.textColor = status == .failed ? .labelColor : .secondaryLabelColor
        statusRow.isHidden = status.message(for: profile) == nil
        progress.isHidden = !status.isWorking
        if status.isWorking { progress.startAnimation(nil) }
        else { progress.stopAnimation(nil) }
        resizeToFit()
    }

    private func resizeToFit() {
        layoutSubtreeIfNeeded()
        let size = NSSize(width: 300, height: stack.fittingSize.height)
        guard size != frame.size else { return }
        setFrameSize(size)
        onResize?()
    }

    var configuration: WebProxyConfiguration {
        var result = WebProxyConfiguration()
        result.mode = enabled.state == .off ? .off : (useDate.state == .on ? .archive : .direct)
        result.archiveDate = dateFormatter.string(from: date.dateValue)
        return result
    }
}

extension ProxySettingsView {
    /// The editor as a sheet: a title, the choices, then Cancel and OK (the default).
    /// `finish` gets true for OK; the caller ends the sheet.
    static func sheet(_ editor: ProxySettingsView, finish: @escaping (Bool) -> Void) -> NSWindow {
        let title = NSTextField(labelWithString: "Web Proxy")
        title.font = .boldSystemFont(ofSize: NSFont.systemFontSize)
        let cancel = InlineActionButton(title: "Cancel") { finish(false) }
        let ok = InlineActionButton(title: "OK") { finish(true) }
        for button in [cancel, ok] {
            button.controlSize = .regular
            button.widthAnchor.constraint(greaterThanOrEqualToConstant: 80).isActive = true
        }
        cancel.keyEquivalent = "\u{1b}"
        ok.keyEquivalent = "\r"
        let buttons = NSStackView(views: [cancel, ok])
        buttons.spacing = 12
        let stack = NSStackView(views: [title, editor, buttons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 16
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
        stack.setCustomSpacing(20, after: editor)
        buttons.trailingAnchor.constraint(equalTo: stack.trailingAnchor, constant: -20).isActive = true
        let sheet = NSWindow(contentRect: .zero, styleMask: [.titled], backing: .buffered, defer: false)
        sheet.contentView = stack
        let fit = { [weak sheet, weak stack] in
            guard let sheet, let stack else { return }
            stack.layoutSubtreeIfNeeded()
            sheet.setContentSize(stack.fittingSize)
        }
        editor.onResize = fit
        fit()
        return sheet
    }
}

