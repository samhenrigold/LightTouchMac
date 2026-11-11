import AppKit
import HostRuntime
import ObjectiveC
import SwiftUI
import Testing

@testable import AppViews
@testable import LightTouchCore

extension SharedState {
    /// Sheets, panels and windows of the app, laid out offscreen (never ordered in).
    @Suite(.serialized) struct AppWindowsTests {
        init() {
            _ = NSApplication.shared
            NSApp.setActivationPolicy(.prohibited)
        }

        static func descendants(_ view: NSView) -> [NSView] {
            var children = view.subviews
            if let stack = view as? NSStackView {
                for child in stack.arrangedSubviews where !children.contains(where: { $0 === child }) {
                    children.append(child)
                }
            }
            return [view] + children.flatMap(descendants)
        }

        /// Settings ▸ Storage (state audit C-11, B-17): measured again when its pane is shown, and while it is shown
        /// when the sessions change, so Delete is asked again after a device starts; every record has its own Delete,
        /// also one whose entry left the catalog and an older record a newer one for the same entry hides in the sidebar.
        @Test func storageSettings() async throws {
            let library = DeviceLibrary.shared
            func record(_ firmware: String) throws -> DeviceInstance {
                let id = UUID()
                let prefix = "Devices/\(id.uuidString)"
                let instance = DeviceInstance(
                    id: id,
                    name: firmware,
                    board: "n72ap",
                    firmware: firmware,
                    created: DeviceInstance.now,
                    base: .init(kind: .prepared, path: prefix + "/base"),
                    storage: .init(
                        key: "fixture",
                        overlay: prefix + "/overlay",
                        snapshot: prefix + "/snapshot",
                        usbmuxConf: prefix + "/usbmuxd-conf"
                    )
                )
                try instance.write(state: library.state)
                return instance
            }
            func until(_ condition: () -> Bool) async {
                let deadline = Date().addingTimeInterval(10)
                while !condition(), Date() < deadline { try? await Task.sleep(for: .milliseconds(20)) }
            }
            var asked: Set<UUID> = []
            let catalog = try FirmwareCatalog.load(
                from: URL(fileURLWithPath: #filePath).deletingLastPathComponent()
                    .appendingPathComponent("../../../../LightTouchMac/Resources/firmware-catalog.json")
                    .standardizedFileURL
            )
            let scratch = FileManager.default.temporaryDirectory.appendingPathComponent(
                "ltm-storage-\(UUID().uuidString)"
            )
            defer { try? FileManager.default.removeItem(at: scratch) }
            let jobs = FirmwareJobs(
                catalog: catalog,
                configuration: .ephemeral,
                state: scratch,
                logs: scratch,
                caches: scratch,
                preparer: nil,
                resources: nil,
                sweep: false
            ) { _ in }
            let usage = StorageUsage(
                catalog: catalog,
                jobs: jobs,
                delete: { _ in },
                canDelete: {
                    asked.insert($0.id)
                    return true
                }
            )
            let settings = SettingsWindowController(general: EmptyView(), capture: EmptyView(), storage: usage)
            settings.pane = .general
            await until { usage.usage.devices.isEmpty }
            let records = try [record("n72ap-0A000"), record("n72ap-7E18"), record("n72ap-7E18")]
            defer {
                for r in records {
                    try? FileManager.default.removeItem(at: DeviceInstance.directory(r.id, state: library.state))
                }
                library.reload()
            }
            library.reload()
            try await Task.sleep(for: .milliseconds(300))
            #expect(usage.usage.devices.isEmpty, "not measured while another pane is shown")
            settings.pane = .storage
            await until { usage.usage.devices.count == 3 }
            #expect(Set(usage.usage.devices.map(\.instance.id)) == Set(records.map(\.id)), "measured when shown")
            let pane = settings.view(for: .storage)
            pane.frame = NSRect(x: 0, y: 0, width: 500, height: 560)
            pane.layoutSubtreeIfNeeded()
            #expect(asked == Set(records.map(\.id)), "each record asks for its own Delete")

            var heard = 0
            usage.isShown = {
                heard += 1
                return true
            }
            NotificationCenter.default.post(name: DeviceSessionHost.didChangeNotification, object: nil)
            #expect(heard == 1, "a device started or stopped: measured, and Delete asked, again")
        }

        /// AppKit sizes Settings to the selected pane (each hosting controller's preferredContentSize): a switch takes the
        /// window to that pane's height, and Storage stops at 560 pt and scrolls.
        @Test func settingsTakesEachPanesHeight() async throws {
            func rows(_ count: Int) -> some View { Form { ForEach(0..<count, id: \.self) { Text("Row \($0)") } } }
            let catalog = try FirmwareCatalog.load(
                from: URL(fileURLWithPath: #filePath).deletingLastPathComponent()
                    .appendingPathComponent("../../../../LightTouchMac/Resources/firmware-catalog.json")
                    .standardizedFileURL
            )
            let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("ltm-settings-\(UUID())")
            defer { try? FileManager.default.removeItem(at: scratch) }
            let jobs = FirmwareJobs(
                catalog: catalog,
                configuration: .ephemeral,
                state: scratch,
                logs: scratch,
                caches: scratch,
                preparer: nil,
                resources: nil,
                sweep: false
            ) { _ in }
            var usage = StorageUsage.Usage(measured: true)
            usage.ipsws = (0..<40).map { ("n72ap-7E18", URL(fileURLWithPath: "/ipsw/\($0).ipsw"), 1 << 30, nil) }
            let settings = SettingsWindowController(
                general: rows(2),
                capture: rows(12),
                storage: StorageUsage(preview: usage, catalog: catalog, jobs: jobs)
            )
            defer { UserDefaults.standard.removeObject(forKey: "NSWindow Frame Settings") }
            let window = settings.window!
            func height() -> CGFloat { window.contentRect(forFrameRect: window.frame).height }
            func settled(_ pane: SettingsWindowController.Pane) async -> CGFloat {
                settings.pane = pane
                try? await Task.sleep(for: .milliseconds(300))
                return height()
            }
            let general = await settled(.general)
            let capture = await settled(.capture)
            let storage = await settled(.storage)
            #expect(general < capture && capture < 560, "general \(general), capture \(capture)")
            #expect(storage == 560, "storage \(storage)")
            #expect(await settled(.general) == general, "back to general")
        }

        /// Windows opt out of state restoration (no restoration class, no autosave) unless named; a named window keeps
        /// only its frame: the first has nothing to apply, a later one with the same name opens where it was left.
        /// LightTouchApplication's own restoration overrides need their own app process and aren't checked here;
        /// RestorationDefaultsTests has the process-only defaults.
        @Test func windowRestorationPolicy() {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 320, height: 240),
                styleMask: [.titled, .closable],
                backing: .buffered,
                defer: false
            )
            window.isRestorable = true
            WindowRestorationPolicy.configure(window)
            #expect(!window.isRestorable && window.restorationClass == nil && window.frameAutosaveName.isEmpty)
            let name = "ltm-frame-test-" + UUID().uuidString
            defer { UserDefaults.standard.removeObject(forKey: "NSWindow Frame " + name) }
            let first = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 320, height: 240),
                styleMask: [.titled, .resizable],
                backing: .buffered,
                defer: false
            )
            #expect(
                !WindowRestorationPolicy.configure(first, frameAutosaveName: name) && first.frameAutosaveName == name
                    && !first.isRestorable
            )
            let moved = NSRect(x: 123, y: 77, width: 500, height: 410)
            first.setFrame(moved, display: false)
            first.saveFrame(usingName: name)
            let second = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 320, height: 240),
                styleMask: [.titled, .resizable],
                backing: .buffered,
                defer: false
            )
            #expect(
                WindowRestorationPolicy.configure(second, frameAutosaveName: name) && second.frame.size == moved.size,
                "saved frame not applied: \(second.frame)"
            )
        }

        /// The Debug Port sheet lays out at a real size with its commands. The menu items and the sheet's text are
        /// LightTouchCoreTests' DeviceSettingsMenuTests.
        @Test func debugPortSheet() {
            let lldb = "lldb -o 'process connect unix-connect:///var/folders/xx/T/ltm-gdb-0a1b2c3d.sock' KERNELCACHE"
            let sheet = NSHostingView(
                rootView: DebugPortView(
                    shortName: "iPod",
                    socket: "/var/folders/xx/T/ltm-gdb-0a1b2c3d.sock",
                    lldbWithSymbols: lldb,
                    enabled: true,
                    onToggle: {},
                    onDone: {}
                )
            )
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 520, height: 400),
                styleMask: [.titled],
                backing: .buffered,
                defer: true
            )
            window.contentView = sheet
            sheet.setFrameSize(sheet.fittingSize)
            sheet.layoutSubtreeIfNeeded()
            #expect(
                sheet.fittingSize.width >= 500 && sheet.fittingSize.height > 250,
                "debug port sheet \(sheet.fittingSize)"
            )
        }

        /// The Help window over the bundled Help.txt: its topics in a sidebar, the chosen topic's text, [Device] renamed
        /// keeping the topic, scrolling and Find. The topics and the text's audit are HelpTopicTests'.
        @Test func helpWindow() throws {
            let whole = try String(
                contentsOf: URL(fileURLWithPath: #filePath).deletingLastPathComponent()
                    .appendingPathComponent("../../../../LightTouchMac/Help.txt").standardizedFileURL,
                encoding: .utf8
            )
            let help = HelpWindowController(text: whole)
            let window = help.window!
            help.show(deviceName: "iPad")
            let topics = HelpTopic.topics(whole)
            let titles = topics.map(\.title)
            let list = try #require(Self.descendants(window.contentView!).compactMap { $0 as? NSTableView }.first)
            let text = help.text
            #expect(list.numberOfRows == topics.count && list.selectedRow == 0)
            #expect(!text.isEditable && text.isSelectable && text.usesFindBar)
            func show(_ title: String) -> String {
                list.selectRowIndexes([titles.firstIndex(of: title)!], byExtendingSelection: false)
                return text.string
            }
            let capture = show("Screenshots and recordings")
            #expect(
                capture.hasPrefix("Screenshots and recordings\n") && capture.contains("Recordings include device audio")
                    && !capture.contains("Physical Size")
            )
            let files = show("Device files")
            #expect(
                files.contains("Show iPad Files") && files.contains("Copy to iPad") && !files.contains("[Device]"),
                "\(files)"
            )
            help.show(deviceName: "iPod")
            #expect(
                text.string.contains("Show iPod Files") && list.selectedRow == titles.firstIndex(of: "Device files"),
                "a new name keeps the topic"
            )
            window.setContentSize(NSSize(width: 560, height: 300))
            window.contentView!.layoutSubtreeIfNeeded()
            _ = show("Screenshots and recordings")
            text.layoutManager!.ensureLayout(for: text.textContainer!)
            text.sizeToFit()
            let scroll = text.enclosingScrollView!
            #expect(
                scroll.hasVerticalScroller && text.frame.height > scroll.contentSize.height
                    && text.textContainer!.widthTracksTextView
            )
            #expect(!window.isVisible)
            window.close()
        }

        /// The Tweaks panel for a stopped 6.1.6 iPhone and a 3.1.3 iPod: every section and switch is there; a switch the
        /// firmware can't take is disabled, never left out; one that's on shows its options. Renders light and dark into
        /// LTM_RENDER_DIR when it's set.
        @Test func tweaksPanel() throws {
            let dir = FileManager.default.temporaryDirectory.appendingPathComponent("tweaks-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: dir) }
            do {
                func render(_ version: String, on: Set<Tweak>, name: String) throws -> NSHostingView<TweaksPanel> {
                    try FileManager.default.createDirectory(
                        at: dir.appendingPathComponent(name),
                        withIntermediateDirectories: true
                    )
                    let tweaks = DeviceTweaks(
                        settings: DeviceSettingsFile(directory: dir.appendingPathComponent(name)),
                        version: version,
                        guestTools: true,
                        clockPinned: false
                    )
                    tweaks.change { $0.on = on }
                    let model = TweaksPanelModel(tweaks: tweaks, guest: nil)
                    model.fingerDots = (get: { true }, set: { _ in })
                    let hosting = NSHostingView(rootView: TweaksPanel(model: model))
                    for (appearance, suffix) in [(NSAppearance.Name.aqua, "light"), (.darkAqua, "dark")] {
                        let window = NSWindow(
                            contentRect: NSRect(x: 0, y: 0, width: 420, height: 1500),
                            styleMask: [.titled],
                            backing: .buffered,
                            defer: true
                        )
                        window.isReleasedWhenClosed = false
                        window.appearance = NSAppearance(named: appearance)
                        window.contentView = hosting
                        for _ in 0..<5 {
                            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
                            hosting.layoutSubtreeIfNeeded()
                        }
                        if let out = ProcessInfo.processInfo.environment["LTM_RENDER_DIR"] {
                            let bitmap = try #require(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
                            hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
                            try bitmap.representation(using: .png, properties: [:])?.write(
                                to: URL(fileURLWithPath: out).appendingPathComponent("tweaks-\(name)-\(suffix).png")
                            )
                        }
                        window.contentView = nil
                        window.close()
                    }
                    return hosting
                }
                let phone = try render(
                    "6.1.6",
                    on: [.signalNumbers, .cleanStatusBar, .slowAnimations, .timeMachine],
                    name: "616"
                )
                let pod = try render("3.1.3", on: [.keynoteClock, .cleanStatusBar, .coreAnimationColors], name: "313")
                #expect(phone.fittingSize.height > pod.fittingSize.height / 2 && pod.fittingSize.height > 400)
                // The model decides what is dimmed and why; the view shows it (TweaksTests has the rules).
                let model = TweaksPanelModel(
                    tweaks: DeviceTweaks(
                        settings: DeviceSettingsFile(directory: dir.appendingPathComponent("616")),
                        version: "6.1.6",
                        guestTools: true,
                        clockPinned: false
                    ),
                    guest: nil
                )
                #expect(
                    !model.isAvailable(.emojiEverywhere) && !model.isAvailable(.keynoteClock)
                )
                #expect(model.isOn(.signalNumbers) && !model.isRunning)
            }
        }

        /// The Carrier panel against a fake modem: Applying… with a spinner until the modem reports the new carrier and
        /// PLMN, not before or after; the SMS field is multiline. The model's rules are CarrierPanelModelTests'.
        @Test func carrierPanel() async throws {
            final class Modem: CarrierBackend {
                var carrierSettings = CarrierSettings()
                var reported = CarrierSettings()
                func setCarrierSettings(_ settings: CarrierSettings) -> Bool {
                    carrierSettings = settings
                    return true
                }
                func modem(_ property: String, _ value: String, done: @escaping @MainActor (Bool) -> Void) {
                    done(true)
                }
                func modemStatus(_ done: @escaping @MainActor (ModemStatus?) -> Void) {
                    done(
                        ModemStatus(
                            json:
                                #"{"carrier": "\#(reported.carrier)", "mcc-mnc": "\#(reported.mccMNC)", "registered": true, "sim-present": true}"#
                        )
                    )
                }
            }
            let modem = Modem()
            let model = CarrierPanelModel(backend: modem)
            let hosting = NSHostingView(rootView: CarrierPanel(model: model))
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 380, height: 760),
                styleMask: [.titled],
                backing: .buffered,
                defer: true
            )
            window.appearance = NSAppearance(named: .aqua)
            window.contentView = hosting
            func settle() {
                for _ in 0..<5 {
                    RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
                    hosting.layoutSubtreeIfNeeded()
                }
            }
            model.poll()
            #expect(!model.applyingNetwork, "applying before any change")
            model.carrierName = "Fictional"
            model.applyNetwork()
            model.poll()
            #expect(model.applyingNetwork, "no progress while the modem still reports the old carrier")
            settle()
            #expect(Self.descendants(hosting).contains { $0 is NSProgressIndicator }, "no spinner while applying")
            modem.reported = modem.carrierSettings
            model.poll()
            #expect(!model.applyingNetwork, "still applying once the modem reports it")
            func messageField() -> NSView? {
                Self.descendants(hosting).first {
                    ($0 as? NSTextField)?.stringValue == model.smsText || ($0 as? NSTextView)?.string == model.smsText
                }
            }
            model.smsText = "x"
            settle()
            let one = messageField()?.frame.height
            model.smsText = (1...5).map { "line \($0)" }.joined(separator: "\n")
            settle()
            let five = messageField()?.frame.height
            #expect(
                one.map { $0 >= 40 } == true && five.map { $0 > one! + 10 } == true,
                "the message field isn't multiline: \(String(describing: one)) -> \(String(describing: five))"
            )
        }

        /// The web proxy sheet: Cancel and OK (the default), the choices enabling each other, the archive date kept in the
        /// local calendar day (west and east of UTC, across a DST change) and the transient status fitting the 300-pt
        /// panel. The per-device proxy files are WebProxyConfigurationTests'.
        @Test(arguments: ["America/New_York", "America/Los_Angeles", "Asia/Tokyo"]) func proxySheet(zone: String) throws
        {
            let saved = NSTimeZone.default
            NSTimeZone.default = TimeZone(identifier: zone)!
            defer { NSTimeZone.default = saved }
            for mode in [WebProxyConfiguration.Mode.off, .direct, .archive] {
                let initial = WebProxyConfiguration(mode: mode, archiveDate: "20090909")
                let panel = ProxySettingsView(configuration: initial, status: .ready, profile: .n72)
                var answers: [Bool] = []
                let sheet = ProxySettingsView.sheet(panel) { answers.append($0) }
                let sheetButtons = Self.descendants(sheet.contentView!).compactMap { $0 as? NSButton }.filter {
                    $0.title == "OK" || $0.title == "Cancel"
                }
                try #require(sheetButtons.map(\.title) == ["Cancel", "OK"])
                #expect(sheetButtons[1].keyEquivalent == "\r" && sheetButtons[0].keyEquivalent == "\u{1b}")
                sheetButtons[0].performClick(nil)
                sheetButtons[1].performClick(nil)
                #expect(answers == [false, true])
                #expect(panel.configuration == initial)
                let all = Self.descendants(panel)
                let buttons = all.compactMap { $0 as? NSButton }
                let enabled = try #require(buttons.first { $0.title == "Use HTTP proxy" })
                let archive = try #require(buttons.first { $0.title == "Browse the Internet Archive" })
                let date = try #require(all.compactMap { $0 as? NSDatePicker }.first)
                let components = Calendar.current.dateComponents([.year, .month, .day, .hour], from: date.dateValue)
                #expect(
                    components.year == 2009 && components.month == 9 && components.day == 9 && components.hour == 0,
                    "archive date shifted in \(zone): \(date.stringValue)"
                )
                #expect(archive.isEnabled == (mode != .off))
                #expect(date.isEnabled == (mode == .archive))
                let readyHeight = panel.frame.height
                for status in [WebProxyStatus.waiting, .applying, .failed, .ready] {
                    panel.updateStatus(status)
                    panel.layoutSubtreeIfNeeded()
                    let visible = Self.descendants(panel).filter { !$0.isHiddenOrHasHiddenAncestor }
                    let labels = visible.compactMap { ($0 as? NSTextField)?.stringValue }
                    if let message = status.message(for: .n72) {
                        #expect(labels.contains(message), "\(labels)")
                    } else {
                        #expect(!labels.contains(where: { $0.contains("proxy…") || $0.contains("Try again") }))
                    }
                    #expect(panel.frame.height >= readyHeight)
                    #expect(panel.frame.width == 300)
                    #expect(
                        sheet.contentView!.frame.height >= panel.frame.height + 60,
                        "the sheet grows with its panel"
                    )
                    for view in visible where view is NSControl {
                        let rect = view.convert(view.bounds, to: panel)
                        #expect(
                            rect.minX >= -3 && rect.maxX <= panel.bounds.width + 3,
                            "horizontal overflow: \(view) \(rect)"
                        )
                        #expect(
                            rect.minY >= -3 && rect.maxY <= panel.bounds.height + 3,
                            "vertical overflow: \(view) \(rect), height \(panel.bounds.height)"
                        )
                    }
                }
                if enabled.state == .off { enabled.performClick(nil) }
                #expect(archive.isEnabled)
                if archive.state == .off { archive.performClick(nil) }
                #expect(date.isEnabled && panel.configuration.mode == .archive)
                #expect(panel.configuration.archiveDate == "20090909")
                enabled.performClick(nil)
                #expect(panel.configuration.mode == .off && !date.isEnabled)
                enabled.performClick(nil)  // turning the proxy off keeps the archive date for next time
                #expect(panel.configuration.mode == .archive)
                let calendar = date.calendar!
                date.dateValue = calendar.date(from: DateComponents(year: 2009, month: 11, day: 1))!
                #expect(panel.configuration.archiveDate == "20091101")
                date.dateValue = calendar.date(byAdding: .day, value: 1, to: date.dateValue)!
                #expect(panel.configuration.archiveDate == "20091102", "day stepping across daylight saving time")
            }
        }

        /// The main pane's console split through the view: the toggle, drags and double-clicks on the bar (detents,
        /// collapse threshold, minimum), a short window squeezing the console and giving it back, per-name persistence,
        /// the log sources and the bar's appearance over the gradient. The layout's numbers are ConsoleSplitLayoutTests'.
        @Test func consoleSplit() async throws {
            typealias L = ConsoleSplitLayout
            // Final geometry, not animation timing: the real Reduce Motion path (a sleeping display pauses the animator).
            let motionGetter = class_getInstanceMethod(
                NSWorkspace.self,
                #selector(getter: NSWorkspace.accessibilityDisplayShouldReduceMotion)
            )!
            let motionless: @convention(block) (AnyObject) -> Bool = { _ in true }
            let replacement = imp_implementationWithBlock(motionless)
            let previous = method_setImplementation(motionGetter, replacement)
            defer {
                method_setImplementation(motionGetter, previous)
                imp_removeBlock(replacement)
            }
            let suite = "ltm-console-split-check-\(getpid())"
            let defaults = UserDefaults(suiteName: suite)!
            defer { defaults.removePersistentDomain(forName: suite) }
            let top = NSView()
            let split = ConsoleSplitView(top: top, autosaveName: "view", defaults: defaults)
            split.appearance = NSAppearance(named: .aqua)
            let host = NSView(frame: NSRect(x: 0, y: 0, width: 800, height: 600 + ConsoleBar.height))
            split.translatesAutoresizingMaskIntoConstraints = false
            host.addSubview(split)
            let hostHeight = host.heightAnchor.constraint(equalToConstant: 0)
            NSLayoutConstraint.activate([
                host.widthAnchor.constraint(equalToConstant: 800), hostHeight,
                split.leadingAnchor.constraint(equalTo: host.leadingAnchor),
                split.trailingAnchor.constraint(equalTo: host.trailingAnchor),
                split.topAnchor.constraint(equalTo: host.topAnchor),
                split.bottomAnchor.constraint(equalTo: host.bottomAnchor)
            ])
            func resize(_ height: CGFloat) {
                hostHeight.constant = height + ConsoleBar.height
                host.layoutSubtreeIfNeeded()
            }
            resize(600)
            let bar = split.bar
            let log = split.log
            #expect(
                log.frame.height == 0 && bar.frame.minY == 0 && top.frame.height == 600 + ConsoleBar.height,
                "collapsed: bar pinned at the bottom, over the top"
            )
            #expect(
                bar.filter.isHidden && bar.clearButton.isHidden && !bar.toggleButton.isHidden,
                "collapsed bar shows only the toggle"
            )
            #expect(
                bar.toggleButton.state == .off && bar.toggleButton.toolTip?.hasPrefix("Show Console (⇧⌘Y)") == true,
                "toggle off"
            )
            let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ltm-console-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: dir) }
            let log1 = dir.appendingPathComponent("serial.log")
            try Data("boot\n".utf8).write(to: log1)
            split.sources = [log1, dir.appendingPathComponent("usbmuxd.log")]
            #expect(
                bar.source.itemTitles == ["Device Console", "USB"] && log.url == log1,
                "sources: \(bar.source.itemTitles)"
            )
            #expect(
                ["app.log", "native.log", "other.log"].map {
                    ConsoleSplitView.title(for: URL(fileURLWithPath: "/l/" + $0))
                }
                    == ["Light Touch", "Emulator", "other.log"],
                "plain log names"
            )
            // The choice follows the log across devices: a new list keeps USB selected.
            bar.source.selectItem(withTitle: "USB")
            bar.source.sendAction(bar.source.action, to: bar.source.target)
            split.sources = [
                URL(fileURLWithPath: "/elsewhere/serial.log"), URL(fileURLWithPath: "/elsewhere/usbmuxd.log")
            ]
            #expect(
                bar.source.titleOfSelectedItem == "USB" && log.url?.path == "/elsewhere/usbmuxd.log",
                "choice follows the log"
            )
            split.sources = [log1, dir.appendingPathComponent("usbmuxd.log")]
            bar.source.selectItem(at: 0)
            bar.source.sendAction(bar.source.action, to: bar.source.target)
            // Over the device's gradient the bar is dark in a light window, the console under it is not.
            #expect(
                bar.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .aqua,
                "no gradient: the bar follows the system"
            )
            bar.overGradient = true
            #expect(
                bar.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua,
                "over the gradient the bar is dark"
            )
            #expect(log.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .aqua, "only the bar is dark")
            func settle() async throws {
                try await Task.sleep(for: .milliseconds(400))
                split.layoutSubtreeIfNeeded()
            }

            bar.toggleButton.performClick(nil)
            try await settle()
            #expect(
                !split.layout.isCollapsed && log.frame.height == 200 && !log.isHidden,
                "toggle shows at 200, got \(log.frame.height)"
            )
            #expect(
                bar.toggleButton.state == .on && !bar.filter.isHidden
                    && bar.toggleButton.toolTip == "Hide Console (⇧⌘Y)",
                "toggle on"
            )
            #expect(L.load("view", from: defaults) == split.layout, "toggle persists")

            // Drags on the bar, from 200: up 62 is 262, within 10 of the middle (100+440)/2 = 270.
            func drag(_ dy: CGFloat, clicks: Int = 1) {
                func event(_ type: NSEvent.EventType, _ y: CGFloat) -> NSEvent {
                    NSEvent.mouseEvent(
                        with: type,
                        location: NSPoint(x: 400, y: y),
                        modifierFlags: [],
                        timestamp: 0,
                        windowNumber: 0,
                        context: nil,
                        eventNumber: 0,
                        clickCount: clicks,
                        pressure: 1
                    )!
                }
                bar.mouseDown(with: event(.leftMouseDown, 300))
                bar.mouseDragged(with: event(.leftMouseDragged, 300 + dy / 2))
                bar.mouseDragged(with: event(.leftMouseDragged, 300 + dy))
                bar.mouseUp(with: event(.leftMouseUp, 300 + dy))
                split.layoutSubtreeIfNeeded()
            }
            drag(62)
            #expect(log.frame.height == 270, "drag to 262 snaps to 270, got \(log.frame.height)")
            drag(-40)
            #expect(log.frame.height == 230, "drag to 230 stays, got \(log.frame.height)")
            drag(180)
            #expect(log.frame.height == 410, "drag to 410 stays, got \(log.frame.height)")
            drag(-400)
            #expect(
                split.layout.isCollapsed && log.frame.height == 0 && split.layout.height == 410,
                "drag below threshold collapses, keeps 410"
            )
            #expect(L.load("view", from: defaults) == L(height: 410, isCollapsed: true), "drag persists")
            drag(150)
            #expect(!split.layout.isCollapsed && log.frame.height == 150, "drag up from collapsed opens at the drag")
            drag(-60)
            #expect(log.frame.height == 100, "between threshold and minimum clamps to 100, got \(log.frame.height)")
            drag(0, clicks: 2)
            try await settle()
            #expect(split.layout.isCollapsed && log.frame.height == 0, "double-click hides")
            drag(0, clicks: 2)
            try await settle()
            #expect(!split.layout.isCollapsed && log.frame.height == 100, "double-click shows")

            // A short window squeezes the console to leave the device 160 pt, and gives the height back.
            drag(300)
            #expect(log.frame.height == 400, "set up 400, got \(log.frame.height)")
            resize(400)
            #expect(
                log.frame.height == 240 && top.frame.height == 160,
                "short window: console 240, got \(log.frame.height)"
            )
            resize(600)
            #expect(
                log.frame.height == 400 && split.layout.height == 400,
                "tall again: the console's height comes back"
            )
            let again = ConsoleSplitView(top: NSView(), autosaveName: "view", defaults: defaults)
            #expect(
                again.layout == L(height: 400, isCollapsed: false) && again.bar.toggleButton.state == .on,
                "restored"
            )
        }

        /// Collapsed, the bar floats over the device pane (issue 33): the pane keeps the whole height, the bar draws
        /// nothing of its own so the pane shows through, and the toggle has an opaque neutral bezel to stand on. The
        /// toggle is a plain button: it takes its own press (no drag from it), the pointer over it is the arrow, and a
        /// click shows the console. The rest of the strip is the divider's grab area, with the resize cursor: a drag
        /// from it sizes the console and a click leaves it hidden; a control of the pane's there (the iPad's Home
        /// button) and what the pane claims (the device) stay the pane's. Expanded, the bar is the divider between
        /// them as before. Renders go to the temporary directory.
        @Test(arguments: [NSAppearance.Name.aqua, .darkAqua]) func collapsedConsoleBarOverlaysThePane(
            _ appearance: NSAppearance.Name
        ) throws {
            final class Fill: NSView {
                var downs = 0
                let button = NSButton(title: "Home", target: nil, action: nil)
                override func mouseDown(with event: NSEvent) { downs += 1 }
                override func draw(_ dirtyRect: NSRect) {
                    NSColor(srgbRed: 1, green: 0, blue: 1, alpha: 1).setFill()
                    bounds.fill()
                }
            }
            let suite = "ltm-console-overlay-check-\(getpid())"
            let defaults = UserDefaults(suiteName: suite)!
            defer { defaults.removePersistentDomain(forName: suite) }
            let top = Fill()
            top.button.frame = NSRect(x: 150, y: 4, width: 40, height: 20)
            top.addSubview(top.button)
            let split = ConsoleSplitView(top: top, autosaveName: "view", defaults: defaults)
            // The pane claims the strip's right end, as the device claims its chassis.
            split.bar.paneTakesPress = { $0.x > 360 }
            split.appearance = NSAppearance(named: appearance)
            // In a window, never ordered in. It doesn't dispatch events while hidden, so `press` does what its
            // sendEvent does: the mouse-down to the view hit-tested under it, the drags and the mouse-up to that view.
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 400, height: 500),
                styleMask: [.borderless],
                backing: .buffered,
                defer: false
            )
            window.contentView = split
            split.layoutSubtreeIfNeeded()
            func event(_ type: NSEvent.EventType, _ p: NSPoint, clicks: Int = 1) -> NSEvent {
                NSEvent.mouseEvent(
                    with: type,
                    location: p,
                    modifierFlags: [],
                    timestamp: 0,
                    windowNumber: window.windowNumber,
                    context: nil,
                    eventNumber: 0,
                    clickCount: clicks,
                    pressure: 1
                )!
            }
            func press(_ points: [NSPoint], clicks: Int = 1) {
                guard let first = points.first, let target = split.hitTest(first) else { return }
                target.mouseDown(with: event(.leftMouseDown, first, clicks: clicks))
                for p in points.dropFirst() { target.mouseDragged(with: event(.leftMouseDragged, p)) }
                target.mouseUp(with: event(.leftMouseUp, points.last ?? first, clicks: clicks))
            }
            let bar = split.bar
            func render(_ name: String) throws -> (NSPoint) -> [Int] {
                let bitmap = split.bitmapImageRepForCachingDisplay(in: split.bounds)!
                split.cacheDisplay(in: split.bounds, to: bitmap)
                let url = FileManager.default.temporaryDirectory.appendingPathComponent(
                    "ltm-console-bar-\(name)-\(appearance.rawValue).png"
                )
                try bitmap.representation(using: .png, properties: [:])?.write(to: url)
                print("render: \(url.path)")
                return { p in
                    var raw = [Int](repeating: 0, count: 4)
                    bitmap.getPixel(
                        &raw,
                        atX: Int(p.x * CGFloat(bitmap.pixelsWide) / split.bounds.width),
                        y: Int((split.bounds.height - p.y) * CGFloat(bitmap.pixelsHigh) / split.bounds.height)
                    )
                    return Array(raw.prefix(3))
                }
            }
            let magentaAt = NSPoint(x: 300, y: 290)
            #expect(split.layout.isCollapsed, "starts collapsed")
            #expect(top.frame == split.bounds, "collapsed: the pane has the whole view, got \(top.frame)")
            #expect(bar.frame.minY == 0 && bar.frame.height == ConsoleBar.height, "bar at the bottom, \(bar.frame)")
            #expect(
                bar.toggleButton.isBordered && bar.toggleButton.bezelStyle == .push
                    && bar.toggleButton.contentTintColor == nil,
                "collapsed: the toggle has the push bezel, untinted"
            )
            #expect(bar.toggleButton.accessibilityLabel() == "Show Console", "the toggle keeps its label")
            var pixel = try render("collapsed")
            let magenta = pixel(magentaAt)
            // Right of the toggle, in the bar's top row and its middle: the pane shows through.
            for y in [ConsoleBar.height - 0.5, ConsoleBar.height / 2] {
                #expect(pixel(NSPoint(x: 300, y: y)) == magenta, "collapsed bar is transparent at y \(y)")
            }
            // The strip's free area is the bar's, with the resize cursor; a click there leaves the console hidden.
            for p in [NSPoint(x: 300, y: 10), NSPoint(x: 220, y: ConsoleBar.height / 2), NSPoint(x: 4, y: 4)] {
                #expect(split.hitTest(p) === bar && bar.grabs(p), "the strip at \(p) is the grab area")
                press([p])
            }
            #expect(top.downs == 0 && split.layout.isCollapsed, "clicks in the grab area leave the console hidden")
            // The pane's control in the strip and what the pane claims stay the pane's, without the resize cursor.
            let home = NSPoint(x: 170, y: 14)
            #expect(split.hitTest(home) === top.button && !bar.grabs(home), "the pane's button in the strip is its own")
            let claimed = NSPoint(x: 380, y: 10)
            #expect(split.hitTest(claimed) == nil || split.hitTest(claimed) === top, "the claimed strip is the pane's")
            #expect(!bar.grabs(claimed), "no resize cursor where the pane claims the strip")
            press([claimed])
            #expect(top.downs == 1, "a click where the pane claims the strip reaches it")
            // The toggle is a plain button: it takes its own press, the pointer over it is the arrow, a click shows.
            let toggle = bar.toggleButton
            let grip = toggle.convert(NSPoint(x: toggle.bounds.midX, y: toggle.bounds.midY), to: nil)
            #expect(split.hitTest(grip) === toggle, "the toggle takes its own press, at \(grip)")
            #expect(!bar.grabs(bar.convert(grip, from: nil)), "no resize cursor over the toggle")
            // Opaque and neutral: no magenta through it, and as gray as the bar's own background.
            let bezel = pixel(bar.toggleButton.convert(NSPoint(x: 8, y: bar.toggleButton.bounds.midY), to: nil))
            #expect(
                bezel.max()! - bezel.min()! < 8,
                "the toggle's bezel is opaque and neutral, got \(bezel) in \(bar.toggleButton.frame)"
            )
            // A drag up from the strip's free area opens the console at the drag.
            let free = NSPoint(x: 300, y: 10)
            press([free, NSPoint(x: free.x, y: free.y + 60), NSPoint(x: free.x, y: free.y + 150)])
            split.layoutSubtreeIfNeeded()
            #expect(
                !split.layout.isCollapsed && split.log.frame.height == 150,
                "drag up from the strip opens at 150, got \(split.log.frame.height)"
            )
            // A double-click on the expanded bar hides the console; a click on the toggle shows it again.
            let barAt = NSPoint(x: 300, y: bar.frame.midY)
            press([barAt], clicks: 2)
            split.layoutSubtreeIfNeeded()
            #expect(split.layout.isCollapsed && top.frame == split.bounds, "double-click on the bar hides")
            toggle.performClick(nil)
            split.layoutSubtreeIfNeeded()
            #expect(!split.layout.isCollapsed, "a click on the toggle shows")
            #expect(
                top.frame.minY == bar.frame.maxY && bar.frame.minY == split.log.frame.maxY,
                "expanded: pane, bar, console stacked; pane \(top.frame) bar \(bar.frame)"
            )
            #expect(!bar.toggleButton.isBordered, "expanded: the toggle is as before")
            pixel = try render("expanded")
            #expect(pixel(magentaAt) == magenta, "the pane above is as it was")
            #expect(pixel(NSPoint(x: 300, y: bar.frame.midY)) != magenta, "expanded bar is opaque")
        }
    }
}
