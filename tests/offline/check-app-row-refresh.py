#!/usr/bin/env python3
"""Native row identity survives unchanged polls and another app's progress."""
from pathlib import Path
import subprocess, tempfile
root = Path(__file__).resolve().parents[2]
source = (root / 'LightTouchMac/AppsInspectorViewController.swift').read_text()
a = source.index('    private struct RowAppearance:')
b = source.index('    /// Capture only values', a)
appearance = source[a:b]
a = source.index('    private func reloadTablePreservingSelection()')
b = source.index('\n    @objc private func appsChanged(', a)
reload = source[a:b]
code = r'''import Cocoa
@MainActor final class Fixture: NSObject, NSTableViewDataSource, NSTableViewDelegate {
 let tableView = NSTableView()
 var rowIdentities = ["one", "two", "three"]
 var displayedRows: [String] = []
''' + appearance + r'''
 private var rowAppearances = [
  RowAppearance(title: "One", subtitle: "Ready"),
  RowAppearance(title: "Two", subtitle: "Ready"),
  RowAppearance(title: "Three", subtitle: "Ready")
 ]
''' + reload + r'''
 func numberOfRows(in tableView: NSTableView) -> Int { rowIdentities.count }
 func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
  NSButton(title: rowAppearances[row].title, target: nil, action: nil)
 }
 static func run() {
  let fixture = Fixture()
  let table = fixture.tableView
  table.dataSource = fixture; table.delegate = fixture; table.rowHeight = 30
  table.addTableColumn(NSTableColumn(identifier: .init("app")))
  let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 320, height: 240),
                        styleMask: [.titled], backing: .buffered, defer: false)
  let scroll = NSScrollView(); scroll.documentView = table
  window.contentView = scroll
  fixture.reloadTablePreservingSelection()
  scroll.layoutSubtreeIfNeeded()
  let first = table.view(atColumn: 0, row: 0, makeIfNecessary: true)!
  let second = table.view(atColumn: 0, row: 1, makeIfNecessary: true)!
  table.selectRowIndexes([1], byExtendingSelection: false)
  // Several polls with identical data must preserve live control objects.
  for _ in 0..<5 { fixture.reloadTablePreservingSelection() }
  precondition(table.view(atColumn: 0, row: 0, makeIfNecessary: true) === first)
  precondition(table.view(atColumn: 0, row: 1, makeIfNecessary: true) === second)
  fixture.rowAppearances[0].subtitle = "Downloading… 50%"
  fixture.reloadTablePreservingSelection()
  precondition(table.view(atColumn: 0, row: 0, makeIfNecessary: true) !== first)
  precondition(table.view(atColumn: 0, row: 1, makeIfNecessary: true) === second,
               "Another app's progress must preserve this row's button/AX element")
  precondition(table.selectedRowIndexes == [1])
  let last = fixture.rowAppearances.removeLast()
  fixture.rowAppearances.insert(last, at: 0)
  fixture.rowIdentities = ["three", "one", "two"]
  fixture.reloadTablePreservingSelection()
  precondition(table.selectedRowIndexes == [2], "Selection follows the app across a reorder")
  print("PASS: native row controls persist through unchanged polls and unrelated progress; reordered selection stays with app")
 }
}
@main struct Check { @MainActor static func main() { _ = NSApplication.shared; Fixture.run() } }
'''
with tempfile.TemporaryDirectory(prefix='ltm-row-refresh-') as directory:
    work = Path(directory)
    (work / 'check.swift').write_text(code)
    subprocess.run(['xcrun', 'swiftc', '-parse-as-library', '-swift-version', '6', '-default-isolation', 'MainActor',
                    '-module-cache-path', str(work / 'modules'), str(work / 'check.swift'), '-o', str(work / 'check')], check=True)
    subprocess.run([str(work / 'check')], check=True, timeout=20)
