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
        swift('catalog',common+['LightTouchMac/IPALibrary.swift','tests/catalog.swift'])
        swift('network',common+['tests/catalog-network.swift'],[port])
        swift('queue',['LightTouchMac/InstallationQueue.swift','tests/installation-queue.swift'])
        run([sys.executable,'tests/check-extracted.py'])
        run([sys.executable,'tests/check-upload.py'])
        run([sys.executable,'tests/check-rotation.py'])
        if '--ui' in sys.argv:
            source=(root/'LightTouchMac/AppsInspectorViewController.swift').read_text()
            start=source.index('    private enum RowIdentity:')
            end=source.index('    @objc private func appsChanged()',start)
            rows=source[start:end]
            fixture=work/'selection.swift'
            fixture.write_text('''import Cocoa
@MainActor final class SelectionCheck: NSObject, NSTableViewDataSource {
 let tableView = NSTableView()
 var searching = false
 final class Job {}
 struct App { let id: String }
 struct Catalog { let ipaID: Int }
 var pending: [Job] = [], visibleApps: [App] = [], catalogResults: [Catalog] = []
 func numberOfRows(in tableView: NSTableView) -> Int { rowIdentities.count }
''' + rows + '''
 static func run() {
  let c = SelectionCheck()
  c.tableView.addTableColumn(NSTableColumn(identifier: .init("name")))
  c.tableView.dataSource = c
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
  c.searching = true; c.catalogResults = [Catalog(ipaID: 1), Catalog(ipaID: 2)]
  c.reloadTablePreservingSelection(); c.tableView.selectRowIndexes([1], byExtendingSelection: false)
  c.catalogResults.reverse(); c.reloadTablePreservingSelection()
  precondition(c.tableView.selectedRow == 0)
  print("PASS: native table selection survives 100 progress updates, removed jobs and reordered catalog results")
 }
}
''')
            swift('ui',common+['LightTouchMac/CatalogDetailsViewController.swift',str(fixture),'tests/catalog-ui.swift'],[port])
    finally:
        server.terminate(); server.wait(timeout=5)
