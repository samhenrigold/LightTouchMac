import AppKit
import Testing

@testable import AppViews
@testable import LightTouchCore

extension SharedState {
    /// Small AppKit controls, laid out in windows that are never ordered in.
    @Suite struct AppViewsTests {
        init() {
            _ = NSApplication.shared
            NSApp.setActivationPolicy(.prohibited)
        }

        /// Device ▸ Jailbreak…'s question: Substrate named only where the jailbreak installs it (iOS 3 to 6), Installer.app
        /// in Cydia's place on iPhone OS 1, Jailbreak first. Each is rendered to LTM_RENDER_DIR when it's set.
        @Test func jailbreakAlertNamesWhatItAdds() throws {
            for (version, name, substrate) in [
                ("4.2.1", "iPhone 4 (4.2.1)", true), ("7.1.2", "iPhone 4 (7.1.2)", false),
                ("2.2.1", "iPod touch (2.2.1)", false), ("1.1.4", "iPod touch (1.1.4)", false)
            ] {
                let alert = JailbreakAlert.make(name: name, version: version)
                #expect(alert.messageText == "Jailbreak \(name)?")
                #expect(
                    alert.informativeText
                        == "Adds \(version == "1.1.4" ? "Installer.app" : "Cydia\(substrate ? ", Substrate," : "")") and afc2, which shows the whole file system "
                        + "in Files. Erase All Content and Settings removes them.",
                    "\(version)"
                )
                #expect(alert.buttons.map(\.title) == ["Jailbreak", "Cancel"])
                alert.layout()
                if let out = ProcessInfo.processInfo.environment["LTM_RENDER_DIR"], let view = alert.window.contentView
                {
                    let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
                    view.cacheDisplay(in: view.bounds, to: bitmap)
                    try bitmap.representation(using: .png, properties: [:])?.write(
                        to: URL(fileURLWithPath: out).appendingPathComponent("jailbreak-\(version).png")
                    )
                }
            }
        }

        /// The Apps pane keeps its width (280, 320, 400 pt, held like the inspector's split view) whatever its message
        /// says: the message wraps inside it, the caption truncates, Retry stays under the message.
        @Test func paneMessageKeepsThePaneWidth() {
            let messages = [
                "No apps installed", "Waiting for the device…", "Legacy Store isn’t responding. Try again in a moment.",
                "Couldn’t reach Legacy Store — The Internet connection appears to be offline.",
                "Couldn’t reach Legacy Store — A server with the specified hostname could not be found.",
                "Legacy Store sent a response Light Touch couldn’t read."
            ]
            for width in [280.0, 320.0, 400.0] {
                for text in messages {
                    let window = NSWindow(
                        contentRect: NSRect(x: 0, y: 0, width: width, height: 360),
                        styleMask: [.titled],
                        backing: .buffered,
                        defer: true
                    )
                    window.appearance = NSAppearance(named: .aqua)
                    let pane = NSView()
                    pane.translatesAutoresizingMaskIntoConstraints = false
                    let host = NSView(frame: NSRect(x: 0, y: 0, width: 500, height: 360))
                    window.contentView = host
                    host.addSubview(pane)
                    let message = NSTextField.paneMessage()
                    let caption = NSTextField.paneCaption()
                    let retry = NSButton(title: "Retry", target: nil, action: nil)
                    retry.translatesAutoresizingMaskIntoConstraints = false
                    message.stringValue = text
                    caption.stringValue = text
                    [message, caption, retry].forEach(pane.addSubview)
                    let hold = pane.widthAnchor.constraint(equalToConstant: width)
                    hold.priority = NSLayoutConstraint.Priority(490)  // NSSplitView's holding priority for an inspector
                    NSLayoutConstraint.activate([
                        hold, pane.widthAnchor.constraint(greaterThanOrEqualToConstant: 280),
                        pane.widthAnchor.constraint(lessThanOrEqualToConstant: 400),
                        pane.leadingAnchor.constraint(equalTo: host.leadingAnchor),
                        pane.topAnchor.constraint(equalTo: host.topAnchor),
                        pane.bottomAnchor.constraint(equalTo: host.bottomAnchor),
                        caption.topAnchor.constraint(equalTo: pane.topAnchor, constant: 12),
                        caption.leadingAnchor.constraint(equalTo: pane.leadingAnchor, constant: 8),
                        caption.trailingAnchor.constraint(equalTo: pane.trailingAnchor, constant: -8),
                        message.centerXAnchor.constraint(equalTo: pane.centerXAnchor),
                        message.centerYAnchor.constraint(equalTo: pane.centerYAnchor),
                        message.leadingAnchor.constraint(equalTo: pane.leadingAnchor, constant: 16),
                        message.trailingAnchor.constraint(equalTo: pane.trailingAnchor, constant: -16),
                        retry.topAnchor.constraint(equalTo: message.bottomAnchor, constant: 12),
                        retry.centerXAnchor.constraint(equalTo: pane.centerXAnchor)
                    ])
                    host.layoutSubtreeIfNeeded()
                    let name = "\(Int(width)) “\(text)”"
                    #expect(abs(pane.frame.width - width) <= 0.5, "\(name): the pane went \(pane.frame.width) wide")
                    for label in [message, caption] {
                        #expect(pane.bounds.contains(label.frame), "\(name): \(label.frame) outside the pane")
                    }
                    let needed = message.cell!.cellSize(
                        forBounds: NSRect(x: 0, y: 0, width: message.frame.width, height: 10_000)
                    )
                    #expect(
                        needed.height <= message.frame.height + 0.5 && needed.width <= message.frame.width + 0.5,
                        "\(name): the message needs \(needed), has \(message.frame.size)"
                    )
                    #expect(
                        retry.frame.minY >= 0 && retry.frame.maxY <= message.frame.minY,
                        "\(name): Retry overlaps the message"
                    )
                }
            }
        }

        /// The 40-point horizon draws pitch and roll, says them to accessibility, and its click levels.
        @Test func attitudeIndicator() throws {
            final class Target: NSObject {
                var leveled = false
                @objc func level(_ sender: Any?) { leveled = true }
            }
            let button = AttitudeIndicatorButton(frame: NSRect(x: 0, y: 0, width: 40, height: 40))
            let target = Target()
            button.target = target
            button.action = #selector(Target.level(_:))
            button.performClick(nil)
            #expect(target.leveled)
            func render() -> Data {
                let bitmap = NSBitmapImageRep(
                    bitmapDataPlanes: nil,
                    pixelsWide: 40,
                    pixelsHigh: 40,
                    bitsPerSample: 8,
                    samplesPerPixel: 4,
                    hasAlpha: true,
                    isPlanar: false,
                    colorSpaceName: .deviceRGB,
                    bytesPerRow: 160,
                    bitsPerPixel: 32
                )!
                NSGraphicsContext.saveGraphicsState()
                NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
                button.draw(button.bounds)
                NSGraphicsContext.restoreGraphicsState()
                return Data(bytes: bitmap.bitmapData!, count: 160 * 40)
            }
            let level = render()
            button.update(pitch: .pi / 6, roll: .pi / 6)
            #expect(render() != level)
            #expect((button.accessibilityValue() as? String)?.contains("30°") == true)
        }

        /// The toolbar's record button: the action, the elapsed time sized in, saving progress inside it, the phase labels,
        /// and the idle reset; an unchanged update touches nothing (it runs on every validation).
        @Test func recordingToolbarButton() {
            final class Target: NSObject, NSToolbarDelegate {
                let button = RecordingToolbarButton(target: nil, action: #selector(record(_:)))
                var count = 0
                @objc func record(_ sender: Any?) { count += 1 }
                func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
                    [.init("record")]
                }
                func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
                    toolbarDefaultItemIdentifiers(toolbar)
                }
                func toolbar(
                    _ toolbar: NSToolbar,
                    itemForItemIdentifier id: NSToolbarItem.Identifier,
                    willBeInsertedIntoToolbar flag: Bool
                ) -> NSToolbarItem? {
                    let item = NSToolbarItem(itemIdentifier: id)
                    item.label = "Record"
                    item.view = button
                    return item
                }
            }
            let target = Target()
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 620, height: 420),
                styleMask: [.titled, .resizable],
                backing: .buffered,
                defer: false
            )
            let toolbar = NSToolbar(identifier: "record-check")
            toolbar.delegate = target
            toolbar.displayMode = .iconOnly
            window.toolbar = toolbar
            let button = target.button
            button.target = target
            button.update(.idle, elapsed: "0:00", enabled: true)
            #expect(button.title.isEmpty && button.accessibilityLabel() == "Start Recording" && button.isEnabled)
            let idleWidth = button.intrinsicContentSize.width
            button.performClick(nil)
            #expect(target.count == 1)
            button.update(.recording, elapsed: "1:23:45", enabled: true)
            #expect(button.title == "1:23:45" && button.accessibilityLabel() == "Stop Recording")
            #expect(button.accessibilityValue() as? String == "1:23:45")
            #expect(button.intrinsicContentSize.width > idleWidth)
            window.contentView?.layoutSubtreeIfNeeded()
            #expect(button.frame.width >= button.intrinsicContentSize.width, "Elapsed time clipped")
            button.performClick(nil)
            #expect(target.count == 2)
            button.update(.saving, elapsed: "1:23:45", enabled: false)
            button.layoutSubtreeIfNeeded()
            let spinner = button.subviews.compactMap { $0 as? NSProgressIndicator }.first
            #expect(!button.isEnabled && button.title.isEmpty && button.accessibilityLabel() == "Saving Recording…")
            #expect(
                spinner.map { $0.frame.width > 0 && $0.frame.height > 0 && button.bounds.contains($0.frame) } == true,
                "Saving progress must fit"
            )
            #expect(button.accessibilityValue() == nil)
            button.update(.idle, elapsed: "0:00", enabled: false)
            #expect(button.intrinsicContentSize.width == idleWidth && button.title.isEmpty && !button.isEnabled)
            let image = button.image
            button.update(.idle, elapsed: "0:00", enabled: false)
            #expect(button.image === image, "unchanged update re-made the image")
            button.update(.idle, elapsed: "0:01", enabled: false)
            #expect(button.image === image, "idle ignores the clock")
            button.update(.idle, elapsed: "0:00", enabled: true)
            #expect(button.image !== image && button.isEnabled)
            // Toolbar items: label, tooltip and symbol assigned only on change.
            let item = NSToolbarItem(itemIdentifier: .init("lock"))
            item.show(label: "Lock", toolTip: "Lock (⌘L)", symbol: "lock")
            let lockImage = item.image
            item.show(label: "Lock", toolTip: "Lock (⌘L)", symbol: "lock")
            #expect(item.image === lockImage)
            item.show(label: "Start", toolTip: "Start (⌘L)", symbol: "power")
            #expect(item.image !== lockImage && item.label == "Start" && item.toolTip == "Start (⌘L)")
        }

        /// The zoom item in the toolbar keeps its control while the customization palette shows a zoom item of its own:
        /// each item gets its own segmented control (issue 107).
        @Test func zoomItemKeepsItsControl() {
            final class Target: NSObject, NSToolbarDelegate {
                @objc func zoom(_ sender: Any?) {}
                func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
                    [NSToolbarItem.zoomIdentifier]
                }
                func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
                    toolbarDefaultItemIdentifiers(toolbar)
                }
                func toolbar(
                    _ toolbar: NSToolbar,
                    itemForItemIdentifier id: NSToolbarItem.Identifier,
                    willBeInsertedIntoToolbar flag: Bool
                ) -> NSToolbarItem? { .zoom(target: self, action: #selector(zoom(_:))) }
            }
            let target = Target()
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 620, height: 420),
                styleMask: [.titled, .resizable],
                backing: .buffered,
                defer: false
            )
            let toolbar = NSToolbar(identifier: "zoom-check")
            toolbar.delegate = target
            window.toolbar = toolbar
            let control = toolbar.items.first?.view as? NSSegmentedControl
            #expect(control?.window === window && control?.segmentCount == 3)
            // What the palette does with the item it asks for.
            let palette = target.toolbar(
                toolbar,
                itemForItemIdentifier: NSToolbarItem.zoomIdentifier,
                willBeInsertedIntoToolbar: false
            )
            let paletteView = NSView()
            if let view = palette?.view { paletteView.addSubview(view) }
            #expect(palette?.view !== control && palette?.view is NSSegmentedControl)
            #expect(control?.window === window, "the palette's item took the toolbar's control")
            withExtendedLifetime(window) {}
        }

        /// The Apps inspector's Store and transfer rows at 240-500 pt: icons and labels align, the title stays one line,
        /// the action keeps its width whatever its text, a transfer shows (in)determinate progress beside Cancel. What each
        /// row says is LightTouchCoreTests' AppsInspectorRowsTests.
        @Test func appRows() {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 400, height: 56),
                styleMask: [.titled],
                backing: .buffered,
                defer: false
            )
            enum Row {
                case result(String)
                case progress(Double?)
            }
            for width in [240.0, 320.0, 500.0] {
                for name in ["Facebook", "Doodle Jump — BE WARNED: Insanely Addictive!"] {
                    for row in [Row.result("Install"), .result("Open"), .progress(0.5), .progress(nil)] {
                        let cell: NSTableCellView
                        switch row {
                        case .result(let button):
                            let app = CatalogApp(
                                bundleID: "test",
                                name: name,
                                developer: "Example Developer",
                                version: "1.0",
                                size: 5_000_000,
                                ipaID: 1,
                                downloadURL: URL(string: "https://example.invalid/1")!
                            )
                            cell = AppRowCells.catalogCell(
                                app,
                                icon: nil,
                                button: button,
                                enabled: true,
                                row: 0,
                                target: nil,
                                action: nil
                            )
                        case .progress(let fraction):
                            cell = AppRowCells.progressCell(
                                icon: nil,
                                title: name,
                                subtitle: "Downloading… 50%",
                                fraction: fraction,
                                job: InstallJob(name: name, device: UUID())
                            ) {}
                        }
                        window.contentView = cell
                        window.setContentSize(NSSize(width: width, height: 56))
                        cell.layoutSubtreeIfNeeded()
                        let title = cell.textField!
                        let image = cell.imageView!
                        let subtitle = cell.subviews.compactMap { $0 as? NSTextField }.first { $0 !== title }!
                        #expect(title.maximumNumberOfLines == 1)
                        #expect(abs(title.frame.minX - subtitle.frame.minX) < 0.5)
                        #expect(abs(image.frame.midY - 28) < 0.5 && abs(image.frame.width - 32) < 0.5)
                        let button = cell.subviews.compactMap { $0 as? NSButton }.first!
                        let buttonFrame = button.alignmentRect(forFrame: button.frame)
                        if case .result = row {
                            #expect(abs(buttonFrame.width - 60) < 0.5, "Action width changed with text")
                        } else {
                            #expect(abs(buttonFrame.width - 54) < 0.5, "Action width changed with text")
                        }
                        #expect(
                            title.frame.maxX < buttonFrame.minX && title.frame.minX > image.frame.maxX,
                            "\(width) \(name)"
                        )
                        if case .progress(let fraction) = row {
                            let progress = cell.subviews.compactMap { $0 as? NSProgressIndicator }.first!
                            #expect(
                                !progress.isHidden && !button.isHidden && progress.frame.width == 16,
                                "Progress must remain visible alongside Cancel"
                            )
                            #expect(progress.isIndeterminate == (fraction == nil))
                        }
                    }
                }
            }
        }
    }
}
