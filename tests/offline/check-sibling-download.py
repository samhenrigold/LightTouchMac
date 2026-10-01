#!/usr/bin/env python3
"""A build that boots its sibling's ramdisk fetches both IPSWs as one job, then prepares.

iPad 4.3.1–4.3.5 carry recipe.keybag_ramdisk_from = "k48ap-8F190" (no public ramdisk keys of
their own). Compiles the production FirmwareJobs (with FirmwareDownloads, IPSWStore,
PreparationJob, DeviceRow and the rest) with a stub Bundled/DeviceLibrary, against a catalog of
the shipped 4.3 and 4.3.1 entries whose sources point at small file:// IPSWs, an ephemeral
URLSession, and tests/fixtures/fake-firmwarekit.py as the preparer:

  download   Download & Prepare on 4.3.1 with neither IPSW here: one job for 4.3.1 reporting
             files == 2 and a fraction that only grows; no job, no device for 4.3; both IPSWs
             in the store; the preparer gets --sibling-entry/--sibling-ipsw (4.3's); one device
  import     4.3.1's IPSW imported with 4.3's missing: 4.3's download is queued as 4.3.1's job
             (files == 1), then the preparation runs with it; one device
  cancel     a job cancelled while both download prepares nothing and leaves 4.3 without a job

Every path is a temp dir (HOME and CFFIXED_USER_HOME too, so Caches/ is inside it; checked before anything runs); everything is deleted at the end.
"""
from pathlib import Path
import hashlib, json, os, subprocess, sys, tempfile
from firmwarekit_leaf import capacity_sources, schema_sources

ROOT = Path(__file__).resolve().parents[2]
APP = ROOT / 'LightTouchMac'
FAKE = ROOT / 'tests/fixtures/fake-firmwarekit.py'
SOURCES = ['FirmwareJobs.swift', 'IPSWStore.swift', 'FirmwareDownloads.swift', 'PreparationJob.swift', 'DeviceInstance.swift',
           'FirmwareCatalog.swift', 'DeviceProfile.swift', 'StorageLocations.swift', 'DeviceStateStorage.swift',
           'DeviceRow.swift', 'BootRecipe.swift']


def source(name):
    """The app's sources live in LightTouchMac/<layer>/ since the service-layering move; find by name."""
    hits = [p for p in APP.rglob(name) if p.is_file()]
    if len(hits) != 1:
        raise SystemExit(f"{name}: expected one file under {APP}, found {hits}")
    return hits[0]

STUBS = r'''
import Foundation
nonisolated enum Bundled {
    static var stateDirectory: URL { URL(fileURLWithPath: ProcessInfo.processInfo.environment["LTM_STATE_DIR"]!) }
    static var logsDirectory: URL { stateDirectory.appendingPathComponent("Logs") }
    static func requireStorage() throws {}
}
@MainActor final class DeviceLibrary {
    static let shared = DeviceLibrary()
    func instances(firmware: String) -> [DeviceInstance] { DeviceInstance.all(state: Bundled.stateDirectory).filter { $0.firmware == firmware } }
    func reload() {}
}
nonisolated func logEvent(_ message: String, _ arguments: CVarArg...) { print("  log: " + String(format: message, arguments: arguments)) }
'''

CHECK = r'''
import Cocoa

func expect(_ ok: Bool, _ what: @autoclosure () -> String, line: Int = #line) {
    if !ok { print("FAIL line \(line): \(what())"); exit(1) }
}
@main struct Check {
@MainActor static func main() async throws {
    _ = NSApplication.shared
    let args = CommandLine.arguments
    let state = Bundled.stateDirectory, fm = FileManager.default
    expect(IPSWStore.cachesDirectory.path.hasPrefix(args[3]), "Caches/ is under the temp HOME: \(IPSWStore.cachesDirectory.path)")
    let catalog = try FirmwareCatalog.load(from: URL(fileURLWithPath: args[1]))
    let point = catalog.entry(id: "k48ap-8G4")!, base = catalog.entry(id: "k48ap-8F190")!
    expect(point.recipe?.keybagRamdiskFrom == base.id, "4.3.1 boots 4.3's ramdisk")
    let store = IPSWStore(downloads: state.appendingPathComponent("Caches/IPSW"), imports: state.appendingPathComponent("IPSW"))
    let jobs = FirmwareJobs(catalog: catalog, store: store, configuration: .ephemeral)
    var seen: [FirmwareJob] = [], baseJobs = 0
    let observer = NotificationCenter.default.addObserver(forName: FirmwareJobs.didChangeNotification, object: jobs, queue: nil) { _ in
        MainActor.assumeIsolated {
            if let job = jobs.jobs[point.id], seen.last != job { seen.append(job) }
            if jobs.jobs[base.id] != nil { baseJobs += 1 }
        }
    }
    defer { NotificationCenter.default.removeObserver(observer) }
    func devices(_ e: FirmwareCatalog.Entry) -> Int { DeviceInstance.all(state: state).filter { $0.firmware == e.id }.count }
    func settle(_ done: () -> Bool) async {
        for _ in 0..<600 where !done() { try? await Task.sleep(for: .milliseconds(50)) }
        expect(done(), "timed out: \(seen)")
    }
    func downloads() -> [FirmwareJob] { seen.filter { if case .downloading = $0 { true } else { false } } }
    func files(_ job: FirmwareJob) -> Int { if case let .downloading(_, _, n) = job { n } else { 0 } }
    func fraction(_ job: FirmwareJob) -> Double { if case let .downloading(f, _, _) = job { f } else { -1 } }
    let argv = { (try? JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: args[2])))) as? [String] ?? [] }

    switch args[4] {
    case "download":
        jobs.downloadAndPrepare(point)
        expect(files(jobs.jobs[point.id] ?? .failed("none")) == 2, "one job, two downloads: \(String(describing: jobs.jobs[point.id]))")
        await settle { devices(point) == 1 || { if case .failed? = jobs.jobs[point.id] { true } else { false } }() }
        expect(devices(point) == 1 && jobs.jobs[point.id] == nil, "4.3.1 prepared: \(seen)")
        expect(!downloads().isEmpty && downloads().allSatisfy { files($0) == 2 }, "every download report is the two-IPSW job: \(downloads())")
        let fractions = downloads().map(fraction)
        expect(fractions == fractions.sorted(), "the one bar only grows: \(fractions)")
        expect(seen.contains { if case .preparing = $0 { true } else { false } }, "then the preparation: \(seen)")
        expect(baseJobs == 0 && devices(base) == 0, "4.3 gets no job and no device of its own")
        expect(store.existing(point.source.sha1!) != nil && store.existing(base.source.sha1!) != nil, "both IPSWs in the store")
        let a = argv()
        expect(a.firstIndex(of: "--sibling-ipsw").map { a[$0 + 1] } == store.existing(base.source.sha1!)!.path, "the preparer boots 4.3's ramdisk: \(a)")
        expect(a.contains("--sibling-entry"), "\(a)")
        print("PASS download: 4.3.1's Download & Prepare fetched 4.3's IPSW beside its own as one job")
    case "import":
        jobs.importIPSW(URL(fileURLWithPath: args[5]), for: point)
        await settle { devices(point) == 1 || { if case .failed? = jobs.jobs[point.id] { true } else { false } }() }
        expect(devices(point) == 1, "4.3.1 prepared after its sibling's download: \(seen)")
        expect(!downloads().isEmpty && downloads().allSatisfy { files($0) == 1 }, "the import queued only 4.3's IPSW: \(downloads())")
        expect(store.existing(base.source.sha1!) != nil && baseJobs == 0, "4.3's IPSW fetched under 4.3.1's job")
        expect(argv().contains("--sibling-ipsw"), "\(argv())")
        print("PASS import: an imported 4.3.1 queued 4.3's download instead of failing")
    case "cancel":
        jobs.downloadAndPrepare(point)
        jobs.cancel(point)
        expect(jobs.jobs[point.id] == nil, "cancelled")
        try? await Task.sleep(for: .seconds(1))
        expect(devices(point) == 0 && jobs.jobs[point.id] == nil && baseJobs == 0, "nothing prepared after a cancel: \(seen)")
        print("PASS cancel: a cancelled two-IPSW job prepares nothing, and 4.3 gets no job")
    default: fatalError(args[4])
    }
}
}
'''


def main():
    tmp = Path(tempfile.mkdtemp(prefix='ltm-sibling-download-'))
    try:
        shipped = json.loads((APP / 'Resources/firmware-catalog.json').read_text())
        entries = {e['id']: e for e in shipped['entries']}
        point, base = entries['k48ap-8G4'], entries['k48ap-8F190']
        assert point['recipe']['keybag_ramdisk_from'] == base['id']
        assert all(e['recipe'].get('keybag_ramdisk_from') == base['id'] for e in shipped['entries']
                   if e['board'] == 'k48ap' and e['version'].startswith('4.3.')), 'every iPad 4.3.x names 4.3'
        ipsws = tmp / 'ipsws'
        ipsws.mkdir()
        for entry, size in ((point, 3 << 20), (base, 5 << 20)):
            path = ipsws / f"{entry['id']}.ipsw"
            path.write_bytes(os.urandom(size))
            entry['source'] = {'kind': 'ipsw', 'url': path.as_uri(), 'sha1': hashlib.sha1(path.read_bytes()).hexdigest(), 'bytes': size}
            entry['estimates'] = {'seconds': 1, 'prepared_bytes': 1 << 20, 'peak_bytes': 1 << 20}
        catalog = tmp / 'catalog.json'
        catalog.write_text(json.dumps({'format': 1, 'entries': [base, point]}))

        (tmp / 'stubs.swift').write_text(STUBS)
        (tmp / 'main.swift').write_text(CHECK)
        subprocess.run(['xcrun', 'swiftc', *schema_sources(), '-O', '-suppress-warnings', '-swift-version', '5', *capacity_sources(ROOT, tmp), '-default-isolation', 'MainActor', '-D', 'DEBUG',
                        '-parse-as-library', '-module-cache-path', tmp / 'modules', *[source(s) for s in SOURCES],
                        ROOT / 'Shared/DeviceLinkProtocol.swift', tmp / 'stubs.swift', tmp / 'main.swift', '-o', tmp / 'check'], check=True)

        for case in ('download', 'import', 'cancel'):
            home, state = tmp / case / 'home', tmp / case / 'state'
            home.mkdir(parents=True)
            state.mkdir(parents=True)
            argv = tmp / case / 'argv.json'
            env = dict(os.environ, HOME=str(home), CFFIXED_USER_HOME=str(home), LTM_STATE_DIR=str(state), LTM_FIRMWAREKIT=str(FAKE), FAKE_ARGV=str(argv))
            subprocess.run([tmp / 'check', catalog, argv, tmp, case, ipsws / 'k48ap-8G4.ipsw'], check=True, env=env, timeout=120)
        print('PASS: check-sibling-download')
    finally:
        subprocess.run(['chflags', '-R', 'nouchg', tmp], check=False)
        subprocess.run(['chmod', '-R', 'u+w', tmp], check=False)
        subprocess.run(['rm', '-rf', tmp], check=False)


if __name__ == '__main__':
    main()
