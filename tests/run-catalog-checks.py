#!/usr/bin/env python3
"""Run catalog, ready-queue, boundary and optional native AppKit checks. No QEMU."""
from pathlib import Path
import os, subprocess, sys, tempfile, time
root = Path(__file__).resolve().parents[1]
def run(args, **kwargs):
    subprocess.run(args, cwd=root, check=True, **kwargs)
with tempfile.TemporaryDirectory(prefix='ltm-checks-') as work:
    work = Path(work)
    env = dict(os.environ, CFFIXED_USER_HOME=str(work/'home'), LTM_STATE_DIR=str(work/'state'))
    (work/'home').mkdir()
    portfile = work/'port'
    server = subprocess.Popen([sys.executable, str(root/'tests/catalog-server.py'), str(portfile)])
    try:
        for _ in range(100):
            if portfile.exists(): break
            if server.poll() is not None: raise RuntimeError('fixture server exited')
            time.sleep(.02)
        port = portfile.read_text()
        def swift(name, sources, arguments=()):
            exe=work/name
            run(['swiftc','-parse-as-library','-module-cache-path',str(work/'modules'), *sources,'-o',str(exe)])
            run([str(exe),*arguments], env=env, timeout=30)
        common = ['LightTouchMac/'+f+'.swift' for f in ['CatalogClient','CatalogCopy','Bundled','AppEventLog']]
        if '--ui-only' not in sys.argv:
            swift('catalog',common+['LightTouchMac/IPALibrary.swift','tests/catalog.swift'])
            swift('network',common+['tests/catalog-network.swift'],[port])
            swift('queue',['LightTouchMac/InstallationQueue.swift','tests/installation-queue.swift'])
            run([sys.executable,'tests/check-extracted.py'])
            run([sys.executable,'tests/check-upload.py'])
            run([sys.executable,'tests/check-rotation.py'])
        if '--ui' in sys.argv or '--ui-only' in sys.argv:
            run([sys.executable,'tests/check-files-ui.py'])
            source=(root/'LightTouchMac/AppsInspectorViewController.swift').read_text()
            start=source.index('    private enum RowIdentity:')
            end=source.index('    @objc private func appsChanged()',start)
            rows=source[start:end]
            def method(signature):
                start = source.index(signature)
                return source[start:source.index("\n    }", start)+6]
            modes = "\n".join(method(signature) for signature in (
                "    private func setMode(", "    private func scheduleSearch(",
                "    private func showPlaceholder(", "    private func showInstalledPlaceholder(",
                "    private var installedPlaceholderText:", "    private func updateButtons("))
            fixture=work/'selection.swift'
            fixture.write_text('''import Cocoa
@MainActor final class SelectionCheck: NSObject, NSTableViewDataSource {
 let tableView = NSTableView()
 enum PaneMode: Int { case installed, store }
 var mode: PaneMode = .installed
 var searching: Bool { get { mode == .store } set { mode = newValue ? .store : .installed } }
 let modeControl = NSSegmentedControl(), searchField = NSSearchField()
 let placeholder = NSTextField(labelWithString: ""), addRemove = NSSegmentedControl()
 var searchTask: Task<Void, Never>?
 var haveLoaded = true, busyWithDevice = false
 final class Emulator { var canReachDevice = true, canQueueInstall = true }
 let emulator = Emulator()
 var selectedApps: [App] { searching ? [] : tableView.selectedRowIndexes.compactMap { visibleApps.indices.contains($0) ? visibleApps[$0] : nil } }
 var apps: [App] { visibleApps }
 func updateFooterVisibility() {}
 func fetchCatalogIcons(_ results: [CatalogApp]) {}
 final class Job {}
 struct App { let id: String }
 static func catalog(_ id: Int) -> CatalogApp {
  CatalogApp(bundleID:nil,name:"Fixture",developer:nil,version:nil,minOS:nil,size:nil,
             ipaID:id,iconURL:nil,downloadURL:URL(string:"https://example.invalid/app.ipa")!,appURL:nil)
 }
 var pending: [Job] = [], visibleApps: [App] = [], catalogResults: [CatalogApp] = []
 func numberOfRows(in tableView: NSTableView) -> Int { rowIdentities.count }
''' + rows + modes + '''
 static func run() {
  let c = SelectionCheck()
  c.tableView.addTableColumn(NSTableColumn(identifier: .init("name")))
  c.tableView.dataSource = c
  c.addRemove.segmentCount = 2
  c.modeControl.segmentCount = 2
  let large = Job(), small = Job()
  c.pending = [large, small]; c.visibleApps = [App(id: "installed")]
  c.reloadTablePreservingSelection()
  c.tableView.selectRowIndexes([0], byExtendingSelection: false)
  for _ in 0..<100 { c.tableView.reloadData(forRowIndexes: [0], columnIndexes: [0]) }
  precondition(c.tableView.selectedRow == 0)
  c.tableView.selectRowIndexes([2], byExtendingSelection: false)
  c.pending.removeFirst(); c.reloadTablePreservingSelection()
  precondition(c.tableView.selectedRow == 1)
  c.pending = []; c.reloadTablePreservingSelection()
  precondition(c.tableView.selectedRow == 0)
  c.searching = true; c.catalogResults = [catalog(1), catalog(2)]
  c.reloadTablePreservingSelection(); c.tableView.selectRowIndexes([1], byExtendingSelection: false)
  c.catalogResults.reverse(); c.reloadTablePreservingSelection()
  precondition(c.tableView.selectedRow == 0)
  // An Installed overlay cannot survive switching to cached Store rows,
  // including during the existing query debounce. Check before any task runs.
  c.visibleApps = []; c.pending = []; c.setMode(.installed)
  precondition(!c.placeholder.isHidden)
  c.setMode(.store)
  precondition(c.placeholder.isHidden && c.tableView.selectedRow == -1)
  c.showInstalledPlaceholder("late Installed failure")
  precondition(c.placeholder.isHidden)
  c.setMode(.installed); c.searchField.stringValue = "query"
  c.setMode(.store); precondition(c.placeholder.isHidden)
  c.catalogResults = []; c.scheduleSearch()
  precondition(c.placeholder.stringValue == "Searching Legacy Store…" && !c.placeholder.isHidden)
  c.searchField.stringValue = ""; c.scheduleSearch()
  precondition(c.placeholder.stringValue == "Loading Legacy Store…")
  let outstanding = c.searchTask
  c.setMode(.installed)
  precondition(outstanding?.isCancelled == true)
  precondition(c.placeholder.stringValue == "No third-party apps installed.")
  c.visibleApps = [App(id:"installed")]; c.reloadTablePreservingSelection()
  c.tableView.selectRowIndexes([0], byExtendingSelection:false)
  c.updateButtons(); precondition(c.addRemove.isEnabled(forSegment:1))
  c.emulator.canReachDevice = false; c.updateButtons()
  precondition(!c.addRemove.isEnabled(forSegment:1))
  c.searchTask?.cancel()
  print("PASS: immediate mode overlays, late Installed failure isolation, Store cancellation and unreachable-device controls")
  print("PASS: native table selection survives 100 progress updates, removed jobs and reordered catalog results")
 }
}
''')
            swift('ui',common+['LightTouchMac/CatalogDetailsViewController.swift',str(fixture),'tests/catalog-ui.swift'],[port])
    finally:
        server.terminate(); server.wait(timeout=5)
