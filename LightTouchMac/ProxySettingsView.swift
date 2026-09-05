import Cocoa

final class ProxySettingsView: NSView {
    private let mode = NSPopUpButton(frame: .zero, pullsDown: false)
    private let useDate = NSButton(checkboxWithTitle: "Browse an archived date", target: nil, action: nil)
    private let date = NSDatePicker()

    init(configuration: WebProxyConfiguration, status: String) {
        super.init(frame: .zero)
        mode.addItems(withTitles: ["No Proxy", "HTTP Proxy"])
        mode.selectItem(at: configuration.mode == .off ? 0 : 1)
        mode.target = self; mode.action = #selector(selectionChanged(_:))
        useDate.state = configuration.mode == .archive ? .on : .off
        useDate.target = self; useDate.action = #selector(selectionChanged(_:))
        date.datePickerStyle = .textFieldAndStepper
        date.datePickerElements = .yearMonthDay
        date.calendar = Calendar(identifier: .gregorian)
        date.timeZone = TimeZone(secondsFromGMT: 0)
        date.dateValue = configuration.dateValue
        date.maxDate = Date()
        let grid = NSGridView(views: [
            [NSTextField(labelWithString: "Proxy"), mode],
            [NSTextField(labelWithString: ""), useDate],
            [NSTextField(labelWithString: "Date"), date],
            [NSTextField(labelWithString: "Status"), NSTextField(wrappingLabelWithString: status)]
        ])
        grid.column(at: 0).xPlacement = .trailing
        grid.column(at: 1).width = 250
        grid.rowSpacing = 10
        grid.frame.size = grid.fittingSize
        frame.size = grid.frame.size
        addSubview(grid)
        selectionChanged(nil)
    }
    required init?(coder: NSCoder) { fatalError("not used") }
    @objc private func selectionChanged(_ sender: Any?) {
        useDate.isEnabled = mode.indexOfSelectedItem == 1
        date.isEnabled = useDate.isEnabled && useDate.state == .on
    }
    var configuration: WebProxyConfiguration {
        var result = WebProxyConfiguration()
        result.mode = mode.indexOfSelectedItem == 0 ? .off : (useDate.state == .on ? .archive : .direct)
        result.archiveDate = WebProxyConfiguration.dateFormatter.string(from: date.dateValue)
        return result
    }
}
