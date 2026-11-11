import AppKit
import HostRuntime
import SwiftUI
import Testing

@testable import LightTouchCore
@testable import Sidebar

extension SharedState {
    /// The sidebar (DeviceLibraryViewController) and the Add Device sheet (AddDeviceView) with the real catalog,
    /// SidebarList, DeviceRow and DeviceStorageWork, in windows never ordered in. Every row is two lines (the marketing
    /// name over the version and its Beta/GM badge; a custom name over "iPad, iOS 3.2.2"); each board shows the artwork
    /// macOS declares for it; rename in place (menu, Return, during a preparation) saves; the context menu dims what a
    /// row can't do; Delete (File ▸ Delete Device…'s ⌘⌫, Edit ▸ Delete) removes an unprepared row and asks the delegate
    /// for a prepared one, and a bare Delete key removes nothing; a download joins the
    /// sidebar with a ring and no percentage; ⌘A and one Delete ask ONE question, and the prepared device says Deleting
    /// while a slow removal runs off the main actor (which answers the removal meanwhile); a failed removal keeps its row with
    /// one alert; an empty sidebar offers Add Device…; the sheet lists every catalog entry once, grouped by device.
    @Suite struct SidebarTests {
        final class Delegate: DeviceLibraryDelegate {
            var deletes: [String] = []
            var allowed: Set<DeviceAction> = Set(DeviceAction.allCases)
            /// Per row, when set (else `allowed`, for every row).
            var permits: ((DeviceAction, FirmwareCatalog.Entry) -> Bool)?
            var batches: [(DeviceAction, [String])] = []
            var selected: [FirmwareCatalog.Entry?] = []
            func library(_ library: DeviceLibraryViewController, didSelect entry: FirmwareCatalog.Entry?) {
                selected.append(entry)
            }
            func libraryRowsDidChange(_ library: DeviceLibraryViewController) {}
            var sessionChanges = 0
            func librarySessionsDidChange(_ library: DeviceLibraryViewController) { sessionChanges += 1 }
            func library(
                _ library: DeviceLibraryViewController,
                canPerform action: DeviceAction,
                for entry: FirmwareCatalog.Entry
            ) -> Bool {
                permits?(action, entry) ?? allowed.contains(action)
            }
            func library(_ library: DeviceLibraryViewController, perform batch: DeviceBatch<FirmwareCatalog.Entry>) {
                batches.append((batch.action, batch.targets.map(\.id)))
            }
            func library(
                _ library: DeviceLibraryViewController,
                perform action: DeviceAction,
                for entry: FirmwareCatalog.Entry
            ) {
                if action == .delete { deletes.append(entry.id) }
            }
            func library(
                _ library: DeviceLibraryViewController,
                importIPSWs urls: [URL],
                for entry: FirmwareCatalog.Entry?
            ) {}
        }

        @Test func sidebarAndAddDeviceSheet() async throws {
            _ = NSApplication.shared
            NSApp.setActivationPolicy(.prohibited)
            let catalog = try FirmwareCatalog.load(
                from: URL(fileURLWithPath: #filePath).deletingLastPathComponent()
                    .appendingPathComponent("../../../../LightTouchMac/Resources/firmware-catalog.json")
                    .standardizedFileURL
            )
            let suite = "ltm-check-sidebar-ui-\(UUID().uuidString)"
            let defaults = UserDefaults(suiteName: suite)!
            defer { defaults.removePersistentDomain(forName: suite) }
            var failures: [String] = []
            func fail(_ s: String) { failures.append(s) }

            func all(_ v: NSView) -> [NSView] { v.subviews.flatMap { [$0] + all($0) } }
            func visible(_ v: NSView) -> Bool {
                var p: NSView? = v
                while let q = p {
                    if q.isHidden { return false }
                    p = q.superview
                }
                return true
            }
            func window(_ size: NSSize) -> QuietWindow {
                let w = QuietWindow(
                    contentRect: NSRect(origin: .zero, size: size),
                    styleMask: [.titled],
                    backing: .buffered,
                    defer: false
                )
                w.appearance = NSAppearance(named: .aqua)
                return w
            }
            /// Each visible row's texts, top to bottom then leading to trailing: [title, subtitle] and any accessory text.
            func rows(_ vc: DeviceLibraryViewController) -> [[String]] {
                let outline = all(vc.view).compactMap { $0 as? NSOutlineView }.first!
                return (0..<outline.numberOfRows).map { @MainActor r in
                    let cell = outline.view(atColumn: 0, row: r, makeIfNecessary: true)!
                    @MainActor func top(_ f: NSTextField) -> CGFloat {
                        let rect = f.convert(f.bounds, to: cell)
                        return cell.isFlipped ? rect.minY : -rect.maxY
                    }
                    @MainActor func before(_ a: NSTextField, _ b: NSTextField) -> Bool {
                        abs(top(a) - top(b)) > 4
                            ? top(a) < top(b) : a.convert(a.bounds, to: cell).minX < b.convert(b.bounds, to: cell).minX
                    }
                    let fields: [NSTextField] = all(cell).compactMap { $0 as? NSTextField }.filter {
                        visible($0) && !$0.stringValue.isEmpty
                    }
                    return fields.sorted(by: before).map(\.stringValue)
                }
            }
            func sidebar(_ ids: [String], names: [String: String] = [:], host: DeviceSessionHost) -> (
                DeviceLibraryViewController, QuietWindow
            ) {
                SidebarList(ids: ids, names: names).save(defaults)
                let vc = DeviceLibraryViewController(host: host, defaults: defaults)
                let w = window(NSSize(width: 240, height: 260))
                w.contentView = vc.view
                vc.view.layoutSubtreeIfNeeded()
                return (vc, w)
            }

            // One kind of device: still the identifier over the version, the beta's badge in the version line.
            let host = DeviceSessionHost(catalog: catalog)
            host.prepared["n72ap-8C148"] = UUID()
            host.downloaded = ["n72ap-8B117"]
            var (vc, w) = sidebar(["n72ap-8C148", "n72ap-8B5080c", "n72ap-8B117", "n72ap-7E18"], host: host)
            var seen = rows(vc)
            if seen.map({ Array($0.prefix(1)) + $0.filter { $0.hasPrefix("iOS") } }) != [
                ["iPod touch (2nd generation)", "iOS 3.1.3"], ["iPod touch (2nd generation)", "iOS 4.1 beta 1"],
                ["iPod touch (2nd generation)", "iOS 4.1"],
                ["iPod touch (2nd generation)", "iOS 4.2.1"]
            ]
                || seen.contains(where: { $0.count != 2 })
            {
                fail("one kind (3.1.3 built in: nothing beside it): \(seen)")
            }
            // Remove IPSW (Settings ▸ Storage): the store says so and the row stops saying Downloaded (state audit B-5).
            let removedIPSW = catalog.entry(id: "n72ap-8B117")!
            host.downloaded = []
            NotificationCenter.default.post(name: IPSWStore.didChangeNotification, object: nil)
            if vc.row(for: removedIPSW).state == .downloaded { fail("a removed IPSW's row still says Downloaded") }
            host.downloaded = ["n72ap-8B117"]

            // Mixed: the same two lines.
            (vc, w) = sidebar(["n72ap-8C148", "k48ap-7B500", "n72ap-8B5080c", "n45ap-4B1"], host: host)
            seen = rows(vc)
            if seen != [
                ["iPad", "iOS 3.2.2"], ["iPod touch", "iOS 1.1.5"], ["iPod touch (2nd generation)", "iOS 4.1 beta 1"],
                ["iPod touch (2nd generation)", "iOS 4.2.1"]
            ] {
                fail("mixed: \(seen)")
            }

            // Artwork: macOS's declared type per board, the two iPods apart, the fallback for a model macOS doesn't know.
            var types: [String: String] = [:]
            for board in Set(catalog.entries.map(\.board)).sorted() {
                guard let profile = catalog.entries.first(where: { $0.board == board })?.profile else {
                    fail("\(board): no profile")
                    continue
                }
                guard let type = profile.deviceType, type.contentType.isDeclared else {
                    fail("\(board) (\(profile.productType)): no declared type")
                    continue
                }
                types[board] = type.identifier
                if profile.icon.isTemplate { fail("\(board)'s icon is the SF Symbol fallback") }
            }
            if types["n45ap"] == nil || types["n45ap"] == types["n72ap"] {
                fail("the iPod 1G and 2G share a type: \(types)")
            }
            if Set(types.values).count != types.count { fail("boards share a type: \(types)") }
            if !Board.icon(modelCode: "Bogus9,9", fallbackSymbol: "ipodtouch").isTemplate {
                fail("an unknown model code didn't fall back to the symbol")
            }
            /// The image as 24×24 pixels, to tell pictures apart.
            func pixels(_ image: NSImage?) -> Data? {
                guard let image,
                    let rep = NSBitmapImageRep(
                        bitmapDataPlanes: nil,
                        pixelsWide: 24,
                        pixelsHigh: 24,
                        bitsPerSample: 8,
                        samplesPerPixel: 4,
                        hasAlpha: true,
                        isPlanar: false,
                        colorSpaceName: .deviceRGB,
                        bytesPerRow: 0,
                        bitsPerPixel: 0
                    )
                else { return nil }
                NSGraphicsContext.saveGraphicsState()
                NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
                image.draw(in: NSRect(x: 0, y: 0, width: 24, height: 24))
                NSGraphicsContext.restoreGraphicsState()
                return rep.bitmapData.map { Data(bytes: $0, count: rep.bytesPerRow * 24) }
            }
            let mixedOutline = all(vc.view).compactMap { $0 as? NSOutlineView }.first!
            let rowIcons = (0..<mixedOutline.numberOfRows).map {
                (mixedOutline.view(atColumn: 0, row: $0, makeIfNecessary: true) as? NSTableCellView)?.imageView
            }
            if rowIcons.contains(where: { $0?.image == nil || $0!.isHidden || $0!.image!.isTemplate }) {
                fail("a mixed row shows no device artwork")
            }
            let iconPixels = rowIcons.map { pixels($0?.image) }
            // iPad, 1G, 2G, 2G: three pictures, the 2G's twice.
            if Set(iconPixels.prefix(3)).count != 3 || iconPixels[2] != iconPixels[3] {
                fail("the rows' artwork doesn't follow the board")
            }
            if let icon = rowIcons[0], icon.frame.height < 24 || icon.frame.height > 34 {
                fail("a two-line row's icon is \(icon.frame.size)")
            }

            // Rename in place through the context menu's Rename: the title turns into a field; ending the edit saves.
            vc.select(catalog.entry(id: "k48ap-7B500")!)
            vc.perform(NSSelectorFromString("renameFromMenu:"), with: nil)
            guard let editor = w.firstResponder as? NSTextView, let field = editor.delegate as? NSTextField,
                field.isEditable
            else {
                fail("Rename didn't start an edit: \(String(describing: w.firstResponder))")
                Issue.record("\(failures)")
                return
            }
            if field.stringValue != "iPad" { fail("the edit starts from \(field.stringValue)") }
            editor.string = "Lab iPad"
            w.makeFirstResponder(nil)
            if (defaults.dictionary(forKey: SidebarList.namesKey) as? [String: String]) != ["k48ap-7B500": "Lab iPad"] {
                fail("rename not saved: \(String(describing: defaults.dictionary(forKey: SidebarList.namesKey)))")
            }
            seen = rows(vc)
            if seen.first != ["Lab iPad", "iPad, iOS 3.2.2"] { fail("renamed: \(seen)") }
            if field.isEditable { fail("the title stays editable after renaming") }
            // And an iPod: its subtitle names the model by its marketing name.
            vc.select(catalog.entry(id: "n72ap-8C148")!)
            vc.perform(NSSelectorFromString("renameFromMenu:"), with: nil)
            if let editor = w.firstResponder as? NSTextView {
                editor.string = "Test iPod"
                w.makeFirstResponder(nil)
            } else {
                fail("Rename didn't start an edit on the iPod row")
            }
            seen = rows(vc)
            if seen.last != ["Test iPod", "iPod touch (2nd generation), iOS 4.2.1"] { fail("renamed iPod: \(seen)") }
            // Return on the selected row starts the same rename (as in the Finder's sidebar).
            do {
                let outline = all(vc.view).compactMap { $0 as? NSOutlineView }.first!
                vc.select(catalog.entry(id: "k48ap-7B500")!)
                w.makeFirstResponder(outline)
                outline.keyDown(
                    with: NSEvent.keyEvent(
                        with: .keyDown,
                        location: .zero,
                        modifierFlags: [],
                        timestamp: 0,
                        windowNumber: w.windowNumber,
                        context: nil,
                        characters: "\r",
                        charactersIgnoringModifiers: "\r",
                        isARepeat: false,
                        keyCode: 36
                    )!
                )
                if let editor = w.firstResponder as? NSTextView {
                    editor.string = "Lab iPad"
                    w.makeFirstResponder(nil)
                } else {
                    fail("Return didn't start a rename: \(String(describing: w.firstResponder))")
                }
                if rows(vc).first != ["Lab iPad", "iPad, iOS 3.2.2"] { fail("Return rename: \(rows(vc))") }
            }
            // Renaming a row whose preparation is moving: its progress updates don't end the edit or lose the typing.
            vc.select(catalog.entry(id: "n45ap-4B1")!)
            vc.perform(NSSelectorFromString("renameFromMenu:"), with: nil)
            if let editor = w.firstResponder as? NSTextView {
                editor.string = "Prep iPod"
                for step in 1...3 {
                    FirmwareJobs.shared.jobs["n45ap-4B1"] = .preparing(
                        Preparation(step: step, steps: 4, name: "Step \(step)", fraction: 0.5)
                    )
                }
                if w.firstResponder !== editor || editor.string != "Prep iPod" {
                    fail(
                        "a preparing row's progress ended the rename: \(String(describing: w.firstResponder)), \(editor.string)"
                    )
                }
                w.makeFirstResponder(nil)
                if (defaults.dictionary(forKey: SidebarList.namesKey) as? [String: String])?["n45ap-4B1"] != "Prep iPod"
                {
                    fail("rename during preparation not saved")
                }
            } else {
                fail("Rename didn't start an edit on a preparing row")
            }
            FirmwareJobs.shared.jobs = [:]
            // Offscreen, a selected source-list row draws its material black: render unselected.
            all(vc.view).compactMap { $0 as? NSOutlineView }.first!.deselectAll(nil)

            // Delete: a prepared row asks through the delegate's delete and stays until it's done; the others go at once.
            let delegate = Delegate()
            vc.delegate = delegate
            let outline = all(vc.view).compactMap { $0 as? NSOutlineView }.first!
            // The context menu lists every command; what the row can't do now is dimmed, not left out.
            vc.select(catalog.entry(id: "n72ap-8C148")!)
            delegate.allowed = [.start]
            let context = NSMenu()
            vc.menuNeedsUpdate(context)
            let commands = context.items.filter { !$0.isSeparatorItem && $0.title != "Rename" }
            let live = commands.filter { vc.validateMenuItem($0) }.map(\.title)
            // Start/Shut Down is one item whose title follows the row (Force Stop beside it, dimmed while stopped); Cancel
            // is always there, dimmed while nothing can be cancelled (never hidden, only disabled).
            if ![
                "Start", "Cancel Download", "Show File System in Finder", "Jailbreak…",
                "Erase All Content and Settings…"
            ]
            .allSatisfy({ t in commands.contains { $0.title == t } })
                || commands.contains(where: { $0.title == "Shut Down…" }) || !live.contains("Start")
                || live.contains("Force Stop…") || live.contains("Cancel Download")
            {
                fail("context menu: \(commands.map(\.title)), enabled \(live)")
            }
            delegate.allowed = Set(DeviceAction.allCases).subtracting([.cancel])
            host.running = ["n72ap-8C148"]
            NotificationCenter.default.post(name: DeviceSessionHost.didChangeNotification, object: nil)
            vc.menuNeedsUpdate(context)
            var titles = context.items.map(\.title)
            if !titles.contains("Shut Down…") || !titles.contains("Force Stop…") || titles.contains("Start")
                || !titles.contains("Cancel Download")
                || context.items.contains(where: { $0.title == "Cancel Download" && vc.validateMenuItem($0) })
            {
                fail("a running row's context menu: \(titles)")
            }
            host.running = []
            delegate.allowed = Set(DeviceAction.allCases)
            FirmwareJobs.shared.jobs["n72ap-8C148"] = .preparing(Preparation(step: 1, steps: 2, name: "x"))
            vc.menuNeedsUpdate(context)
            titles = context.items.map(\.title)
            if !titles.contains("Cancel Preparation") || !titles.contains("Start")
                || !context.items.contains(where: { $0.title == "Cancel Preparation" && vc.validateMenuItem($0) })
            {
                fail("a preparing row's context menu: \(titles)")
            }
            FirmwareJobs.shared.jobs = [:]
            // The Dock's bar: running jobs averaged, each as its row's bar; nothing running, no bar.
            let dock = FirmwareJob.dockProgress([
                .downloading(fraction: 0.5),
                .preparing(Preparation(step: 1, steps: 2, name: "x", fraction: 0.5, startsAt: 0.5)), .failed("x")
            ])
            if dock.map({ abs($0 - 0.4375) > 0.0001 }) ?? true { fail("Dock progress: \(String(describing: dock))") }
            if FirmwareJob.dockProgress([FirmwareJob.failed("x")]) != nil
                || FirmwareJob.dockProgress([FirmwareJob]()) != nil
            {
                fail("a Dock bar with nothing running")
            }
            let delete = NSEvent.keyEvent(
                with: .keyDown,
                location: .zero,
                modifierFlags: [],
                timestamp: 0,
                windowNumber: w.windowNumber,
                context: nil,
                characters: "\u{7f}",
                charactersIgnoringModifiers: "\u{7f}",
                isARepeat: false,
                keyCode: 51
            )!
            vc.select(catalog.entry(id: "n72ap-8C148")!)
            // A bare Delete or Forward Delete key in the sidebar removes nothing; the menu's ⌘⌫ (removeTargets, as
            // Edit ▸ Delete) does.
            let forwardDelete = NSEvent.keyEvent(
                with: .keyDown,
                location: .zero,
                modifierFlags: [],
                timestamp: 0,
                windowNumber: w.windowNumber,
                context: nil,
                characters: String(UnicodeScalar(UInt16(NSDeleteFunctionKey))!),
                charactersIgnoringModifiers: String(UnicodeScalar(UInt16(NSDeleteFunctionKey))!),
                isARepeat: false,
                keyCode: 117
            )!
            let before = vc.entries.map(\.id)
            outline.keyDown(with: delete)
            outline.keyDown(with: forwardDelete)
            if !delegate.deletes.isEmpty || vc.entries.map(\.id) != before {
                fail("a bare Delete key removed \(delegate.deletes), left \(vc.entries.map(\.id))")
            }
            if w.unhandled != [#selector(NSResponder.keyDown(with:)), #selector(NSResponder.keyDown(with:))] {
                fail("Delete and Forward Delete reached no handler: \(w.unhandled)")
            }
            vc.delete(nil)
            if delegate.deletes != ["n72ap-8C148"] || !vc.entries.contains(where: { $0.id == "n72ap-8C148" }) {
                fail("prepared delete: \(delegate.deletes)")
            }
            vc.select(catalog.entry(id: "n72ap-8B5080c")!)
            vc.delete(nil)
            if vc.entries.contains(where: { $0.id == "n72ap-8B5080c" })
                || defaults.stringArray(forKey: SidebarList.entriesKey)?.contains("n72ap-8B5080c") != false
            {
                fail("Delete didn't remove an unprepared row")
            }
            // A download started elsewhere (an IPSW dropped on the empty area) brings its entry in; its row shows the
            // ring, no percentage.
            FirmwareJobs.shared.jobs["n72ap-8B117"] = .downloading(fraction: 0.25)
            if !vc.entries.contains(where: { $0.id == "n72ap-8B117" }) { fail("a job's entry didn't join the sidebar") }
            if let index = vc.entries.firstIndex(where: { $0.id == "n72ap-8B117" }) {
                let texts = rows(vc)[index]
                let cell = outline.view(atColumn: 0, row: index, makeIfNecessary: true)!
                let ring = all(cell).compactMap { $0 as? NSProgressIndicator }.first
                if texts != ["iPod touch (2nd generation)", "iOS 4.1"] { fail("a download's row reads \(texts)") }
                if ring.map({ !visible($0) || $0.isIndeterminate || $0.doubleValue != 0.125 }) ?? true {
                    fail("a 25% download's row has no ring at 12.5% (the first half of the job) ")
                }
                outline.deselectAll(nil)
            }
            // A failed download leaves with Delete and stays gone.
            FirmwareJobs.shared.jobs["n72ap-8B117"] = .failed("x")
            vc.select(catalog.entry(id: "n72ap-8B117")!)
            vc.delete(nil)
            FirmwareJobs.shared.jobs["n72ap-8C148"] = nil  // the next state change
            if vc.entries.contains(where: { $0.id == "n72ap-8B117" }) { fail("a failed download's row came back") }
            if FirmwareJobs.shared.jobs["n72ap-8B117"] != nil { fail("the removed row's failure outlived it") }
            FirmwareJobs.shared.jobs = [:]

            // Several rows: ⌘A, then one Delete for the lot.
            let multi = DeviceSessionHost(catalog: catalog)
            multi.deleteSeconds = 0.8
            multi.prepared = ["n72ap-8C148": UUID(), "k48ap-7B500": UUID()]
            multi.running = ["k48ap-7B500"]
            multi.downloaded = ["n72ap-8B117"]
            (vc, w) = sidebar(["n72ap-8C148", "k48ap-7B500", "n72ap-8B117", "n45ap-4B1"], host: multi)
            let multiDelegate = Delegate()
            vc.delegate = multiDelegate
            var alerts: [NSAlert] = []
            var answer = NSApplication.ModalResponse.alertSecondButtonReturn
            vc.presentAlert = { alert, _, done in
                alerts.append(alert)
                done(answer)
            }
            let multiOutline = all(vc.view).compactMap { $0 as? NSOutlineView }.first!
            w.makeFirstResponder(multiOutline)
            multiOutline.selectAll(nil)
            if vc.selectedEntries.count != 4 || vc.selectedEntry != nil {
                fail("⌘A: \(vc.selectedEntries.map(\.id)), single \(String(describing: vc.selectedEntry?.id))")
            }
            if multiDelegate.selected.last != .some(nil) {
                fail("several rows selected still name one entry to the window")
            }
            if !vc.canRemoveTargets { fail("Delete dimmed over a removable selection") }
            // Several rows' context menu: each command for the rows it applies to, saying how many, dimmed (not left
            // out) when none does; choosing one hands the window those rows alone.
            multiDelegate.permits = { action, entry in vc.row(for: entry).allows(action, canDownload: true) }
            let several = NSMenu()
            vc.menuNeedsUpdate(several)
            let severalTitles = several.items.filter { !$0.isSeparatorItem }.map(\.title)
            if severalTitles != [
                "Start 1 Device", "Force Stop 1 Device…", "Jailbreak Devices…", "Erase 2 Devices…",
                "Delete 3 Devices…"
            ]
                // Jailbreak is dimmed: the stopped device is iOS 4.2.1, which takes no jailbreak yet.
                || several.items.filter({ !$0.isSeparatorItem }).map(vc.validateMenuItem)
                    != [true, true, false, true, true]
            {
                fail("several rows' context menu: \(severalTitles)")
            }
            if let erase = several.items.first(where: { $0.title == "Erase 2 Devices…" }), let action = erase.action {
                NSApp.sendAction(action, to: erase.target, from: erase)
            }
            if multiDelegate.batches.map(\.0) != [.erase]
                || Set(multiDelegate.batches.first?.1 ?? []) != ["n72ap-8C148", "k48ap-7B500"]
            {
                fail("several rows' Erase handed the window \(multiDelegate.batches)")
            }
            multiDelegate.permits = { _, _ in false }
            vc.menuNeedsUpdate(several)
            if several.items.contains(where: { $0.title == "Force Stop Devices…" && vc.validateMenuItem($0) })
                || !several.items.contains(where: { $0.title == "Force Stop Devices…" })
            {
                fail("with nothing to stop: \(several.items.map(\.title))")
            }
            multiDelegate.permits = nil
            // Offscreen, the selection's material draws black (as in sidebar-renamed's note): the rows' artwork shows on it.
            vc.delete(nil)  // Cancel
            if alerts.count != 1 { fail("a mixed batch asked \(alerts.count) questions") }
            if let alert = alerts.first {
                if alert.messageText != "Delete 3 devices?" { fail("batch question: \(alert.messageText)") }
                if !alert.informativeText.contains("iPod touch (2nd generation) iOS 4.2.1")
                    || !alert.informativeText.contains("iPad iOS 3.2.2")
                {
                    fail("the question doesn't name the prepared and the skipped device: \(alert.informativeText)")
                }
                alert.layout()
            }
            if vc.entries.count != 4 || !multi.deleted.isEmpty || !multiDelegate.deletes.isEmpty {
                fail("Cancel changed the sidebar: \(vc.entries.map(\.id)) \(multi.deleted)")
            }
            answer = .alertFirstButtonReturn
            multiOutline.selectAll(nil)
            vc.delete(nil)
            if alerts.count != 2 { fail("the second Delete asked \(alerts.count - 1) questions") }
            // The unprepared rows left at once; the prepared one is Deleting until its storage is gone.
            let doomed = catalog.entry(id: "n72ap-8C148")!
            if vc.entries.map(\.id) != ["k48ap-7B500", "n72ap-8C148"] {
                fail("while deleting: \(vc.entries.map(\.id))")
            }
            if vc.row(for: doomed).state != .deleting || vc.row(for: doomed).allows(.start, canDownload: true)
                || vc.row(for: doomed).canRemoveFromSidebar
            {
                fail(
                    "a deleting row: \(vc.row(for: doomed).state), startable \(vc.row(for: doomed).allows(.start, canDownload: true))"
                )
            }
            let doomedCell = multiOutline.view(atColumn: 0, row: 1, makeIfNecessary: true)!
            if !(doomedCell.accessibilityLabel() ?? "").contains("Deleting") {
                fail("a deleting row doesn't say so: \(doomedCell.accessibilityLabel() ?? "nil")")
            }
            if !all(doomedCell).contains(where: {
                ($0 as? NSProgressIndicator).map { visible($0) && $0.isIndeterminate } ?? false
            }) {
                fail("a deleting row has no spinner")
            }
            multiOutline.deselectAll(nil)
            // The main actor stays free while the fake removal sleeps on its thread: it runs a block the removal
            // posts (StandIns), however slowly a loaded host schedules it. 60 s only bounds a hang.
            let began = Date()
            while vc.entries.count > 1, Date().timeIntervalSince(began) < 60 {
                try await Task.sleep(for: .milliseconds(10))
            }
            if multi.mainAnswered.withLock({ $0 }) != true {
                fail("the main actor stalled during deletion: it didn't answer the removal")
            }
            if multi.deleted != ["n72ap-8C148"] || !multiDelegate.deletes.isEmpty {
                fail("batch deleted \(multi.deleted), per-row deletes \(multiDelegate.deletes)")
            }
            if vc.entries.map(\.id) != ["k48ap-7B500"]
                || defaults.stringArray(forKey: SidebarList.entriesKey) != ["k48ap-7B500"]
            {
                fail("after the batch: \(vc.entries.map(\.id))")
            }
            if multi.deletions.contains("n72ap-8C148") { fail("still marked deleting") }
            if alerts.count != 2 { fail("a successful deletion showed an alert") }

            // A deletion that fails: the row stays, back to ready, and one alert says why.
            let broken = DeviceSessionHost(catalog: catalog)
            broken.prepared = ["n72ap-8C148": UUID(), "n72ap-8B117": UUID()]
            broken.failing = true
            (vc, w) = sidebar(["n72ap-8C148", "n72ap-8B117"], host: broken)
            vc.delegate = multiDelegate
            var failureAlerts: [NSAlert] = []
            vc.presentAlert = { alert, _, done in
                failureAlerts.append(alert)
                done(.alertFirstButtonReturn)
            }
            let brokenOutline = all(vc.view).compactMap { $0 as? NSOutlineView }.first!
            brokenOutline.selectAll(nil)
            vc.delete(nil)
            let failStart = Date()
            while !broken.deletions.busy.isEmpty || failureAlerts.count < 2, Date().timeIntervalSince(failStart) < 60 {
                try await Task.sleep(for: .milliseconds(10))
            }
            if vc.entries.count != 2 || vc.entries.contains(where: { vc.row(for: $0).state != .ready }) {
                fail("failed deletion: \(vc.entries.map { "\($0.id) \(vc.row(for: $0).state)" })")
            }
            if failureAlerts.count != 2 || !failureAlerts[1].messageText.contains("couldn’t be removed") {
                fail("failed deletion alerts: \(failureAlerts.map(\.messageText))")
            }
            // Nothing prepared: no question. All running or busy: Delete dims.
            (vc, w) = sidebar(["k48ap-7B500", "n72ap-8B117", "n45ap-4B1"], host: multi)
            vc.delegate = multiDelegate
            vc.presentAlert = { alert, _, done in
                alerts.append(alert)
                done(answer)
            }
            let plainOutline = all(vc.view).compactMap { $0 as? NSOutlineView }.first!
            plainOutline.selectRowIndexes([1, 2], byExtendingSelection: false)
            vc.delete(nil)
            if alerts.count != 2 || vc.entries.map(\.id) != ["k48ap-7B500"] {
                fail("unprepared batch: \(alerts.count) questions, left \(vc.entries.map(\.id))")
            }
            FirmwareJobs.shared.jobs["n72ap-8B117"] = .downloading(fraction: 0.5)
            plainOutline.selectAll(nil)
            let editDelete = NSMenuItem(title: "Delete", action: #selector(NSText.delete(_:)), keyEquivalent: "")
            if vc.selectedEntries.count != 2 || vc.validateMenuItem(editDelete) {
                fail("Edit ▸ Delete enabled over running and downloading rows")
            }
            FirmwareJobs.shared.jobs = [:]

            // Empty: the sidebar's own Add Device….
            (vc, w) = sidebar([], host: DeviceSessionHost(catalog: catalog))
            let add = all(vc.view).compactMap { $0 as? NSButton }.filter { visible($0) && $0.title == "Add Device…" }
            if add.count != 1 { fail("empty sidebar: no Add Device…") }
            var added = false
            vc.onAdd = { added = true }
            add.first?.performClick(nil)
            if !added { fail("empty sidebar's Add Device… does nothing") }

            // The sheet: every entry once, grouped by device.
            let sheet = AddDeviceView(
                catalog: catalog,
                added: ["k48ap-7B500", "n72ap-8C148"],
                downloaded: ["n72ap-8B117", "k48ap-7B500", "n72ap-8C148"],
                selection: ["n72ap-8B117"],
                onAdd: { _ in },
                onCancel: {}
            )
            if sheet.groups.flatMap(\.entries).map(\.id) != catalog.entries.map(\.id) {
                fail("the sheet's entries aren't the catalog's, in its order")
            }
            if sheet.groups.map(\.name) != [
                "iPad", "iPod touch", "iPod touch (2nd generation)", "iPod touch (3rd generation)",
                "iPod touch (4th generation)", "iPhone", "iPhone 3GS",
                "iPhone 4"
            ] {
                fail("sheet groups: \(sheet.groups.map(\.name))")
            }
            // macOS draws the iPod touch 3G (iPod3,1) with the 2G's picture, the same chassis: those two may match.
            let art = Dictionary(uniqueKeysWithValues: sheet.groups.map { ($0.id, pixels($0.icon)) })
            if sheet.groups.contains(where: \.icon.isTemplate)
                || Set(art.filter { $0.key != "n18ap" }.values).count != sheet.groups.count - 1
                || art["n18ap"] != art["n72ap"]
            {
                fail("the sheet's headers don't show each device's artwork")
            }
            // Only stable builds by default; Show experimental brings back the rest, every device with its own.
            let stable = AddDeviceView.shown(sheet.groups, experimental: false).flatMap(\.entries)
            let releases = catalog.entries.filter {
                $0.status == .available || ($0.status == .userIPSW && $0.prerelease == nil)
            }
            if stable.isEmpty || stable.map(\.id) != releases.map(\.id) || releases.count == catalog.entries.count
                || AddDeviceView.shown(sheet.groups, experimental: true).flatMap(\.entries).map(\.id)
                    != catalog.entries.map(\.id)
            {
                fail("Show experimental: \(stable.map(\.id))")
            }
            // A supported build says nothing; the others keep their tag.
            let tags = FirmwareCatalog.Entry.Status.allCasesForCheck.map { AddDeviceRow.statusText($0) }
            if tags != [nil, "Experimental", "Untested", "Coming Soon", "Requires an IPSW"] {
                fail("the sheet's tags: \(tags)")
            }
            #expect(failures.isEmpty, "\(failures.joined(separator: "\n"))")
        }

        /// The Add Device sheet's split, in its own window never ordered in: devices on the left (only those with a
        /// shown build), the chosen device's versions on the right. Add, and Return in the versions list, hand over
        /// the picks across devices in catalog order, never an entry already added or one hidden by Show experimental;
        /// an added row can't be picked by keyboard; letters type-select a device; the sheet resizes, autosaves its
        /// size and grows no toolbar. Renders (light and dark) go to the temporary directory.
        @Test func addDeviceSheetSplitsByDevice() throws {
            _ = NSApplication.shared
            NSApp.setActivationPolicy(.prohibited)
            let catalog = try FirmwareCatalog.load(
                from: URL(fileURLWithPath: #filePath).deletingLastPathComponent()
                    .appendingPathComponent("../../../../LightTouchMac/Resources/firmware-catalog.json")
                    .standardizedFileURL
            )
            // The emulator's machine table (cellular, panel limits) as the app lists it from its helper.
            Machines.set(
                try JSONDecoder().decode(
                    [DeviceInfo].self,
                    from: Data(
                        contentsOf: URL(fileURLWithPath: #filePath).deletingLastPathComponent()
                            .appendingPathComponent("../../../fixtures/machines.json").standardizedFileURL
                    )
                )
            )
            let experimentalKey = "addDeviceShowsExperimental"
            defer {
                UserDefaults.standard.removeObject(forKey: experimentalKey)
                NSApp.appearance = nil
            }
            var failures: [String] = []
            func fail(_ s: String) { failures.append(s) }
            func all(_ v: NSView) -> [NSView] { v.subviews.flatMap { [$0] + all($0) } }
            func key(
                _ characters: String,
                _ code: UInt16,
                in window: NSWindow,
                modifiers: NSEvent.ModifierFlags = []
            ) -> NSEvent {
                NSEvent.keyEvent(
                    with: .keyDown,
                    location: .zero,
                    modifierFlags: modifiers,
                    timestamp: 0,
                    windowNumber: window.windowNumber,
                    context: nil,
                    characters: characters,
                    charactersIgnoringModifiers: characters,
                    isARepeat: false,
                    keyCode: code
                )!
            }
            var addedIDs: [[String]] = []
            func sheet(
                experimental: Bool,
                selection: Set<String> = [],
                device: String? = nil,
                added: Set<String> = ["k48ap-7B500", "n72ap-8C148"],
                appearance: NSAppearance.Name = .aqua,
                size: NSSize = NSSize(width: 800, height: 620)
            ) -> (NSWindow, [NSTableView]) {
                UserDefaults.standard.set(experimental, forKey: experimentalKey)
                // Before the view is made: SwiftUI outside the lists takes the appearance it starts with.
                NSApp.appearance = NSAppearance(named: appearance)
                let view = AddDeviceView(
                    catalog: catalog,
                    added: added,
                    downloaded: ["n72ap-8B117", "k48ap-7B500", "n72ap-8C148", "k48ap-7B367", "n90ap-11D257"],
                    // As the bundled itpacks (qemu-ios mkpkg's families) have them.
                    guestPackaged: ["n88ap-10B500", "n90ap-11D257", "k48ap-9B206"],
                    selection: selection,
                    device: device,
                    onAdd: { addedIDs.append($0) },
                    onCancel: {}
                )
                let window = view.makeSheet()
                window.setFrameAutosaveName("")
                window.appearance = NSAppearance(named: appearance)
                window.setContentSize(size)
                window.contentView?.layoutSubtreeIfNeeded()
                RunLoop.main.run(until: Date().addingTimeInterval(0.2))
                window.contentView?.layoutSubtreeIfNeeded()
                let tables = all(window.contentView!).compactMap { $0 as? NSTableView }
                    .sorted { $0.convert($0.bounds, to: nil).minX < $1.convert($1.bounds, to: nil).minX }
                return (window, tables)
            }
            /// The live sheet's lists are AppKit source-list and inset tables: a selected sidebar row's highlight is an
            /// NSVisualEffectView with the .selection material, which the window server composites (accent while the
            /// window is key and the list focused, gray otherwise) and which draws black in a window never ordered in.
            /// For the render only, that material is swapped for the color it composites to, emphasized in the
            /// focused list (the versions list when the sheet opens) while the sheet is key, or not (another window is).
            var emphasized = true
            func paintSelection(_ content: NSView) {
                for table in all(content).compactMap({ $0 as? NSTableView }) {
                    // The focused list's selection is the accent color, the other's gray.
                    let focused = emphasized && table.window?.firstResponder === table
                    for row in all(table).compactMap({ $0 as? NSTableRowView }) where row.isSelected {
                        row.isEmphasized = focused
                        for effect in row.subviews.compactMap({ $0 as? NSVisualEffectView })
                        where effect.material == .selection {
                            effect.isHidden = true
                            let box = NSBox(frame: effect.frame)
                            box.boxType = .custom
                            box.borderWidth = 0
                            box.cornerRadius = 5
                            box.fillColor =
                                focused ? .selectedContentBackgroundColor : .unemphasizedSelectedContentBackgroundColor
                            row.addSubview(box, positioned: .below, relativeTo: nil)
                        }
                    }
                }
            }
            func render(_ window: NSWindow, _ name: String) throws {
                let content = window.contentView!
                paintSelection(content)
                content.display()
                RunLoop.main.run(until: Date().addingTimeInterval(0.3))
                let bitmap = content.bitmapImageRepForCachingDisplay(in: content.bounds)!
                content.cacheDisplay(in: content.bounds, to: bitmap)
                // Over the window's background, which its frame view draws, not the content view.
                let out = NSBitmapImageRep(
                    bitmapDataPlanes: nil,
                    pixelsWide: bitmap.pixelsWide,
                    pixelsHigh: bitmap.pixelsHigh,
                    bitsPerSample: 8,
                    samplesPerPixel: 4,
                    hasAlpha: true,
                    isPlanar: false,
                    colorSpaceName: .deviceRGB,
                    bytesPerRow: 0,
                    bitsPerPixel: 0
                )!
                out.size = content.bounds.size
                NSGraphicsContext.saveGraphicsState()
                NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: out)
                window.effectiveAppearance.performAsCurrentDrawingAppearance {
                    NSColor.windowBackgroundColor.setFill()
                    content.bounds.fill()
                }
                bitmap.draw(
                    in: content.bounds,
                    from: .zero,
                    operation: .sourceOver,
                    fraction: 1,
                    respectFlipped: true,
                    hints: nil
                )
                NSGraphicsContext.restoreGraphicsState()
                let url = FileManager.default.temporaryDirectory.appendingPathComponent("ltm-add-device-\(name).png")
                try out.representation(using: .png, properties: [:])?.write(to: url)
                print("render: \(url.path)")
            }
            /// Return outside the lists: the Add button's default-action shortcut.
            func pressAdd(_ window: NSWindow) {
                window.makeFirstResponder(nil)
                _ = window.performKeyEquivalent(with: key("\r", 36, in: window))
            }

            // Stable only: two devices, the first chosen; nothing picked, Add dims.
            var (window, tables) = sheet(experimental: false)
            if window.styleMask.contains(.resizable) == false || window.toolbar != nil
                || makeSheetAutosaveName(catalog) != "AddDeviceSheet"
            {
                fail("sheet window: \(window.styleMask), toolbar \(String(describing: window.toolbar))")
            }
            if window.contentMinSize.width < 600 || window.contentMinSize.width > 800 {
                fail("sheet minimum: \(window.contentMinSize)")
            }
            if tables.count != 2 || tables.first?.numberOfRows != 2 {
                fail("stable split: \(tables.count) lists, \(tables.first?.numberOfRows ?? -1) devices")
            }
            pressAdd(window)
            if !addedIDs.isEmpty { fail("Add with nothing picked handed over \(addedIDs)") }
            try render(window, "stable-light")

            // An added iPad version: Return on it adds nothing, the arrow skips it.
            if let versions = tables.last {
                window.makeFirstResponder(versions)
                versions.keyDown(with: key(String(UnicodeScalar(NSDownArrowFunctionKey)!), 125, in: window))
                versions.keyDown(with: key(String(UnicodeScalar(NSDownArrowFunctionKey)!), 125, in: window))
                versions.keyDown(with: key("\r", 36, in: window))
                if addedIDs.last.map({ $0.contains("k48ap-7B500") }) ?? false {
                    fail("an added version was picked: \(addedIDs)")
                }
            }

            // The sheet opens with the versions list focused, not the devices: its selection is the active one and
            // the arrow keys move through the versions and leave the device.
            (window, tables) = sheet(experimental: false, selection: ["k48ap-7B367"], device: "k48ap")
            if tables.count == 2, let devices = tables.first, let versions = tables.last {
                func focused() -> String {
                    let responder = window.firstResponder
                    return responder === versions
                        ? "versions"
                        : responder === devices ? "devices" : "\(responder.map { "\(type(of: $0))" } ?? "nothing")"
                }
                // What AppKit does when the sheet becomes key (it is never ordered in here).
                window.makeFirstResponder(window.initialFirstResponder)
                if focused() != "versions" { fail("the sheet opens with \(focused()) focused, not the versions") }
                try render(window, "focus-versions-light")
                let device = devices.selectedRow
                let version = versions.selectedRow
                window.firstResponder?.keyDown(
                    with: key(String(UnicodeScalar(NSDownArrowFunctionKey)!), 125, in: window)
                )
                RunLoop.main.run(until: Date().addingTimeInterval(0.2))
                if devices.selectedRow != device || versions.selectedRow == version {
                    fail(
                        "Down arrow: device row \(device) to \(devices.selectedRow), version \(version) to \(versions.selectedRow)"
                    )
                }
                // Tab and Shift-Tab are SwiftUI's focus moves, which run only in a key window: both lists take it.
                if !devices.acceptsFirstResponder || !versions.acceptsFirstResponder {
                    fail(
                        "a list that can't take the focus: \(devices.acceptsFirstResponder) \(versions.acceptsFirstResponder)"
                    )
                }
            } else {
                fail("focus: \(tables.count) lists")
            }

            // Picks across devices, an added one and a hidden experimental one: Add hands over the rest in order.
            addedIDs = []
            (window, tables) = sheet(
                experimental: false,
                selection: ["n72ap-5H11a", "k48ap-7B367", "k48ap-7B500", "n72ap-8C134"],
                device: "n72ap",
                appearance: .darkAqua
            )
            try render(window, "picked-ipod2g-dark")
            pressAdd(window)
            if addedIDs != [["k48ap-7B367", "n72ap-5H11a"]] { fail("Add handed over \(addedIDs)") }
            addedIDs = []
            if let versions = tables.last {
                window.makeFirstResponder(versions)
                versions.keyDown(with: key("\r", 36, in: window))
            }
            if addedIDs != [["k48ap-7B367", "n72ap-5H11a"]] { fail("Return handed over \(addedIDs)") }

            // Experimental shown: every device. One pick on each device below, and several, in light and dark;
            // type-select reaches the iPhone 3GS.
            (window, tables) = sheet(experimental: true, selection: ["n88ap-10B500"], device: "n88ap")
            if tables.first?.numberOfRows != 8 { fail("experimental devices: \(tables.first?.numberOfRows ?? -1)") }
            let picks: [(String, Set<String>, String)] = [
                ("iphone3gs-6.1.6", ["n88ap-10B500"], "n88ap"),
                ("iphone4-7.1.2", ["n90ap-11D257"], "n90ap"),
                ("ipod1g-1.1.4", ["n45ap-4A102"], "n45ap"),
                ("ipad-5.1.1", ["k48ap-9B206"], "k48ap"),
                ("several", ["n88ap-10B500", "n90ap-11D257", "k48ap-9B206"], "n90ap")
            ]
            for (name, selection, device) in picks {
                for appearance in [NSAppearance.Name.aqua, .darkAqua] {
                    (window, tables) = sheet(
                        experimental: true,
                        selection: selection,
                        device: device,
                        appearance: appearance
                    )
                    try render(window, "\(name)-\(appearance == .aqua ? "light" : "dark")")
                }
            }
            // Not key (another window is): the device list's selection gray.
            emphasized = false
            (window, tables) = sheet(experimental: true, selection: ["n90ap-11D257"], device: "n90ap")
            try render(window, "iphone4-7.1.2-inactive-light")
            (window, tables) = sheet(experimental: true, device: "k48ap", size: NSSize(width: 700, height: 500))
            try render(window, "ipad-minimum-inactive-light")
            emphasized = true
            if let devices = tables.first {
                window.makeFirstResponder(devices)
                devices.selectRowIndexes([0], byExtendingSelection: false)
                for c in "iphone 3" { devices.keyDown(with: key(String(c), 0, in: window)) }
                RunLoop.main.run(until: Date().addingTimeInterval(0.2))
                if devices.selectedRow != 6 { fail("type-select: row \(devices.selectedRow)") }
            }
            #expect(failures.isEmpty, "\(failures.joined(separator: "\n"))")
        }

        private func makeSheetAutosaveName(_ catalog: FirmwareCatalog) -> String {
            AddDeviceView(catalog: catalog, added: [], downloaded: [], onAdd: { _ in }, onCancel: {})
                .makeSheet().frameAutosaveName
        }

        /// A session replaced by another in the same phase (a restart that never shows as stopped) leaves every row
        /// as it was; the window is still told, so it never keeps the old session.
        @Test func aReplacedSessionReachesTheWindowWithNoRowChange() throws {
            _ = NSApplication.shared
            let catalog = try FirmwareCatalog.load(
                from: URL(fileURLWithPath: #filePath).deletingLastPathComponent()
                    .appendingPathComponent("../../../../LightTouchMac/Resources/firmware-catalog.json")
                    .standardizedFileURL
            )
            let suite = "ltm-check-sidebar-sessions-\(UUID().uuidString)"
            let defaults = UserDefaults(suiteName: suite)!
            defer { defaults.removePersistentDomain(forName: suite) }
            let host = DeviceSessionHost(catalog: catalog)
            host.prepared["n72ap-8C148"] = UUID()
            host.running = ["n72ap-8C148"]
            SidebarList(ids: ["n72ap-8C148"], names: [:]).save(defaults)
            let vc = DeviceLibraryViewController(host: host, defaults: defaults)
            let delegate = Delegate()
            vc.delegate = delegate
            _ = vc.view
            host.sessions = [DeviceSession()]  // the restart's new session, running like the old one
            NotificationCenter.default.post(name: DeviceSessionHost.didChangeNotification, object: host)
            #expect(delegate.sessionChanges == 1)
        }
    }
}

/// A key nothing handles ends at the window, which beeps; this window notes it instead, so a test that checks a key
/// does nothing stays quiet and can say the key went unhandled.
final class QuietWindow: NSWindow {
    var unhandled: [Selector] = []
    override func noResponder(for eventSelector: Selector) { unhandled.append(eventSelector) }
}
