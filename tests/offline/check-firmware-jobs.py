#!/usr/bin/env python3
"""IPSW store, downloads and preparation, outside the app.

    tests/offline/check-firmware-jobs.py              # offline: hashing, dedupe, import matching,
                                              # disk-space math, the JSON Lines parser, and
                                              # PreparationJob against tests/fixtures/fake-firmwarekit.py
    tests/offline/check-firmware-jobs.py --download   # also: the iPad 3.2 IPSW from Apple's CDN (479 MB)
                                              # through a background URLSession, cancelled (resume
                                              # data deleted), started again, the process then
                                              # killed -9 mid-way and a new one finishing the same
                                              # task; SHA1 checked. And the local copy in
                                              # ~/Downloads as an already-downloaded dedupe hit.

Compiles IPSWStore, FirmwareDownloads, PreparationJob, DeviceInstance, DeviceStateStorage,
FirmwareCatalog, DeviceProfile and StorageLocations with a stub Bundled. Also: the removal
guard (Erase/Delete stay inside the device's own storage), Delete Device through
Devices/.deleting-<uuid> with a read-only base, the atomic publish, and the launch sweeps. Every path is a temp dir; nothing
reads or writes the real Application Support or Caches. Everything is deleted at the end.
"""
import sys
from pathlib import Path
sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "scripts"))
import host_runtime
from pathlib import Path
import os, shutil, signal, subprocess, sys, tempfile, time, uuid
from firmwarekit_leaf import capacity_sources, schema_sources

ROOT = Path(__file__).resolve().parents[2]
APP = ROOT / 'LightTouchMac'
FAKE = ROOT / 'tests/fixtures/fake-firmwarekit.py'
LOCAL_IPSW = Path.home() / 'Downloads/ipad1-ios32-feasibility/iPad1,1_3.2_7B367_Restore.ipsw'
SOURCES = ['Library/IPSWStore.swift', 'Library/FirmwareDownloads.swift', 'Library/PreparationJob.swift', 'Library/DeviceInstance.swift',
           'Library/FirmwareCatalog.swift', 'Device/DeviceProfile.swift', 'Library/StorageLocations.swift', 'Library/DeviceStateStorage.swift']

STUBS = r'''
import Foundation
nonisolated enum Bundled {
    static var stateDirectory: URL { URL(fileURLWithPath: ProcessInfo.processInfo.environment["LTM_STATE_DIR"]!) }
}
nonisolated func logEvent(_ message: String, _ arguments: CVarArg...) {}
'''

CHECK = r'''
import CryptoKit
import Foundation

func expect(_ ok: Bool, _ what: @autoclosure () -> String, line: Int = #line) {
    if !ok { print("FAIL line \(line): \(what())"); exit(1) }
}
func throwsError(_ expected: FirmwareError, _ body: () throws -> Void, line: Int = #line) {
    do { try body(); expect(false, "no error, wanted \(expected)", line: line) }
    catch { expect(error as? FirmwareError == expected, "\(error), wanted \(expected)", line: line) }
}
func hex(_ digest: some Sequence<UInt8>) -> String { digest.map { String(format: "%02x", $0) }.joined() }
let fm = FileManager.default
let args = CommandLine.arguments
let catalog = try FirmwareCatalog.load(from: URL(fileURLWithPath: args[2]))
let tmp = URL(fileURLWithPath: args[3])
let iPad32 = catalog.entry(id: "k48ap-7B367")!

func allocatedKiB(_ url: URL) -> Int {
    Int(try! url.resourceValues(forKeys: [.totalFileAllocatedSizeKey]).totalFileAllocatedSize! / 1024)
}

/// Runs a PreparationJob to its last event.
func prepare(_ entry: FirmwareCatalog.Entry, state: URL, cache: URL, mode: String,
             cancelAfterStep: Int? = nil) -> (events: [PreparationJob.Event], job: PreparationJob) {
    setenv("FAKE_MODE", mode, 1)
    setenv("FAKE_ARGV", tmp.appendingPathComponent("argv.json").path, 1)
    let done = DispatchSemaphore(value: 0)
    let box = NSLock()
    var events: [PreparationJob.Event] = []
    var job: PreparationJob!
    job = PreparationJob(.init(entry: entry, ipsw: tmp.appendingPathComponent("fake.ipsw"), state: state,
                               preparer: URL(fileURLWithPath: args[4]), helper: URL(fileURLWithPath: "/nonexistent/LightTouchDevice"),
                               cache: cache, log: tmp.appendingPathComponent("logs/\(entry.id).log"))) { event in
        box.withLock { events.append(event) }
        switch event {
        case let .step(index, _, _) where index == cancelAfterStep: job.cancel()
        case .published, .failed, .cancelled: done.signal()
        default: break
        }
    }
    let started = Date()
    job.start()
    expect(done.wait(timeout: .now() + 30) == .success, "preparation \(mode) never finished")
    if cancelAfterStep != nil { expect(Date().timeIntervalSince(started) < 5, "cancel took \(Date().timeIntervalSince(started)) s") }
    return (box.withLock { events }, job)
}

switch args[1] {
case "unit":
    // SHA1, streamed in chunks: a known vector, and a file over two chunks.
    let abc = tmp.appendingPathComponent("abc")
    try Data("abc".utf8).write(to: abc)
    expect(try IPSWStore.sha1(of: abc) == "a9993e364706816aba3e25717850c26c9cd0d89d", "sha1(abc)")
    var big = Data(count: 9 << 20)
    for i in stride(from: 0, to: big.count, by: 4093) { big[i] = UInt8(truncatingIfNeeded: i &* 31) }
    let bigURL = tmp.appendingPathComponent("big")
    try big.write(to: bigURL)
    var fractions: [Double] = []
    let bigSHA = try IPSWStore.sha1(of: bigURL) { fractions.append($0) }
    expect(bigSHA == hex(Insecure.SHA1.hash(data: big)), "streamed sha1 matches the one-shot hash")
    expect(fractions.count == 3 && fractions.last == 1, "progress per 4 MiB chunk: \(fractions)")

    // Install: size and sha1 checked, then <sha1>.ipsw; a mismatch deletes the file.
    let store = IPSWStore(downloads: tmp.appendingPathComponent("Caches/IPSW"), imports: tmp.appendingPathComponent("State/IPSW"))
    try StorageLocations.privateDirectory(store.downloads)
    try big.write(to: store.partial(bigSHA))
    throwsError(.corrupted) { _ = try store.install(store.partial(bigSHA), sha1: bigSHA, bytes: Int64(big.count) + 1) }
    expect(!fm.fileExists(atPath: store.partial(bigSHA).path), "a size mismatch deletes the download")
    var bad = big; bad[5] ^= 1
    try bad.write(to: store.partial(bigSHA))
    throwsError(.corrupted) { _ = try store.install(store.partial(bigSHA), sha1: bigSHA, bytes: Int64(big.count)) }
    expect(!fm.fileExists(atPath: store.partial(bigSHA).path), "a sha1 mismatch deletes the download")
    expect(FirmwareError.corrupted.localizedDescription == "The download is damaged. Try again.", FirmwareError.corrupted.localizedDescription)
    expect(store.existing(bigSHA) == nil, "nothing stored yet")
    try big.write(to: store.partial(bigSHA))
    let installed = try store.install(store.partial(bigSHA), sha1: bigSHA, bytes: Int64(big.count))
    expect(installed == store.download(bigSHA) && !fm.fileExists(atPath: store.partial(bigSHA).path), "renamed into place")

    // Dedupe by sha1 across Caches and State/IPSW.
    expect(store.existing(bigSHA) == store.download(bigSHA), "a download satisfies it")
    try StorageLocations.privateDirectory(store.imports)
    try fm.moveItem(at: store.download(bigSHA), to: store.imported(bigSHA))
    expect(store.existing(bigSHA) == store.imported(bigSHA), "an import satisfies it")

    // Disk space: required vs available, with both in the message.
    try IPSWStore.checkSpace(100, available: 100)
    throwsError(.notEnoughSpace(required: 3_700_184_797, available: 1_000_000_000)) {
        try IPSWStore.checkSpace(iPad32.estimates.peakBytes, available: 1_000_000_000)
    }
    let space = FirmwareError.notEnoughSpace(required: 3_700_184_797, available: 1_000_000_000).localizedDescription
    expect(space == "Not enough disk space: this needs 3.7 GB, and 1 GB is available.", space)
    try IPSWStore.checkSpace(1, at: tmp.appendingPathComponent("not/made/yet"))
    do { try IPSWStore.checkSpace(Int64.max, at: tmp); expect(false, "no volume has Int64.max free") }
    catch let FirmwareError.notEnoughSpace(required, available) { expect(required == .max && available > 0, "\(available)") }
    expect(iPad32.estimates.peakBytes == iPad32.source.bytes! + (3 << 30) && iPad32.estimates.seconds == 90, "7B367 estimates")
    for id in ["k48ap-7B500", "k48ap-8C148"] {
        let e = catalog.entry(id: id)!
        expect(e.estimates.peakBytes == e.source.bytes! + (3 << 30) && e.estimates.preparedBytes > 1 << 30, "\(id) estimates")
    }

    // Catalog matching: by sha1; else by Restore.plist (the pinned build, another file; or unsupported).
    expect(try IPSWStore.match(sha1: iPad32.source.sha1!, restore: nil, in: catalog).id == iPad32.id, "sha1 match")
    throwsError(.wrongFile(model: "iPad", version: "3.2")) {
        _ = try IPSWStore.match(sha1: bigSHA, restore: ("iPad1,1", "7B367"), in: catalog)
    }
    expect(FirmwareError.wrongFile(model: "iPad", version: "3.2").localizedDescription
           == "This isn’t the IPSW Light Touch knows for iPad iOS 3.2.", "wrong-file words")
    throwsError(.unsupported) { _ = try IPSWStore.match(sha1: bigSHA, restore: ("iPad1,1", "7B999"), in: catalog) }
    throwsError(.unsupported) { _ = try IPSWStore.match(sha1: bigSHA, restore: nil, in: catalog) }
    expect(FirmwareError.unsupported.localizedDescription == "This IPSW isn’t supported.", "unsupported words")

    // Import of real zips: Restore.plist through unzip -p, a wrong file, junk, and a match cloned into State/IPSW.
    let known = URL(fileURLWithPath: args[5]), other = URL(fileURLWithPath: args[6])
    expect(IPSWStore.restoreInfo(known).map { "\($0.productType) \($0.build)" } == "iPad1,1 7B367", "Restore.plist read")
    expect(IPSWStore.restoreInfo(bigURL) == nil, "no Restore.plist in a non-zip")
    throwsError(.wrongFile(model: "iPad", version: "3.2")) { _ = try store.importIPSW(known, catalog: catalog) }
    throwsError(.unsupported) { _ = try store.importIPSW(other, catalog: catalog) }
    throwsError(.unsupported) { _ = try store.importIPSW(bigURL, catalog: catalog) }
    var pinned = catalog
    let knownSHA = try IPSWStore.sha1(of: known)
    pinned.entries[pinned.entries.firstIndex { $0.id == iPad32.id }!].source.sha1 = knownSHA
    let fresh = IPSWStore(downloads: tmp.appendingPathComponent("C2/IPSW"), imports: tmp.appendingPathComponent("S2/IPSW"))
    let imported = try fresh.importIPSW(known, catalog: pinned)
    expect(imported.entry.id == iPad32.id && imported.ipsw == fresh.imported(knownSHA), "import matched and cloned")
    expect(try IPSWStore.sha1(of: imported.ipsw) == knownSHA && fm.fileExists(atPath: known.path), "the original stays")
    expect(try fresh.importIPSW(known, catalog: pinned).ipsw == fresh.imported(knownSHA), "a second import dedupes")
    expect(try fm.contentsOfDirectory(atPath: fresh.imports.path) == ["\(knownSHA).ipsw"], "no temp left")

    // The preparer's JSON Lines.
    typealias L = PreparationJob.Line
    expect(L(#"{"event":"begin","steps":9}"#) == .begin(steps: 9), "begin")
    expect(L(#"{"event":"begin","steps":2,"seconds":[1.5,70]}"#) == .begin(steps: 2, seconds: [1.5, 70]), "begin with seconds")
    expect(L(#"{"event":"step","index":3,"name":"Building the system volume"}"#) == .step(index: 3, name: "Building the system volume"), "step")
    expect(L(#"{"event":"progress","fraction":0.42}"#) == .progress(0.42), "progress")
    expect(L(#"{"event":"progress","fraction":0.5,"detail":"Booting to seal the flash — 42 s"}"#)
           == .progress(0.5, detail: "Booting to seal the flash — 42 s"), "progress with detail")
    expect(L(#"{"event":"warning","message":"slow disk"}"#) == .warning("slow disk"), "warning")
    expect(L(#"{"event":"done","lock":"device.lock.json"}"#) == .done(lock: "device.lock.json"), "done")
    expect(L(#"{"event":"error","code":"activation_failed","message":"exit 2"}"#) == .error(code: "activation_failed", message: "exit 2"), "error")
    for junk in ["", "not json", #"{"event":"step"}"#, #"{"event":"begin","steps":"x"}"#, #"{"event":"new"}"#, "[1]"] {
        expect(L(junk) == nil, "ignored: \(junk)")
    }
    expect(PreparationJob.message(code: "disk_full", detail: "") == "Not enough disk space to prepare this device.", "disk_full")
    expect(PreparationJob.message(code: "internal", detail: "boom") == "Preparation failed: boom", "internal")
    expect(PreparationJob.message(code: "whatever", detail: "") == "Preparation failed.", "unknown code")
    // A required piece that doesn't fit: what, in plain words (5.0 beta 1's OpenGLES front end in RC1); the proof is the log's.
    expect(L(#"{"event":"error","code":"unsupported","message":"OpenGLES front end (contrib/gles-public) does not fit this firmware: x","piece":"OpenGLES front end (contrib/gles-public)"}"#)
           == .error(code: "unsupported", message: "OpenGLES front end (contrib/gles-public) does not fit this firmware: x", piece: "OpenGLES front end (contrib/gles-public)"), "error with piece")
    let gl = PreparationJob.message(code: "unsupported", detail: "OpenGLES front end (contrib/gles-public) does not fit this firmware: x",
                                    piece: "OpenGLES front end (contrib/gles-public)", beta: true)
    expect(gl == "Light Touch can’t prepare this beta yet: its graphics library isn’t supported.", gl)
    for (piece, words) in [("kernelcache at the path iBoot loads", "the way it starts up isn’t supported"), ("boot-arg rd", "the way it starts up isn’t supported"),
                           ("libappsync.dylib (in installd)", "installing apps on it isn’t supported"), ("it_boot (guest-package loader)", "the guest tools don’t run on it")] {
        let m = PreparationJob.message(code: "unsupported", detail: "", piece: piece)
        expect(m == "Light Touch can’t prepare this version yet: \(words).", m)
    }
    expect(PreparationJob.message(code: "unsupported", detail: "not a zip archive") == "This IPSW isn’t supported.", "unsupported without a piece")
    let identity = PreparationJob.identity(identityJSON: Data(#"{"udid":"u1","die-id":["0x1","0x2"]}"#.utf8),
                                           lock: Data(#"{"identity":{"seed":"s","udid":"u2","die_id":"0x3:0x4"}}"#.utf8), seed: "x")
    expect(identity == .init(seed: "s", udid: "u1", dieID: "0x1:0x2"), "\(identity)")

    // PreparationJob against the fake preparer: publish, errors, cancel.
    let state = tmp.appendingPathComponent("PState"), cache = tmp.appendingPathComponent("PCache/Decrypted")
    try StorageLocations.privateDirectory(state)
    let preparing = PreparationJob.preparing(state)
    func leftovers() -> [String] { (try? fm.contentsOfDirectory(atPath: preparing.path)) ?? [] }
    func devices() -> [String] { (try? fm.contentsOfDirectory(atPath: state.appendingPathComponent("Devices").path)) ?? [] }

    var run = prepare(iPad32, state: state, cache: cache, mode: "ok")
    guard case let .published(device)? = run.events.last else { expect(false, "not published: \(run.events)"); exit(1) }
    expect(run.events.contains(.step(1, of: 3, name: "Decrypting")) && run.events.contains(.step(3, of: 3, name: "Sealing")), "\(run.events)")
    // Progress: begin's seconds first, then per step a monotonic fraction with a detail, ending at 1.
    expect(run.events.first == .begin(seconds: [5, 10, 70]), "begin first: \(run.events)")
    var sealing: [Double] = []
    var inSeal = false
    for event in run.events {
        if case let .step(index, _, _) = event { inSeal = index == 3 }
        if inSeal, case let .progress(fraction, detail) = event {
            expect(detail?.hasPrefix("Booting to seal the flash — ") == true, "detail \(String(describing: detail))")
            sealing.append(fraction)
        }
    }
    expect(sealing == [0, 0.25, 0.5, 0.75, 1], "sealing progress \(sealing)")
    let argv = try JSONSerialization.jsonObject(with: Data(contentsOf: tmp.appendingPathComponent("argv.json"))) as! [String]
    func flag(_ name: String) -> String? { argv.firstIndex(of: name).map { argv[$0 + 1] } }
    expect(!argv.contains("--activation-hook") && flag("--helper") == "/nonexistent/LightTouchDevice"
           && flag("--cache") == cache.path && flag("--seed") == device.id.uuidString && flag("--out") != nil, "argv \(argv)")
    let base = DeviceInstance.directory(device.id, state: state).appendingPathComponent("base")
    let lockData = try Data(contentsOf: base.appendingPathComponent("device.lock.json"))
    let lockJSON = try JSONSerialization.jsonObject(with: lockData) as! [String: Any]
    expect(DeviceInstance.all(state: state) == [device], "the record is on disk")
    expect(device.base == .init(kind: .prepared, path: "Devices/\(device.id.uuidString)/base") && device.firmware == iPad32.id
           && device.board == "k48ap" && device.storage.writableNOR == nil, "\(device)")
    expect(device.identity == .init(seed: device.id.uuidString, udid: lockJSON["identity"].flatMap { ($0 as! [String: Any])["udid"] as? String },
                                    dieID: "0x00000123:0x00000456"), "identity \(String(describing: device.identity))")
    expect(device.provenance?.sha256 == PreparationJob.sha256(lockData), "provenance")
    let store1 = base.appendingPathComponent("nand/store")
    expect(try allocatedKiB(store1) < 1024 && (fm.attributesOfItem(atPath: store1.path)[.size] as! Int) == 1 << 30, "the NAND stays sparse")
    expect(leftovers().isEmpty, "Preparing/ is empty after a publish: \(leftovers())")
    expect(fm.fileExists(atPath: cache.appendingPathComponent("decrypted-v2/\(iPad32.source.sha1!)").path), "verified decrypt cache remains available after a publish")
    let publishedListing = try fm.subpathsOfDirectory(atPath: DeviceInstance.directory(device.id, state: state).path).sorted()
    let publishedRecord = try Data(contentsOf: DeviceInstance.directory(device.id, state: state).appendingPathComponent("device.json"))

    // A writable-NOR recipe publishes its nor.bin.
    run = prepare(catalog.entry(id: "k48ap-8C148")!, state: state, cache: cache, mode: "ok")
    guard case let .published(device4)? = run.events.last else { expect(false, "8C148: \(run.events)"); exit(1) }
    expect(device4.storage.writableNOR == "Devices/\(device4.id.uuidString)/nor.bin"
           && fm.fileExists(atPath: DeviceInstance.directory(device4.id, state: state).appendingPathComponent("base/nor.bin").path), "nor.bin")

    // An iPod base has iBoot.bin, nor.bin and gid-blobs.bin instead of kboot.bin.
    run = prepare(catalog.entry(id: "n72ap-8C148")!, state: state, cache: cache, mode: "ok")
    guard case let .published(pod)? = run.events.last else { expect(false, "n72ap-8C148: \(run.events)"); exit(1) }
    expect(pod.board == "n72ap" && pod.storage.writableNOR == "Devices/\(pod.id.uuidString)/nor.bin"
           && !fm.fileExists(atPath: DeviceInstance.directory(pod.id, state: state).appendingPathComponent("base/kboot.bin").path), "iPod publish")

    // Failures: an error event, a crash, output without a lock. Nothing left, nothing published.
    let before = Set(devices())
    let sha1 = iPad32.source.sha1!
    try StorageLocations.privateDirectory(cache.appendingPathComponent("\(sha1).tmp"))
    run = prepare(iPad32, state: state, cache: cache, mode: "error")
    expect(run.events.last == .failed("Light Touch doesn’t have the keys for this firmware."), "\(run.events)")
    expect(fm.fileExists(atPath: cache.appendingPathComponent("\(sha1).tmp").path)
           && fm.fileExists(atPath: cache.appendingPathComponent("decrypted-v2/\(sha1)").path),
           "failed jobs retain cache state for coordinated maintenance")
    // An IPSW failing its SHA in the preparer is deleted.
    let ipsw = tmp.appendingPathComponent("fake.ipsw")
    try Data("ipsw".utf8).write(to: ipsw)
    run = prepare(iPad32, state: state, cache: cache, mode: "sha")
    expect(run.events.last == .failed("This IPSW doesn’t match the one Light Touch knows.") && !fm.fileExists(atPath: ipsw.path),
           "a sha_mismatch deletes the IPSW: \(run.events)")
    run = prepare(iPad32, state: state, cache: cache, mode: "crash")
    expect(run.events.last == .failed("Preparation stopped unexpectedly."), "\(run.events)")
    run = prepare(iPad32, state: state, cache: cache, mode: "incomplete")
    expect(run.events.last == .failed("Couldn’t save the prepared device: The prepared device is incomplete (device.lock.json is missing)."), "\(run.events)")
    expect(Set(devices()) == before && leftovers().isEmpty, "failures leave nothing: \(devices()) \(leftovers())")

    // Cancel: SIGTERM mid-way (with a read-only nand/ in staging), staging removed, published devices untouched.
    run = prepare(iPad32, state: state, cache: cache, mode: "slow", cancelAfterStep: 2)
    expect(run.events.last == .cancelled, "\(run.events)")
    expect(!fm.fileExists(atPath: run.job.staging.path) && leftovers().isEmpty, "cancel removes staging: \(leftovers())")
    expect(Set(devices()) == before, "cancel publishes nothing")
    expect(try fm.subpathsOfDirectory(atPath: DeviceInstance.directory(device.id, state: state).path).sorted() == publishedListing
           && (try Data(contentsOf: DeviceInstance.directory(device.id, state: state).appendingPathComponent("device.json"))) == publishedRecord,
           "the published device is untouched by later failures and cancels")

    // Publish is one rename: when it can't happen (Devices/ is a file here),
    // nothing appears in Devices/ and nothing is left in Preparing/.
    let blocked = tmp.appendingPathComponent("BlockedState")
    try StorageLocations.privateDirectory(blocked)
    try Data().write(to: blocked.appendingPathComponent("Devices"))
    run = prepare(iPad32, state: blocked, cache: cache, mode: "ok")
    expect(run.events.last.map { if case .failed = $0 { true } else { false } } == true, "\(run.events)")
    expect(((try? fm.contentsOfDirectory(atPath: PreparationJob.preparing(blocked).path)) ?? []).isEmpty, "a failed publish leaves no .publish")

    // Removal guard: Erase and Delete stay strictly inside the state root, off
    // the root itself, Devices/ and every other record's directory.
    let otherDevice = DeviceInstance.directory(device4.id, state: state)
    let mine = DeviceInstance.directory(device.id, state: state)
    let outside = tmp.appendingPathComponent("outside")
    try Data("keep".utf8).write(to: outside)
    try fm.createSymbolicLink(at: mine.appendingPathComponent("escape"), withDestinationURL: outside)
    for (path, why) in [(state, "the state root"), (state.appendingPathComponent("Devices"), "Devices/"),
                        (otherDevice, "another record"), (otherDevice.appendingPathComponent("overlay"), "inside another record"),
                        (outside, "outside the state root"), (state.appendingPathComponent("Devices/../../outside"), "a .. escape"),
                        (mine.appendingPathComponent("escape"), "a symlink out")] {
        do { try DeviceStateStorage.checkRemovable(path, state: state, owner: device.id); expect(false, "\(why) was removable") } catch {}
    }
    try DeviceStateStorage.checkRemovable(mine.appendingPathComponent("overlay"), state: state, owner: device.id)
    try DeviceStateStorage.checkRemovable(state.appendingPathComponent("nandrw-legacy"), state: state, owner: device.id)
    do {
        try DeviceStateStorage.erase(overlay: otherDevice, snapshots: [mine.appendingPathComponent("snapshot")], state: state, owner: device.id)
        expect(false, "erase reached another record")
    } catch {}
    expect(fm.fileExists(atPath: otherDevice.appendingPathComponent("device.json").path) && fm.fileExists(atPath: outside.path), "nothing was removed")
    try fm.removeItem(at: mine.appendingPathComponent("escape"))

    // Delete Device: Devices/<uuid> -> .deleting-<uuid>, then removed with its read-only base.
    let nandDir = mine.appendingPathComponent("base/nand")
    expect(!fm.isWritableFile(atPath: nandDir.path), "the published base/nand is read-only")
    try DeviceStateStorage.removeDevice(device.id, state: state)
    expect(!fm.fileExists(atPath: mine.path) && !devices().contains { $0.hasPrefix(".deleting-") }, "deleted whole: \(devices())")
    expect(!DeviceInstance.all(state: state).contains(device) && DeviceInstance.all(state: state).contains(device4), "the other devices stay")
    // A delete interrupted after its rename: never listed, finished by the launch sweep.
    let tornID = UUID()
    let torn = state.appendingPathComponent("Devices/.deleting-\(tornID.uuidString)")
    try fm.createDirectory(at: torn.appendingPathComponent("base/nand"), withIntermediateDirectories: true)
    let ghost = String(decoding: try DeviceInstance.encoder.encode(device4), as: UTF8.self)
        .replacingOccurrences(of: device4.id.uuidString, with: tornID.uuidString)
    try Data(ghost.utf8).write(to: torn.appendingPathComponent("device.json"))
    chmod(torn.appendingPathComponent("base/nand").path, 0o555)
    expect(!DeviceInstance.all(state: state).contains { $0.id == tornID }, "a .deleting- directory is no device, even with a valid record")
    DeviceStateStorage.sweepDeleting(state: state)
    expect(!fm.fileExists(atPath: torn.path), "the sweep finishes the delete")

    // Launch sweeps: Preparing/ (read-only leftovers included), .partial downloads, .importing copies.
    let stale = preparing.appendingPathComponent("\(UUID().uuidString)/nand")
    try fm.createDirectory(at: stale, withIntermediateDirectories: true)
    try fm.createDirectory(at: preparing.appendingPathComponent("\(UUID().uuidString).publish/base"), withIntermediateDirectories: true)
    chmod(stale.path, 0o555)
    PreparationJob.sweep(state: state)
    expect(leftovers().isEmpty, "the Preparing sweep leaves nothing: \(leftovers())")
    let swept = IPSWStore(downloads: tmp.appendingPathComponent("C3/IPSW"), imports: tmp.appendingPathComponent("S3/IPSW"))
    for url in [swept.partial("a"), swept.download("b"), swept.resumeData("b"),
                swept.imports.appendingPathComponent(".c.importing"), swept.imported("d")] {
        try StorageLocations.privateDirectory(url.deletingLastPathComponent())
        try Data("x".utf8).write(to: url)
    }
    swept.sweep()
    expect(!fm.fileExists(atPath: swept.partial("a").path) && !fm.fileExists(atPath: swept.imports.appendingPathComponent(".c.importing").path)
           && swept.existing("b") != nil && swept.existing("d") != nil, "the download sweep")
    try swept.remove("b")
    expect(swept.existing("b") == nil && !fm.fileExists(atPath: swept.resumeData("b").path), "Remove IPSW takes its .resume too")

    // A preparer that can't start.
    let missing = PreparationJob(.init(entry: iPad32, ipsw: bigURL, state: state, preparer: URL(fileURLWithPath: "/nonexistent/firmwarekit"),
                                       helper: bigURL, cache: cache, log: tmp.appendingPathComponent("logs/x.log"))) { event in
        if case .failed(let message) = event { print("  missing preparer: \(message)") } else { expect(false, "\(event)") }
    }
    missing.start()
    expect(leftovers().isEmpty, "a preparer that can't start leaves nothing")
    print("PASS: sha1 streaming, install checks, dedupe, disk space, import matching, JSON Lines, publish, failures, cancel, "
          + "decrypt cache, sha mismatch, atomic publish, removal guard, Delete Device, launch sweeps")

case "dedupe":
    // The local copy of the iPad 3.2 IPSW, cloned into a temp cache, is an already-downloaded hit.
    let store = IPSWStore(downloads: tmp.appendingPathComponent("Caches/IPSW"), imports: tmp.appendingPathComponent("State/IPSW"))
    try StorageLocations.privateDirectory(store.downloads)
    let sha1 = iPad32.source.sha1!
    try fm.copyItem(at: URL(fileURLWithPath: args[4]), to: store.partial(sha1))   // APFS clone
    let url = try store.install(store.partial(sha1), sha1: sha1, bytes: iPad32.source.bytes)
    expect(store.existing(sha1) == url, "dedupe hit")
    print("PASS: the local 7B367 IPSW verifies (sha1 \(sha1), \(iPad32.source.bytes!) bytes) and is a dedupe hit")

case "download":
    // args[4]: session identifier; args[5]: cancel|resume-then-wait|finish
    let store = IPSWStore(downloads: tmp.appendingPathComponent("Caches/IPSW"), imports: tmp.appendingPathComponent("State/IPSW"))
    let sha1 = iPad32.source.sha1!, bytes = iPad32.source.bytes!
    let finished = DispatchSemaphore(value: 0)
    let phase = args[5]
    var last = 0.0
    var downloads: FirmwareDownloads!
    downloads = FirmwareDownloads(store: store, configuration: .background(withIdentifier: args[4]),
                                  expectedBytes: { $0 == sha1 ? bytes : nil }) { _, event in
        switch event {
        case let .progress(fraction):
            if fraction - last >= 0.05 || fraction == 1 { last = fraction; print(String(format: "progress %.3f", fraction)); fflush(stdout) }
            if phase == "cancel", fraction > 0.08 { downloads.cancel(sha1: sha1) }
        case let .resumed(offset): print("resumed at \(offset)"); fflush(stdout)
        case .cancelled:
            print("cancelled; resume data \(fm.fileExists(atPath: store.resumeData(sha1).path) ? "KEPT" : "deleted")"); fflush(stdout)
            finished.signal()
        case let .finished(url): print("finished \(url.lastPathComponent)"); fflush(stdout); finished.signal()
        case let .failed(error): print("failed \(error.localizedDescription)"); fflush(stdout); exit(1)
        }
    }
    if phase != "finish" { try downloads.start(sha1: sha1, url: iPad32.source.url!) }
    else { downloads.active { print("reattached tasks \($0)"); fflush(stdout) } }
    // The driver kills resume-then-wait with SIGKILL mid-way.
    expect(finished.wait(timeout: .now() + 540) == .success, "download phase \(phase) timed out")
    if phase == "finish" {
        expect(store.existing(sha1) == store.download(sha1), "installed as <sha1>.ipsw")
        expect(try IPSWStore.sha1(of: store.download(sha1)) == sha1, "sha1 of the finished download")
        print("PASS: finished after relaunch, sha1 \(sha1)")
    }

default: fatalError(args[1])
}
'''


def build(tmp):
    (tmp / 'stubs.swift').write_text(STUBS)
    (tmp / 'main.swift').write_text(CHECK)
    subprocess.run(['xcrun', 'swiftc', *host_runtime.swift_flags(Path(__file__).resolve().parents[2]), *schema_sources(), '-O', '-suppress-warnings', '-swift-version', '5', *capacity_sources(ROOT, tmp), '-module-cache-path', str(tmp / 'modules'),
                    *[str(APP / s) for s in SOURCES], str(ROOT / 'Shared/DeviceLinkProtocol.swift'),
                    str(tmp / 'stubs.swift'), str(tmp / 'main.swift'),
                    '-o', str(tmp / 'check')], check=True)
    return tmp / 'check'


def zip_with_restore(path, product, build):
    d = path.parent / (path.name + '.d')
    d.mkdir()
    import plistlib
    (d / 'Restore.plist').write_bytes(plistlib.dumps({'ProductType': product, 'ProductBuildVersion': build}))
    subprocess.run(['/usr/bin/zip', '-q', '-j', str(path), str(d / 'Restore.plist')], check=True)


def main():
    download = '--download' in sys.argv
    catalog = str(APP / 'Resources/firmware-catalog.json')
    tmp = Path(tempfile.mkdtemp(prefix='ltm-firmware-jobs-'))
    env = dict(os.environ, LTM_STATE_DIR=str(tmp / 'unused-state'))
    try:
        check = build(tmp)
        zip_with_restore(tmp / 'known.ipsw', 'iPad1,1', '7B367')
        zip_with_restore(tmp / 'other.ipsw', 'iPhone1,1', '1A543a')
        subprocess.run([str(check), 'unit', catalog, str(tmp), str(FAKE), str(tmp / 'known.ipsw'), str(tmp / 'other.ipsw')],
                       check=True, env=env)
        if not download:
            return
        work = tmp / 'dl'
        work.mkdir()
        if LOCAL_IPSW.exists():
            dd = tmp / 'dedupe'
            dd.mkdir()
            subprocess.run([str(check), 'dedupe', catalog, str(dd), str(LOCAL_IPSW)], check=True, env=env)
        ident = 'gold.samhenri.LightTouchMac.ipsw.test-' + uuid.uuid4().hex[:8]
        run = lambda phase: [str(check), 'download', catalog, str(work), ident, phase]
        # 1. start, cancel at ~8%: the download and its resume data are discarded.
        out = subprocess.run(run('cancel'), check=True, env=env, capture_output=True, text=True, timeout=300).stdout
        print(out, end='')
        assert 'resume data deleted' in out, out
        # 2. start again (from zero), then SIGKILL the process mid-way.
        p = subprocess.Popen(run('resume-then-wait'), env=env, stdout=subprocess.PIPE, stdin=subprocess.DEVNULL, text=True)
        resumed, fraction = None, 0.0
        try:
            for line in p.stdout:
                print(line, end='')
                if line.startswith('resumed at '):
                    resumed = int(line.split()[-1])
                if line.startswith('progress '):
                    fraction = float(line.split()[1])
                    if fraction >= 0.3:
                        break
        finally:
            p.send_signal(signal.SIGKILL)
            p.wait()
        assert not resumed, 'a cancelled download resumed'
        print(f'killed -9 at {fraction:.0%}')
        # 3. a new process, same session identifier: the task goes on and finishes; sha1 checked.
        r = subprocess.run(run('finish'), env=env, capture_output=True, text=True, timeout=560)
        out = r.stdout
        print(out, end='')
        assert r.returncode == 0 and 'PASS' in out, 'relaunch did not finish the download'
        first = next((float(l.split()[1]) for l in out.splitlines() if l.startswith('progress ')), None)
        print(f'PASS: download cancelled and discarded, started again, killed -9, finished by a relaunch'
              + (f' (first progress after relaunch {first:.0%})' if first is not None else ''))
    finally:
        subprocess.run(['chmod', '-R', 'u+w', str(tmp)])
        shutil.rmtree(tmp, ignore_errors=True)


if __name__ == '__main__':
    main()
