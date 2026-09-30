#!/usr/bin/env python3
"""The sidebar (DeviceLibraryViewController) and the Add Device sheet (AddDeviceView), rendered offscreen.

Compiles the real view controller and sheet with the real catalog, SidebarList and DeviceRow, and stubs for the
app singletons they ask (DeviceSessionHost, FirmwareJobs, the sessions). Everything lays out in windows that are
never ordered front: nothing appears on screen. PNGs land in --out (default a temp dir):
sidebar-{one-kind,mixed,renamed,empty}.png and add-device.png.

Checks what the user sees, from the rendered cells: one kind of device titles rows by version; mixed kinds show
the product name over the version; a custom name shows over "iPad, iOS 3.2.2". Renaming in place (the context
menu's Rename, typing, ending the edit) saves the name to defaults; Delete on a row with nothing on disk removes
it (saved), on a prepared one it asks the delegate to delete instead; an empty sidebar shows Add Device…. A
download starting for an entry not in the list adds it. The sheet lists every catalog entry once.
"""
from pathlib import Path
import argparse, subprocess, tempfile

app = Path(__file__).resolve().parents[2] / 'LightTouchMac'
ap = argparse.ArgumentParser()
ap.add_argument('--out')
args = ap.parse_args()

stubs = r'''
import Cocoa
final class FirmwareJobs {
    static let shared = FirmwareJobs()
    static let didChangeNotification = Notification.Name("FirmwareJobsDidChange")
    var jobs: [String: FirmwareJob] = [:] { didSet { NotificationCenter.default.post(name: Self.didChangeNotification, object: self) } }
}
struct StubInstance { let firmware: String }
final class DeviceLibrary {
    static let didChangeNotification = Notification.Name("DeviceLibraryDidChange")
    var instances: [StubInstance] = []
}
final class EmulatorController { var canQueueInstall = false }
final class DeviceSession {
    static let didChangeNotification = Notification.Name("DeviceSessionDidChange")
    let emulator = EmulatorController()
}
nonisolated enum PreparedMedia { static let extensions: Set<String> = [] }
enum AppInstaller { static func start(_ url: URL, with emulator: EmulatorController, presenting: NSWindow?) {} }
final class DeviceSessionHost {
    static let didChangeNotification = Notification.Name("DeviceSessionHostDidChange")
    let catalog: FirmwareCatalog
    let library = DeviceLibrary()
    var prepared: [String: UUID] = [:]
    var downloaded: Set<String> = []
    init(catalog: FirmwareCatalog) { self.catalog = catalog }
    func instance(for entry: FirmwareCatalog.Entry) -> StubInstance? { prepared[entry.id].map { _ in StubInstance(firmware: entry.id) } }
    func session(for entry: FirmwareCatalog.Entry) -> DeviceSession? { nil }
    func row(for entry: FirmwareCatalog.Entry) -> DeviceRow {
        DeviceRow(entry: entry, instanceID: prepared[entry.id], session: nil, job: FirmwareJobs.shared.jobs[entry.id],
                  failure: nil, downloaded: downloaded.contains(entry.id))
    }
}
'''

check = r'''
import Cocoa
import SwiftUI

final class Delegate: DeviceLibraryDelegate {
    var deletes: [String] = []
    func library(_ library: DeviceLibraryViewController, didSelect entry: FirmwareCatalog.Entry?) {}
    func libraryRowsDidChange(_ library: DeviceLibraryViewController) {}
    func library(_ library: DeviceLibraryViewController, canPerform action: DeviceAction, for entry: FirmwareCatalog.Entry) -> Bool { true }
    func library(_ library: DeviceLibraryViewController, perform action: DeviceAction, for entry: FirmwareCatalog.Entry) {
        if action == .delete { deletes.append(entry.id) }
    }
    func library(_ library: DeviceLibraryViewController, importIPSW url: URL, for entry: FirmwareCatalog.Entry?) {}
}

@main struct Check {
    static func main() throws {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        let args = CommandLine.arguments
        let catalog = try FirmwareCatalog.load(from: URL(fileURLWithPath: args[1]))
        let out = URL(fileURLWithPath: args[2])
        let suite = "ltm-check-sidebar-ui-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        var failures: [String] = []
        func fail(_ s: String) { failures.append(s) }

        func all(_ v: NSView) -> [NSView] { v.subviews.flatMap { [$0] + all($0) } }
        func visible(_ v: NSView) -> Bool { var p: NSView? = v; while let q = p { if q.isHidden { return false }; p = q.superview }; return true }
        func render(_ view: NSView, _ name: String) throws {
            view.layoutSubtreeIfNeeded()
            view.displayIfNeeded()
            let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds)!
            view.cacheDisplay(in: view.bounds, to: rep)
            try rep.representation(using: .png, properties: [:])!.write(to: out.appendingPathComponent(name + ".png"))
        }
        func window(_ size: NSSize) -> NSWindow {
            let w = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled], backing: .buffered, defer: false)
            w.appearance = NSAppearance(named: .aqua)
            return w
        }
        /// Each visible row's texts, top to bottom then leading to trailing: [title, badge?, subtitle?].
        func rows(_ vc: DeviceLibraryViewController) -> [[String]] {
            let outline = all(vc.view).compactMap { $0 as? NSOutlineView }.first!
            return (0..<outline.numberOfRows).map { r in
                let cell = outline.view(atColumn: 0, row: r, makeIfNecessary: true)!
                func top(_ f: NSTextField) -> CGFloat {
                    let rect = f.convert(f.bounds, to: cell)
                    return cell.isFlipped ? rect.minY : -rect.maxY
                }
                func before(_ a: NSTextField, _ b: NSTextField) -> Bool {
                    abs(top(a) - top(b)) > 4 ? top(a) < top(b) : a.convert(a.bounds, to: cell).minX < b.convert(b.bounds, to: cell).minX
                }
                let fields: [NSTextField] = all(cell).compactMap { $0 as? NSTextField }.filter { visible($0) && !$0.stringValue.isEmpty }
                return fields.sorted(by: before).map(\.stringValue)
            }
        }
        func sidebar(_ ids: [String], names: [String: String] = [:], host: DeviceSessionHost) -> (DeviceLibraryViewController, NSWindow) {
            SidebarList(ids: ids, names: names).save(defaults)
            let vc = DeviceLibraryViewController(host: host, defaults: defaults)
            let w = window(NSSize(width: 240, height: 260))
            w.contentView = vc.view
            vc.view.layoutSubtreeIfNeeded()
            return (vc, w)
        }

        // One kind: versions, with the beta's tag.
        let host = DeviceSessionHost(catalog: catalog)
        host.prepared["n72ap-8C148"] = UUID()
        host.downloaded = ["n72ap-8B117"]
        var (vc, w) = sidebar(["n72ap-8C148", "n72ap-8B5080c", "n72ap-8B117", "n72ap-7E18"], host: host)
        var seen = rows(vc)
        if seen != [["iOS 3.1.3", "Requires an IPSW"], ["iOS 4.1", "Beta 1"], ["iOS 4.1"], ["iOS 4.2.1"]] { fail("one kind: \(seen)") }
        try render(vc.view, "sidebar-one-kind")

        // Mixed: product names over versions.
        (vc, w) = sidebar(["n72ap-8C148", "k48ap-7B500", "n72ap-8B5080c"], host: host)
        seen = rows(vc)
        if seen != [["iPad", "iOS 3.2.2"], ["iPod touch (2nd generation)", "iOS 4.1 Beta 1"], ["iPod touch (2nd generation)", "iOS 4.2.1"]] { fail("mixed: \(seen)") }
        try render(vc.view, "sidebar-mixed")

        // Rename in place through the context menu's Rename: the title turns into a field; ending the edit saves.
        vc.select(catalog.entry(id: "k48ap-7B500")!)
        vc.perform(NSSelectorFromString("renameFromMenu:"), with: nil)
        guard let editor = w.firstResponder as? NSTextView, let field = editor.delegate as? NSTextField, field.isEditable else {
            fail("Rename didn't start an edit: \(String(describing: w.firstResponder))"); precondition(failures.isEmpty, failures.joined(separator: "\n")); return
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
        // Offscreen, a selected source-list row draws its material black: render unselected.
        all(vc.view).compactMap { $0 as? NSOutlineView }.first!.deselectAll(nil)
        try render(vc.view, "sidebar-renamed")

        // Delete: a prepared row asks through the delegate's delete and stays until it's done; the others go at once.
        let delegate = Delegate()
        vc.delegate = delegate
        let outline = all(vc.view).compactMap { $0 as? NSOutlineView }.first!
        let delete = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: w.windowNumber,
                                      context: nil, characters: "\u{7f}", charactersIgnoringModifiers: "\u{7f}", isARepeat: false, keyCode: 51)!
        vc.select(catalog.entry(id: "n72ap-8C148")!)
        outline.keyDown(with: delete)
        if delegate.deletes != ["n72ap-8C148"] || !vc.entries.contains(where: { $0.id == "n72ap-8C148" }) { fail("prepared delete: \(delegate.deletes)") }
        vc.select(catalog.entry(id: "n72ap-8B5080c")!)
        outline.keyDown(with: delete)
        if vc.entries.contains(where: { $0.id == "n72ap-8B5080c" }) || defaults.stringArray(forKey: SidebarList.entriesKey)?.contains("n72ap-8B5080c") != false {
            fail("Delete didn't remove an unprepared row")
        }
        // A download started elsewhere (an IPSW dropped on the empty area) brings its entry in.
        FirmwareJobs.shared.jobs["n72ap-8B117"] = .downloading(fraction: 0.2)
        if !vc.entries.contains(where: { $0.id == "n72ap-8B117" }) { fail("a job's entry didn't join the sidebar") }
        FirmwareJobs.shared.jobs = [:]

        // Empty: the sidebar's own Add Device….
        (vc, w) = sidebar([], host: DeviceSessionHost(catalog: catalog))
        let add = all(vc.view).compactMap { $0 as? NSButton }.filter { visible($0) && $0.title == "Add Device…" }
        if add.count != 1 { fail("empty sidebar: no Add Device…") }
        var added = false
        vc.onAdd = { added = true }
        add.first?.performClick(nil)
        if !added { fail("empty sidebar's Add Device… does nothing") }
        try render(vc.view, "sidebar-empty")

        // The sheet: every entry once, grouped by device.
        let sheet = AddDeviceView(catalog: catalog, added: ["k48ap-7B500", "n72ap-8C148"], downloaded: ["n72ap-8B117", "k48ap-7B500", "n72ap-8C148"],
                                  selection: ["n72ap-8B117"], onAdd: { _ in }, onCancel: {})
        if sheet.groups.flatMap(\.entries).map(\.id) != catalog.entries.map(\.id) { fail("the sheet's entries aren't the catalog's, in its order") }
        if sheet.groups.map(\.name) != ["iPad", "iPod touch", "iPod touch (2nd generation)"] { fail("sheet groups: \(sheet.groups.map(\.name))") }
        try renderSheet(sheet, "add-device")
        // The iPod touch (2nd generation) part, which a 480-point sheet shows after scrolling.
        var ipod = catalog
        ipod.entries = catalog.entries.filter { $0.board == "n72ap" }
        try renderSheet(AddDeviceView(catalog: ipod, added: ["n72ap-8C148"], downloaded: ["n72ap-8B117", "n72ap-8C148", "n72ap-7E18"],
                                      selection: ["n72ap-8B117"], onAdd: { _ in }, onCancel: {}), "add-device-ipod")
        func renderSheet(_ view: AddDeviceView, _ name: String) throws {
            let hosting = NSHostingView(rootView: view)
            let sw = window(NSSize(width: 440, height: 480))
            sw.contentView = hosting
            try render(hosting, name)
        }

        precondition(failures.isEmpty, failures.joined(separator: "\n"))
        print("PASS: sidebar titles (one kind, mixed, renamed), rename saves, Delete removes or asks, empty Add Device…, the Add Device sheet")
    }
}
'''

with tempfile.TemporaryDirectory(prefix='ltm-sidebar-ui-') as tmp:
    tmp = Path(tmp)
    out = Path(args.out) if args.out else tmp / 'out'
    out.mkdir(parents=True, exist_ok=True)
    (tmp / 'stubs.swift').write_text(stubs)
    (tmp / 'main.swift').write_text(check)
    subprocess.run(['xcrun', 'swiftc', '-parse-as-library', '-swift-version', '5', '-default-isolation', 'MainActor',
                    '-module-cache-path', str(tmp / 'modules'),
                    str(app / 'Library/FirmwareCatalog.swift'), str(app / 'Device/DeviceProfile.swift'),
                    str(app / 'Device/DeviceRow.swift'), str(app / 'Library/SidebarList.swift'),
                    str(app / 'UI/DroppedFiles.swift'), str(app / 'UI/DeviceLibraryViewController.swift'),
                    str(app / 'UI/AddDeviceView.swift'), str(tmp / 'stubs.swift'), str(tmp / 'main.swift'),
                    '-o', str(tmp / 'check')], check=True)
    subprocess.run([str(tmp / 'check'), str(app / 'Resources/firmware-catalog.json'), str(out)], check=True, timeout=60)
