#!/usr/bin/env python3
"""The Store's filter menu and the version sheet, against recorded Legacy Store responses. Offline, nothing on screen.

tests/fixtures/store-filter: live /api/emulator/apps answers (2026-09-30) for Hotel Dash (family 1), Hotel Dash
Deluxe (family 2, iPad only), Diner Dash (1, 2) and Agent Dash (1, 2; needs iOS 4.1) judged for iPod2,1 3.1.3 and
iPad1,1 3.2, plus Hotel Dash's and Tap Tap Dash's version lists and copy records.

Filter (real CatalogFilter + CatalogFilterButton, driven through its menu items, in a throwaway defaults suite):
the iPod's menu offers only Show Unavailable Apps; turning it off hides the iPad-only Hotel Dash Deluxe and Agent
Dash there; iPad Apps Only on the iPad leaves Hotel Dash Deluxe and Diner Dash and drops iPhone-only Hotel Dash;
the same saved choice never hides iPhone apps on the iPod; a new button reads both choices back.
Sheet (real CatalogDetailsModel/View over CatalogClient and a local server): Hotel Dash on the iPod lists its armv6
copies with twin copies numbered, revalidates 207203 and installs it, and notes a downgrade from 1.10.3; Tap Tap
Dash on the iPad (arm64 only) shows the processor reason and keeps Install disabled. The sheet fits its content.
Renders filter-*.png and sheet-*.png into --out (offscreen windows, never ordered front).
"""
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import urlparse, parse_qs
import argparse, os, subprocess, tempfile, threading

root = Path(__file__).resolve().parents[2]
fixtures = root / 'tests/fixtures/store-filter'
ap = argparse.ArgumentParser()
ap.add_argument('--out')
args = ap.parse_args()


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *a): pass

    def do_GET(self):
        url = urlparse(self.path)
        query = parse_qs(url.query)
        name = {'/api/v1/apps/com.playfirst.hoteldash/versions': 'versions-hoteldash.json',
                '/api/v1/apps/com.secondarm.taptapdash/versions': 'versions-taptapdash.json'}.get(url.path)
        if url.path.startswith('/api/v1/copies/'):
            name = 'copy-' + url.path.rsplit('/', 1)[1] + '.json'
        if url.path == '/api/emulator/apps' and query.get('ipa_id') == ['207203']:
            name = 'emulator-207203.json'
        if not name or not (fixtures / name).exists():
            return self.send_error(404)
        body = (fixtures / name).read_bytes()
        self.send_response(200)
        self.send_header('Content-Type', 'application/json')
        self.send_header('Content-Length', str(len(body)))
        self.end_headers()
        self.wfile.write(body)


code = r'''import Cocoa
import SwiftUI
@main struct Check {
 @MainActor static func main() async throws {
  func check(_ ok: Bool, _ what: String, line: Int = #line) { precondition(ok, "line \(line): \(what)") }
  _ = NSApplication.shared
  NSApp.setActivationPolicy(.prohibited)
  CatalogClient.baseURL = URL(string: "http://127.0.0.1:\(CommandLine.arguments[1])")!
  let fixtures = URL(fileURLWithPath: CommandLine.arguments[2]), out = URL(fileURLWithPath: CommandLine.arguments[3])
  struct Envelope: Decodable { let apps: [CatalogApp] }
  func apps(_ name: String) throws -> [CatalogApp] {
   try JSONDecoder().decode(Envelope.self, from: Data(contentsOf: fixtures.appendingPathComponent(name))).apps
  }
  func render(_ view: NSView, _ name: String) throws {
   let window = NSWindow(contentRect: NSRect(origin: .zero, size: view.fittingSize), styleMask: [.titled], backing: .buffered, defer: true)
   window.appearance = NSAppearance(named: .aqua)
   window.contentView = view
   view.layoutSubtreeIfNeeded()
   let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds)!
   view.cacheDisplay(in: view.bounds, to: rep)
   try rep.representation(using: .png, properties: [:])!.write(to: out.appendingPathComponent(name))
  }
  let ipod = try apps("ipod2-3.1.3-dash.json"), ipad = try apps("ipad1-3.2-dash.json")
  let names = { (list: [CatalogApp]) in Set(list.map(\.name)) }
  let suite = "ltm-store-ui-check-\(ProcessInfo.processInfo.processIdentifier)"
  let defaults = UserDefaults(suiteName: suite)!
  defer { defaults.removePersistentDomain(forName: suite) }

  // iPod: no family choice; the default shows unavailable apps greyed, the toggle hides them.
  let podButton = CatalogFilterButton(isIPad: false, defaults: defaults)
  let items = podButton.menu!.items
  check(items[1...3].allSatisfy(\.isHidden) && !items[4].isHidden && items[4].title == "Show Unavailable Apps", "iPod menu is the toggle alone")
  check(items[4].state == .on && podButton.apply(ipod).count == 4, "default: every app, unavailable ones greyed")
  var changes = 0
  podButton.onChange = { changes += 1 }
  podButton.menu!.performActionForItem(at: 4)
  check(changes == 1 && items[4].state == .off, "toggle reports and checks off")
  check(names(podButton.apply(ipod)) == ["Hotel Dash", "Diner Dash"], "iPad-only and too-new apps hidden on the iPod: \(names(podButton.apply(ipod)))")

  // iPad: the family choice, read back with the toggle the iPod saved.
  let padButton = CatalogFilterButton(isIPad: true, defaults: defaults)
  let padItems = padButton.menu!.items
  check(!padButton.filter.showUnavailable, "Show Unavailable persisted")
  check(!padItems[1].isHidden && !padItems[2].isHidden && padItems[1].state == .on, "iPad offers both families, all apps by default")
  check(names(padButton.apply(ipad)) == ["Hotel Dash", "Hotel Dash Deluxe", "Diner Dash"], "iPad, all families, runnable")
  try render(strip(padButton), "filter-ipad-all.png")
  padButton.menu!.performActionForItem(at: 2)
  check(padItems[2].state == .on && padItems[1].state == .off, "iPad Apps Only checked")
  check(names(padButton.apply(ipad)) == ["Hotel Dash Deluxe", "Diner Dash"], "iPad Apps Only drops iPhone-only Hotel Dash")
  padButton.menu!.performActionForItem(at: 4)
  check(names(padButton.apply(ipad)) == ["Hotel Dash Deluxe", "Diner Dash", "Agent Dash"], "unavailable iPad-capable app shown again")
  try render(strip(padButton), "filter-ipad-ipad-only.png")

  // Both choices survive a relaunch; the iPad-only choice never narrows an iPod.
  let reread = CatalogFilter.load(defaults)
  check(reread.iPadOnly && reread.showUnavailable, "both choices persisted")
  let pod2 = CatalogFilterButton(isIPad: false, defaults: defaults)
  check(names(pod2.apply(ipod)) == names(ipod), "iPad Apps Only doesn't apply on an iPod")
  try render(strip(pod2), "filter-ipod.png")
  check(CatalogFilter.load(UserDefaults(suiteName: suite + "-fresh")!) == CatalogFilter(), "fresh defaults: all apps, unavailable shown")

  // The version sheet: a compatible app on the iPod, installed at a newer version.
  let hotel = ipod.first { $0.name == "Hotel Dash" }!
  var installed: Int?
  let good = CatalogDetailsModel(app: hotel, device: "iPod2,1", deviceOS: "3.1.3", arch: "armv6", installedVersion: "1.10.3",
                                 canInstall: { true }, install: { installed = $0.ipaID })
  await good.load()
  let rows = good.rows ?? []
  check(rows.count == 7 && rows.allSatisfy { $0.copy.architectures?.contains("armv6") == true }, "the iPod's armv6 copies: \(rows.map(\.copy.ipa_id))")
  check(good.selection == "207203", "the row's own copy selected")
  let own = rows.first { $0.copy.ipa_id == "207203" }!, twin = rows.first { $0.copy.ipa_id == "5635" }!
  check(good.title(own) == "1.1.51 · 65.6 MB" && good.title(twin).hasSuffix(" · Copy 5635"), "\(good.title(own)) / \(good.title(twin))")
  await good.check()
  check(good.problem == nil && good.canInstallSelection, "compatible copy installable: \(good.problem ?? "")")
  check(good.downgradeNote == "Version 1.10.3 is installed. An older version may not read its data.", "downgrade note")
  let goodView = NSHostingView(rootView: CatalogDetailsView(model: good))
  check(goodView.fittingSize.height < 360, "sheet fits its content: \(goodView.fittingSize)")
  try render(goodView, "sheet-compatible.png")
  good.installSelection()
  check(installed == 207203, "Install fetches the revalidated copy")

  // An arm64-only app on the iPad: the reason, Install disabled.
  let dash = try apps("search-86286-ipad1-4.2.1.json")[0]
  let bad = CatalogDetailsModel(app: dash, device: "iPad1,1", deviceOS: "4.2.1", arch: "armv7", installedVersion: nil,
                                canInstall: { true }, install: { _ in preconditionFailure("installed an incompatible copy") })
  await bad.load()
  check(bad.rows?.map(\.copy.ipa_id) == ["86286"], "only the row's own copy: \(bad.rows?.map(\.copy.ipa_id) ?? [])")
  await bad.check()
  check(bad.problem == "This copy needs a newer processor than this device has." && !bad.canInstallSelection && bad.downgradeNote == nil,
        "incompatible: \(bad.problem ?? "nil")")
  bad.installSelection()
  let badView = NSHostingView(rootView: CatalogDetailsView(model: bad))
  check(badView.fittingSize.height < 360, "sheet fits its content: \(badView.fittingSize)")
  try render(badView, "sheet-incompatible.png")
  print("PASS: Store filter (iPod toggle only, iPad family choice, persistence) and version sheet (install, reason, downgrade note)")
 }

 /// The pane's top row as the inspector lays it out: Installed/Store, then the filter.
 @MainActor static func strip(_ button: NSPopUpButton) -> NSView {
  let pane = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 40))
  let mode = NSSegmentedControl(labels: ["Installed", "Store"], trackingMode: .selectOne, target: nil, action: nil)
  mode.selectedSegment = 1
  mode.segmentDistribution = .fillEqually
  mode.controlSize = .large
  for view in [mode, button] as [NSView] { view.translatesAutoresizingMaskIntoConstraints = false; pane.addSubview(view) }
  NSLayoutConstraint.activate([
   mode.topAnchor.constraint(equalTo: pane.topAnchor, constant: 6),
   mode.leadingAnchor.constraint(equalTo: pane.leadingAnchor, constant: 8),
   button.leadingAnchor.constraint(equalTo: mode.trailingAnchor, constant: 4),
   button.centerYAnchor.constraint(equalTo: mode.centerYAnchor),
   button.trailingAnchor.constraint(equalTo: pane.trailingAnchor, constant: -6),
   pane.widthAnchor.constraint(equalToConstant: 300), pane.heightAnchor.constraint(equalToConstant: 40),
  ])
  return pane
 }
}
'''

with tempfile.TemporaryDirectory(prefix='ltm-store-ui-') as directory:
    work = Path(directory)
    out = Path(args.out) if args.out else work / 'out'
    out.mkdir(parents=True, exist_ok=True)
    (work / 'home').mkdir()
    (work / 'check.swift').write_text(code)
    (work / 'paths.swift').write_text('extension DeviceInstance { var paths: Paths { paths(state: Bundled.stateDirectory, logs: Bundled.logsDirectory) } }\n')
    sources = ['Features/CatalogClient', 'Features/CatalogCopy', 'Features/CatalogFilter', 'UI/CatalogFilterButton',
               'UI/CatalogDetailsViewController', 'Library/Bundled', 'Transport/AppEventLog', 'Library/StorageLocations',
               'Transport/NativeLogging', 'Library/IPALibrary', 'Library/DeviceInstance', 'Device/DeviceProfile', 'Library/FirmwareCatalog']
    subprocess.run(['xcrun', 'swiftc', '-parse-as-library', '-module-cache-path', str(work / 'modules'),
                    str(root / 'Packages/FirmwareKit/Sources/FirmwareSchema/FirmwareWire.swift'), *[str(root / f'LightTouchMac/{s}.swift') for s in sources], str(work / 'paths.swift'), str(work / 'check.swift'),
                    '-o', str(work / 'check')], check=True)
    server = ThreadingHTTPServer(('127.0.0.1', 0), Handler)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    env = dict(os.environ, CFFIXED_USER_HOME=str(work / 'home'), LTM_STATE_DIR=str(work / 'state'))
    try:
        subprocess.run([str(work / 'check'), str(server.server_port), str(fixtures), str(out)], check=True, timeout=60, env=env)
    finally:
        server.shutdown()
