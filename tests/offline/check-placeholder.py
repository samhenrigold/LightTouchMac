#!/usr/bin/env python3
"""The prepare screen (DevicePlaceholderViewController) in every state, and its build-info popover.

Compiles the real view controller with the real catalog and DeviceRow, stubs for the app singletons it asks
(FirmwareJobs, IPSWStore, Bundled, DroppedFiles), and lays it out in a window that is never ordered front:
nothing appears on screen. Each state renders to <out>/placeholder-<state>.png (--out DIR, default a temp dir).

Checks: the name, version and state lines stack in that order in one column; the buttons share one row with the
default button last (Device Logs to its left); no label is clipped; every state shows a state line. The info
popover (ⓘ) has a real size (RC1's was 0×0 and showed nothing) and shows the support status and its
explanation, the source note and the release date for experimental, untested, beta and paid-update builds.
"""
from pathlib import Path
from firmwarekit_leaf import schema_sources
import argparse, subprocess, tempfile

root = Path(__file__).resolve().parents[2]
app = root / 'LightTouchMac'
ap = argparse.ArgumentParser()
ap.add_argument('--out')
args = ap.parse_args()

stubs = r'''
import Cocoa
final class FirmwareJobs { static let shared = FirmwareJobs(); var unavailableReason: String? = nil; var canDownload = true }
enum IPSWStore { static func availableSpace(at url: URL) throws -> Int64 { 1 << 40 } }
enum Bundled { static let stateDirectory = URL(fileURLWithPath: NSTemporaryDirectory()) }
enum DroppedFiles { case ipsw; static func files(_ urls: [URL], _ kind: DroppedFiles) -> [URL] { urls } }
'''

check = r'''
import Cocoa
@main struct Check {
    static func main() throws {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        let args = CommandLine.arguments
        let catalog = try FirmwareCatalog.load(from: URL(fileURLWithPath: args[1]))
        let out = URL(fileURLWithPath: args[2])
        func entry(_ id: String) -> FirmwareCatalog.Entry { catalog.entry(id: id)! }
        let id = UUID()
        let beta = entry("k48ap-9A5220p"), ipad = entry("k48ap-7B500"), ipod = entry("n72ap-7E18")
        var prep = Preparation(step: 3, steps: 7, name: "Decrypting", fraction: 0.4)
        prep.remaining = 95
        let unsupported = "Light Touch can’t prepare this beta yet: its graphics library isn’t supported."
        let states: [(String, DeviceRow)] = [
            ("not-downloaded", DeviceRow(entry: beta, instanceID: nil, session: nil, job: nil, failure: nil)),
            ("downloaded", DeviceRow(entry: ipad, instanceID: nil, session: nil, job: nil, failure: nil, downloaded: true)),
            ("downloading", DeviceRow(entry: beta, instanceID: nil, session: nil, job: .downloading(fraction: 0.43, remaining: 70), failure: nil)),
            ("preparing", DeviceRow(entry: beta, instanceID: nil, session: nil, job: .preparing(prep), failure: nil)),
            ("error", DeviceRow(entry: beta, instanceID: nil, session: nil, job: .failed(unsupported), failure: nil)),
            ("ready", DeviceRow(entry: ipad, instanceID: id, session: nil, job: nil, failure: nil)),
            ("stopped", DeviceRow(entry: ipad, instanceID: id, session: .dead("The iPad stopped unexpectedly. Open Device Logs for details."), job: nil, failure: nil)),
            ("requires-ipsw", DeviceRow(entry: ipod, instanceID: nil, session: nil, job: nil, failure: nil)),
        ]
        var failures: [String] = []
        for (name, row) in states {
            let vc = DevicePlaceholderViewController()
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 640), styleMask: [.titled], backing: .buffered, defer: true)
            window.appearance = NSAppearance(named: .aqua)
            window.contentView = vc.view
            vc.update(row, canDownload: true)
            vc.view.layoutSubtreeIfNeeded()
            let view = vc.view
            let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds)!
            view.cacheDisplay(in: view.bounds, to: rep)
            try rep.representation(using: .png, properties: [:])!.write(to: out.appendingPathComponent("placeholder-\(name).png"))

            func all(_ v: NSView) -> [NSView] { v.subviews.flatMap { [$0] + all($0) } }
            func visible(_ v: NSView) -> Bool { var p: NSView? = v; while let q = p { if q.isHidden { return false }; p = q.superview }; return v.window != nil }
            func frame(_ v: NSView) -> NSRect { v.convert(v.alignmentRect(forFrame: v.frame).offsetBy(dx: -v.frame.minX, dy: -v.frame.minY), to: view) }
            let labels = all(view).compactMap { $0 as? NSTextField }.filter { visible($0) && !$0.stringValue.isEmpty }
            let buttons = all(view).compactMap { $0 as? NSButton }.filter { visible($0) && $0.isBordered }
            func fail(_ s: String) { failures.append("\(name): \(s)") }
            for l in labels {
                let f = frame(l)
                if !view.bounds.contains(f) { fail("\(l.stringValue) outside the view") }
                if l.maximumNumberOfLines != 0 || l.cell?.wraps == false, l.intrinsicContentSize.width > l.frame.width + 0.5 { fail("\(l.stringValue) clipped") }
            }
            // Top to bottom: name, version, state.
            let texts = labels.sorted { frame($0).midY > frame($1).midY }.map(\.stringValue)
            guard let n = texts.firstIndex(of: row.entry.profile!.marketingName), let v = texts.firstIndex(where: { $0.hasPrefix("iOS ") }) else {
                fail("no name or version: \(texts)"); continue
            }
            if !(n < v && v + 1 < texts.count) { fail("order: \(texts)") }
            if texts.count < 3 { fail("no state line: \(texts)") }
            if let primary = row.primaryTitle {
                guard let p = buttons.first(where: { $0.title == primary }) else { fail("no \(primary)"); continue }
                for b in buttons where b !== p {
                    if abs(frame(b).midY - frame(p).midY) > 0.5 { fail("\(b.title) not on \(primary)'s row") }
                    if frame(b).maxX > frame(p).minX { fail("\(b.title) after the default button") }
                    if abs(frame(b).height - frame(p).height) > 0.5 { fail("\(b.title) and \(primary) differ in size") }
                }
                if p.keyEquivalent == "\r" && row.primaryAction == .cancel { fail("Return cancels") }
            }
            if row.isError && !buttons.contains(where: { $0.title == "Device Logs" }) { fail("an error without Device Logs") }
        }

        // The ⓘ popover: a real size and the build's words, for experimental, untested and beta builds.
        for e in [entry("k48ap-7B405"), entry("n45ap-3B48b"), beta, entry("n72ap-8C5091e"), entry("n72ap-7E18")] {
            let row = DeviceRow(entry: e, instanceID: nil, session: nil, job: nil, failure: nil)
            guard let content = DevicePlaceholderViewController.infoContent(for: row) else { failures.append("\(e.id): no popover"); continue }
            let size = content.preferredContentSize
            content.view.layoutSubtreeIfNeeded()
            let words = content.view.subviews.compactMap { $0 as? NSTextField }.filter { !$0.stringValue.isEmpty && $0.frame.width > 20 && $0.frame.height > 8 }
            let text = words.map(\.stringValue).joined(separator: "\n")
            if size.width < 100 || size.height < 40 || content.view.frame.size != size { failures.append("\(e.id): popover size \(size), view \(content.view.frame.size)") }
            if let tag = row.supportNote, !words.contains(where: { $0.stringValue == tag }) || !text.contains(row.supportExplanation ?? "?") {
                failures.append("\(e.id): no \(tag) and its explanation: \(text)")
            }
            if !text.contains("Released ") { failures.append("\(e.id): no release date: \(text)") }
            if let note = e.statusNote, !text.contains(note) { failures.append("\(e.id): no source note: \(text)") }
            for w in words where !content.view.bounds.contains(w.frame) { failures.append("\(e.id): \(w.stringValue) outside the popover") }
            let rep = content.view.bitmapImageRepForCachingDisplay(in: content.view.bounds)!
            content.view.cacheDisplay(in: content.view.bounds, to: rep)
            try rep.representation(using: .png, properties: [:])!.write(to: out.appendingPathComponent("popover-\(e.id).png"))
        }
        precondition(failures.isEmpty, failures.joined(separator: "\n"))
        print("PASS: the prepare screen in every state (name, version, state; one button row) and the build popover's words")
    }
}
'''

with tempfile.TemporaryDirectory(prefix='ltm-placeholder-') as tmp:
    tmp = Path(tmp)
    out = Path(args.out) if args.out else tmp / 'out'
    out.mkdir(parents=True, exist_ok=True)
    source = (app / 'UI/DevicePlaceholderViewController.swift').read_text()
    art = 'NSImage(named: $0.shellImageName)'
    assert art in source, 'the art lookup moved: update this check'
    assets = app / 'Assets.xcassets'
    (tmp / 'placeholder.swift').write_text(source.replace(art, f'NSImage(contentsOfFile: "{assets}/" + $0.shellImageName + ".imageset/" + ($0.shellImageName == "shell" ? "shell_opaque.png" : "ipad-frame.png"))'))
    (tmp / 'stubs.swift').write_text(stubs)
    (tmp / 'main.swift').write_text(check)
    subprocess.run(['xcrun', 'swiftc', *schema_sources(), '-parse-as-library', '-swift-version', '5', '-module-cache-path', str(tmp / 'modules'),
                    str(app / 'Library/FirmwareCatalog.swift'), str(app / 'Device/DeviceProfile.swift'),
                    str(app / 'Device/DeviceProfile+Display.swift'), str(app / 'Device/DeviceRow.swift'),
                    str(tmp / 'placeholder.swift'), str(tmp / 'stubs.swift'), str(tmp / 'main.swift'), '-o', str(tmp / 'check')], check=True)
    subprocess.run([str(tmp / 'check'), str(app / 'Resources/firmware-catalog.json'), str(out)], check=True, timeout=60)
