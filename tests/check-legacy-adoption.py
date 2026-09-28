#!/usr/bin/env python3
"""Adopt every legacy state-key branch into Devices/<uuid>/device.json, in place.

Fixture state trees stand in for a packaged iPod (active pointer, retained old
base, and the pre-pointer 1.0 layout), a development iPod (nand-current, with
state before and after migrateStateNames), and a development iPad with an
overlay and a quarantined snapshot. Adoption must record the paths each device
already uses, change no existing path or inode, and be idempotent. Also checks
the shipped firmware catalog. Everything lives in a temporary directory.
"""
from pathlib import Path
import hashlib, json, os, re, subprocess, tempfile, uuid

root = Path(__file__).resolve().parents[1]
app = root / 'LightTouchMac'

# ---- Firmware catalog --------------------------------------------------------
catalog = json.loads((app / 'Resources/firmware-catalog.json').read_text())
assert catalog['format'] == 1
ids = [e['id'] for e in catalog['entries']]
assert len(ids) == len(set(ids)), 'duplicate catalog ids'
hexre = re.compile(r'^[0-9a-f]+$')
for e in catalog['entries']:
    for field in ('id', 'board', 'product_type', 'version', 'build', 'status', 'source', 'keys',
                  'emulator', 'estimates'):
        assert field in e, (e['id'], field)
    assert e['id'] == f"{e['board']}-{e['build']}", e['id']
    assert e['board'] in ('n72ap', 'k48ap') and e['product_type'] in ('iPod2,1', 'iPad1,1')
    assert e['status'] in ('available', 'experimental', 'coming_soon', 'user_ipsw')
    assert 'activation_hook' not in e
    src = e['source']
    if src['kind'] == 'bundled':
        assert src['resource'] == 'device/nand.itnand'
    else:
        assert src['kind'] == 'ipsw' and len(src['sha1']) == 40 and hexre.match(src['sha1']) and src['bytes'] > 0
        assert e['status'] == 'user_ipsw' or src['url'].startswith('https://')
    for name in ('iBoot', 'kernelcache', 'DeviceTree', 'UpdateRamDisk', 'rootfs'):
        assert name in e['keys'], (e['id'], name)
    for name, k in e['keys'].items():
        assert k['file'] and hexre.match(k['key']) and len(k['key']) in (32, 64, 72), (e['id'], name)
        assert name == 'rootfs' or (len(k.get('iv', '')) == 32 and hexre.match(k['iv'])), (e['id'], name)
    if e['status'] in ('available', 'experimental') and src['kind'] == 'ipsw':
        r = e['recipe']
        for field in ('name', 'version', 'storage', 'system_mib', 'data_size', 'options'):
            assert field in r, (e['id'], field)
    assert e['emulator']['min_protocol'] >= 1
status = {e['id']: e['status'] for e in catalog['entries']}
assert status == {'n72ap-7E18': 'user_ipsw', 'k48ap-7B500': 'available', 'k48ap-7B367': 'available',
                  'k48ap-8C148': 'experimental', 'n72ap-8C148': 'coming_soon', 'n72ap-5F138': 'coming_soon'}, status
sha = {e['id']: e['source'].get('sha1') for e in catalog['entries']}
assert sha['n72ap-7E18'] == '5f4f5c01eda2f811f73167e7d1f82dbeed82367b'   # docs/ipod/from-ipsw.md's IPSW
assert sha['k48ap-7B367'] == '172e8297af74b91971a802e6ad137c891f553099'
assert sha['k48ap-8C148'] == '8717b3bedc925b587566442ad375aa65d857e79a'
assert sha['k48ap-7B500'] == '68b613f78581d36eab96aa5a007001dff142baa3'

# ---- Key oracle (independent of the Swift) -----------------------------------
def b36(n):
    s = ''
    while True:
        n, r = divmod(n, 36)
        s = '0123456789abcdefghijklmnopqrstuvwxyz'[r] + s
        if not n: return s
def djb2(text):
    h = 5381
    for b in text.encode(): h = (h * 33 + b) & (2**64 - 1)
    return b36(h)
def legacy_key(files_root, nand): return f'{nand}-{djb2(files_root)}' if files_root else nand
def ipad_key(path): return f'ipad1-{os.path.basename(path)}-{djb2(path)}'

CHECK = r'''
import Foundation
nonisolated final class Counter: @unchecked Sendable { var value = 0 }
@main struct Check {
    @MainActor static func main() throws {
        let a = CommandLine.arguments
        let state = URL(fileURLWithPath: a[2], isDirectory: true)
        switch a[1] {
        case "resolve":
            // Mirrors LaunchOptions.resolved()/adoptionInputs.
            let filesRoot = a[3]
            var nand = a[4]
            if nand == "nand-current" {
                let target = try? FileManager.default.destinationOfSymbolicLink(atPath: "\(filesRoot)/nand-current")
                nand = target.map { ($0 as NSString).lastPathComponent } ?? "nand-ultimate"
            }
            let inputs = LegacyAdoption.Inputs(filesRoot: filesRoot, nand: nand, nandImage: "\(filesRoot)/\(nand)",
                packedNAND: "\(filesRoot)/nand.itnand", ipad1NAND: "\(filesRoot)/ipad1/userland/golden-appsync")
            let defaults = UserDefaults(suiteName: a[6])!
            let library = DeviceLibrary(state: state)
            let posted = Counter()
            let token = NotificationCenter.default.addObserver(forName: DeviceLibrary.didChangeNotification, object: library, queue: nil) { _ in posted.value += 1 }
            defer { NotificationCenter.default.removeObserver(token) }
            let before = library.instances
            let r = try LegacyAdoption.resolve(inputs, profile: a[5] == "ipad1" ? .iPad1 : .iPodTouch2G, state: state, defaults: defaults)
            library.reload()
            precondition(library.instance(id: r.instance.id) == r.instance)
            precondition((library.instances != before) == (posted.value == 1))
            let paths = r.instance.paths(state: state, logs: state.appendingPathComponent("Logs"))
            let out: [String: Any] = ["id": r.instance.id.uuidString, "packed": r.packedImage?.key ?? NSNull(),
                                      "retained": r.retained, "overlay": paths.overlay.path, "work": paths.work.path,
                                      "logs": paths.logs.path, "notice": defaults.object(forKey: r.instance.defaultsKey("deviceNotice")) ?? NSNull(),
                                      "pose": defaults.object(forKey: r.instance.defaultsKey("motionPose")) ?? NSNull()]
            print(String(decoding: try JSONSerialization.data(withJSONObject: out, options: .sortedKeys), as: UTF8.self))
        case "erase":
            try DeviceStateStorage.adoptBundledImageAfterErase(state: state, nand: a[3], manifest: URL(fileURLWithPath: a[4]))
        case "library":
            let library = DeviceLibrary(state: state)
            let posted = Counter()
            let token = NotificationCenter.default.addObserver(forName: DeviceLibrary.didChangeNotification, object: library, queue: nil) { _ in posted.value += 1 }
            defer { NotificationCenter.default.removeObserver(token) }
            let record = DeviceInstance(id: UUID(), name: "iPad", board: "k48ap", firmware: "k48ap-7B367", created: DeviceInstance.now,
                base: .init(kind: .prepared, path: "Devices/x/base"),
                storage: .init(key: "k", overlay: "o", writableNOR: nil, snapshot: "s", resetMarker: nil, usbmuxConf: "c"))
            try library.save(record)
            precondition(posted.value == 1 && library.instances(firmware: "k48ap-7B367") == [record])
            let saved = try DeviceInstance.read(DeviceInstance.directory(record.id, state: state).appendingPathComponent("device.json"))
            precondition(saved == record)
            try library.save(record)
            precondition(posted.value == 1)
            try library.remove(id: record.id)
            precondition(posted.value == 2 && library.instance(id: record.id) == nil)
            let catalog = try FirmwareCatalog.load(from: URL(fileURLWithPath: a[3]))
            precondition(catalog.entry(id: FirmwareCatalog.legacyIPodID)?.profile == .iPodTouch2G)
            precondition(catalog.entry(id: FirmwareCatalog.developmentIPadID)?.recipe?.options["appsync"] == true)
        default: fatalError()
        }
    }
}
'''

def tree(state):
    """path -> (inode, size, sha256) for files, (inode,) for directories."""
    out = {}
    for dirpath, dirs, files in os.walk(state):
        for name in dirs + files:
            p = Path(dirpath) / name
            st = p.lstat()
            if p.is_file() and not p.is_symlink():
                out[str(p.relative_to(state))] = (st.st_ino, st.st_size, hashlib.sha256(p.read_bytes()).hexdigest())
            else:  # a directory's size grows with new entries; its identity must not change
                out[str(p.relative_to(state))] = (st.st_ino,)
    return out

def write(p, text='x'):
    p.parent.mkdir(parents=True, exist_ok=True)
    p.write_text(text)

with tempfile.TemporaryDirectory(prefix='ltm-legacy-adoption-') as temporary:
    work = Path(temporary)
    exe = work / 'check'
    (work / 'check.swift').write_text(CHECK)
    sources = ['DeviceProfile', 'FirmwareCatalog', 'DeviceInstance', 'LegacyAdoption', 'DeviceStateStorage',
               'StorageLocations', 'DeviceLibrary', 'Bundled', 'NativeLogging', 'AppEventLog']
    subprocess.run(['xcrun', 'swiftc', '-swift-version', '6', '-default-isolation', 'MainActor',
                    '-module-cache-path', str(work / 'modules'), *[str(app / f'{s}.swift') for s in sources],
                    str(work / 'check.swift'), '-o', str(exe)], check=True)
    env = dict(os.environ, LTM_STATE_DIR=str(work / 'app-state'))  # AppEventLog's root, never the user's
    suite = f'ltm-legacy-adoption-{uuid.uuid4()}'

    def run(*args):
        return subprocess.run([str(exe), *map(str, args)], check=True, capture_output=True, text=True, env=env).stdout

    def resolve(state, files_root, nand, profile='ipod'):
        return json.loads(run('resolve', state, files_root, nand, profile, suite))

    def records(state):
        d = state / 'Devices'
        return {p.name: json.loads((p / 'device.json').read_text()) for p in d.iterdir()} if d.exists() else {}

    def adopt(state, files_root, nand, profile='ipod'):
        """Resolve twice; nothing pre-existing moves and the second run is a no-op."""
        before = tree(state)
        first = resolve(state, files_root, nand, profile)
        after = tree(state)
        for path, identity in before.items():
            assert after.get(path) == identity, f'{state.name}: {path} changed {identity} -> {after.get(path)}'
        recs = records(state)
        second = resolve(state, files_root, nand, profile)
        assert first == second, (first, second)
        assert records(state) == recs and tree(state) == after, f'{state.name}: second run changed state'
        assert not [p for p in state.iterdir() if p.name.startswith('.Devices-adopting')]
        return first, recs

    def only(recs, board):
        found = [r for r in recs.values() if r['board'] == board]
        assert len(found) == 1, found
        return found[0]

    def defaults_write(key, plist_type, value):
        subprocess.run(['defaults', 'write', suite, key, plist_type, *value], check=True)

    try:
        defaults_write('deviceNotice', '-dict', ['message', 'Legacy notice', 'operation', 'erase'])
        defaults_write('motionPose', '-int', ['1'])

        # 1. Packaged app: nand.itnand, active pointer to the shipped digest.
        digest = 'a' * 64
        files = work / 'Light Touch.app/Contents/Resources/device'
        write(files / 'nand.itnand'); write(files / 'nand.itnand.sha256', digest + '\n')
        state = work / 'packaged'
        key = f'nand-ultimate-{digest}'
        write(state / f'device/nand-ultimate-{digest}/bus0-ce0.pages')
        write(state / 'device/active-nand-ultimate.json', json.dumps({'key': key, 'directory': f'device/nand-ultimate-{digest}'}))
        write(state / f'nandrw-{key}/cs0/page'); write(state / f'nandrw-{key}/nor.bin')
        write(state / f'snapshot-{key}'); write(state / f'snapshot-{key}.meta')
        write(state / 'work/usbmuxd-conf/SystemConfiguration.plist'); write(state / 'work/usbmuxd-conf/0123.plist')
        result, recs = adopt(state, files, 'nand-current')
        assert len(recs) == 1, recs  # no iPad image or overlay here
        r = only(recs, 'n72ap')
        assert r['id'] == result['id'] and r['format'] == 1 and r['firmware'] == 'n72ap-7E18' and r['name'] == 'iPod touch'
        assert r['base'] == {'kind': 'legacyBundled', 'path': f'device/nand-ultimate-{digest}'}
        assert r['storage'] == {'key': key, 'overlay': f'nandrw-{key}', 'writableNOR': f'nandrw-{key}/nor.bin',
                                'snapshot': f'snapshot-{key}', 'resetMarker': f'.reset-{key}',
                                'usbmuxConf': 'work/usbmuxd-conf'}, r['storage']
        assert r['legacy'] == {'filesRoot': str(files), 'nand': 'nand-ultimate', 'pointer': 'device/active-nand-ultimate.json'}
        assert result['packed'] == key and result['retained'] is False
        assert result['overlay'] == str(state / f'nandrw-{key}')
        assert result['work'] == str(state / f"Devices/{r['id']}/work")
        assert result['logs'] == str(state / f"Logs/Devices/{r['id']}")
        assert result['notice'] == {'message': 'Legacy notice', 'operation': 'erase'} and result['pose'] == 1

        # Erase adopts the newly bundled base; the record follows the pointer.
        new_digest = 'b' * 64
        write(files / 'nand.itnand.sha256', new_digest + '\n')
        again = resolve(state, files, 'nand-current')
        assert again['id'] == r['id'] and again['retained'] is True and again['packed'] == key
        run('erase', state, 'nand-ultimate', files / 'nand.itnand.sha256')
        erased = resolve(state, files, 'nand-current')
        r2 = only(records(state), 'n72ap')
        new_key = f'nand-ultimate-{new_digest}'
        assert erased['id'] == r['id'] and erased['packed'] == new_key and erased['retained'] is False
        assert r2['storage']['key'] == new_key and r2['storage']['overlay'] == f'nandrw-{new_key}'
        assert r2['base']['path'] == f'device/nand-ultimate-{new_digest}' and r2['created'] == r['created']
        write(files / 'nand.itnand.sha256', digest + '\n')

        # 2. Packaged, keeping an older base: the pointer wins over the manifest.
        state = work / 'retained'
        old = 'c' * 64
        write(state / f'device/nand-ultimate-{old}/page')
        write(state / 'device/active-nand-ultimate.json', json.dumps({'key': f'nand-ultimate-{old}', 'directory': f'device/nand-ultimate-{old}'}))
        write(state / f'nandrw-nand-ultimate-{old}/page')
        write(state / f'snapshot-nand-ultimate-{old}.bad')
        result, recs = adopt(state, files, 'nand-current')
        r = only(recs, 'n72ap')
        assert result['retained'] is True and r['storage']['key'] == f'nand-ultimate-{old}'
        assert r['base']['path'] == f'device/nand-ultimate-{old}'

        # 3. The first itnand release: unpacked to device/nand-ultimate, no pointer,
        # overlay keyed by the bundle path. The pointer is created, nothing else.
        state = work / 'release-1.0'
        k = legacy_key(str(files), 'nand-ultimate')
        write(state / 'device/nand-ultimate/page')
        write(state / f'nandrw-{k}/page'); write(state / f'snapshot-{k}'); write(state / f'snapshot-{k}.meta')
        result, recs = adopt(state, files, 'nand-current')
        r = only(recs, 'n72ap')
        assert r['base'] == {'kind': 'legacyBundled', 'path': 'device/nand-ultimate'}
        assert r['storage']['key'] == k and r['storage']['overlay'] == f'nandrw-{k}' and r['storage']['snapshot'] == f'snapshot-{k}'
        assert json.loads((state / 'device/active-nand-ultimate.json').read_text()) == {'key': k, 'directory': 'device/nand-ultimate'}
        assert result['retained'] is True

        # 3b. Same, but the overlay predates keying on the files root.
        state = work / 'release-unkeyed'
        write(state / 'device/nand-ultimate/page'); write(state / 'nandrw-nand-ultimate/page')
        result, recs = adopt(state, files, 'nand-current')
        r = only(recs, 'n72ap')
        assert r['storage']['key'] == 'nand-ultimate' and r['storage']['overlay'] == 'nandrw-nand-ultimate'

        # 4. Development iPod: LTM_FILES + nand-current -> nand-agent-v4, state already
        # migrated by migrateStateNames; plus an iPad image with an overlay.
        dev = work / 'qemu-ios-files'
        write(dev / 'nand-agent-v4/bus0-ce0.pages')
        os.symlink('nand-agent-v4', dev / 'nand-current')
        ipad_nand = dev / 'ipad1/userland/golden-appsync'
        write(ipad_nand / 'page')
        state = work / 'development'
        k = legacy_key(str(dev), 'nand-agent-v4')
        ik = ipad_key(str(ipad_nand))
        write(state / f'nandrw-{k}/page'); write(state / f'nandrw-{k}/nor.bin')
        write(state / f'snapshot-{k}'); write(state / f'snapshot-{k}.meta'); write(state / f'snapshot-{k}.tmp')
        write(state / f'nandrw-{ik}/.base-identity', 'identity'); write(state / f'nandrw-{ik}/page')
        write(state / f'snapshot-{ik}.bad'); write(state / f'snapshot-{ik}.bad.meta')
        write(state / 'work/usbmuxd-conf/SystemConfiguration.plist', 'host')
        write(state / 'work/usbmuxd-conf/ipad-udid.plist', 'pairing')
        result, recs = adopt(state, dev, 'nand-current')
        assert len(recs) == 2
        r, ipad = only(recs, 'n72ap'), only(recs, 'k48ap')
        assert r['id'] == result['id'] and result['packed'] is None and result['retained'] is False
        assert r['base'] == {'kind': 'development', 'path': str(dev / 'nand-agent-v4')}
        assert r['storage'] == {'key': k, 'overlay': f'nandrw-{k}', 'writableNOR': f'nandrw-{k}/nor.bin',
                                'snapshot': f'snapshot-{k}', 'resetMarker': f'.reset-{k}', 'usbmuxConf': 'work/usbmuxd-conf'}
        assert r['legacy'] == {'filesRoot': str(dev), 'nand': 'nand-agent-v4'}
        assert ipad['firmware'] == 'k48ap-7B500' and ipad['name'] == 'iPad'
        assert ipad['base'] == {'kind': 'development', 'path': str(ipad_nand)}
        conf = f"Devices/{ipad['id']}/usbmuxd-conf"
        assert ipad['storage'] == {'key': ik, 'overlay': f'nandrw-{ik}', 'snapshot': f'snapshot-{ik}',
                                   'resetMarker': f'.reset-{ik}', 'usbmuxConf': conf}, ipad['storage']
        assert (state / conf / 'ipad-udid.plist').read_text() == 'pairing'  # a copy; the original stays
        assert (state / 'work/usbmuxd-conf/ipad-udid.plist').read_text() == 'pairing'
        iresult, irecs = adopt(state, dev, 'nand-current', 'ipad1')
        assert iresult['id'] == ipad['id'] and irecs == recs
        assert iresult['notice'] is None and iresult['pose'] is None  # only the iPod inherits
        assert result['notice'] == {'message': 'Legacy notice', 'operation': 'erase'}

        # A development launch naming another files root adopts that state too.
        other = work / 'other-files'
        write(other / 'nand-ultimate/page')
        ok = legacy_key(str(other), 'nand-ultimate')
        write(state / f'nandrw-{ok}/page')
        oresult, orecs = adopt(state, other, 'nand-ultimate')
        assert len(orecs) == 3 and orecs[oresult['id']]['storage']['overlay'] == f'nandrw-{ok}'
        assert orecs[oresult['id']]['storage']['usbmuxConf'] == f"Devices/{oresult['id']}/usbmuxd-conf"
        assert oresult['notice'] is None
        assert resolve(state, dev, 'nand-current')['id'] == r['id']

        # 5. Development iPod before migrateStateNames: the old names are recorded
        # where they are instead of being renamed.
        state = work / 'unmigrated'
        write(state / 'nandrw-nand-agent-v4/page'); write(state / 'snapshot-nand-agent-v4')
        write(state / 'snapshot-nand-agent-v4.meta'); write(state / '.reset-nand-agent-v4')
        write(state / f'nandrw-{ik}/page')
        result, recs = adopt(state, dev, 'nand-current', 'ipad1')
        r, ipad = only(recs, 'n72ap'), only(recs, 'k48ap')
        assert result['id'] == ipad['id']
        assert r['storage']['key'] == k  # identity key is still the keyed name
        assert r['storage']['overlay'] == 'nandrw-nand-agent-v4' and r['storage']['snapshot'] == 'snapshot-nand-agent-v4'
        assert r['storage']['resetMarker'] == '.reset-nand-agent-v4' and r['storage']['usbmuxConf'] == 'work/usbmuxd-conf'
        assert ipad['storage']['usbmuxConf'] == f"Devices/{ipad['id']}/usbmuxd-conf"

        # 6. A fresh install: records are created, no legacy state required.
        state = work / 'fresh'
        state.mkdir()
        result, recs = adopt(state, files, 'nand-current')
        r = only(recs, 'n72ap')
        assert r['storage']['key'] == key and result['packed'] == key

        # 7. An unattributable packaged overlay fails as before, but still adopts the iPad.
        state = work / 'ambiguous'
        write(state / 'device/nand-ultimate/page')
        write(state / 'nandrw-nand-ultimate-one/page'); write(state / 'nandrw-nand-ultimate-two/page')
        amb = work / 'amb-files'
        write(amb / 'nand.itnand'); write(amb / 'nand.itnand.sha256', digest + '\n')
        write(amb / 'ipad1/userland/golden-appsync/page')
        failed = subprocess.run([str(exe), 'resolve', state, amb, 'nand-current', 'ipod', suite], capture_output=True, env=env)
        assert failed.returncode != 0
        assert [x['board'] for x in records(state).values()] == ['k48ap']
        assert (state / 'nandrw-nand-ultimate-one/page').exists()

        run('library', work / 'library', app / 'Resources/firmware-catalog.json')
    finally:
        subprocess.run(['defaults', 'delete', suite], capture_output=True)
        plist = Path.home() / f'Library/Preferences/{suite}.plist'
        if plist.exists(): plist.unlink()

print('PASS: catalog validated; legacy state adopted in place for packaged, retained, 1.0, unkeyed, development, '
      'unmigrated, iPad, fresh and ambiguous trees; idempotent; erase follows the pointer')
