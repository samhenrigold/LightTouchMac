import AppKit
import HostRuntime
import Testing

@testable import AppViews
@testable import LightTouchCore

/// The prepare screen's layout as the main window uses it: one DevicePlaceholderViewController, switched from device
/// to device and state to state (the longest preparation steps among them), in two window sizes. In every state no
/// view's layout is ambiguous, every line of text fits its label whole, and the Skip
/// Setup Assistant and Jailbreak checkboxes (two, one or none) share one leading edge, sit as a group centered under
/// the button row, and never overlap it. Import IPSW… shows wherever the row's Import IPSW… does (a device not
/// downloaded yet among them), just before the primary button on its row, the row centered. Each state is rendered to LTM_RENDER_DIR (else the temporary directory).
extension SharedState {
    @Suite struct PlaceholderLayoutTests {
        @Test func optionsStayAlignedAcrossSwitches() throws {
            _ = NSApplication.shared
            NSApp.setActivationPolicy(.prohibited)
            let catalog = try FirmwareCatalog.load(
                from: URL(fileURLWithPath: #filePath).deletingLastPathComponent()
                    .appendingPathComponent("../../../../LightTouchMac/Resources/firmware-catalog.json")
                    .standardizedFileURL
            )
            func entry(_ id: String) -> FirmwareCatalog.Entry { catalog.entry(id: id)! }
            let both = entry("n90ap-9B206")  // iOS 5: Skip Setup and Jailbreak
            let one = entry("k48ap-7B500")  // iOS 3.2.2: Jailbreak only
            let none = entry("m68ap-1A543a")  // iPhone OS 1.0: neither
            let prep = Preparation(step: 3, steps: 7, name: "Decrypting", fraction: 0.4)
            let id = UUID()
            // The longest step names (FirmwareKit's StepPlan.plans), which the headline shows whole.
            let longSteps = [
                "Writing the identity, NOR and boot files", "Building the system and data volumes",
                "Creating the data-protection keybag"
            ]
            .map { name in
                (
                    "preparing-" + name.split(separator: " ")[0].lowercased(),
                    DeviceRow(
                        entry: both,
                        instanceID: nil,
                        session: nil,
                        job: .preparing(Preparation(step: 4, steps: 7, name: name, fraction: 0.18))
                    )
                )
            }
            var states: [(String, DeviceRow)] = [
                ("two-options", DeviceRow(entry: both, instanceID: nil, session: nil, job: nil)),
                ("one-option", DeviceRow(entry: one, instanceID: nil, session: nil, job: nil, downloaded: true)),
                ("no-options", DeviceRow(entry: none, instanceID: nil, session: nil, job: nil)),
                ("two-options-again", DeviceRow(entry: both, instanceID: nil, session: nil, job: nil)),
                ("preparing", DeviceRow(entry: both, instanceID: nil, session: nil, job: .preparing(prep))),
                ("failed", DeviceRow(entry: both, instanceID: nil, session: nil, job: .failed("The restore failed."))),
                ("one-option-after-failed", DeviceRow(entry: one, instanceID: nil, session: nil, job: nil)),
                ("ready", DeviceRow(entry: one, instanceID: id, session: nil, job: nil)),
                ("two-options-last", DeviceRow(entry: both, instanceID: nil, session: nil, job: nil))
            ]
            states += longSteps
            let renders = URL(
                fileURLWithPath: ProcessInfo.processInfo.environment["LTM_RENDER_DIR"]
                    ?? FileManager.default.temporaryDirectory.path
            )
            var failures: [String] = []
            for size in [NSSize(width: 760, height: 640), NSSize(width: 520, height: 600)] {
                let vc = DevicePlaceholderViewController()
                var chosen: Set<String> = []
                let choice: (get: (String) -> Bool, set: (String, Bool) -> Void) = (
                    { chosen.contains($0) }, { id, on in if on { chosen.insert(id) } else { chosen.remove(id) } }
                )
                vc.skipsSetup = choice
                vc.jailbreaks = choice
                let window = NSWindow(
                    contentRect: NSRect(origin: .zero, size: size),
                    styleMask: [.titled],
                    backing: .buffered,
                    defer: true
                )
                window.appearance = NSAppearance(named: .aqua)
                window.contentView = vc.view
                let view = vc.view
                func all(_ v: NSView) -> [NSView] { v.subviews.flatMap { [$0] + all($0) } }
                func visible(_ v: NSView) -> Bool {
                    var p: NSView? = v
                    while let q = p {
                        if q.isHidden { return false }
                        p = q.superview
                    }
                    return true
                }
                func frame(_ v: NSView) -> NSRect {
                    view.convert(v.alignmentRect(forFrame: v.frame), from: v.superview)
                }
                for (name, row) in states {
                    let label = "\(name) \(Int(size.width))x\(Int(size.height))"
                    vc.update(row, canDownload: true)
                    view.layoutSubtreeIfNeeded()
                    // Rendered first: drawing lays the view out again, and what's checked is what's drawn.
                    if let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                        view.cacheDisplay(in: view.bounds, to: bitmap)
                        try bitmap.representation(using: .png, properties: [:])?.write(
                            to: renders.appendingPathComponent(
                                "placeholder-\(name)-\(Int(size.width))x\(Int(size.height)).png"
                            )
                        )
                    }
                    for v in all(view) where visible(v) && v.hasAmbiguousLayout {
                        failures.append("\(label): \(v) has ambiguous layout")
                    }
                    let boxes = all(view).compactMap { $0 as? NSButton }.filter {
                        visible($0) && ["Skip Setup Assistant", "Jailbreak"].contains($0.title)
                    }
                    let offered = [FirmwareJobs.offersSkipSetup(row.entry), true]
                    let want: Int
                    switch row.state {
                    case .notDownloaded, .downloaded: want = offered.filter { $0 }.count
                    default: want = 0
                    }
                    if boxes.count != want { failures.append("\(label): \(boxes.count) options, want \(want)") }
                    let buttons = all(view).compactMap { $0 as? NSButton }.filter {
                        visible($0) && $0.isBordered && $0.bezelStyle == .push && !boxes.contains($0)
                    }
                    // Every line of text is drawn centered (a label wider than its text draws it at its alignment);
                    // the version line is centered with its info button beside it.
                    for text in all(view).compactMap({ $0 as? NSTextField })
                    where visible(text) && !text.stringValue.isEmpty {
                        let f = frame(text)
                        // ...and whole: the text laid out at the label's width fits its frame.
                        let needed = text.cell!.cellSize(
                            forBounds: NSRect(x: 0, y: 0, width: text.frame.width, height: .greatestFiniteMagnitude)
                        )
                        if needed.width > text.frame.width + 0.5 || needed.height > text.frame.height + 0.5 {
                            failures.append(
                                "\(label): \(text.stringValue) needs \(needed), has \(text.frame.size)"
                            )
                        }
                        let width = min(f.width, text.attributedStringValue.size().width)
                        let x = text.alignment == .center ? f.midX : f.minX + width / 2
                        let slack: CGFloat = text.stringValue.hasPrefix("iOS ") && row.catalogNote != nil ? 14 : 1.5
                        if abs(x - view.bounds.midX) > slack {
                            failures.append(
                                "\(label): \(text.stringValue) drawn centered at \(x), view at \(view.bounds.midX)"
                            )
                        }
                    }
                    let importButton = buttons.first { $0.title == "Import IPSW…" }
                    let wantImport = row.allows(.importIPSW, canDownload: true) && row.primaryAction != .importIPSW
                    if (importButton != nil) != wantImport {
                        failures.append("\(label): Import IPSW… shown \(importButton != nil), want \(wantImport)")
                    }
                    if let importButton, let primary = buttons.first(where: { $0.title == row.primaryTitle }) {
                        let i = frame(importButton)
                        let p = frame(primary)
                        if abs(i.midY - p.midY) > 0.5 || i.maxX > p.minX || p.minX - i.maxX > 20 {
                            failures.append("\(label): Import IPSW… at \(i), not just before \(primary.title) at \(p)")
                        }
                        let row = buttons.map(frame).reduce(p) { $0.union($1) }
                        if abs(row.midX - view.bounds.midX) > 1 || !view.bounds.contains(row) {
                            failures.append("\(label): buttons at \(row), view \(view.bounds)")
                        }
                    }
                    if !boxes.isEmpty, let primary = buttons.first(where: { $0.title == row.primaryTitle }) {
                        let rects = boxes.map(frame)
                        let lead = rects.map(\.minX)
                        if (lead.max() ?? 0) - (lead.min() ?? 0) > 0.5 {
                            failures.append("\(label): options' leading edges \(lead)")
                        }
                        let group = rects.reduce(rects[0]) { $0.union($1) }
                        let row = buttons.map(frame).reduce(frame(primary)) { $0.union($1) }
                        if abs(group.midX - row.midX) > 1 || abs(group.midX - view.bounds.midX) > 1 {
                            failures.append(
                                "\(label): options centered at \(group.midX), buttons at \(row.midX), view at \(view.bounds.midX)"
                            )
                        }
                        if group.minY < row.maxY { failures.append("\(label): options overlap the buttons") }
                        for r in rects where !view.bounds.contains(r) {
                            failures.append("\(label): an option outside the view")
                        }
                    }
                }
            }
            #expect(failures.isEmpty, "\(failures.joined(separator: "\n"))")
        }
    }
}
