import FirmwareSchema
import Foundation
import HostRuntime
import Testing

@testable import LightTouchCore

/// FirmwareJobs' bookkeeping across the commands a user can mix (the state audit's B-1, B-2, B-3, B-12): Try Again
/// right after Cancel, an IPSW dropped on a job under way, Cancel while an import is checking its IPSW, and a relaunch
/// with a two-IPSW download half done. Each runs the real FirmwareJobs over its own state with a scripted preparer.
@Suite struct FirmwareJobLifecycleTests {
    typealias Harness = FirmwareJobsTests.Harness
    init() { _ = LibraryFixtures.isolatedAppState }

    /// One iPad entry whose small IPSW is in the store already (Prepare goes straight to the preparer), or, with
    /// `url`, one that downloads from there.
    @MainActor static func single(_ tmp: URL, preparer: URL, url: String? = nil) throws -> (
        Harness, FirmwareCatalog.Entry, ipsw: Data
    ) {
        let data = LibraryFixtures.randomData(1 << 20)
        let sha1 = IPSWStoreTests.sha1Hex(data)
        var entry = FirmwareJobsTests.entry("k48ap-7B367")
        entry["estimates"] = FirmwareJobsTests.smallEstimates
        entry["source"] = [
            "kind": "ipsw", "url": url ?? "http://127.0.0.1:9/none.ipsw", "sha1": sha1, "bytes": data.count
        ]
        let catalog = try FirmwareJobsTests.catalog([entry], in: tmp)
        let h = try Harness(tmp, catalog: catalog, preparer: preparer)
        if url == nil {
            try StorageLocations.privateDirectory(h.store.downloads)
            try data.write(to: h.store.download(sha1))
        }
        return (h, catalog.entries[0], data)
    }

    /// A preparer script that appends a line to `runs` each time it starts a preparation (not the decrypt-cache prune
    /// that follows one), then runs `body`.
    static func counting(_ tmp: URL, runs: URL, _ body: String) throws -> URL {
        try LibraryFixtures.script(
            tmp.appendingPathComponent("counting-\(UUID().uuidString.prefix(8))"),
            "[ \"$1\" = cache-prune ] && exit 0\necho run >> '\(runs.path)'\n" + body
        )
    }
    static func runs(_ url: URL) -> Int {
        ((try? String(contentsOf: url, encoding: .utf8)) ?? "").split(separator: "\n").count
    }

    @MainActor static func until(_ seconds: Double = 20, _ condition: () -> Bool) async {
        let deadline = Date().addingTimeInterval(seconds)
        while !condition(), Date() < deadline { try? await Task.sleep(for: .milliseconds(50)) }
    }
    static func step(_ job: FirmwareJob?) -> Int { if case .preparing(let p)? = job { p.step } else { 0 } }
    static func isPreparing(_ job: FirmwareJob?) -> Bool { if case .preparing? = job { true } else { false } }
    static func isDownloading(_ job: FirmwareJob?) -> Bool { if case .downloading? = job { true } else { false } }

    // MARK: - B-1: Try Again right after Cancel

    /// The first preparer stops the way firmwarekit does, a second after SIGTERM (it detaches its images); a Prepare
    /// clicked in that second still prepares the device once the old preparer is gone.
    @Test func tryAgainRightAfterCancelPrepares() async throws {
        try await LibraryFixtures.withScratch { tmp in
            let mark = tmp.appendingPathComponent("first-run")
            let runs = tmp.appendingPathComponent("runs")
            let ok = try LibraryFixtures.fakePreparer(in: tmp)
            let preparer = try Self.counting(
                tmp,
                runs: runs,
                """
                [ -e '\(mark.path)' ] && exec '\(ok.path)' "$@"
                touch '\(mark.path)'
                echo '{"event": "begin", "steps": 3}'
                echo '{"event": "step", "index": 1, "name": "Decrypting"}'
                trap 'kill $! 2>/dev/null; sleep 1; exit 143' TERM
                sleep 60 >/dev/null 2>&1 &
                wait $!
                """
            )
            let (h, e, _) = try Self.single(tmp, preparer: preparer)
            h.jobs.downloadAndPrepare(e)
            await Self.until { Self.step(h.jobs.jobs[e.id]) == 1 }
            #expect(Self.step(h.jobs.jobs[e.id]) == 1, "the first preparer is under way: \(h.seen)")
            h.jobs.cancel(e)
            h.jobs.downloadAndPrepare(e)
            #expect(Self.isPreparing(h.jobs.jobs[e.id]), "the row shows the Prepare it was asked for")
            await Self.until { h.devices(e.id).count == 1 && h.jobs.jobs[e.id] == nil }
            #expect(h.devices(e.id).count == 1, "prepared once the cancelled preparer exited: \(h.seen)")
            #expect(Self.runs(runs) == 2)
        }
    }

    // MARK: - B-2: an import onto a job under way

    /// An IPSW dropped on the row (or the window) of an entry that is preparing leaves that preparation alone: its
    /// progress stays, no second preparer starts.
    @Test func anImportLeavesARunningPreparationAlone() async throws {
        try await LibraryFixtures.withScratch { tmp in
            let runs = tmp.appendingPathComponent("runs")
            let slow = try LibraryFixtures.fakePreparer(in: tmp, mode: "slow")
            let preparer = try Self.counting(tmp, runs: runs, "exec '\(slow.path)' \"$@\"")
            let (h, e, data) = try Self.single(tmp, preparer: preparer)
            let dropped = tmp.appendingPathComponent("dropped.ipsw")
            try data.write(to: dropped)
            h.jobs.downloadAndPrepare(e)
            await Self.until { Self.step(h.jobs.jobs[e.id]) == 2 }
            for row in [nil, e] {
                h.jobs.importIPSW(dropped, for: row)
                try await Task.sleep(for: .seconds(1.5))
                #expect(
                    Self.step(h.jobs.jobs[e.id]) == 2,
                    "an import onto \(row?.id ?? "the window") kept the preparation's progress: \(h.seen)"
                )
                #expect(Self.runs(runs) == 1, "one preparer")
            }
            h.jobs.cancel(e)
            await Self.until { h.jobs.jobs[e.id] == nil }
        }
    }

    /// The same IPSW dropped while it downloads: the download job goes on and prepares once, not a preparation beside
    /// it.
    @Test func anImportLeavesARunningDownloadAlone() async throws {
        try await LibraryFixtures.withScratch { tmp in
            let server = try await TestHTTPServer([:], hanging: ["/slow.ipsw"])
            defer { server.stop() }
            let runs = tmp.appendingPathComponent("runs")
            let ok = try LibraryFixtures.fakePreparer(in: tmp)
            let preparer = try Self.counting(tmp, runs: runs, "exec '\(ok.path)' \"$@\"")
            let (h, e, data) = try Self.single(tmp, preparer: preparer, url: server.base + "/slow.ipsw")
            let dropped = tmp.appendingPathComponent("dropped.ipsw")
            try data.write(to: dropped)
            h.jobs.downloadAndPrepare(e)
            #expect(Self.isDownloading(h.jobs.jobs[e.id]))
            h.jobs.importIPSW(dropped, for: nil)
            try await Task.sleep(for: .seconds(2))
            #expect(Self.isDownloading(h.jobs.jobs[e.id]), "still the download job: \(h.seen)")
            #expect(Self.runs(runs) == 0 && h.devices(e.id).isEmpty, "no preparation beside the download")
            h.jobs.cancel(e)
        }
    }

    // MARK: - Folders of IPSWs

    /// A folder of IPSWs (Import IPSW… or a drop) is stored, not prepared: the one the catalog knows, two levels down,
    /// lands in the store and its row reads it again; the junk beside it is skipped without an alert; no job, no
    /// device. A folder with nothing it knows says so once. Download and Prepare then uses the stored copy (its URL is
    /// unreachable), and the folder again copies nothing more.
    @Test func aFolderIsStoredNotPrepared() async throws {
        try await LibraryFixtures.withScratch { tmp in
            let (h, e, data) = try Self.single(
                tmp,
                preparer: try LibraryFixtures.fakePreparer(in: tmp),
                url: "http://127.0.0.1:9/none.ipsw"
            )
            let fm = FileManager.default
            func folder(_ name: String, _ files: [String: Data]) throws -> URL {
                let root = tmp.appendingPathComponent(name)
                for (path, contents) in files {
                    let url = root.appendingPathComponent(path)
                    try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try contents.write(to: url)
                }
                return root
            }
            let junk = Data("not an IPSW".utf8)
            let mixed = try folder(
                "mixed",
                ["a/b/known.ipsw": data, "junk.ipsw": junk, "a/other.IPSW": junk + junk, "notes.txt": junk]
            )
            #expect(DroppedFiles(mixed) == .ipsw, "a dropped folder goes to the library")
            #expect(
                DroppedFiles.ipsws(in: [mixed]).map(\.lastPathComponent) == ["known.ipsw", "other.IPSW", "junk.ipsw"]
            )
            var storeChanges = 0
            let observer = NotificationCenter.default.addObserver(
                forName: IPSWStore.didChangeNotification,
                object: nil,
                queue: nil
            ) { _ in storeChanges += 1 }
            defer { NotificationCenter.default.removeObserver(observer) }
            h.jobs.importIPSWs([mixed])
            await Self.until { storeChanges > 0 }
            try await Task.sleep(for: .milliseconds(500))
            #expect(h.store.existing(e.source.sha1!) == h.store.imported(e.source.sha1!), "stored: the row says so")
            // At least: IPSWStoreTests, running alongside, posts the same process-wide notification.
            #expect(storeChanges >= 1, "the rows were told")
            #expect(h.changes[e.id] == nil && h.devices(e.id).isEmpty, "nothing prepared: \(h.seen)")
            #expect(h.errors.isEmpty, "the skipped files raised no alert: \(h.errors)")

            let unknown = try folder("unknown", ["x.ipsw": junk, "deeper/y.ipsw": junk + junk])
            h.jobs.importIPSWs([unknown])
            await Self.until { !h.errors.isEmpty }
            try await Task.sleep(for: .milliseconds(500))
            #expect(h.errors == ["None of these files is a supported IPSW."], "one alert for the lot")

            h.jobs.downloadAndPrepare(e)
            await Self.until { h.devices(e.id).count == 1 && h.jobs.jobs[e.id] == nil }
            #expect(h.devices(e.id).count == 1 && h.downloads(e.id).isEmpty, "prepared from the store: \(h.seen)")

            h.jobs.importIPSWs([mixed, unknown])
            await Self.until { storeChanges > 1 }
            #expect(try fm.contentsOfDirectory(atPath: h.store.imports.path) == ["\(e.source.sha1!).ipsw"])
            #expect(h.errors.count == 1 && h.devices(e.id).count == 1, "\(h.errors) \(h.seen)")
        }
    }

    // MARK: - B-12: Cancel while an import checks its IPSW

    /// 64 MiB of zeros: long enough to hash (a few seconds) that a Cancel lands while it does.
    static let zerosSHA1 = "44fac4bedde4df04b9572ac665d3ac2c5cd00c7d"
    static let zerosBytes: Int64 = 64 << 20

    @Test func cancellingAnImportStopsIt() async throws {
        try await LibraryFixtures.withScratch { tmp in
            var entry = FirmwareJobsTests.entry("k48ap-7B367")
            entry["estimates"] = FirmwareJobsTests.smallEstimates
            entry["source"] = [
                "kind": "ipsw", "url": "http://127.0.0.1:9/none.ipsw", "sha1": Self.zerosSHA1, "bytes": Self.zerosBytes
            ]
            let catalog = try FirmwareJobsTests.catalog([entry], in: tmp)
            let e = catalog.entries[0]
            let h = try Harness(tmp, catalog: catalog, preparer: try LibraryFixtures.fakePreparer(in: tmp))
            let big = tmp.appendingPathComponent("zeros.ipsw")
            FileManager.default.createFile(atPath: big.path, contents: nil)
            let handle = try FileHandle(forWritingTo: big)
            try handle.truncate(atOffset: UInt64(Self.zerosBytes))  // sparse
            try handle.close()
            h.jobs.importIPSW(big, for: e)
            #expect(Self.isPreparing(h.jobs.jobs[e.id]), "the row says Checking the IPSW")
            #expect(h.jobs.preparing == 0, "Quit has no preparation to ask about")
            h.jobs.cancel(e)
            #expect(h.jobs.jobs[e.id] == nil)
            await Self.until(8) { h.store.existing(Self.zerosSHA1) != nil }
            #expect(h.store.existing(Self.zerosSHA1) == nil, "the cancelled import didn't land in the store")
            #expect(h.jobs.jobs[e.id] == nil && h.devices(e.id).isEmpty, "\(h.seen)")
        }
    }

    // MARK: - B-3: a relaunch resumes what was asked

    /// Download and Prepare iPad 4.3.1 (its own IPSW and 4.3's), quit while 4.3's is still downloading, and that
    /// download finishes while the app is closed: the next launch prepares 4.3.1, and 4.3 gets no job.
    @Test func aRelaunchPreparesTheTwoIPSWJobItWasAskedFor() async throws {
        try await LibraryFixtures.withScratch { tmp in
            let server = try await TestHTTPServer([:], hanging: ["/base.ipsw"])
            defer { server.stop() }
            let (h, point, base, _, _) = try FirmwareJobsTests().siblings(tmp, baseURL: server.base + "/base.ipsw")
            h.jobs.downloadAndPrepare(point)
            await Self.until { h.store.existing(point.source.sha1!) != nil }
            #expect(Self.isDownloading(h.jobs.jobs[point.id]), "waiting for 4.3's IPSW")
            // While the app is closed, 4.3's download lands.
            try FileManager.default.copyItem(
                at: tmp.appendingPathComponent("ipsws/k48ap-8F190.ipsw"),
                to: h.store.download(base.source.sha1!)
            )
            #expect(
                (try? Data(contentsOf: h.state.appendingPathComponent("FirmwareJobs.json"))).flatMap {
                    try? JSONDecoder().decode([String: [String]].self, from: $0)
                } == [point.id: [point.source.sha1!, base.source.sha1!]],
                "the job's intent is saved"
            )
            let relaunched = try Harness(tmp, catalog: h.catalog, preparer: h.jobs.preparer)
            await Self.until { !relaunched.devices(point.id).isEmpty && relaunched.jobs.jobs[point.id] == nil }
            #expect(relaunched.devices(point.id).count == 1, "4.3.1 prepared after the relaunch: \(relaunched.seen)")
            #expect(relaunched.changes[base.id] == nil && relaunched.devices(base.id).isEmpty, "4.3 got no job")
        }
    }

    /// A download task the session still has that no saved job waits for (here 4.3's IPSW) gives its entry no job.
    @Test func aLeftoverDownloadTaskStartsNoJob() async throws {
        try await LibraryFixtures.withScratch { tmp in
            let (h, point, base, _, _) = try FirmwareJobsTests().siblings(tmp)
            h.jobs.receive(.tasks([base.source.sha1!, point.source.sha1!]))
            #expect(h.jobs.jobs.isEmpty && h.changes.isEmpty, "\(h.jobs.jobs)")
        }
    }
}
