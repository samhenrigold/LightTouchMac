import Cocoa

final class BatterySettingsView: NSView {
    private let slider = NSSlider(value: 96, minValue: 0, maxValue: 100, target: nil, action: nil)
    private let capacity = NSLevelIndicator()
    private let valueLabel = NSTextField(labelWithString: "")
    private let chargingMenu = NSPopUpButton(frame: .zero, pullsDown: false)

    private let drainField = NSTextField(string: "0")

    init(level: Int, charging: Int, drain: Double) {
        super.init(frame: .zero)
        slider.integerValue = level
        slider.target = self
        slider.action = #selector(updateCapacity(_:))
        slider.setAccessibilityLabel("Target battery level")
        capacity.levelIndicatorStyle = .continuousCapacity
        capacity.minValue = 0
        capacity.maxValue = 100
        capacity.warningValue = 10
        capacity.criticalValue = 20
        capacity.fillColor = .systemRed
        capacity.warningFillColor = .systemYellow
        capacity.criticalFillColor = .systemGreen
        capacity.isEditable = false
        chargingMenu.addItems(withTitles: ["Automatic (USB)", "Charging", "Not Charging"])
        chargingMenu.selectItem(at: charging)
        let formatter = NumberFormatter()
        formatter.minimum = 0
        formatter.maximum = 100
        formatter.maximumFractionDigits = 2
        drainField.formatter = formatter
        drainField.doubleValue = drain
        drainField.setAccessibilityLabel("Battery drain percent per minute")
        drainField.toolTip = "0 disables drain. Pausing the device or connecting USB power stops drain unless charging is set to Not Charging."
        let ends = NSStackView(views: [NSTextField(labelWithString: "Empty"), NSView(), NSTextField(labelWithString: "Full")])
        ends.orientation = .horizontal
        ends.views[1].setContentHuggingPriority(.defaultLow, for: .horizontal)
        let grid = NSGridView(views: [
            [NSTextField(labelWithString: "Battery"), capacity, valueLabel],
            [NSView(), slider, NSView()],
            [NSView(), ends, NSView()],
            [NSTextField(labelWithString: "Charging"), chargingMenu, NSView()],
            [NSTextField(labelWithString: "Drain"), drainField, NSTextField(labelWithString: "%/min")],
        ])
        grid.column(at: 0).xPlacement = .trailing
        grid.column(at: 0).width = 70
        grid.column(at: 1).xPlacement = .fill
        grid.column(at: 2).width = 48
        grid.column(at: 1).width = 230
        grid.rowSpacing = 8
        updateCapacity(nil)
        grid.frame.size = grid.fittingSize
        frame.size = grid.frame.size
        addSubview(grid)
        updateCapacity(nil)
    }
    required init?(coder: NSCoder) { fatalError("not used") }
    var level: Int { slider.integerValue }
    var charging: Int { chargingMenu.indexOfSelectedItem }
    var drain: Double { drainField.doubleValue }
    @objc private func updateCapacity(_ sender: Any?) {
        capacity.integerValue = level
        valueLabel.stringValue = "\(level)%"
        capacity.setAccessibilityValue(valueLabel.stringValue)
    }
}
