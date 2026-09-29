#!/usr/bin/env python3
"""The built-in iPod is an ordinary prepared device, and the old layout is erased once.

Compiles the production FirmwareCatalog, DeviceInstance, DeviceStateStorage, StorageLocations,
PreparationJob (its static publish), BundledBase, LegacyState and IPALibrary with stubs, against
the shipped catalog and a small packed base made with scripts/pack-base.py, in a temp state dir:

  fresh     no Devices/: the blob unpacks into Preparing/<id>/ and publishes as Devices/<id>
            with a .prepared record whose base has the boot files BootRecipe.preparedFiles wants,
            the base locked (uchg) and identity.json 0600; a second publish for the entry is
            refused by the one-device-per-entry rule the app applies
  legacy    the old layout (State/device/<nand>-<digest>, active-<nand>.json, nandrw-<key>, a
            legacyBundled record with a retained IPA, work/usbmuxd-conf, State/IPAs) is found;
            erase() keeps the IPAs in the library and the pairing, removes the rest; then the
            bundled publish seeds the new device with that pairing and removes it from work/
  none      a state dir with only prepared records has no legacy state

Also the catalog's shape: exactly one entry is bundled, and it is the iPod 3.1.3 user_ipsw entry.
"""
from pathlib import Path
import json, os, re, subprocess, sys, tempfile

ROOT = Path(__file__).resolve().parents[2]
APP = ROOT / 'LightTouchMac'
SOURCES = ['FirmwareCatalog.swift', 'DeviceInstance.swift', 'DeviceStateStorage.swift', 'StorageLocations.swift',
           'PreparationJob.swift', 'DeviceProfile.swift', 'BundledBase.swift', 'LegacyState.swift', 'IPALibrary.swift',
           'IPSWStore.swift', 'FirmwareDownloads.swift']

catalog = json.loads((APP / 'Resources/firmware-catalog.json').read_text())
bundled = [e for e in catalog['entries'] if e.get('bundled')]
assert [e['id'] for e in bundled] == ['n72ap-7E18'], bundled
assert bundled[0]['status'] == 'user_ipsw' and bundled[0]['bundled'] == 'device/n72ap-7E18.itbase'
assert bundled[0]['source']['sha1'] == '5f4f5c01eda2f811f73167e7d1f82dbeed82367b'
hexre = re.compile(r'^[0-9a-f]+$')
for e in catalog['entries']:
    assert e['id'] == f"{e['board']}-{e['build']}" and e['source']['kind'] == 'ipsw', e['id']
    assert len(e['source']['sha1']) == 40 and hexre.match(e['source']['sha1']) and e['source']['bytes'] > 0
    assert e['status'] == 'user_ipsw' or e['source']['url'].startswith('https://'), e['id']
    assert 'activation_hook' not in e and 'resource' not in e['source']

STUBS = r'''
import Foundation
nonisolated enum Bundled {
    static var stateDirectory: URL { URL(fileURLWithPath: ProcessInfo.processInfo.environment["LTM_STATE_DIR"]!) }
    static var logsDirectory: URL { stateDirectory.appendingPathComponent("Logs") }
}
extension DeviceInstance {
    nonisolated var paths: Paths { paths(state: Bundled.stateDirectory, logs: Bundled.logsDirectory) }
}
nonisolated func logEvent(_ message: String, _ arguments: CVarArg...) { print("  log: " + String(format: message, arguments: arguments)) }
'''

CHECK = r'''
import Foundation

func expect(_ ok: Bool, _ what: @autoclosure () -> String, line: Int = #line) {
    if !ok { print("FAIL line \(line): \(what())"); exit(1) }
}
@main struct Check {
@MainActor static func main() throws {
let fm = FileManager.default
let args = CommandLine.arguments
let catalog = try FirmwareCatalog.load(from: URL(fileURLWithPath: args[1]))
let blob = URL(fileURLWithPath: args[2])
let state = Bundled.stateDirectory
let entry = catalog.bundledEntry!
expect(entry.id == "n72ap-7E18" && entry.profile == .iPodTouch2G, "the bundled entry")

/// What FirmwareJobs.prepareBundled does, without the job bookkeeping.
func publishBundled(pairing: URL?) throws -> DeviceInstance {
    let id = UUID()
    let staging = PreparationJob.preparing(state).appendingPathComponent(id.uuidString, isDirectory: true)
    try StorageLocations.privateDirectory(staging)
    try BundledBase.unpack(blob, into: staging)
    let instance = try PreparationJob.publish(staging: staging, entry: entry, id: id, state: state, pairing: pairing)
    if let pairing { try? DeviceStateStorage.removeTree(pairing) }
    return instance
}
func mode(_ url: URL) -> Int { (try! fm.attributesOfItem(atPath: url.path)[.posixPermissions] as! NSNumber).intValue }

switch args[3] {
case "fresh":
    expect(LegacyState.find(state: state, applicationSupport: nil) == nil, "a fresh state has nothing legacy")
    expect(DeviceInstance.all(state: state).isEmpty, "no devices yet")
    let instance = try publishBundled(pairing: nil)
    let records = DeviceInstance.all(state: state)
    expect(records == [instance] && instance.firmware == entry.id && instance.board == "n72ap", "published as the entry's device: \(records)")
    expect(instance.base.kind == .prepared && instance.base.path == "Devices/\(instance.id.uuidString)/base", "a prepared record: \(instance.base)")
    expect(instance.storage.writableNOR == "Devices/\(instance.id.uuidString)/nor.bin" && instance.storage.usbmuxConf == "Devices/\(instance.id.uuidString)/usbmuxd-conf", "\(instance.storage)")
    expect(instance.identity?.udid != nil && instance.provenance?.sha256 != nil && instance.storage.key.count == 16, "identity and provenance from the lock")
    let paths = instance.paths
    let boot = DeviceProfile.iPodTouch2G.preparedBoot(strategy: BootRecipe.bootStrategy(paths.base.appendingPathComponent("device.lock.json")))
    let files = try BootRecipe.preparedFiles(base: paths.base, overlay: paths.overlay, writableNOR: paths.writableNOR, boot: boot.boot, also: boot.files)
    expect(files.boot.lastPathComponent == "iBoot.bin" && fm.fileExists(atPath: files.nand.appendingPathComponent("cs0/1.page").path), "the boot files BootRecipe wants")
    expect(files.writableNOR.map { fm.fileExists(atPath: $0.path) && mode($0) & 0o200 != 0 } == true, "a writable NOR clone on first boot")
    expect(mode(paths.base.appendingPathComponent("identity.json")) == 0o600 && mode(paths.base.appendingPathComponent("nor.bin")) == 0o444, "packed modes kept")
    expect(try DeviceStateStorage.pinOverlay(paths.overlay, toBase: instance.storage.key), "the overlay is pinned to the base")
    expect((try? fm.removeItem(at: paths.base.appendingPathComponent("gid-blobs.bin"))) == nil, "the base is locked")
    expect((try? fm.contentsOfDirectory(atPath: PreparationJob.preparing(state).path))?.isEmpty == true, "Preparing/ is empty afterwards")
    expect(DeviceInstance.lockLacksActivation(paths.base.appendingPathComponent("device.lock.json")) == false, "the lock records the activation")
    expect(!DeviceInstance.all(state: state).filter { $0.firmware == entry.id }.isEmpty, "the row is Ready: a device exists for the entry")
    print("PASS fresh: the built-in iPod is published as a prepared device from its packed base")

case "legacy":
    let legacy = LegacyState.find(state: state, applicationSupport: URL(fileURLWithPath: args[4]))!
    expect(legacy.records.count == 1 && legacy.oldRoot != nil, "the legacy record and the old root are found: \(legacy.records) \(String(describing: legacy.oldRoot))")
    let names = Set(legacy.items.map(\.lastPathComponent))
    expect(names.isSuperset(of: ["device", "nandrw-nand-ultimate", "snapshot-nand-ultimate", "IPAs", "app.log", "usbmuxd.pid", "session.env", "AppCache"]), "\(names)")
    expect(!names.contains("Library") && !names.contains("Devices") && !names.contains("work") && !names.contains(".app-lock"), "the library, the devices and the pairing stay: \(names)")
    expect(DeviceInstance.all(state: state).isEmpty, "the legacy record does not decode as a device")
    try legacy.erase()
    for name in ["device", "nandrw-nand-ultimate", "snapshot-nand-ultimate", "IPAs", "app.log", "AppCache", "work/usbmuxd.pid", "work/session.env"] {
        expect(!fm.fileExists(atPath: state.appendingPathComponent(name).path), "\(name) erased")
    }
    expect(!fm.fileExists(atPath: args[4] + "/LightTouchMac"), "the old root erased")
    expect((try? fm.contentsOfDirectory(atPath: state.appendingPathComponent("Devices").path))?.isEmpty == true, "the legacy record's directory erased")
    let pairing = state.appendingPathComponent("work/usbmuxd-conf")
    expect(fm.fileExists(atPath: pairing.appendingPathComponent("device.plist").path), "the pairing survives the erase")
    let kept = Set(IPALibrary.index.values.map(\.bundleID))
    expect(kept == ["com.example.retained", "com.example.shared", "com.example.old"], "every retained IPA is in the library: \(kept)")
    expect(fm.fileExists(atPath: state.appendingPathComponent("Library/IPAs/index.json").path), "the library index")
    expect(LegacyState.find(state: state, applicationSupport: URL(fileURLWithPath: args[4])) == nil, "erased once: nothing legacy left")
    let instance = try publishBundled(pairing: fm.fileExists(atPath: pairing.path) ? pairing : nil)
    expect(fm.fileExists(atPath: instance.paths.usbmuxConf.appendingPathComponent("device.plist").path), "the new device is seeded with the pairing")
    expect(!fm.fileExists(atPath: pairing.path), "the pairing left work/")
    expect(DeviceInstance.all(state: state).map(\.id) == [instance.id], "one device: the built-in iPod")
    print("PASS legacy: the old layout goes, IPAs and pairing stay, the built-in iPod takes the pairing")

case "none":
    expect(LegacyState.find(state: state, applicationSupport: URL(fileURLWithPath: args[4])) == nil, "prepared records are not legacy")
    print("PASS none: a library of prepared devices has nothing to erase")
default: fatalError(args[3])
}
}
}
'''


def main():
    tmp = Path(tempfile.mkdtemp(prefix='ltm-bundled-prepared-'))
    try:
        # A small base with the shape firmwarekit's n72 recipe makes, packed as the release does.
        base = tmp / 'base'
        (base / 'nand/cs0').mkdir(parents=True)
        (base / 'nand/cs0/1.page').write_bytes(b'\xff' * 4160)
        for name in ('iBoot.bin', 'gid-blobs.bin'):
            (base / name).write_bytes(b'boot')
        (base / 'nor.bin').write_bytes(b'\x00' * 1048576)
        (base / 'nor.bin').chmod(0o444)
        (base / 'identity.json').write_text(json.dumps({'udid': 'a' * 40, 'seed': 'fixture'}))
        (base / 'identity.json').chmod(0o600)
        (base / 'device.lock.json').write_text(json.dumps({
            'format': 1, 'entry': {'id': 'n72ap-7E18'}, 'machine': {'aes-uid': 'engine'},
            'identity': {'udid': 'a' * 40, 'seed': 'fixture'}, 'inputs': {'activation': {'input_sha256': '0', 'output_sha256': '0'}}}))
        blob = tmp / 'n72ap-7E18.itbase'
        subprocess.run([sys.executable, ROOT / 'scripts/pack-base.py', 'pack', base, blob], check=True, stdout=subprocess.DEVNULL)

        (tmp / 'stubs.swift').write_text(STUBS)
        (tmp / 'main.swift').write_text(CHECK)
        subprocess.run(['xcrun', 'swiftc', '-O', '-suppress-warnings', '-swift-version', '5', '-default-isolation', 'MainActor', str(APP / 'BootRecipe.swift'),
                        '-parse-as-library', '-module-cache-path', tmp / 'modules', *[APP / s for s in SOURCES], ROOT / 'Shared/DeviceLinkProtocol.swift',
                        tmp / 'stubs.swift', tmp / 'main.swift', '-o', tmp / 'check'], check=True)
        catalog_path = APP / 'Resources/firmware-catalog.json'

        def run(case, state, support=''):
            state.mkdir(parents=True, exist_ok=True)
            subprocess.run([tmp / 'check', catalog_path, blob, case, support], check=True, env=dict(os.environ, LTM_STATE_DIR=str(state)))

        run('fresh', tmp / 'fresh')

        # The old layout: a 1.0 root, plus a multidevice state with an adopted (legacyBundled) iPod.
        support = tmp / 'Library/Application Support'
        old = support / 'LightTouchMac'
        (old / 'IPAs').mkdir(parents=True)
        (old / 'IPAs/com.example.old.ipa').write_bytes(b'old ipa')
        (old / 'work/usbmuxd-conf').mkdir(parents=True)
        (old / 'work/usbmuxd-conf/device.plist').write_text('paired')
        state = support / 'gold.samhenri.LightTouchMac'
        digest = 'b' * 64
        (state / f'device/nand-ultimate-{digest}/cs0').mkdir(parents=True)
        (state / f'device/nand-ultimate-{digest}/cs0/0.page').write_bytes(b'\xff' * 4160)
        (state / 'device/active-nand-ultimate.json').write_text(json.dumps({'key': f'nand-ultimate-{digest}', 'directory': f'device/nand-ultimate-{digest}'}))
        (state / 'nandrw-nand-ultimate/cs0').mkdir(parents=True)
        (state / 'nandrw-nand-ultimate/nor.bin').write_bytes(b'\x00' * 16)
        (state / 'snapshot-nand-ultimate').write_bytes(b'ram')
        (state / 'IPAs').mkdir()
        (state / 'IPAs/com.example.shared.ipa').write_bytes(b'shared ipa')
        (state / 'AppCache').mkdir()
        (state / 'app.log').write_text('events')
        (state / 'work').mkdir()
        (state / 'work/usbmuxd.pid').write_text('1\n')
        (state / 'work/session.env').write_text('SOCK=x\n')
        (state / 'work/usbmuxd-conf').mkdir()
        (state / 'work/usbmuxd-conf/device.plist').write_text('paired')
        (state / 'work/usbmuxd-conf/SystemConfiguration.plist').write_text('host')
        (state / 'Library/IPAs').mkdir(parents=True)
        (state / 'Library/IPAs/index.json').write_text('{}')
        record = str(__import__('uuid').uuid4()).upper()
        (state / f'Devices/{record}/IPAs').mkdir(parents=True)
        (state / f'Devices/{record}/IPAs/com.example.retained.ipa').write_bytes(b'retained ipa')
        (state / f'Devices/{record}/device.json').write_text(json.dumps({
            'format': 1, 'id': record, 'name': 'iPod touch', 'board': 'n72ap', 'firmware': 'n72ap-7E18', 'created': '2026-09-01T00:00:00Z',
            'base': {'kind': 'legacyBundled', 'path': f'device/nand-ultimate-{digest}'},
            'storage': {'key': 'nand-ultimate', 'overlay': 'nandrw-nand-ultimate', 'writableNOR': 'nandrw-nand-ultimate/nor.bin',
                        'snapshot': 'snapshot-nand-ultimate', 'usbmuxConf': 'work/usbmuxd-conf'},
            'legacy': {'filesRoot': '/x', 'nand': 'nand-ultimate', 'pointer': 'device/active-nand-ultimate.json'}}))
        run('legacy', state, support)

        prepared = tmp / 'prepared'
        run('fresh', prepared)   # leaves one prepared record
        run('none', prepared, tmp / 'nowhere')
        print('PASS: check-bundled-prepared')
    finally:
        subprocess.run(['chmod', '-R', 'u+w', tmp], check=False)
        subprocess.run(['chflags', '-R', 'nouchg', tmp], check=False)
        subprocess.run(['rm', '-rf', tmp], check=False)


if __name__ == '__main__':
    main()
