#!/usr/bin/env python3
"""GuestPackage (LightTouchMac/Guest/GuestPackage.swift) against qemu-ios's mkpkg.py as the oracle.

A package tree with a manifest is packed with mkpkg.pack; mkpkg.py `offer` composes the
reference offer directory; the app's compose must write the same `offer` text and the same
payload files. Also: verdict lines from device.json `guest`, the built-in (serial 0) offer,
hooks dropped by the preparer's lock (another GL table, a target the device lacks), stub and
foreign-build packages, a host protocol the app doesn't speak, a payload that doesn't match its
manifest, the UI status for each report, and a tolerant `guest` record decode.

    tests/sessions/check-guest-package.py [--qemu-ios DIR]     (default: the pin, scripts/sources.py)
"""
import argparse, hashlib, json, os, subprocess, sys, tempfile
from pathlib import Path

root = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(root / 'scripts'))
import sources  # the pinned checkouts (build-support/sources.json)
ap = argparse.ArgumentParser()
ap.add_argument('--qemu-ios', type=Path, default=sources.path('qemu-ios'))
args = ap.parse_args()
sys.path.insert(0, str(args.qemu_ios / 'contrib/guest-package'))
import mkpkg

MBX = mkpkg.MBX


def package(tree, family, builds, serial, stub=False, host=None):
    """A package directory as mkpkg.assemble writes one."""
    pkg = tree / family
    files = []
    for name, mode in (('bin/it_agent', 0o755), ('bin/itmedia', 0o755), ('jobs/com.qemu.it-agent.plist', 0o644),
                       ('hooks/MBXGLEngine', 0o755), ('hooks/libappsync.dylib', 0o755)):
        data = (family + name).encode() * 50
        (pkg / name).parent.mkdir(parents=True, exist_ok=True)
        (pkg / name).write_bytes(data)
        (pkg / name).chmod(mode)
        files.append({'name': name, 'mode': '%o' % mode, 'size': len(data), 'sha256': hashlib.sha256(data).hexdigest()})
    manifest = {'format': 1, 'serial': serial, 'version': '1.%d.0' % serial, 'family': family, 'arch': 'armv6', 'stub': stub,
                'requires': {'boards': ['n72ap'], 'builds': builds, 'link': 'modern', 'host': host or mkpkg.HOST},
                'provides': ['it_agent', 'itmedia'], 'files': files, 'jobs': ['jobs/com.qemu.it-agent.plist'],
                'hooks': [{'file': 'hooks/MBXGLEngine', 'target': MBX, 'gli': '7E18', 'respring': True},
                          {'file': 'hooks/libappsync.dylib', 'target': '/usr/lib/libappsync.dylib', 'gli': None, 'respring': False}]}
    (pkg / 'manifest.json').write_text(json.dumps(manifest))
    return manifest


with tempfile.TemporaryDirectory(prefix='ltm-guest-package-') as t:
    t = Path(t)
    tree = t / 'packages'
    package(tree, 'n72-ios2', ['5F138'], 3, stub=True)
    good = package(tree, 'n72-ios3', ['7E18'], 7)
    package(tree, 'n72-ios9', ['9A1'], 7, host={'guest-package': [2, 3], 'gles': [0, 0]})
    entries = []
    for family in ('n72-ios2', 'n72-ios3', 'n72-ios9'):
        m = json.loads((tree / family / 'manifest.json').read_text())
        entries.append((family + '/manifest.json', (tree / family / 'manifest.json').read_bytes()))
        entries += [(family + '/' + f['name'], (tree / family / f['name']).read_bytes()) for f in m['files']]
    entries += [('loader/it_boot', b'\xce\xfa\xed\xfe'), ('loader/com.qemu.it-boot.plist', b'<plist/>')]
    mkpkg.pack(entries, str(t / 'armv6.itpack'))
    mkpkg.offer(str(tree / 'n72-ios3'), str(t / 'oracle'), '7E18', good=[5], bad=[6])
    # The oracle for a lock that kept only the GL hook: the manifest without the other hook.
    trimmed = dict(good, hooks=good['hooks'][:1], files=[f for f in good['files'] if f['name'] != 'hooks/libappsync.dylib'])
    (t / 'trimmed.txt').write_text(mkpkg.offer_text(trimmed, '7E18'))

    check = r'''
import Foundation
struct GuestPackageReport: Sendable, Equatable { var serial: Int64; var result: Int32 }
enum DeviceToolsError: Error { case failed(String) }
func files(_ dir: URL) -> [String: Data] {
  var out: [String: Data] = [:]
  for rel in (try? FileManager.default.subpathsOfDirectory(atPath: dir.path)) ?? [] {
    var isDir: ObjCBool = false
    if FileManager.default.fileExists(atPath: dir.appendingPathComponent(rel).path, isDirectory: &isDir), !isDir.boolValue {
      out[rel] = try! Data(contentsOf: dir.appendingPathComponent(rel))
    }
  }
  return out
}
func check(_ ok: Bool, _ message: String = "", line: Int = #line) { precondition(ok, "line \(line): \(message)") }
@main struct Check {
 static func main() throws {
  let t = URL(fileURLWithPath: CommandLine.arguments[1])
  let pack = t.appendingPathComponent("armv6.itpack")
  let entries = try GuestPackage.read(pack)
  check(entries.count == 20 && entries.last?.name == "loader/com.qemu.it-boot.plist")
  // The same offer and payloads as mkpkg.py offer, with the record's verdicts.
  var record = DeviceInstance.Guest(); record.lastGood = 5; record.bad = [6]
  let dir = t.appendingPathComponent("work/guest-offer")
  let offer = try GuestPackage.compose(itpack: pack, board: "n72ap", build: "7E18", lock: nil, guest: record, into: dir)!
  check(offer == GuestPackage.Offer(bundled: 7, version: "1.7.0", serial: 7, glHook: true))
  let ours = files(dir), oracle = files(t.appendingPathComponent("oracle"))
  check(ours == oracle, "offer directory differs from mkpkg.py offer: \(ours.keys.sorted()) vs \(oracle.keys.sorted())")
  // Recomposing replaces the directory and leaves no staging behind.
  _ = try GuestPackage.compose(itpack: pack, board: "n72ap", build: "7E18", lock: nil, guest: nil, into: dir)
  let text = String(decoding: try Data(contentsOf: dir.appendingPathComponent("offer")), as: UTF8.self)
  let left = try FileManager.default.contentsOfDirectory(atPath: dir.deletingLastPathComponent().path)
  check(!text.contains("verdict") && left == ["guest-offer"], "\(left)")
  // A lock that kept only the GL hook drops the other (and its file), as the seed did.
  var lock = GuestPackage.LockRecord(seed: 1, gli: "7E18", hooks: [GuestPackage.Manifest.mbx])
  _ = try GuestPackage.compose(itpack: pack, board: "n72ap", build: "7E18", lock: lock, guest: nil, into: dir)
  let trimmed = String(decoding: try Data(contentsOf: dir.appendingPathComponent("offer")), as: UTF8.self)
  check(trimmed == String(decoding: try Data(contentsOf: t.appendingPathComponent("trimmed.txt")), as: UTF8.self), trimmed)
  check(!FileManager.default.fileExists(atPath: dir.appendingPathComponent("hooks/libappsync.dylib").path))
  // No shim installed (gli null): the GL hook goes, and the offer has no GL hook.
  lock = GuestPackage.LockRecord(seed: 1, gli: nil, hooks: nil)
  let noGL = try GuestPackage.compose(itpack: pack, board: "n72ap", build: "7E18", lock: lock, guest: nil, into: dir)!
  check(!noGL.glHook && !FileManager.default.fileExists(atPath: dir.appendingPathComponent("hooks/MBXGLEngine").path))
  // Built-in tools: serial 0, no payloads, while the bundled serial is the one chosen.
  record.builtIn = 7
  let builtIn = try GuestPackage.compose(itpack: pack, board: "n72ap", build: "7E18", lock: nil, guest: record, into: dir)!
  check(builtIn.serial == 0 && files(dir).keys.sorted() == ["offer"])
  let zero = String(decoding: try Data(contentsOf: dir.appendingPathComponent("offer")), as: UTF8.self)
  check(zero == "ltpkg 1\nbuild 7E18\nserial 0 1.7.0\nverdict good 5\nverdict bad 6\n", zero)
  record.builtIn = 6
  check(try GuestPackage.compose(itpack: pack, board: "n72ap", build: "7E18", lock: nil, guest: record, into: dir)!.serial == 7,
               "a newer bundled package ends the built-in choice")
  // Nothing for a stub, another build, another board or an unspoken host protocol; no directory either.
  for (board, build) in [("n72ap", "5F138"), ("n72ap", "8C148"), ("k48ap", "7E18"), ("n72ap", "9A1")] {
   let none = try GuestPackage.compose(itpack: pack, board: board, build: build, lock: nil, guest: nil, into: dir)
   check(none == nil, build)
   check(!FileManager.default.fileExists(atPath: dir.path))
  }
  // Not an itpack.
  do {
   _ = try GuestPackage.read(t.appendingPathComponent("oracle/offer")); fatalError("not an itpack accepted")
  } catch {}
  // UI status.
  let o = GuestPackage.Offer(bundled: 7, version: "1.7.0", serial: 7, glHook: true)
  typealias S = GuestPackage.Status
  check(GuestPackage.status(report: nil, offer: nil, record: nil, glesProtocol: 0) == S.unknown)
  check(GuestPackage.status(report: .init(serial: 7, result: 1), offer: o, record: nil, glesProtocol: 0) == S.current(serial: 7))
  check(GuestPackage.status(report: .init(serial: 7, result: 0), offer: o, record: nil, glesProtocol: 0) == S.current(serial: 7))
  check(GuestPackage.status(report: .init(serial: 5, result: -2), offer: o, record: nil, glesProtocol: 0) == S.outOfDate)
  check(GuestPackage.status(report: .init(serial: 7, result: 0), offer: o, record: nil, glesProtocol: 3) == S.outOfDate, "GL wire out of range")
  check(GuestPackage.status(report: .init(serial: 5, result: 3), offer: o, record: nil, glesProtocol: 0) == S.reverted(serial: 5, why: .revertedBad))
  check(GuestPackage.status(report: .init(serial: 5, result: 5), offer: o, record: nil, glesProtocol: 0) == S.reverted(serial: 5, why: .refused))
  check(GuestPackage.status(report: .init(serial: 1, result: 2), offer: GuestPackage.Offer(bundled: 7, version: "", serial: 0, glHook: false),
                                   record: nil, glesProtocol: 0) == S.builtIn(serial: 1))
  var restored = DeviceInstance.Guest(); restored.active = 5
  check(GuestPackage.status(report: nil, offer: o, record: restored, glesProtocol: 0) == S.outOfDate, "a restored session on older tools")
  restored.bad = [7]
  check(GuestPackage.status(report: nil, offer: o, record: restored, glesProtocol: 0) == S.unknown)
  check(S.outOfDate.text == "Out of date — restart to update" && S.legacy.text == "Won’t update — erase and prepare again to get updates")
  check(S.current(serial: 3).text == "Up to date" && S.builtIn(serial: 1).text == "Built in")
  check(S.reverted(serial: 1, why: .revertedBad).text == "Using an earlier version — the update didn’t work")
  check(S.reverted(serial: 1, why: .revertedTries).text.hasSuffix("kept failing") && S.reverted(serial: 1, why: .refused).text.hasSuffix("was refused"))
  check(S.unknown.text == "Unknown" && S.notResponding.text == "Not responding" && S.recovery.text == "Unavailable in recovery mode" && S.notBooted.text == "Waiting for iOS")
  // Verdicts.
  typealias V = GuestPackage.Verdict
  let r7 = GuestPackageReport(serial: 7, result: 1)
  var seen = DeviceInstance.Guest(); seen.seed = 1; seen.lastGood = 5
  check(GuestPackage.verdict(report: r7, healthyFor: .seconds(10), elapsed: .seconds(40), record: seen, restored: false) == V.good(7))
  check(GuestPackage.verdict(report: r7, healthyFor: .seconds(9), elapsed: .seconds(40), record: seen, restored: false) == nil)
  check(GuestPackage.verdict(report: nil, healthyFor: .seconds(30), elapsed: .seconds(60), record: seen, restored: false) == V.legacy)
  check(GuestPackage.verdict(report: nil, healthyFor: .seconds(30), elapsed: .seconds(60), record: seen, restored: true) == V.undecided)
  check(GuestPackage.verdict(report: r7, healthyFor: .zero, elapsed: .seconds(300), record: seen, restored: false) == V.bad(7))
  check(GuestPackage.verdict(report: .init(serial: 5, result: 0), healthyFor: .zero, elapsed: .seconds(300), record: seen, restored: false) == V.undecided, "the last good package is not judged bad")
  check(GuestPackage.verdict(report: .init(serial: 1, result: 3), healthyFor: .zero, elapsed: .seconds(300), record: seen, restored: false) == V.undecided, "the seed is the floor")
  check(GuestPackage.verdict(report: nil, healthyFor: .zero, elapsed: .seconds(300), record: seen, restored: false) == V.undecided)
  // device.json `guest`: missing keys decode; nil guest is omitted from the record.
  let g = try JSONDecoder().decode(DeviceInstance.Guest.self, from: Data("{\"active\": 3}".utf8))
  check(g.active == 3 && g.bad == [] && g.seed == nil)
  let round = try JSONDecoder().decode(DeviceInstance.Guest.self, from: try JSONEncoder().encode(record))
  check(round == record)
  // The preparer's record.
  let lockFile = t.appendingPathComponent("device.lock.json")
  try Data("{\"guest_package\": {\"family\": \"n72-ios3\", \"seed\": 1, \"gli\": null, \"hooks\": [\"/usr/lib/libappsync.dylib\"]}}".utf8).write(to: lockFile)
  check(GuestPackage.lockRecord(lockFile) == GuestPackage.LockRecord(seed: 1, gli: nil, hooks: ["/usr/lib/libappsync.dylib"]))
  check(GuestPackage.lockRecord(t.appendingPathComponent("missing.json")) == nil)
  check(GuestPackage.arch(board: "n72ap") == "armv6" && GuestPackage.arch(board: "k48ap") == "armv7")
  print("PASS: itpack read, offer identical to mkpkg.py (verdicts, lock-dropped hooks), built-in serial 0, no offer for stubs/other builds/host protocols, UI status, verdicts, guest record")
 }
}
'''
    # A corrupt payload: flip a byte inside one file's data before packing.
    bent = [(n, (d[:-1] + bytes([d[-1] ^ 1])) if n == 'n72-ios3/bin/itmedia' else d) for n, d in entries]
    mkpkg.pack(bent, str(t / 'corrupt.itpack'))
    check = check.replace('  // UI status.', r'''  do {
   _ = try GuestPackage.compose(itpack: t.appendingPathComponent("corrupt.itpack"), board: "n72ap", build: "7E18", lock: nil, guest: nil, into: dir)
   preconditionFailure("a corrupt payload was offered")
  } catch {}
  precondition(!FileManager.default.fileExists(atPath: dir.path))
  // UI status.''')
    (t / 'check.swift').write_text(check.replace('GuestPackage.Manifest.mbx', '"%s"' % MBX))
    app = root / 'LightTouchMac'
    subprocess.run(['xcrun', 'swiftc', '-swift-version', '5', '-default-isolation', 'MainActor', '-parse-as-library',
                    '-module-cache-path', str(t / 'modules'), str(app / 'Guest/GuestPackage.swift'), str(app / 'Library/DeviceInstance.swift'),
                    str(app / 'Device/DeviceProfile.swift'), str(app / 'Library/StorageLocations.swift'), str(app / 'Library/FirmwareCatalog.swift'), str(t / 'check.swift'), '-o', str(t / 'check')],
                   check=True)
    subprocess.run([str(t / 'check'), str(t)], check=True, timeout=60)
