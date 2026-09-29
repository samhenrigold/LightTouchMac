#!/usr/bin/env python3
"""A published base is immutable until the app deletes it; a running device's files are watched.

DeviceStateStorage.lockBase makes base/ and every directory in it uchg: nothing inside can be
deleted, renamed or added to (the Finder shows a system dialog), and removeTree still removes the
whole tree afterwards. DeviceFileWatch on a directory reports its files being unlinked or renamed,
and the directory itself being renamed, once each.
"""
from pathlib import Path
import subprocess, tempfile

root = Path(__file__).resolve().parents[2]
source = r'''import Foundation
@main struct Check {
 static func main() throws {
  let fm = FileManager.default
  let work = fm.temporaryDirectory.appendingPathComponent("ltm-device-files-\(UUID().uuidString)")
  defer { try? DeviceStateStorage.removeTree(work) }
  let base = work.appendingPathComponent("base"), page = base.appendingPathComponent("nand/cs0/page0")
  try fm.createDirectory(at: page.deletingLastPathComponent(), withIntermediateDirectories: true)
  try Data("page".utf8).write(to: page)
  try Data("boot".utf8).write(to: base.appendingPathComponent("iBoot.bin"))
  try fm.setAttributes([.posixPermissions: 0o444], ofItemAtPath: page.path)
  for dir in ["nand/cs0", "nand", ""] { try fm.setAttributes([.posixPermissions: 0o555], ofItemAtPath: base.appendingPathComponent(dir).path) }
  DeviceStateStorage.lockBase(base)
  DeviceStateStorage.lockBase(base)   // idempotent
  func refused(_ what: String, _ body: () throws -> Void) {
   do { try body(); preconditionFailure("\(what) was allowed on a locked base") } catch {}
  }
  refused("unlink page") { try fm.removeItem(at: page) }
  refused("rename base") { try fm.moveItem(at: base, to: work.appendingPathComponent("moved")) }
  refused("add to base") { try Data().write(to: base.appendingPathComponent("stray")) }
  refused("unlink iBoot") { try fm.removeItem(at: base.appendingPathComponent("iBoot.bin")) }
  let read = try Data(contentsOf: page)
  precondition(read == Data("page".utf8), "reading a locked base")
  try DeviceStateStorage.removeTree(base)
  precondition(!fm.fileExists(atPath: base.path), "removeTree unlocks and removes the base")

  // The watch: a file unlinked, a file renamed, the directory renamed; each once.
  let overlay = work.appendingPathComponent("overlay")
  try fm.createDirectory(at: overlay, withIntermediateDirectories: true)
  for name in ["nor.bin", "bus0-ce0.pages"] { try Data(name.utf8).write(to: overlay.appendingPathComponent(name)) }
  let seen = Seen()
  let watch = DeviceFileWatch(directories: [overlay], base: nil) { seen.add($0) }
  precondition(watch.count == 3, "\(watch.count)")
  try fm.removeItem(at: overlay.appendingPathComponent("nor.bin"))
  usleep(200_000)
  precondition(seen.paths == [overlay.appendingPathComponent("nor.bin").path], "\(seen.paths)")
  try fm.moveItem(at: overlay.appendingPathComponent("bus0-ce0.pages"), to: overlay.appendingPathComponent("elsewhere"))
  usleep(200_000)
  precondition(seen.paths.count == 2 && seen.paths[1].hasSuffix("bus0-ce0.pages"), "\(seen.paths)")
  try fm.moveItem(at: overlay, to: work.appendingPathComponent("overlay-moved"))
  usleep(200_000)
  precondition(seen.paths.contains(overlay.path), "\(seen.paths)")
  _ = watch
  precondition(DeviceFileWatch.notice(shortName: "iPad") == "Files of this iPad were changed while it was running. Stop and start it again; unsaved changes may be lost.")
  print("PASS: a locked base refuses deletes, renames and additions until removeTree; the watch reports unlinks and renames")
 }
}
final class Seen: @unchecked Sendable {
 private let lock = NSLock(); private var seen: [String] = []
 func add(_ path: String) { lock.withLock { seen.append(path) } }
 var paths: [String] { lock.withLock { seen } }
}
'''
with tempfile.TemporaryDirectory(prefix='ltm-device-files-') as d:
    p = Path(d) / 'check.swift'
    p.write_text(source)
    subprocess.run(['swiftc', '-parse-as-library', '-module-cache-path', d + '/modules', str(root / 'LightTouchMac/DeviceStateStorage.swift'),
                    str(root / 'LightTouchMac/DeviceFileWatch.swift'), str(p), '-o', d + '/check'], check=True)
    subprocess.run([d + '/check'], check=True, timeout=20)
