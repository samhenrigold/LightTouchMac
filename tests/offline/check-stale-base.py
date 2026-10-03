#!/usr/bin/env python3
"""A device whose base an older recipe made is flagged for Prepare Again; current and other boards' bases aren't.

Compiles the real DeviceRow (its lock reader and the comparison) with the real FirmwareCatalog against the
shipped catalog, and writes device.lock.json files in the shape firmwarekit writes (entry.content is the catalog
entry the base was prepared from, every lock since the first firmwarekit):

  n45 old       an N45 base from before the 4-page map context fix (recipe 1): flagged, Prepare Again allowed
  n45 RC7       recipe 2 (the 4-page map fix; RC7's bases): not flagged
  n72 RC7       recipe 1 bases before exact GPT/HFS size (RC7's), never started since: not flagged across
                2.x/3.x/4.x, because boot admission migrates n72 1 -> 2 in place at the next start
                (FirmwareWire.admissionRecipeSteps); an N72 lock below every declared step (recipe 0) still is
  n72 current   recipe 2, even an older tool-version field: not flagged
  k48           recipe 1 entries (RC4 to RC7 bases): not flagged
The RC7 cases pin the shipped recipes: a later bump flags every existing device, so it must change them knowingly.
  n72 migrated  recipe 1 with boot admission's migrated-recipe.json (recipe 2) in the device directory: not
                flagged; nor with a marker naming recipe 1 (the admission step still applies)
  device.py     a lock with no entry (the Python preparer): not flagged; nor an unreadable lock
Also: Prepare Again needs the preparer and a stopped device; Start stays the placeholder's button.
"""
from pathlib import Path
import copy, json, subprocess, tempfile, sys

root = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(root / 'scripts'))
import host_runtime
app = root / 'LightTouchMac'
catalog = json.loads((app / 'Resources/firmware-catalog.json').read_text())
entries = {e['id']: e for e in catalog['entries']}
assert entries['n45ap-4B1']['recipe']['version'] > 1, 'the N45 entries require the fixed recipe'
assert all(e['recipe']['version'] > 1 for e in entries.values() if e['board'] == 'n72ap'), 'all N72 recipes mark the corrected partition geometry'


def lock(entry_id, recipe=None, tool='0.2.0'):
    content = copy.deepcopy(entries[entry_id])
    if recipe is not None:
        content['recipe']['version'] = recipe
    return {'format': 1, 'board': content['board'], 'build': content['build'],
            'tool': {'name': 'firmwarekit', 'version': tool}, 'entry': {'id': entry_id, 'sha256': '0' * 64, 'content': content}}


cases = [  # name, entry, lock (dict, or raw text), flagged[, the device directory's migrated-recipe.json]
    ('n45-old', 'n45ap-4B1', lock('n45ap-4B1', recipe=1), True),
    ('n45-old-3A101a', 'n45ap-3A101a', lock('n45ap-3A101a', recipe=1), True),
    ('n45-current', 'n45ap-4B1', lock('n45ap-4B1'), False),
    ('n45-rc7', 'n45ap-3A101a', lock('n45ap-3A101a', recipe=2), False),
    ('n72-rc7-unmigrated-2x', 'n72ap-5F138', lock('n72ap-5F138', recipe=1), False),
    ('n72-rc7-unmigrated-3x', 'n72ap-7E18', lock('n72ap-7E18', recipe=1), False),
    ('n72-rc7-unmigrated-4x', 'n72ap-8C148', lock('n72ap-8C148', recipe=1), False),
    ('n72-below-admission-steps', 'n72ap-7E18', lock('n72ap-7E18', recipe=0), True),
    ('n72-current', 'n72ap-7E18', lock('n72ap-7E18'), False),
    ('n72-exact-gpt', 'n72ap-8C148', lock('n72ap-8C148', recipe=2), False),
    ('n72-current-old-tool-field', 'n72ap-7E18', lock('n72ap-7E18', tool='0.1.0'), False),
    ('n72-rc7-migrated-2x', 'n72ap-5F138', lock('n72ap-5F138', recipe=1), False, {'recipe': 2, 'step': 'n72-exact-gpt'}),
    ('n72-rc7-migrated-3x', 'n72ap-7E18', lock('n72ap-7E18', recipe=1), False, {'recipe': 2, 'step': 'n72-exact-gpt'}),
    ('n72-rc7-migrated-4x', 'n72ap-8C148', lock('n72ap-8C148', recipe=1), False, {'recipe': 2, 'step': 'n72-exact-gpt'}),
    ('n72-rc7-marker-recipe-1', 'n72ap-7E18', lock('n72ap-7E18', recipe=1), False, {'recipe': 1}),
    ('k48-rc4', 'k48ap-7B500', lock('k48ap-7B500', tool='0.1.0'), False),
    ('k48-rc5', 'k48ap-8C148', lock('k48ap-8C148'), False),
    ('k48-rc7', 'k48ap-7B500', lock('k48ap-7B500', recipe=1), False),
    ('device-py', 'n45ap-4B1', {'format': 1, 'board': 'n45ap', 'activation_hook': None}, False),
    ('unreadable', 'n45ap-4B1', 'not json', False),
]

check = r'''
import Foundation
@main struct Check {
    static func main() throws {
        let args = CommandLine.arguments
        let catalog = try FirmwareCatalog.load(from: URL(fileURLWithPath: args[1]))
        var failures: [String] = []
        for spec in args.dropFirst(2) {
            let f = spec.split(separator: ":").map(String.init)   // name:entry:lock path:flagged:device directory
            let entry = catalog.entry(id: f[1])!, want = f[3] == "1"
            let row = DeviceRow(entry: entry, instanceID: UUID(), session: nil, job: nil,
                                baseRecipe: DeviceRow.baseRecipeVersion(URL(fileURLWithPath: f[2]), device: URL(fileURLWithPath: f[4])))
            if row.preparedByOlderRecipe != want { failures.append("\(f[0]): flagged \(row.preparedByOlderRecipe), want \(want)") }
            if row.allows(.prepareAgain, canDownload: true) != want { failures.append("\(f[0]): Prepare Again allowed \(!want)") }
            if (row.olderRecipeNote != nil) != want { failures.append("\(f[0]): note \(row.olderRecipeNote ?? "nil")") }
            if row.primaryAction != .start { failures.append("\(f[0]): the button is \(String(describing: row.primaryAction)), not Start") }
            guard want else { continue }
            if row.olderRecipeNote != "This iPod was prepared by an older version of Light Touch." { failures.append("\(f[0]): \(row.olderRecipeNote ?? "no note")") }
            if row.allows(.prepareAgain, canDownload: false) { failures.append("\(f[0]): Prepare Again without the preparer") }
            let running = DeviceRow(entry: entry, instanceID: UUID(), session: .running, job: nil, baseRecipe: 1)
            if running.allows(.prepareAgain, canDownload: true) { failures.append("\(f[0]): Prepare Again while running") }
            if DeviceRow(entry: entry, instanceID: nil, session: nil, job: nil, baseRecipe: 1).preparedByOlderRecipe {
                failures.append("\(f[0]): flagged with no device")
            }
        }
        precondition(failures.isEmpty, failures.joined(separator: "\n"))
        print("PASS: \(args.count - 2) locks; only bases older than their entry's recipe are flagged for Prepare Again")
    }
}
'''

with tempfile.TemporaryDirectory(prefix='ltm-stale-base-') as tmp:
    tmp = Path(tmp)
    specs = []
    for name, entry_id, body, flagged, *marker in cases:
        path = tmp / f'{name}.lock.json'
        path.write_text(body if isinstance(body, str) else json.dumps(body))
        device = tmp / f'{name}.device'   # every case has one; only the migrated ones hold a marker
        device.mkdir()
        if marker:
            (device / 'migrated-recipe.json').write_text(json.dumps(marker[0]))
        specs.append(f'{name}:{entry_id}:{path}:{int(flagged)}:{device}')
    (tmp / 'main.swift').write_text(check)
    subprocess.run(['xcrun', 'swiftc', *host_runtime.swift_flags(root), '-parse-as-library', '-swift-version', '5', '-module-cache-path', str(tmp / 'modules'),
                    str(root / 'Packages/FirmwareKit/Sources/FirmwareSchema/FirmwareWire.swift'), str(app / 'Library/FirmwareCatalog.swift'), str(app / 'Device/DeviceProfile.swift'),
                    str(app / 'Device/DeviceRow.swift'), str(tmp / 'main.swift'), '-o', str(tmp / 'check')], check=True)
    subprocess.run([str(tmp / 'check'), str(app / 'Resources/firmware-catalog.json'), *specs], check=True, timeout=60)
