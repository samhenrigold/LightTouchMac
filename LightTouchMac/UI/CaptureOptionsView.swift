import Cocoa
import UniformTypeIdentifiers

/// Capture-specific choices, shared with the toolbar's Save/Open actions.
final class CaptureOptionsView: NSView {
    private let preferences: CapturePreferences
    private let authorizeNotifications: () async -> Bool
    private let saveLocation = NSPopUpButton(frame: .zero, pullsDown: false)
    private let openInApplication = NSPopUpButton(frame: .zero, pullsDown: false)
    private let spaceBar = NSPopUpButton(frame: .zero, pullsDown: false)
    private let reminder = NSPopUpButton(frame: .zero, pullsDown: false)
    private let reveal = NSButton(checkboxWithTitle: "Show captures in Finder", target: nil, action: nil)
    private let copy = NSButton(checkboxWithTitle: "Copy screenshots to the clipboard", target: nil, action: nil)
    private let sound = NSButton(checkboxWithTitle: "Play sound effects", target: nil, action: nil)
    private let recovery = NSButton(checkboxWithTitle: "Notify when interrupted recordings are recovered", target: nil, action: nil)
    private let notificationSettings = NSButton(title: "Notifications are disabled. Open System Settings…", target: nil, action: nil)
    private let stack = NSStackView()
    private var isChoosing = false
    private var isAuthorizing = false
    var onChange: (() -> Void)?
    var onResize: (() -> Void)?

    init(preferences: CapturePreferences = .shared, profile: DeviceProfile,
         authorizeNotifications: @escaping () async -> Bool = { await CaptureNotifications.shared.requestAuthorization() }) {
        self.preferences = preferences
        self.authorizeNotifications = authorizeNotifications
        super.init(frame: .zero)
        for popup in [saveLocation, openInApplication, spaceBar, reminder] {
            popup.target = self
            popup.widthAnchor.constraint(equalToConstant: 220).isActive = true
            popup.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            popup.cell?.lineBreakMode = .byTruncatingMiddle
        }
        saveLocation.action = #selector(locationChanged(_:))
        saveLocation.setAccessibilityLabel("Save location")
        openInApplication.action = #selector(applicationChanged(_:))
        openInApplication.setAccessibilityLabel("Open in application")
        spaceBar.action = #selector(spaceBarChanged(_:))
        spaceBar.setAccessibilityLabel("Space bar")
        reminder.action = #selector(reminderChanged(_:))
        reminder.setAccessibilityLabel("Recording reminder")
        for choice in CaptureSpaceBarAction.allCases {
            spaceBar.addItem(withTitle: choice.title(for: profile))
            spaceBar.lastItem?.tag = choice.rawValue
        }
        for duration in CaptureReminderDuration.allCases {
            reminder.addItem(withTitle: duration.title)
            reminder.lastItem?.tag = duration.rawValue
        }
        for button in [reveal, copy, sound, recovery] { button.target = self }
        reveal.action = #selector(revealChanged(_:))
        copy.action = #selector(copyChanged(_:))
        sound.action = #selector(soundChanged(_:))
        recovery.action = #selector(recoveryChanged(_:))
        notificationSettings.target = self
        notificationSettings.action = #selector(openNotificationSettings(_:))
        notificationSettings.isBordered = false
        notificationSettings.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        notificationSettings.contentTintColor = .secondaryLabelColor
        notificationSettings.isHidden = true

        let locations = grid([
            [NSTextField(labelWithString: "Save location:"), saveLocation],
            [NSTextField(labelWithString: "“Open in” application:"), openInApplication],
        ])
        let shortcuts = grid([[NSTextField(labelWithString: "Space bar:"), spaceBar]])
        let reminders = grid([[NSTextField(labelWithString: "Remind me if away for:"), reminder]])
        let afterCapture = NSStackView(views: [reveal, copy, sound])
        afterCapture.orientation = .vertical
        afterCapture.alignment = .leading
        afterCapture.spacing = 8
        let notifications = NSStackView(views: [recovery, reminders, notificationSettings])
        notifications.orientation = .vertical
        notifications.alignment = .leading
        notifications.spacing = 10
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 16
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
        for view in [locations, separator(), afterCapture, shortcuts, separator(), notifications] {
            stack.addArrangedSubview(view)
        }
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.widthAnchor.constraint(equalToConstant: 430),
        ])
        reload()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override var fittingSize: NSSize { stack.fittingSize }

    private func grid(_ rows: [[NSView]]) -> NSGridView {
        let grid = NSGridView(views: rows)
        grid.column(at: 0).width = 160
        grid.column(at: 0).xPlacement = .trailing
        grid.columnSpacing = 8
        grid.rowSpacing = 10
        grid.yPlacement = .center
        return grid
    }

    private func separator() -> NSView {
        let line = NSBox()
        line.boxType = .separator
        line.widthAnchor.constraint(equalToConstant: 390).isActive = true
        return line
    }

    func reload() {
        saveLocation.removeAllItems()
        let locations = preferences.saveLocations
        for url in locations {
            var name = FileManager.default.displayName(atPath: url.path)
            if locations.filter({ $0.lastPathComponent == url.lastPathComponent }).count > 1 {
                name += " — " + url.deletingLastPathComponent().lastPathComponent
            }
            addItem(to: saveLocation, title: name, url: url)
        }
        select(preferences.saveLocation, in: saveLocation)
        saveLocation.menu?.addItem(.separator())
        saveLocation.addItem(withTitle: "Other…")

        openInApplication.removeAllItems()
        let preview = CapturePreferences.previewApplicationURL
        var applications = NSWorkspace.shared.urlsForApplications(toOpen: URL(fileURLWithPath: "/Screenshot.png"))
        if let selected = preferences.openInApplicationURL { applications.append(selected) }
        if let preview { applications.append(preview) }
        var seen = Set<String>()
        applications = applications.filter { CapturePreferences.isApplication($0) && seen.insert($0.path).inserted }
            .sorted { CapturePreferences.applicationName($0).localizedStandardCompare(CapturePreferences.applicationName($1)) == .orderedAscending }
        if let preview {
            addItem(to: openInApplication, title: CapturePreferences.applicationName(preview) + " (default)", url: preview)
            applications.removeAll { $0 == preview }
            if !applications.isEmpty { openInApplication.menu?.addItem(.separator()) }
        }
        for url in applications { addItem(to: openInApplication, title: CapturePreferences.applicationName(url), url: url) }
        if let selected = preferences.openInApplicationURL { select(selected, in: openInApplication) }
        openInApplication.menu?.addItem(.separator())
        openInApplication.addItem(withTitle: "Other…")
        reveal.state = preferences.openFinderAfterCapture ? .on : .off
        copy.state = preferences.copyOnCapture ? .on : .off
        sound.state = preferences.soundEffectsEnabled ? .on : .off
        recovery.state = preferences.notifyOnRecordingRecovery ? .on : .off
        spaceBar.selectItem(withTag: preferences.spaceBarAction.rawValue)
        reminder.selectItem(withTag: preferences.reminderAfterDuration)
        resizeToFit()
    }

    private func addItem(to popup: NSPopUpButton, title: String, url: URL) {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.representedObject = url
        item.toolTip = url.path
        let icon = NSWorkspace.shared.icon(forFile: url.path).copy() as! NSImage
        icon.size = NSSize(width: 16, height: 16)
        item.image = icon
        popup.menu?.addItem(item)
    }

    private func select(_ url: URL, in popup: NSPopUpButton) {
        if let item = popup.itemArray.first(where: { ($0.representedObject as? URL)?.standardizedFileURL.path == url.standardizedFileURL.path }) {
            popup.select(item)
        }
    }

    private func changed() { reload(); onChange?() }

    @objc private func locationChanged(_ sender: NSPopUpButton) {
        if let url = sender.selectedItem?.representedObject as? URL {
            preferences.saveLocation = url
            changed()
        } else {
            reload()
            let panel = NSOpenPanel()
            panel.canChooseDirectories = true
            panel.canChooseFiles = false
            panel.canCreateDirectories = true
            panel.directoryURL = preferences.saveLocation
            panel.prompt = "Choose"
            present(panel) { [weak self] url in
                guard let self, let url else { return }
                self.preferences.saveLocation = url
                self.changed()
            }
        }
    }

    @objc private func applicationChanged(_ sender: NSPopUpButton) {
        if let url = sender.selectedItem?.representedObject as? URL {
            preferences.openInApplicationURL = url
            changed()
        } else {
            reload()
            let panel = NSOpenPanel()
            panel.allowedContentTypes = [.application]
            panel.directoryURL = URL(fileURLWithPath: "/Applications", isDirectory: true)
            panel.prompt = "Choose"
            present(panel) { [weak self] url in
                guard let self, let url else { return }
                self.preferences.openInApplicationURL = url
                self.changed()
            }
        }
    }

    private func present(_ panel: NSOpenPanel, completion: @escaping (URL?) -> Void) {
        guard !isChoosing else { return }
        isChoosing = true
        panel.allowsMultipleSelection = false
        let finished: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            self?.isChoosing = false
            completion(response == .OK ? panel.url : nil)
        }
        if let window { panel.beginSheetModal(for: window, completionHandler: finished) }
        else { panel.begin(completionHandler: finished) }
    }

    @objc private func revealChanged(_ sender: NSButton) { preferences.openFinderAfterCapture = sender.state == .on; changed() }
    @objc private func copyChanged(_ sender: NSButton) { preferences.copyOnCapture = sender.state == .on; changed() }
    @objc private func soundChanged(_ sender: NSButton) { preferences.soundEffectsEnabled = sender.state == .on; changed() }
    @objc private func spaceBarChanged(_ sender: NSPopUpButton) {
        preferences.spaceBarAction = CaptureSpaceBarAction(rawValue: sender.selectedTag()) ?? .none
        changed()
    }
    @objc private func recoveryChanged(_ sender: NSButton) {
        guard sender.state == .on else { preferences.notifyOnRecordingRecovery = false; changed(); return }
        requestNotifications { [weak self] allowed in self?.preferences.notifyOnRecordingRecovery = allowed }
    }
    @objc private func reminderChanged(_ sender: NSPopUpButton) {
        let duration = sender.selectedTag()
        guard duration > 0 else { preferences.reminderAfterDuration = 0; changed(); return }
        requestNotifications { [weak self] allowed in self?.preferences.reminderAfterDuration = allowed ? duration : 0 }
    }
    private func requestNotifications(_ completion: @escaping (Bool) -> Void) {
        guard !isAuthorizing else { return }
        isAuthorizing = true
        recovery.isEnabled = false
        reminder.isEnabled = false
        Task { [weak self] in
            guard let self else { return }
            let allowed = await authorizeNotifications()
            completion(allowed)
            notificationSettings.isHidden = allowed
            isAuthorizing = false
            recovery.isEnabled = true
            reminder.isEnabled = true
            changed()
        }
    }
    @objc private func openNotificationSettings(_ sender: Any?) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension") { NSWorkspace.shared.open(url) }
    }
    private func resizeToFit() {
        layoutSubtreeIfNeeded()
        let size = fittingSize
        guard frame.size != size else { return }
        setFrameSize(size)
        onResize?()
    }
}
