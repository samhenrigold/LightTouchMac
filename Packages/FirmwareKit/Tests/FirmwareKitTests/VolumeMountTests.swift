import Foundation
import Testing

@testable import FirmwareKit

@Suite(.serialized, .detachesItsImages) struct VolumeMountTests {
    static func attached(_ image: URL) async throws -> Bool {
        try await VolumeMount.exec("/usr/bin/hdiutil", ["info"]).1.contains(image.resolvingSymlinksInPath().path)
    }

    /// A fresh volume: files written through the mount land in the catalog,
    /// the junk is gone, fsck passed and nothing stays attached.
    @Test(.enabled(if: FixtureRequirements.corpusEnabled, "Firmware corpus test; set FK_TEST_CORPUS=1 to run"))
    func makeMountEdit() async throws {
        try await Oracle.withTemp { dir in
            let img = dir.appendingPathComponent("data.img")
            let mnt = dir.appendingPathComponent("mnt")
            try await VolumeMount.makeHFS(img, size: 64 << 20 + 123)
            #expect(try VolumeMount.size(img) == 64 << 20)
            try await VolumeMount.withMounted(img, at: mnt) { root in
                try FileManager.default.createDirectory(
                    at: root.appendingPathComponent("a/b"),
                    withIntermediateDirectories: true
                )
                try Data("hi\n".utf8).write(to: root.appendingPathComponent("a/b/c.txt"))
                try FileManager.default.createSymbolicLink(
                    atPath: root.appendingPathComponent("a/l").path,
                    withDestinationPath: "b/c.txt"
                )
                try FileManager.default.createDirectory(
                    at: root.appendingPathComponent(".fseventsd"),
                    withIntermediateDirectories: true
                )
            }
            #expect(!(try await Self.attached(img)))
            let vol = try HFSPlusVolume(img)
            #expect(vol.signature == "HX")
            let l = try vol.listing()
            #expect(l.first { $0.path == "a/b/c.txt" }?.sha256 == Oracle.sha256(Data("hi\n".utf8)))
            #expect(l.first { $0.path == "a/l" }?.link == "b/c.txt")
            #expect(!l.contains { $0.path.hasPrefix(".fseventsd") })

            // A host-written journal (header bytes, need-init clear) handed to the device: zeroed, need-init set.
            let w = try HFSPlusVolume(img, writable: true)
            let j = try #require(try w.journal())
            let jib = try Data(contentsOf: img)[1036..<1040].reduce(0) { $0 << 8 | Int($1) } * w.blockSize
            try w.restore([(j.offset, Data(repeating: 0xAB, count: 512)), (jib, Data([0, 0, 0, 1]))])
            #expect(try w.journal()?.needsInit == false)
            try w.leaveJournalToDevice()
            #expect(try w.journal()?.needsInit == true && w.journalSnapshot()?.last?.bytes == Data(count: j.size))
        }
    }

    /// The host's fseventsd writes nothing on a volume mounted for an edit (.fseventsd/no_log, put there before the
    /// mount): its uuid file and event logs took blocks the kernel then didn't give to what came after them, so where
    /// a recipe's files and the 1.x root's journal landed varied by host and run. It goes with the junk at the end.
    @Test func fseventsdWritesNothingOnTheMount() async throws {
        try await Oracle.withTemp { dir in
            let fm = FileManager.default
            // fseventsd passes over mounts in the temporary directory (/var/folders), so these mount outside it
            let mnt = fm.homeDirectoryForCurrentUser.appendingPathComponent(
                "Library/Caches/FirmwareKitTests-\(UUID().uuidString)"
            )
            defer { try? fm.removeItem(at: mnt) }
            let logs = { (root: URL) in
                (try? fm.contentsOfDirectory(atPath: root.appendingPathComponent(".fseventsd").path)) ?? []
            }
            // without no_log, fseventsd makes its uuid file within a second or so of the mount
            let control = dir.appendingPathComponent("control.img")
            try await VolumeMount.makeHFS(control, size: 64 << 20, journaled: false)
            let plain = try await VolumeMount.attachHidden(control, at: mnt)
            var seen: [String] = []
            for _ in 0..<20 {
                try await Task.sleep(for: .milliseconds(250))
                seen = logs(mnt)
                if !seen.isEmpty { break }
            }
            try await VolumeMount.detach(plain.device)
            try #require(!seen.isEmpty, "fseventsd logged nothing on a plain mount at \(mnt.path)")
            let img = dir.appendingPathComponent("data.img")
            try await VolumeMount.makeHFS(img, size: 64 << 20, journaled: false)
            let logged = try await VolumeMount.withMounted(img, at: mnt) { root in
                try Data(count: 4096).write(to: root.appendingPathComponent("a"))
                try await Task.sleep(for: .seconds(2))
                return logs(root)
            }
            #expect(logged == ["no_log"])
            #expect(try !HFSPlusVolume(img).listing().contains { $0.path.hasPrefix(".fseventsd") })
        }
    }

    /// A handle left open on the volume: unmount fails, the image is force-detached and the call throws.
    /// iOS 6's data volume: kHFSContentProtectionBit in both volume headers, the rest of the attributes kept.
    @Test func contentProtection() async throws {
        try await Oracle.withTemp { dir in
            let img = dir.appendingPathComponent("data.img")
            try await VolumeMount.makeHFS(img, size: 32 << 20)
            let attrs = { (at: Int) throws -> UInt32 in
                let d = try Data(contentsOf: img)
                return d[at + 4..<at + 8].reduce(0) { $0 << 8 | UInt32($1) }
            }
            let before = try attrs(1024)
            let size = try Int(VolumeMount.size(img))
            try HFSPlusVolume(img, writable: true).setContentProtection()
            #expect(try attrs(1024) == before | 0x4000_0000 && before & 0x4000_0000 == 0)
            #expect(try attrs(size - 1024) & 0x4000_0000 != 0)
        }
    }

    /// Every mount for Finder, as the kernel reports it: Show File System's (hidden, read and write) and firmwarekit
    /// mount's (hidden with --root, else where Finder shows it; read-only) are quarantined with setuid and device nodes
    /// ignored, and a file copied out of one carries the quarantine.
    @Test(arguments: [(visible: false, readOnly: false), (false, true), (true, true)])
    func finderMountIsQuarantined(visible: Bool, readOnly: Bool) async throws {
        try await Oracle.withTemp { dir in
            let img = dir.appendingPathComponent("v.img")
            try await VolumeMount.makeHFS(
                img,
                size: 16 << 20,
                name: "LTM-\(UUID().uuidString.prefix(8))",
                journaled: false
            )
            try await VolumeMount.withMounted(img, at: dir.appendingPathComponent("w")) {
                try Data("f".utf8).write(to: $0.appendingPathComponent("f"))
            }
            let attached =
                visible
                ? try await VolumeMount.attachVisible(img, readOnly: readOnly)
                : try await VolumeMount.attachHidden(img, at: dir.appendingPathComponent("mnt"), readOnly: readOnly)
            let mnt = URL(fileURLWithPath: attached.mountPoint ?? "/nonexistent")
            var fs = statfs()
            let mounted = statfs(mnt.path, &fs) == 0
            let copy = dir.appendingPathComponent("copied")
            let copied = (try? FileManager.default.copyItem(at: mnt.appendingPathComponent("f"), to: copy)) != nil
            try await VolumeMount.detach(attached.device)
            #expect(mounted && copied)
            let want =
                UInt32(MNT_QUARANTINE | MNT_NOSUID | MNT_NODEV) | (visible ? 0 : UInt32(MNT_DONTBROWSE))
                | (readOnly ? UInt32(MNT_RDONLY) : 0)
            let seen = fs.f_flags & UInt32(MNT_QUARANTINE | MNT_NOSUID | MNT_NODEV | MNT_DONTBROWSE | MNT_RDONLY)
            #expect(seen == want, "flags \(fs.f_flags)")
            #expect(getxattr(copy.path, "com.apple.quarantine", nil, 0, 0, 0) > 0, "no quarantine on a copy")
        }
    }

    @Test func busyVolumeIsDetached() async throws {
        try await Oracle.withTemp { dir in
            let img = dir.appendingPathComponent("v.img")
            try await VolumeMount.makeHFS(img, size: 16 << 20)
            var held: FileHandle?
            await #expect(throws: FirmwareError.self) {
                try await VolumeMount.withMounted(img, at: dir.appendingPathComponent("mnt")) { root in
                    FileManager.default.createFile(atPath: root.appendingPathComponent("f").path, contents: Data())
                    held = try FileHandle(forWritingTo: root.appendingPathComponent("f"))
                }
            }
            try? held?.close()
            #expect(!(try await Self.attached(img)))
        }
    }

    /// smoke #36: a volume whose only fsck findings are wrong HFSX folder counts comes out of withMounted repaired
    /// and clean; a wrong item count (valence), alone or beside a folder count, still fails and nothing is set.
    @Test func folderCountsAloneAreRepaired() async throws {
        try await Oracle.withTemp { dir in
            let img = dir.appendingPathComponent("v.img")
            let mnt = dir.appendingPathComponent("mnt")
            try await VolumeMount.makeHFS(img, size: 16 << 20)
            try await VolumeMount.withMounted(img, at: mnt) { root in
                for d in ["a/b", "a/c", "d/e"] {
                    try FileManager.default.createDirectory(
                        at: root.appendingPathComponent(d),
                        withIntermediateDirectories: true
                    )
                }
            }
            let pristine = try Data(contentsOf: img)
            func corrupt(folderCount: String?, valence: String?) throws {
                try pristine.write(to: img)
                let v = try HFSPlusVolume(img, writable: true)
                if let folderCount { try v.setFolderCounts([try v.record(at: folderCount).cnid: 0]) }
                if let valence {
                    let r = try v.record(at: valence)
                    let t = try v.btree(v.catalogFork, fileID: HFSPlusVolume.catalogID)
                    try v.write(
                        v.catalogFork,
                        fileID: HFSPlusVolume.catalogID,
                        offset: r.node * t.nodeSize + r.bodyOffset + 4,
                        bytes: [0, 0, 0, 9]
                    )
                }
            }
            func edit() async throws {
                try await VolumeMount.withMounted(img, at: mnt) { root in
                    try Data("x".utf8).write(to: root.appendingPathComponent("x"))
                }
            }
            func fsck() async throws -> (ok: Bool, output: String) {
                let dev = try await VolumeMount.attach(img)
                do {
                    let r = try await VolumeMount.check(dev)
                    try await VolumeMount.detach(dev)
                    return r
                } catch {
                    await VolumeMount.cleanupDetach(dev)
                    throw error
                }
            }

            try corrupt(folderCount: "a", valence: nil)
            let before = try await fsck()
            let a = try HFSPlusVolume(img).record(at: "a").cnid
            #expect(!before.ok && VolumeMount.folderCountFindings(before.output) == [a: 2], "\(before.output)")
            try await edit()
            let after = try await fsck()
            #expect(after.ok, "\(after.output)")

            for (fc, val) in [(nil, "d"), ("a", "d")] as [(String?, String?)] {
                try corrupt(folderCount: fc, valence: val)
                await #expect(throws: FirmwareError.self) { try await edit() }
                let left = try await fsck()
                #expect(left.output.contains("Invalid directory item count"), "\(left.output)")
                #expect(
                    left.output.contains("Incorrect folder count") == (fc != nil),
                    "a folder count was set beside another finding"
                )
                #expect(!(try await Self.attached(img)))
            }
        }
    }

    /// Growing the raw 7B500 / 8C148 system volume to partition 1 (1280 MiB): the volume header's geometry
    /// follows, the tree is unchanged, the alternate header moves and fsck passes.
    @Test(
        .enabled(if: FixtureRequirements.corpusEnabled, "Firmware corpus test; set FK_TEST_CORPUS=1 to run"),
        arguments: HFSOracle.ipads
    ) func grow(_ fw: Oracle.Firmware) async throws {
        try await Oracle.withTemp { dir in
            guard let raw = try await HFSOracle.rawSystem(fw, in: dir) else {
                try FixtureRequirements.missing(
                    #"VolumeMountTests.swift: let raw = try await HFSOracle.rawSystem(fw, in: dir)"#
                )
            }
            let blocks = 1280 << 20 / 4096
            let before = try HFSPlusVolume(raw)
            let tree = try before.listing(hashes: false)
            try await Oracle.time("grow \(fw.entryID)") { try await VolumeMount.grow(raw, toBytes: blocks * 4096) }
            #expect(try VolumeMount.size(raw) == blocks * 4096)
            let a = try HFSPlusVolume(raw)
            // the volume spans the partition but its last block (as grow_to_partition left it)
            #expect(
                a.blockSize == before.blockSize && (a.totalBlocks + 1) * a.blockSize == blocks * 4096,
                "\(before.totalBlocks) x \(before.blockSize) -> \(a.totalBlocks) x \(a.blockSize)"
            )
            #expect(a.freeBlocks > before.freeBlocks)
            #expect(try a.listing(hashes: false) == tree)
            let avh = { (u: URL) throws -> Data in
                let f = try FileHandle(forReadingFrom: u)
                defer { try? f.close() }
                try f.seek(toOffset: UInt64(blocks * 4096 - 1024))
                return try f.read(upToCount: 2) ?? Data()
            }
            #expect(try avh(raw) == Data("HX".utf8))
            let dev = try await VolumeMount.attach(raw)
            let fsck = try await VolumeMount.check(dev)
            try await VolumeMount.detach(dev)
            #expect(fsck.ok, "\(fsck.output)")
        }
    }
    private actor AttachGate {
        private var reached = false
        private var arrival: CheckedContinuation<Void, Never>?
        private var release: CheckedContinuation<Void, Never>?
        func pause() async {
            reached = true
            arrival?.resume()
            arrival = nil
            await withCheckedContinuation { release = $0 }
        }
        func wait() async { if !reached { await withCheckedContinuation { arrival = $0 } } }
        func open() {
            release?.resume()
            release = nil
        }
    }

    @Test func cancelledAttachAfterActualSideEffectCleansOnlyNewOwnedDevice() async throws {
        try await Oracle.withTemp { dir in
            let image = dir.appendingPathComponent("cancelled.img")
            let preserved = dir.appendingPathComponent("preserved.img")
            try await VolumeMount.makeHFS(image, size: 16 << 20)
            try await VolumeMount.makeHFS(preserved, size: 16 << 20)
            let retained = try await DiskImage.attach(preserved, readOnly: true)
            do {
                let gate = AttachGate()
                let tool = Task {
                    try await DiskImage.attach(
                        image,
                        execute: { argv in
                            let output = try await DiskImage.run(argv)
                            await gate.pause()
                            return output
                        }
                    )
                }
                await gate.wait()
                // `hdiutil info` can leave an attached image out while others attach or detach: presence is polled.
                #expect(
                    try await DiskImageTests.eventually {
                        try await DiskImage.checkedAttachedImages().contains {
                            URL(fileURLWithPath: $0.image).resolvingSymlinksInPath().path
                                == image.resolvingSymlinksInPath().path
                        }
                    }
                )
                tool.cancel()
                await gate.open()
                await #expect(throws: CancellationError.self) { _ = try await tool.value }
                let after = try await DiskImage.checkedAttachedImages()
                #expect(
                    !after.contains {
                        URL(fileURLWithPath: $0.image).resolvingSymlinksInPath().path
                            == image.resolvingSymlinksInPath().path
                    }
                )
                #expect(
                    try await DiskImageTests.eventually {
                        try await DiskImage.checkedAttachedImages().contains { $0.device == retained.device }
                    }
                )
            } catch {
                try await DiskImage.detach(retained.device)
                throw error
            }
            try await DiskImage.detach(retained.device)
        }
    }

    @Test func cancelledMountedBodyAwaitsUncancelledCleanup() async throws {
        try await Oracle.withTemp { dir in
            let image = dir.appendingPathComponent("cancelled-body.img")
            try await VolumeMount.makeHFS(image, size: 16 << 20)
            let gate = AttachGate()
            let operation = Task {
                try await VolumeMount.withMounted(image, at: dir.appendingPathComponent("mount")) { _ in
                    await gate.pause()
                }
            }
            await gate.wait()
            operation.cancel()
            await gate.open()
            await #expect(throws: CancellationError.self) { try await operation.value }
            let attached = try await DiskImage.checkedAttachedImages()
            #expect(
                !attached.contains {
                    URL(fileURLWithPath: $0.image).resolvingSymlinksInPath().path
                        == image.resolvingSymlinksInPath().path
                }
            )
        }
    }
}
