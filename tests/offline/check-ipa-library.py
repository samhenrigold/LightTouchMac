#!/usr/bin/env python3
"""The IPA library: one blob per archive, a clone per device, uninstall per device, Store dedupe with no transfer.

Offline. Compiles the real IPALibrary, CatalogClient and Features/AppInstaller.swift (the removal flow; the rest
of what it reaches is tests/fixtures/app-installer.swift) against an isolated LTM_STATE_DIR; the Legacy Store is tests/fixtures/catalog-server.py minus its IPA route, so a transfer the library
should have skipped fails loudly.
"""
from http.server import ThreadingHTTPServer
from pathlib import Path
import importlib.util, os, subprocess, tempfile, threading

root = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location('catalog_server', root / 'tests/fixtures/catalog-server.py')
fixture = importlib.util.module_from_spec(spec)
spec.loader.exec_module(fixture)


class Handler(fixture.Handler):
    def do_GET(self):
        if self.path.startswith('/ipa/'):
            self.server.transfers.append(self.path)
            self.send_error(500)
            return
        super().do_GET()


code = r'''import Cocoa
import CryptoKit
extension DeviceInstance {
 nonisolated var paths: Paths { paths(state: Bundled.stateDirectory, logs: Bundled.logsDirectory) }
}
@MainActor final class EmulatorController {
 var services: EmulatorController { get throws { self } }  // EmulatorController.services: the uninstall
 let instance: DeviceInstance
 init(_ instance: DeviceInstance) { self.instance = instance }
 var removed: [String] = []
 func uninstall(_ id: String) async throws { removed.append(id) }
 func reportConnectionFailure(_ error: Error, operation: String) {}
 // Not reached: this check queues removals only.
 let profile = DeviceProfile.iPodTouch2G, iosVersion = "3.1.3", guestArch = "armv6", productType: String? = "iPod2,1"
 var installPipeline: InstallPipeline { get throws { InstallPipeline() } }
 func install(_ ipa: URL, placeholderRaised: Bool, progress: @escaping @Sendable (String) -> Void) async throws -> String { "" }
 func importMedia(_ media: PreparedMedia, progress: @escaping @Sendable (Double) -> Void, willCommit: () -> Void) async throws {}
}
@main struct Check {
 @MainActor static func main() async throws {
  AppInstaller.presentError = { error, _ in preconditionFailure("\(error)") }
  let fm = FileManager.default
  let state = Bundled.stateDirectory
  func check(_ condition: Bool, _ what: String, line: Int = #line) { precondition(condition, "line \(line): \(what)") }
  func device(_ name: String) -> DeviceInstance {
   DeviceInstance(id: UUID(), name: name, board: "n72ap", firmware: "ipod-3.1.3", created: .now,
                  base: .init(kind: .prepared, path: "Devices/\(name)/base"),
                  storage: .init(key: name, overlay: "Devices/\(name)/overlay", snapshot: "Devices/\(name)/snapshot",
                                 usbmuxConf: "Devices/\(name)/usbmuxd-conf"))
  }
  func bytes(_ url: URL) -> Data { (try? Data(contentsOf: url)) ?? Data() }
  func blobs() -> [String] {
   ((try? fm.contentsOfDirectory(atPath: IPALibrary.directory.path)) ?? []).filter { $0.hasSuffix(".ipa") }.sorted()
  }
  func hex(_ digest: some Sequence<UInt8>) -> String { digest.map { String(format: "%02x", $0) }.joined() }
  let a = device("a"), b = device("b"), c = device("c")
  DeviceLibrary.shared.instances = [a, b, c]
  let work = state.appendingPathComponent("scratch", isDirectory: true)
  try fm.createDirectory(at: work, withIntermediateDirectories: true)
  let fixtureBytes = Data(String(repeating: "catalog download fixture\n", count: 4096).utf8)
  let ipa = work.appendingPathComponent("Fixture App.ipa")
  try fixtureBytes.write(to: ipa)
  let sha = hex(SHA256.hash(data: fixtureBytes)), md5 = hex(Insecure.MD5.hash(data: fixtureBytes))

  // The same archive on two devices: one blob, one entry, a copy each.
  await IPALibrary.adopt(ipa, .init(bundleID: "test.fixture", name: "Fixture App", version: "1.0", minOS: "3.0", catalogIpaID: 123), device: a)
  await IPALibrary.adopt(ipa, .init(bundleID: "test.fixture", name: "Fixture App"), device: b)
  check(blobs() == ["\(sha).ipa"], "one blob named by its sha256: \(blobs())")
  let entry = IPALibrary.index[sha]
  check(IPALibrary.index.count == 1 && entry?.bundleID == "test.fixture" && entry?.name == "Fixture App"
        && entry?.version == "1.0" && entry?.minOS == "3.0" && entry?.size == Int64(fixtureBytes.count)
        && entry?.md5 == md5 && entry?.catalogIpaID == 123, "one index entry with the install's fields: \(String(describing: entry))")
  let onDisk = try JSONSerialization.jsonObject(with: Data(contentsOf: IPALibrary.directory.appendingPathComponent("index.json"))) as? [String: Any]
  check(onDisk?.keys.sorted() == [sha], "index.json holds that entry")
  guard let copyA = IPALibrary.url(for: "test.fixture", device: a), let copyB = IPALibrary.url(for: "test.fixture", device: b) else {
   preconditionFailure("both devices keep a copy")
  }
  check(copyA.path.hasPrefix(a.paths.ipas.path) && copyB.path.hasPrefix(b.paths.ipas.path), "copies live under each device")
  check(bytes(copyA) == fixtureBytes && bytes(copyB) == fixtureBytes, "copies carry the bytes")
  // A missing source changes nothing; re-adopting the device's own copy keeps it.
  await IPALibrary.adopt(ipa.appendingPathExtension("missing"), .init(bundleID: "test.fixture"), device: a)
  await IPALibrary.adopt(copyA, .init(bundleID: "test.fixture"), device: a)
  check(bytes(copyA) == fixtureBytes && blobs().count == 1 && IPALibrary.index.count == 1, "failed and self adoption preserve bytes")

  // Legacy Store: the copy's checksum is in the library, so no transfer; a copy it lacks still fetches (and verifies).
  CatalogClient.baseURL = URL(string: "http://127.0.0.1:\(CommandLine.arguments[1])")!
  func app(_ id: Int) -> CatalogApp {
   CatalogApp(bundleID: "test.fixture", name: "Fixture App", developer: nil, version: "1.0", minOS: "3.0", size: Int64(fixtureBytes.count),
              ipaID: id, iconURL: nil, downloadURL: CatalogClient.baseURL.appendingPathComponent("ipa/\(id)"), appURL: nil)
  }
  let reused = try await CatalogClient.download(app(123)) { _ in }
  check(reused.path.hasPrefix(Bundled.workDirectory.appendingPathComponent("catalog-123-").path) && reused.lastPathComponent == "Fixture App.ipa",
        "the library copy is handed over as the usual scratch file: \(reused.path)")
  check(bytes(reused) == fixtureBytes, "with the archive's bytes")
  try fm.removeItem(at: reused.deletingLastPathComponent())
  do {
   _ = try await CatalogClient.download(app(666)) { _ in }
   preconditionFailure("a copy the library lacks was not fetched")
  } catch CatalogError.badStatus(500) {}
  check(!((try? fm.contentsOfDirectory(atPath: Bundled.workDirectory.path)) ?? []).contains { $0.hasPrefix("catalog-666-") },
        "a failed transfer owns no scratch directory")

  // Uninstall on A: A's copy goes, B's copy and the app-wide icon stay; the blob stays.
  let emulatorA = EmulatorController(a), emulatorB = EmulatorController(b)
  func uninstall(_ emulator: EmulatorController) async throws {
   var finished = false
   AppInstaller.remove([InstalledApp(id: "test.fixture")], with: emulator, presenting: nil, willRemove: { _ in }, didRemove: { _ in }) { finished = true }
   let deadline = ContinuousClock.now + .seconds(5)
   while !finished {
    precondition(ContinuousClock.now < deadline, "removal stalled")
    try await Task.sleep(for: .milliseconds(5))
   }
  }
  try await uninstall(emulatorA)
  check(emulatorA.removed == ["test.fixture"] && IPALibrary.url(for: "test.fixture", device: a) == nil, "A's copy is gone")
  check(bytes(copyB) == fixtureBytes && AppMetadataCache.shared.forgotten.isEmpty, "B keeps its copy and the icon")
  check(blobs() == ["\(sha).ipa"], "the blob stays")
  check(IPALibrary.unused(devices: [a, b, c]).isEmpty, "a blob B references is not unused")
  try await uninstall(emulatorB)
  check(IPALibrary.url(for: "test.fixture", device: b) == nil && AppMetadataCache.shared.forgotten == ["test.fixture"],
        "the last device's uninstall drops the icon")
  check(blobs() == ["\(sha).ipa"] && IPALibrary.index.count == 1, "the blob and its entry outlive every device copy")

  // Remove Unused takes only the blobs no device references.
  let otherBytes = Data(String(repeating: "another archive\n", count: 1000).utf8)
  let other = work.appendingPathComponent("Other.ipa")
  try otherBytes.write(to: other)
  await IPALibrary.adopt(other, .init(bundleID: "test.other"), device: a)
  let otherSha = hex(SHA256.hash(data: otherBytes))
  check(blobs() == ["\(otherSha).ipa", "\(sha).ipa"].sorted(), "two blobs")
  check(IPALibrary.unused(devices: [a, b, c]).keys.sorted() == [sha], "only the fixture is unused")
  try IPALibrary.removeUnused(devices: [a, b, c])
  check(blobs() == ["\(otherSha).ipa"] && IPALibrary.index.keys.sorted() == [otherSha], "the referenced blob stays, the other is gone")
  check(bytes(IPALibrary.url(for: "test.other", device: a)!) == otherBytes, "A's copy is untouched")

  // The launch sweep: a device copy from before the store is hashed in once; a directory of copies from
  // the old layout (LegacyState) is adopted the same way. Running the sweep again reads nothing.
  let handBytes = Data(String(repeating: "hand-made copy\n", count: 500).utf8)
  let legacyBytes = Data(String(repeating: "legacy shared copy\n", count: 500).utf8)
  try StorageLocations.privateDirectory(c.paths.ipas)
  try handBytes.write(to: c.paths.ipas.appendingPathComponent("hand.made.ipa"))
  let shared = state.appendingPathComponent("IPAs", isDirectory: true)
  try fm.createDirectory(at: shared, withIntermediateDirectories: true)
  try legacyBytes.write(to: shared.appendingPathComponent("legacy.app.ipa"))
  IPALibrary.sweep(devices: [a, b, c])
  await IPALibrary.adopt(copies: shared)
  let handSha = hex(SHA256.hash(data: handBytes)), legacySha = hex(SHA256.hash(data: legacyBytes))
  check(blobs() == ["\(otherSha).ipa", "\(handSha).ipa", "\(legacySha).ipa"].sorted(), "the hand-made and legacy copies are blobs: \(blobs())")
  check(IPALibrary.index[handSha]?.bundleID == "hand.made" && IPALibrary.index[handSha]?.size == Int64(handBytes.count)
        && IPALibrary.index[legacySha]?.bundleID == "legacy.app", "indexed by their file names")
  check(bytes(c.paths.ipas.appendingPathComponent("hand.made.ipa")) == handBytes, "C's copy is untouched")
  let before = try fm.attributesOfItem(atPath: IPALibrary.directory.appendingPathComponent("index.json").path)[.modificationDate] as? Date
  let indexBefore = IPALibrary.index
  try await Task.sleep(for: .milliseconds(20))
  IPALibrary.sweep(devices: [a, b, c])
  let after = try fm.attributesOfItem(atPath: IPALibrary.directory.appendingPathComponent("index.json").path)[.modificationDate] as? Date
  check(IPALibrary.index == indexBefore && blobs().count == 3 && before == after, "the second sweep changes nothing")
  print("PASS: one blob per archive with one index entry, a clone per device, uninstall per device keeps the other's copy and icon, Remove Unused spares referenced blobs, Store reuses the library without a transfer, the launch sweep is idempotent")
 }
}
'''

with tempfile.TemporaryDirectory(prefix='ltm-ipa-library-') as directory:
    work = Path(directory)
    (work / 'home').mkdir()
    env = dict(os.environ, CFFIXED_USER_HOME=str(work / 'home'), LTM_STATE_DIR=str(work / 'state'))
    server = ThreadingHTTPServer(('127.0.0.1', 0), Handler)
    server.transfers = []
    threading.Thread(target=server.serve_forever, daemon=True).start()
    try:
        (work / 'check.swift').write_text(code)
        sources = ['Library/IPALibrary', 'Features/CatalogClient', 'Features/CatalogCopy', 'Library/Bundled', 'Transport/AppEventLog', 'Library/StorageLocations', 'Transport/NativeLogging',
                   'Library/DeviceInstance', 'Device/DeviceProfile', 'Library/FirmwareCatalog', 'Features/InstallationQueue',
                   'Features/AppInstaller', 'Transport/DeviceExecution']
        subprocess.run(['xcrun', 'swiftc', '-swift-version', '5', '-default-isolation', 'MainActor', '-parse-as-library',
                        '-module-cache-path', str(work / 'modules'), str(root / 'Packages/FirmwareKit/Sources/FirmwareSchema/FirmwareWire.swift'), *[str(root / f'LightTouchMac/{s}.swift') for s in sources],
                        str(root / 'tests/fixtures/app-installer.swift'), str(work / 'check.swift'), '-o', str(work / 'check')], check=True)
        subprocess.run([str(work / 'check'), str(server.server_port)], check=True, timeout=60, env=env)
    finally:
        server.shutdown()
    assert server.transfers == ['/ipa/666'], server.transfers
