import AppKit
import HostRuntime
import Testing

@testable import LightTouchCore
@testable import Menus

extension SharedState {
    /// The real menu bar (App/MainMenu.swift whole) for the iPod and the iPad: every item, its menu, its shortcut, and
    /// which start hidden or alternate; any move, rename or shortcut change fails here first. Also: command homes,
    /// the Window menu's order, unique and reserved shortcuts, flat submenus, the empty Apps menu, and Escape's discard
    /// (only in the device window, with no sheet and no text being edited). The Device menu's validation is
    /// DeviceMenuStateTests'.
    @Suite struct MenuBarTests {
        /// One line per item; "-" is a separator. The iPad's differs only in its name: every board lists every item
        /// (Compass Heading, Carrier…), and what its hardware lacks is dimmed by validation, never left out.
        /// The process's name where the menus use it; Help's sponsor item names the project, whatever the process.
        static func bar(_ app: String) -> String {
            ipodBar.replacingOccurrences(of: "Light Touch", with: app)
                .replacingOccurrences(of: "Sponsor the \(app) project", with: "Sponsor the Light Touch project")
        }
        static let ipodBar = """
            Light Touch/About Light Touch
            Light Touch/Check for Updates…
            Light Touch/-
            Light Touch/Settings…  ⌘,
            Light Touch/-
            Light Touch/Services ▸
            Light Touch/-
            Light Touch/Hide Light Touch  ⌘h
            Light Touch/Hide Others  ⌥⌘h
            Light Touch/Show All
            Light Touch/-
            Light Touch/Quit Light Touch  ⌘q
            File/Add Device…  ⌘n
            File/-
            File/Import IPSW…
            File/Download and Prepare
            File/Cancel Download
            File/-
            File/Start
            File/-
            File/Show in Finder
            File/Delete Device…  ⌘⌫
            File/-
            File/Copy to iPod…
            File/Save to Mac…
            File/Cancel Transfer
            File/Refresh Files
            File/-
            File/Close  ⌘w
            Edit/Undo  ⌘z
            Edit/Redo  ⇧⌘z
            Edit/-
            Edit/Cut  ⌘x
            Edit/Copy  ⌘c
            Edit/Paste  ⌘v
            Edit/Delete
            Edit/Select All  ⌘a
            Edit/-
            Edit/Paste Text to iPod  ⌃⌘v
            Edit/-
            Edit/Find…  ⌘f
            Edit/Search Apps  ⌥⌘f alternate
            Edit/-
            Edit/Select Text on Screen
            View/Show Sidebar  ⌃⌘s
            View/Show Inspector  ⌥⌘i
            View/Show Console  ⇧⌘y
            View/-
            View/Physical Size  ⌘8
            View/Pixel Accurate  ⌘9
            View/Zoom to Fit  ⌘0
            View/Zoom In  ⌘+
            View/Zoom In  ⌘= hidden
            View/Zoom Out  ⌘-
            View/-
            View/Device Bezels ▸
            View/Device Bezels/3D
            View/Device Bezels/2D
            View/Device Bezels/Off
            View/Free-Form Screen
            View/Native Size
            View/Show Finger Dots
            View/Show Hidden Files
            View/-
            View/Show Toolbar  ⌥⌘t
            View/Customize Toolbar…
            View/-
            View/Enter Full Screen  ⌃⌘f
            Device/Home Screen  ⇧⌘h
            Device/Lock  ⌘l
            Device/-
            Device/Rotate Left  ⌘←
            Device/Rotate Right  ⌘→
            Device/Rotate Automatically
            Device/-
            Device/Motion ▸
            Device/Motion/Upright
            Device/Motion/Flat
            Device/Motion/-
            Device/Motion/Reset Tilt
            Device/Motion/-
            Device/Motion/Shake
            Device/Motion/Special Trick
            Device/Compass Heading ▸
            Device/Compass Heading/North
            Device/Compass Heading/East
            Device/Compass Heading/South
            Device/Compass Heading/West
            Device/Input ▸
            Device/Input/Volume Up  ⌥⌘↑
            Device/Input/Volume Down  ⌥⌘↓
            Device/Input/-
            Device/Input/Send Keyboard Input
            Device/Input/Connect Hardware Keyboard  ⇧⌘k
            Device/Network ▸
            Device/Network/Connect to the Internet
            Device/Network/Attach to Local Network
            Device/Network/-
            Device/Network/Proxy…
            Device/Accessibility ▸
            Device/Accessibility/VoiceOver
            Device/Accessibility/Zoom
            Device/Accessibility/White on Black
            Device/Accessibility/Mono Audio
            Device/Accessibility/Speak Auto-text
            Device/Carrier…
            Device/Tweaks…
            Device/Play on Phone…
            Device/Debugging ▸
            Device/Debugging/Debug Port…
            Device/Debugging/Copy lldb Command
            Device/-
            Device/Pause
            Device/-
            Device/Restart…
            Device/Shut Down…  ⌘.
            Device/Force Stop…
            Device/-
            Device/Jailbreak…
            Device/Erase All Content and Settings…
            Apps/Install App…  ⇧⌘i
            Apps/Import Media…
            Apps/-
            Apps/Open
            Apps/Uninstall…
            Apps/View on Legacy Store
            Apps/-
            Apps/Refresh Apps
            Capture/Save Screenshot  ⌘s
            Capture/Save Screenshot As…  ⇧⌘s
            Capture/Copy Screenshot
            Capture/Open Screenshot in Preview
            Capture/-
            Capture/Start Recording  ⌘r
            Capture/Discard Recording…  ⎋
            Capture/-
            Capture/Capture Screen Only
            Capture/Record Device Bezel
            Window/Minimize  ⌘m
            Window/Zoom
            Window/-
            Window/Show Device  ⌘1
            Window/Show iPod Files  ⌘2
            Window/Device Logs
            Window/-
            Window/Bring All to Front
            Help/Light Touch Help  ⌘?
            Help/Sponsor the Light Touch project
            Help/-
            Help/Export Diagnostics…
            Help/Copy Bug Report Info
            """

        /// One line per item: its menu path, title, shortcut, and whether it starts hidden or is an Option alternate.
        @MainActor func dump(_ menu: NSMenu, _ path: String) -> [String] {
            menu.items.flatMap { item -> [String] in
                if item.isSeparatorItem { return [path + "/-"] }
                var mods = ""
                let m = item.keyEquivalentModifierMask
                if m.contains(.control) { mods += "⌃" }
                if m.contains(.option) { mods += "⌥" }
                if m.contains(.shift) { mods += "⇧" }
                if m.contains(.command) { mods += "⌘" }
                let arrows: [Int: String] = [
                    NSLeftArrowFunctionKey: "←", NSRightArrowFunctionKey: "→", NSUpArrowFunctionKey: "↑",
                    NSDownArrowFunctionKey: "↓", 0x1b: "⎋", 0x7f: "⌫"
                ]
                let key =
                    item.keyEquivalent.unicodeScalars.first.flatMap { arrows[Int($0.value)] } ?? item.keyEquivalent
                var line =
                    path + "/" + item.title + (item.submenu != nil ? " ▸" : "") + (key.isEmpty ? "" : "  " + mods + key)
                if item.isHidden { line += " hidden" }
                if item.isAlternate { line += " alternate" }
                // AppKit fills Services and Help's search; their contents aren't ours.
                guard let sub = item.submenu, item.title != "Services" else { return [line] }
                return [line] + dump(sub, path + "/" + item.title)
            }
        }

        /// Help ▸ Copy Bug Report Info goes to the app delegate (so it works with no window or device) and puts one
        /// fenced, scrubbed block on the pasteboard.
        @Test func copyBugReportInfo() throws {
            _ = NSApplication.shared
            MainMenuBuilder.install(profile: .n72)
            let item = try #require(
                NSApp.mainMenu!.item(withTitle: "Help")!.submenu!.item(withTitle: BugReportCopy.title)
            )
            #expect(item.action == #selector(AppDelegate.copyBugReportInfo(_:)) && item.target == nil)
            let pasteboard = NSPasteboard(name: .init("LightTouch-tests-" + UUID().uuidString))
            defer { pasteboard.releaseGlobally() }
            pasteboard.setString("stale", forType: .string)
            let text = BugReportCopy.copy(devices: [], to: pasteboard)
            let copied = try #require(pasteboard.string(forType: .string))
            #expect(copied == text && copied.hasPrefix("```text\nLight Touch ") && copied.hasSuffix("\n```\n"))
            #expect(copied.contains("No device") && !copied.contains(NSHomeDirectory()))
        }

        @Test func menuBar() {
            _ = NSApplication.shared
            MainMenuBuilder.install(profile: .k48)
            // The application menu is named for the running process (xctest under Xcode, Light Touch in the app).
            let appName = NSApp.mainMenu!.items[0].submenu!.items[0].title.replacingOccurrences(of: "About ", with: "")
            let ipad = NSApp.mainMenu!.items.flatMap { dump($0.submenu!, $0.title) }
            let expectedIPad = Self.bar(appName).replacingOccurrences(of: "iPod", with: "iPad").components(
                separatedBy: "\n"
            )
            #expect(ipad == expectedIPad, "iPad menu bar:\n\(ipad.joined(separator: "\n"))")
            MainMenuBuilder.install(profile: .n72)
            let root = NSApp.mainMenu!
            let bar = root.items.flatMap { dump($0.submenu!, $0.title) }
            #expect(
                bar == Self.bar(appName).components(separatedBy: "\n"),
                "iPod menu bar:\n\(bar.joined(separator: "\n"))"
            )
            // With no device the Apps menu still lists its commands, every one dimmed, and a
            // device's inspector leaving hands it back the same way (MainMenuBuilder.resetAppsMenu).
            let apps = root.item(withTitle: "Apps")!.submenu!
            #expect(
                !apps.autoenablesItems && apps.delegate == nil && apps.items.count == 8
                    && apps.items.allSatisfy { !$0.isEnabled },
                "Apps with no device"
            )
            apps.removeAllItems()
            apps.addItem(withTitle: "Open “Stale”", action: nil, keyEquivalent: "")
            MainMenuBuilder.resetAppsMenu()
            #expect(
                apps.items.map(\.title) == [
                    "Install App…", "Import Media…", "", "Open", "Uninstall…", "View on Legacy Store", "",
                    "Refresh Apps"
                ]
                    && apps.items.allSatisfy { !$0.isEnabled },
                "Apps reset"
            )
            #expect(
                root.item(withTitle: "View")!.submenu!.items[0].action == #selector(
                    NSSplitViewController.toggleSidebar(_:)
                )
            )
            let app = root.items[0].submenu!
            #expect(app.item(withTitle: "Settings…") != nil)
            let device = root.item(withTitle: "Device")!.submenu!
            func find(_ name: String, in menu: NSMenu) -> NSMenuItem? {
                for item in menu.items {
                    if item.title == name { return item }
                    if let sub = item.submenu, let match = find(name, in: sub) { return match }
                }
                return nil
            }
            #expect(!root.autoenablesItems && root.items.allSatisfy { $0.isEnabled })
            #expect(find("Reset Tilt", in: device) != nil && find("Upright", in: device) != nil)
            let motion = device.item(withTitle: "Motion")!.submenu!
            let input = device.item(withTitle: "Input")!.submenu!
            #expect(
                find("Upright", in: motion) != nil && find("Flat", in: motion) != nil
                    && find("Shake", in: motion) != nil
            )
            #expect(find("Upright", in: input) == nil && find("Reset Tilt", in: input) == nil)
            for name in ["Add Device…", "Start", "Import IPSW…", "Delete Device…", "Show in Finder"] {
                #expect(find(name, in: device) == nil, "library command \(name) belongs to File")
            }
            let help = root.item(withTitle: "Help")!.submenu!
            for name in ["Open SSH", "Restart SpringBoard", "Verbose Boot", "Kernel Console"] {
                #expect(find(name, in: root) == nil, "Developer command leaked into the regular menus")
            }
            #expect(find("Device Logs", in: help) == nil)
            let file = root.item(withTitle: "File")!.submenu!
            // Delete Device… is ⌘⌫; while text is being edited the text view answers it with its own ⌘⌫ (delete to
            // the beginning of the line), so the menu never takes the key from the text.
            let deleteDevice = find("Delete Device…", in: file)!
            #expect(deleteDevice.keyEquivalent == "\u{7f}" && deleteDevice.keyEquivalentModifierMask == [.command])
            let text = NSTextView()
            text.string = "one two"
            text.setSelectedRange(NSRange(location: 7, length: 0))
            #expect(text.validateMenuItem(deleteDevice), "the text view takes ⌘⌫ while it's edited")
            NSApp.sendAction(deleteDevice.action!, to: text, from: deleteDevice)
            #expect(text.string.isEmpty, "⌘⌫ in text deletes to the line's start, got \(text.string)")
            for name in ["Copy to iPod…", "Save to Mac…", "Cancel Transfer", "Refresh Files", "Close"] {
                #expect(find(name, in: file) != nil, "\(name)")
            }
            let capture = root.item(withTitle: "Capture")!.submenu!
            #expect(
                capture.items.prefix(4).map(\.title) == [
                    "Save Screenshot", "Save Screenshot As…", "Copy Screenshot", "Open Screenshot in Preview"
                ]
            )
            #expect(find("Save Screenshot", in: capture)?.keyEquivalent == "s")
            #expect(find("Save Screenshot", in: capture)?.keyEquivalentModifierMask == [.command])
            #expect(capture.items.allSatisfy { $0.submenu == nil }, "Capture stays flat")
            #expect(
                capture.items.filter { !$0.isSeparatorItem }.map(\.title) == [
                    "Save Screenshot", "Save Screenshot As…", "Copy Screenshot", "Open Screenshot in Preview",
                    "Start Recording", "Discard Recording…",
                    "Capture Screen Only", "Record Device Bezel"
                ]
            )
            #expect(
                find("Open Screenshot in Preview", in: capture)?.keyEquivalent.isEmpty == true,
                "⌘O is Open’s, not a new screenshot’s"
            )
            for (name, key, modifiers) in [
                ("Save Screenshot As…", "s", NSEvent.ModifierFlags([.shift, .command])),
                ("Start Recording", "r", [.command]),
                ("Discard Recording…", "\u{1b}", [])
            ] {
                #expect(
                    find(name, in: capture)?.keyEquivalent == key
                        && find(name, in: capture)?.keyEquivalentModifierMask == modifiers
                )
            }
            #expect(find("Copy Screenshot", in: capture)?.keyEquivalent.isEmpty == true)
            #expect(find("Copy", in: root.item(withTitle: "Edit")!.submenu!)?.keyEquivalent == "c")
            #expect(find("Show Finger Dots", in: root.item(withTitle: "View")!.submenu!) != nil)
            #expect(find("Discard Recording…", in: capture)?.isHidden == false)
            // Escape is Discard's only in the device window, with no sheet and no text being edited; else it passes on.
            let esc = NSEvent.keyEvent(
                with: .keyDown,
                location: .zero,
                modifierFlags: [],
                timestamp: 0,
                windowNumber: 0,
                context: nil,
                characters: "\u{1b}",
                charactersIgnoringModifiers: "\u{1b}",
                isARepeat: false,
                keyCode: 53
            )!
            #expect(!capture.performKeyEquivalent(with: esc), "with no device window key, Escape passes on")
            let deviceWindow = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 200, height: 200),
                styleMask: [.titled],
                backing: .buffered,
                defer: false
            )
            let owner = MainWindowController(window: deviceWindow)
            #expect(
                CaptureMenu.escapeDiscards(in: deviceWindow) && !CaptureMenu.escapeDiscards(in: NSWindow())
                    && !CaptureMenu.escapeDiscards(in: nil)
            )
            let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 100, height: 20))
            deviceWindow.contentView!.addSubview(field)
            #expect(deviceWindow.makeFirstResponder(field) && deviceWindow.firstResponder is NSText)
            #expect(!CaptureMenu.escapeDiscards(in: deviceWindow), "Escape stays the text field's")
            deviceWindow.makeFirstResponder(nil)
            deviceWindow.beginSheet(
                NSWindow(
                    contentRect: NSRect(x: 0, y: 0, width: 50, height: 50),
                    styleMask: [.titled],
                    backing: .buffered,
                    defer: false
                )
            )
            #expect(!CaptureMenu.escapeDiscards(in: deviceWindow), "Escape stays the sheet's")
            withExtendedLifetime(owner) {}
            #expect(find("Save Screenshot As…", in: file) == nil)
            #expect(find("Rotate Left", in: device)?.keyEquivalent == String(UnicodeScalar(NSLeftArrowFunctionKey)!))
            #expect(find("Rotate Right", in: device)?.keyEquivalent == String(UnicodeScalar(NSRightArrowFunctionKey)!))
            for name in ["Shake", "Pause"] { #expect(find(name, in: device)?.keyEquivalent.isEmpty == true) }
            func leaves(_ menu: NSMenu) -> [NSMenuItem] {
                menu.items.flatMap { item in item.submenu.map(leaves) ?? [item] }
            }
            var shortcuts = Set<String>()
            for item in leaves(root) where !item.keyEquivalent.isEmpty {
                let chord = "\(item.keyEquivalent.lowercased()):\(item.keyEquivalentModifierMask.rawValue)"
                #expect(shortcuts.insert(chord).inserted, "Duplicate shortcut: \(item.title)")
                let arrows = [NSLeftArrowFunctionKey, NSRightArrowFunctionKey].map { String(UnicodeScalar($0)!) }
                // Command-arrows are rotation's (Sam, 0928c); nothing else may take them.
                #expect(
                    !(arrows.contains(item.keyEquivalent) && item.keyEquivalentModifierMask == [.command])
                        || item.title.hasPrefix("Rotate "),
                    "Command-arrow is rotation's: \(item.title)"
                )
                #expect(
                    !(item.keyEquivalentModifierMask == [.command, .option]
                        && ["+", "-", "="].contains(item.keyEquivalent)),
                    "Reserved accessibility zoom"
                )
            }
            let windows = root.item(withTitle: "Window")!.submenu!
            #expect(
                windows.items.map(\.title) == [
                    "Minimize", "Zoom", "", "Show Device", "Show iPod Files", "Device Logs", "", "Bring All to Front"
                ]
            )
            #expect(windows.item(withTitle: "Show Device")?.keyEquivalent == "1")
            #expect(windows.item(withTitle: "Show iPod Files")?.keyEquivalent == "2")
            #expect(find("Show Capture Controls", in: root) == nil && find("Hide Capture Controls", in: root) == nil)
            for menu in root.items.compactMap({ $0.submenu }) {
                for submenu in menu.items.compactMap({ $0.submenu }) {
                    #expect(submenu.items.allSatisfy { $0.submenu == nil }, "Avoid nested submenus")
                }
            }
            for name in [
                "Volume Up", "Volume Down", "Shut Down…", "Force Stop…", "Rotate Automatically",
                "Connect to the Internet"
            ] {
                #expect(find(name, in: device) != nil, "\(name)")
            }
            for name in ["Volume Up", "Volume Down"] {
                let item = find(name, in: device)!
                #expect(item.keyEquivalentModifierMask == [.option, .command])
                #expect(item.keyEquivalent != "-" && item.keyEquivalent != "=")
            }
            #expect(root.item(withTitle: "Help")!.submenu!.item(withTitle: "Export Diagnostics…") != nil)
            #expect(device.item(withTitle: "Save State Now") == nil)
            #expect(root.item(withTitle: "Window")!.submenu!.item(withTitle: "Show iPod Files") != nil)
            #expect(root.item(withTitle: "View")!.submenu!.item(withTitle: "Physical Size") != nil)
        }
    }
}
