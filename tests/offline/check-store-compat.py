#!/usr/bin/env python3
"""Legacy Store device compatibility (API 2.1) against recorded responses of both shapes. Offline.

tests/fixtures/store-compat: old-* are the live API's responses (2.0 shape, 2026-09-29: "enigmo", copy 195588);
new-* are the same records judged by the lighttouch-api branch's own compatOf (jangle 1649920) for iPod2,1 3.1.3,
iPad1,1 3.2 and iPod1,1 1.1.5, with Enigmo 3.3-H's armv6 slice flagged as ARMv7 code (plan 020). The fixture server
answers like each server would: the old one ignores device/os, the new one judges and 404s incompatible copies.
Compiles the real CatalogClient, CatalogCopy and IPALibrary.
"""
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import urlparse, parse_qs
import json, os, subprocess, tempfile, threading

root = Path(__file__).resolve().parents[2]
import sys
sys.path.insert(0, str(root / "scripts"))
import host_runtime
fixtures = root / 'tests/fixtures/store-compat'
load = lambda name: json.loads((fixtures / name).read_text())
FILES = {'iPod2,1': 'new-ipod2-3.1.3-enigmo', 'iPad1,1': 'new-ipad1-3.2-enigmo', 'iPod1,1': 'new-ipod1-1.1.5-enigmo'}


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *args): pass

    def reply(self, code, data):
        body = json.dumps(data).encode()
        self.send_response(code)
        self.send_header('Content-Type', 'application/json')
        self.send_header('Content-Length', str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        url = urlparse(self.path)
        query = {k: v[0] for k, v in parse_qs(url.query).items()}
        self.server.requests.append((url.path, query))
        device = query.get('device') if self.server.new else None
        if url.path == '/api/emulator/apps':
            data = load(FILES[device] + ('-include' if 'ipa_id' in query or 'incompatible' in query else '') + '.json') \
                if device else load('old-enigmo.json')
            if 'ipa_id' in query:
                apps = [a for a in data['apps'] if str(a['ipa_id']) == query['ipa_id']]
                if apps and not apps[0].get('compat', {'compatible': True})['compatible']:
                    return self.reply(404, {'error': 'not_compatible'})
                data = dict(data, apps=apps)
            return self.reply(200, data)
        if url.path == '/api/v1/copies/7':   # a copy record whose ipa_id isn't a string: the app can't read it
            return self.reply(200, {'ipa_id': [7]})
        if url.path == '/api/v1/copies/195588':
            return self.reply(200, load('new-copy-195588.json' if self.server.new else 'old-copy-195588.json'))
        self.send_error(500)   # /ipa/…: every download here must come from the library


code = r'''import Foundation
@main struct Check {
 @MainActor static func main() async throws {
  func check(_ condition: Bool, _ what: String, line: Int = #line) { precondition(condition, "line \(line): \(what)") }
  let fixtures = URL(fileURLWithPath: CommandLine.arguments[2])
  CatalogClient.baseURL = URL(string: "http://127.0.0.1:\(CommandLine.arguments[1])")!
  let new = CommandLine.arguments[3] == "new"
  // Live copy record (Box.net 1682, 09-29): Mach-O families come as numbers ([1,2]), not strings.
  let box = try JSONDecoder().decode(CatalogCopy.self, from: Data(contentsOf: fixtures.appendingPathComponent("live-copy-1682.json")))
  check(box.binary?.device_family_macho == ["1", "2"], "numeric device_family_macho decodes")
  check(box.unavailableReason(minimumOS: "3.0", deviceOS: "4.2", arch: "armv7") == nil, "Box installs on the iPad")
  func names(_ apps: [CatalogApp]) -> [String: String?] {
   Dictionary(uniqueKeysWithValues: apps.map { ($0.name, $0.incompatibility) })
  }

  // The library already holds Enigmo 3.3-H's bytes (index.json as IPALibrary writes it).
  let blob = Data("enigmo fixture bytes".utf8)
  try FileManager.default.createDirectory(at: IPALibrary.directory, withIntermediateDirectories: true)
  try blob.write(to: IPALibrary.blob("feed"))
  try JSONSerialization.data(withJSONObject: ["feed": ["bundleID": "com.pangea.Enigmo", "size": blob.count,
                                                       "md5": "1ce61d09f89df054e99b72eabffbd640"]])
   .write(to: IPALibrary.directory.appendingPathComponent("index.json"))

  if !new {
   // The live (2.0) API: no compat, no md5; the target parameters change nothing.
   for device in [nil, "iPod2,1"] {
    let found = try await CatalogClient.search("enigmo", device: device, os: "3.1.3")
    check(found.count == 4 && found.allSatisfy { $0.compat == nil && $0.md5 == nil && $0.incompatibility == nil },
          "old shape decodes as before")
    check(found[0].subtitle == "Pangea Software, Inc. · 5.1 MB", "old subtitle: \(found[0].subtitle)")
   }
   // Without md5 on the record the copy record is fetched, checked, and its md5 finds the library copy.
   let enigmo = try await CatalogClient.compatibleCopy(195588, device: "iPod2,1", os: "3.1.3")
   let file = try await CatalogClient.download(enigmo, device: "iPod2,1") { _ in }
   check((try? Data(contentsOf: file)) == blob, "old shape: library copy via the copy record")
   try FileManager.default.removeItem(at: file.deletingLastPathComponent())
   let copy = try JSONDecoder().decode(CatalogCopy.self, from: Data(contentsOf: fixtures.appendingPathComponent("old-copy-195588.json")))
   check(copy.binary?.armv7_code == nil && copy.unavailableReason(minimumOS: "3.0") == nil, "old copy record passes on armv6")
   print("PASS: live (2.0) response shape: search and copy records decode unchanged, download checks the copy record and reuses the library")
   return
  }

  // A response that doesn't decode: CatalogError.unreadable in plain words; app.log has the coding path.
  do { _ = try await CatalogClient.copyDetails(7); preconditionFailure("decoded a garbled copy record") }
  catch CatalogError.unreadable {}
  check(CatalogError.unreadable.localizedDescription == "Legacy Store sent a response Light Touch couldn’t read.", "plain words")
  await AppEventLog.shared.flush()
  let appLog = { (try? String(contentsOf: Bundled.preparedLogsDirectory!.appendingPathComponent("app.log"), encoding: .utf8)) ?? "" }
  check(appLog().contains("Legacy Store: couldn’t read /api/v1/copies/7") && appLog().contains("typeMismatch") && appLog().contains("ipa_id"),
        "the DecodingError and its coding path are in app.log: \(appLog())")

  // iPod touch 2G: Enigmo 3.3-H's armv6 slice is ARMv7 code, greyed with the reason; the other three run.
  let ipod2 = try await CatalogClient.search("enigmo", device: "iPod2,1", os: "3.1.3")
  check(names(ipod2) == ["Enigmo": "Needs a newer processor", "Enigmo 2": nil, "Enigmo!": nil, "Enigmous": nil], "\(names(ipod2))")
  check(ipod2[0].subtitle == "Needs a newer processor" && ipod2[1].subtitle.hasPrefix("Pangea Software"), "subtitle carries the reason")
  check(ipod2[0].md5 == "1ce61d09f89df054e99b72eabffbd640", "search record md5")
  do { _ = try await CatalogClient.compatibleCopy(195588, device: "iPod2,1", os: "3.1.3"); preconditionFailure("iPod took Enigmo") }
  catch CatalogError.badStatus(404) {}
  await AppEventLog.shared.flush()
  check(appLog().contains("Legacy Store: HTTP 404 for /api/emulator/apps?"), "the HTTP status is in app.log")
  // The suggested list (no query) asks for compatible apps only.
  _ = try await CatalogClient.search("", device: "iPod2,1", os: "3.1.3")

  // iPad: the same copy runs (its armv7 core executes the ARMv7 code); every family, so no family parameter.
  let ipad = try await CatalogClient.search("enigmo", device: "iPad1,1", os: "3.2")
  check(ipad.count == 4 && ipad.allSatisfy { $0.compat?.compatible == true && $0.incompatibility == nil }, "\(names(ipad))")
  // The search record's md5 is in the library: no copy record, no transfer.
  let enigmo = try await CatalogClient.compatibleCopy(195588, device: "iPad1,1", os: "3.2")
  let file = try await CatalogClient.download(enigmo, device: "iPad1,1", deviceOS: "3.2", arch: "armv7") { _ in }
  check((try? Data(contentsOf: file)) == blob, "the library copy, by the record's md5")
  try FileManager.default.removeItem(at: file.deletingLastPathComponent())

  // iPod touch 1G on 1.1.5: nothing qualifies (App Store floor 2.0); a search says why.
  check(try await CatalogClient.search("", device: "iPod1,1", os: "1.1.5").isEmpty, "iPod1,1 suggestions are empty")
  let ipod1 = try await CatalogClient.search("enigmo", device: "iPod1,1", os: "1.1.5")
  check(names(ipod1) == ["Enigmo": "Needs a newer processor", "Enigmo 2": "Requires iOS 3.0",
                         "Enigmo!": "Requires iOS 3.0", "Enigmous": "Requires iOS 2.0"], "\(names(ipod1))")

  // Copy record 2.1: armv7_code refuses an armv6 device only.
  let copy = try JSONDecoder().decode(CatalogCopy.self, from: Data(contentsOf: fixtures.appendingPathComponent("new-copy-195588.json")))
  check(copy.unavailableReason(minimumOS: "3.0") == "This copy needs a newer processor than this device has.", "armv6 refused")
  check(copy.unavailableReason(minimumOS: "3.0", deviceOS: "3.2", arch: "armv7") == nil, "armv7 allowed")
  // Reasons the fixtures don't carry.
  func reason(_ code: String) -> String? {
   CatalogApp(bundleID: nil, name: "", developer: nil, version: nil, minOS: nil, size: nil, ipaID: 1, iconURL: nil,
              downloadURL: URL(string: "https://example.invalid")!, appURL: nil,
              compat: .init(compatible: false, reasons: [code])).incompatibility
  }
  for (code, words) in [("no_armv6_or_armv7_slice", "Needs a newer processor"), ("unsupported_device_family", "Not made for this device"),
                        ("capability:telephony", "Needs hardware this device doesn’t have"), ("capability:!armv6", "Not made for this device"),
                        ("encrypted", "Encrypted — can’t open in Light Touch"), ("something_new", "Not compatible with this device")] {
   check(reason(code) == words, "\(code): \(String(describing: reason(code)))")
  }
  print("PASS: API 2.1 shape: iPod2,1 greys Enigmo (ARMv7 code) with its reason and 404s its copy, iPad1,1 runs it and reuses the library by md5 with no copy request, iPod1,1 gets none and each reason")
 }
}
'''

with tempfile.TemporaryDirectory(prefix='ltm-store-compat-') as directory:
    work = Path(directory)
    (work / 'home').mkdir()
    (work / 'check.swift').write_text(code)
    (work / 'paths.swift').write_text('extension DeviceInstance { var paths: Paths { paths(state: Bundled.stateDirectory, logs: Bundled.logsDirectory) } }\n')
    sources = ['Features/CatalogClient', 'Features/CatalogCopy', 'Library/Bundled', 'Transport/AppEventLog', 'Library/StorageLocations',
               'Transport/NativeLogging', 'Library/IPALibrary', 'Library/DeviceInstance', 'Device/DeviceProfile', 'Library/FirmwareCatalog']
    subprocess.run(['xcrun', 'swiftc', *host_runtime.swift_flags(root), '-parse-as-library', '-module-cache-path', str(work / 'modules'),
                    str(root / 'Packages/FirmwareKit/Sources/FirmwareSchema/FirmwareWire.swift'), *[str(root / f'LightTouchMac/{s}.swift') for s in sources], str(work / 'paths.swift'), str(work / 'check.swift'),
                    '-o', str(work / 'check')], check=True)
    for shape in ('old', 'new'):
        env = dict(os.environ, CFFIXED_USER_HOME=str(work / 'home'), LTM_STATE_DIR=str(work / f'state-{shape}'))
        server = ThreadingHTTPServer(('127.0.0.1', 0), Handler)
        server.new, server.requests = shape == 'new', []
        threading.Thread(target=server.serve_forever, daemon=True).start()
        try:
            subprocess.run([str(work / 'check'), str(server.server_port), str(fixtures), shape], check=True, timeout=60, env=env)
        finally:
            server.shutdown()
        paths = [p for p, _ in server.requests]
        assert not any(p.startswith('/ipa/') for p in paths), paths
        searches = [q for p, q in server.requests if p == '/api/emulator/apps' and 'ipa_id' not in q]
        # Every search names the device when there is one; only a query asks for the excluded apps too; no family.
        assert all(('q' in q) == (q.get('incompatible') == 'include') and 'family' not in q for q in searches), searches
        assert all(q.get('os') for q in searches if 'device' in q), searches
        if shape == 'new':
            assert [q.get('device') for q in searches] == ['iPod2,1', 'iPod2,1', 'iPad1,1', 'iPod1,1', 'iPod1,1'], searches
            lookups = [q for p, q in server.requests if p == '/api/emulator/apps' and 'ipa_id' in q]
            assert all(q.get('device') and q.get('os') and 'incompatible' not in q for q in lookups), lookups
            assert '/api/v1/copies/195588' not in paths, 'a known md5 still fetched the copy record'
        else:
            assert paths.count('/api/v1/copies/195588') == 1, paths
