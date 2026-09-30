#!/usr/bin/env python3
"""The Apps pane keeps its width whatever its message says, and Legacy Store's errors read plainly.

Compiles UI/PaneMessage.swift (the pane's message and caption) and CatalogClient.swift's CatalogError. Each
message sits in a pane pinned like the inspector's (16 pt margins, the split view holding the pane's width at
a lower priority than the content, 280-400 pt) with a Retry button under it, in a window never ordered front.
At 280, 320 and 400 pt, for empty, loading and error strings: the pane keeps its width, the message wraps
(nothing clipped or truncated) and stays inside the pane; the caption truncates instead of widening it.
A server error (HTTP 502) reads "Legacy Store isn’t responding. Try again in a moment.", no status code.
Renders <out>/pane-<width>-<n>.png (--out DIR).
"""
from pathlib import Path
import argparse, subprocess, tempfile

root = Path(__file__).resolve().parents[2]
app = root / 'LightTouchMac'
ap = argparse.ArgumentParser()
ap.add_argument('--out')
args = ap.parse_args()

client = (app / 'Features/CatalogClient.swift').read_text()
start = client.index('nonisolated enum CatalogError')
catalog_error = 'import Foundation\n' + client[start:client.index('\n}\n', start) + 3]

check = r'''
import Cocoa
@main struct Check {
    static func main() throws {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        let out = URL(fileURLWithPath: CommandLine.arguments[1])
        let server = CatalogError.badStatus(502).localizedDescription
        precondition(server == "Legacy Store isn’t responding. Try again in a moment.", server)
        for code in [404, 500, 0] {
            let text = CatalogError.badStatus(code).localizedDescription
            precondition(!text.contains("HTTP"), text)
        }
        let messages = ["No apps installed", "Waiting for the device…", server,
                        "Couldn’t reach Legacy Store — The Internet connection appears to be offline.",
                        "Couldn’t reach Legacy Store — A server with the specified hostname could not be found.",
                        "Legacy Store sent a response Light Touch couldn’t read."]
        var failures: [String] = []
        for width in [280.0, 320.0, 400.0] {
            for (n, text) in messages.enumerated() {
                let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: 360), styleMask: [.titled], backing: .buffered, defer: true)
                window.appearance = NSAppearance(named: .aqua)
                let pane = NSView()
                pane.translatesAutoresizingMaskIntoConstraints = false
                let host = NSView(frame: NSRect(x: 0, y: 0, width: 500, height: 360))
                window.contentView = host
                host.addSubview(pane)
                let message = NSTextField.paneMessage(), caption = NSTextField.paneCaption()
                let retry = NSButton(title: "Retry", target: nil, action: nil)
                retry.translatesAutoresizingMaskIntoConstraints = false
                message.stringValue = text
                caption.stringValue = text
                [message, caption, retry].forEach(pane.addSubview)
                let hold = pane.widthAnchor.constraint(equalToConstant: width)
                hold.priority = NSLayoutConstraint.Priority(490)   // NSSplitView's holding priority for an inspector
                NSLayoutConstraint.activate([
                    hold, pane.widthAnchor.constraint(greaterThanOrEqualToConstant: 280), pane.widthAnchor.constraint(lessThanOrEqualToConstant: 400),
                    pane.leadingAnchor.constraint(equalTo: host.leadingAnchor), pane.topAnchor.constraint(equalTo: host.topAnchor),
                    pane.bottomAnchor.constraint(equalTo: host.bottomAnchor),
                    caption.topAnchor.constraint(equalTo: pane.topAnchor, constant: 12),
                    caption.leadingAnchor.constraint(equalTo: pane.leadingAnchor, constant: 8),
                    caption.trailingAnchor.constraint(equalTo: pane.trailingAnchor, constant: -8),
                    message.centerXAnchor.constraint(equalTo: pane.centerXAnchor), message.centerYAnchor.constraint(equalTo: pane.centerYAnchor),
                    message.leadingAnchor.constraint(equalTo: pane.leadingAnchor, constant: 16),
                    message.trailingAnchor.constraint(equalTo: pane.trailingAnchor, constant: -16),
                    retry.topAnchor.constraint(equalTo: message.bottomAnchor, constant: 12), retry.centerXAnchor.constraint(equalTo: pane.centerXAnchor),
                ])
                host.layoutSubtreeIfNeeded()
                let name = "\(Int(width)) “\(text)”"
                if abs(pane.frame.width - width) > 0.5 { failures.append("\(name): the pane went \(pane.frame.width) wide") }
                for label in [message, caption] where !pane.bounds.contains(label.frame) { failures.append("\(name): \(label.frame) outside the pane") }
                let needed = message.cell!.cellSize(forBounds: NSRect(x: 0, y: 0, width: message.frame.width, height: 10_000))
                if needed.height > message.frame.height + 0.5 || needed.width > message.frame.width + 0.5 {
                    failures.append("\(name): the message needs \(needed), has \(message.frame.size)")
                }
                if retry.frame.minY < 0 || retry.frame.maxY > message.frame.minY { failures.append("\(name): Retry overlaps the message") }
                let rep = pane.bitmapImageRepForCachingDisplay(in: pane.bounds)!
                pane.cacheDisplay(in: pane.bounds, to: rep)
                try rep.representation(using: .png, properties: [:])!.write(to: out.appendingPathComponent("pane-\(Int(width))-\(n).png"))
            }
        }
        precondition(failures.isEmpty, failures.joined(separator: "\n"))
        print("PASS: the Apps pane keeps 280/320/400 pt with every message wrapped inside it; Legacy Store's server errors read plainly")
    }
}
'''

with tempfile.TemporaryDirectory(prefix='ltm-pane-message-') as tmp:
    tmp = Path(tmp)
    out = Path(args.out) if args.out else tmp / 'out'
    out.mkdir(parents=True, exist_ok=True)
    (tmp / 'error.swift').write_text(catalog_error)
    (tmp / 'main.swift').write_text(check)
    subprocess.run(['xcrun', 'swiftc', '-parse-as-library', '-swift-version', '5', '-module-cache-path', str(tmp / 'modules'),
                    str(app / 'UI/PaneMessage.swift'), str(tmp / 'error.swift'), str(tmp / 'main.swift'), '-o', str(tmp / 'check')], check=True)
    subprocess.run([str(tmp / 'check'), str(out)], check=True, timeout=60)
