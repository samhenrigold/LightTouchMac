import Crypto
import FirmwareSchema
import Foundation
import HostRuntime
import Network
import Testing
import os

@testable import LightTouchCore

/// FirmwareJobs end to end, each over its own temporary state, logs and caches, an ephemeral URLSession and a fake
/// or real firmwarekit: a download whose first source fails comes from the next one, sha1-checked (and a "rar"
/// source unwrapped by the real firmwarekit); a build that boots its sibling's ramdisk fetches both IPSWs as one
/// job; the built-in iPod is unpacked as a device of its own on a fresh install only.
@Suite struct FirmwareJobsTests {
    init() { _ = LibraryFixtures.isolatedAppState }

    /// The shipped catalog's entries as JSON, to edit and load as a test catalog.
    static let shipped: [String: Any] =
        try! JSONSerialization.jsonObject(with: Data(contentsOf: LibraryFixtures.shippedCatalog)) as! [String: Any]
    static func entry(_ id: String) -> [String: Any] {
        (shipped["entries"] as! [[String: Any]]).first { $0["id"] as? String == id }!
    }
    static func catalog(_ entries: [[String: Any]], in directory: URL) throws -> FirmwareCatalog {
        let url = directory.appendingPathComponent("catalog.json")
        try JSONSerialization.data(withJSONObject: ["format": 1, "entries": entries]).write(to: url)
        return try FirmwareCatalog.load(from: url)
    }
    static let smallEstimates: [String: Any] = ["seconds": 1, "prepared_bytes": 1 << 20, "peak_bytes": 1 << 20]

    /// A FirmwareJobs over `root`'s state, logs and caches, recording every change to one entry's job.
    @MainActor final class Harness {
        let state: URL, store: IPSWStore, jobs: FirmwareJobs, library: DeviceLibrary, catalog: FirmwareCatalog
        let defaults = UserDefaults(suiteName: "ltm-tests-\(UUID().uuidString)")!
        var seen: [String: [FirmwareJob]] = [:]
        var changes: [String: Int] = [:]
        /// What FirmwareJobs asked the app to show in an alert.
        var errors: [String] { alerts.messages }
        private final class Alerts { var messages: [String] = [] }
        private let alerts: Alerts
        private var observer: (any NSObjectProtocol)?

        init(_ root: URL, catalog: FirmwareCatalog, preparer: URL?, resources: URL? = nil, sweep: Bool = false) throws {
            self.catalog = catalog
            let alerts = Alerts()
            self.alerts = alerts
            state = root.appendingPathComponent("state")
            try StorageLocations.privateDirectory(state)
            store = IPSWStore(
                downloads: root.appendingPathComponent("Caches/IPSW"),
                imports: state.appendingPathComponent("IPSW")
            )
            library = DeviceLibrary(state: state)
            jobs = FirmwareJobs(
                catalog: catalog,
                store: store,
                configuration: .ephemeral,
                state: state,
                logs: root.appendingPathComponent("Logs"),
                caches: root.appendingPathComponent("Caches"),
                preparer: preparer,
                resources: resources,
                library: library,
                sweep: sweep,
                defaults: defaults,
                presentError: { [alerts] in alerts.messages.append($0.localizedDescription) }
            )
            observer = NotificationCenter.default.addObserver(
                forName: FirmwareJobs.didChangeNotification,
                object: jobs,
                queue: nil
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    for (id, job) in self.jobs.jobs {
                        if self.seen[id]?.last != job { self.seen[id, default: []].append(job) }
                        self.changes[id, default: 0] += 1
                    }
                }
            }
        }
        deinit { observer.map(NotificationCenter.default.removeObserver) }

        func devices(_ id: String) -> [DeviceInstance] { DeviceInstance.all(state: state).filter { $0.firmware == id } }
        func failed(_ id: String) -> Bool { if case .failed? = jobs.jobs[id] { true } else { false } }
        /// Waits (up to 60 s) for a failure, or a device whose job has gone (the record is renamed into place on the
        /// preparer's thread just before the job hears).
        func settle(_ id: String) async {
            for _ in 0..<1200 where !failed(id) && (devices(id).isEmpty || jobs.jobs[id] != nil) {
                try? await Task.sleep(for: .milliseconds(50))
            }
        }
        func downloads(_ id: String) -> [FirmwareJob] {
            (seen[id] ?? []).filter { if case .downloading = $0 { true } else { false } }
        }
    }

    static func files(_ job: FirmwareJob?) -> Int { if case .downloading(_, _, let n, _, _)? = job { n } else { 0 } }
    static func fraction(_ job: FirmwareJob) -> Double {
        if case .downloading(let f, _, _, _, _) = job { f } else { -1 }
    }

    // MARK: - Sources and mirrors

    struct Source: Sendable, CustomTestStringConvertible {
        enum Outcome: Sendable { case success, direct, failure }
        let name: String
        /// The entry's source, given the server's base URL and the good file's sha1.
        let source: @Sendable (_ base: String, _ sha1: String) -> [String: any Sendable]
        let outcome: Outcome
        /// The paths the server must have seen, in order.
        let paths: [String]
        var testDescription: String { name }
    }
    nonisolated static let size = 2 << 20
    nonisolated static func ipsw(_ url: String, mirrors: [(String, String)], sha1: String) -> [String: any Sendable] {
        [
            "kind": "ipsw", "url": url, "sha1": sha1, "bytes": size,
            "mirrors": mirrors.map { ["url": $0.0, "sha1": $0.1, "bytes": size] }
        ]
    }
    /// Unrar.swift's own test fixture (MIT): a 107-byte RAR 5 archive holding README.md, 40 bytes.
    nonisolated static let rar = Data(
        base64Encoded:
            "UmFyIRoHAQAzkrXlCgEFBgAFAQGAgAD3EqflHwICqAAGqACkgwIWO/FfV7UGeoAAAQlSRUFETUUubWQjIFVucmFyCgpBIGRlc2NyaXB0aW9uIG9mIHRoaXMgcGFja2FnZS4KHXdWUQMFBAA="
    )!
    nonisolated static let member = Data("# Unrar\n\nA description of this package.\n".utf8)
    nonisolated static func rarSource(_ base: String, archiveSHA1: String) -> [String: any Sendable] {
        [
            "kind": "rar", "url": base + "/media_ipsw.rar", "archive_sha1": archiveSHA1, "archive_bytes": rar.count,
            "member": "README.md",
            "sha1": IPSWStoreTests.sha1Hex(member), "bytes": member.count
        ]
    }
    nonisolated static let sources: [Source] = [
        .init(
            name: "404: the mirror's copy",
            source: { b, s in ipsw(b + "/gone.ipsw", mirrors: [(b + "/good.ipsw", s)], sha1: s) },
            outcome: .success,
            paths: ["/gone.ipsw", "/good.ipsw"]
        ),
        .init(
            name: "hash: other bytes rejected, the mirror's copy",
            source: { b, s in ipsw(b + "/bad.ipsw", mirrors: [(b + "/good.ipsw", s)], sha1: s) },
            outcome: .success,
            paths: ["/bad.ipsw", "/good.ipsw"]
        ),
        .init(
            name: "dns: the mirror's copy",
            source: { b, s in ipsw("http://ipsw.invalid/gone.ipsw", mirrors: [(b + "/good.ipsw", s)], sha1: s) },
            outcome: .success,
            paths: ["/good.ipsw"]
        ),
        .init(
            name: "exhausted: fails, nothing kept",
            source: { b, s in ipsw(b + "/gone.ipsw", mirrors: [(b + "/bad.ipsw", s)], sha1: s) },
            outcome: .failure,
            paths: ["/gone.ipsw", "/bad.ipsw"]
        ),
        .init(
            name: "unlisted: a mirror for another sha1 is never asked",
            source: { b, s in
                ipsw(b + "/gone.ipsw", mirrors: [(b + "/good.ipsw", String(repeating: "0", count: 40))], sha1: s)
            },
            outcome: .failure,
            paths: ["/gone.ipsw"]
        ),
        .init(
            name: "rar: unwrapped by firmwarekit",
            source: { b, _ in rarSource(b, archiveSHA1: IPSWStoreTests.sha1Hex(rar)) },
            outcome: .direct,
            paths: ["/media_ipsw.rar"]
        ),
        .init(
            name: "rar-other: another archive's sha1 fails",
            source: { b, _ in rarSource(b, archiveSHA1: String(repeating: "0", count: 40)) },
            outcome: .failure,
            paths: ["/media_ipsw.rar"]
        )
    ]

    @Test(arguments: sources)
    func aFailedSourceFallsBackToTheNext(_ c: Source) async throws {
        try await LibraryFixtures.withScratch { tmp in
            let good = LibraryFixtures.randomData(Self.size)
            let bad = LibraryFixtures.randomData(Self.size)
            let server = try await TestHTTPServer(["/good.ipsw": good, "/bad.ipsw": bad, "/media_ipsw.rar": Self.rar])
            defer { server.stop() }
            var entry = Self.entry("k48ap-7B367")
            entry["estimates"] = Self.smallEstimates
            entry["source"] = c.source(server.base, IPSWStoreTests.sha1Hex(good))
            let catalog = try Self.catalog([entry], in: tmp)
            let e = catalog.entries[0]
            let preparer = try LibraryFixtures.fakePreparer(in: tmp, unwrap: try await FirmwareKitTool.path())
            let h = try Harness(tmp, catalog: catalog, preparer: preparer)
            h.jobs.downloadAndPrepare(e)
            await h.settle(e.id)
            let mirrors = Set(
                (h.seen[e.id] ?? []).compactMap {
                    if case .downloading(_, _, _, let mirror, _) = $0 { mirror } else { nil }
                }
            )
            switch c.outcome {
            case .success, .direct:
                #expect(h.devices(e.id).count == 1 && h.jobs.jobs[e.id] == nil, "prepared: \(h.seen)")
                let stored = try #require(h.store.existing(e.source.sha1!))
                #expect(
                    try IPSWStore.sha1(of: stored) == e.source.sha1!,
                    "the stored IPSW hashes to the catalog's sha1"
                )
                if c.outcome == .success { #expect(mirrors == ["127.0.0.1"], "the job named the mirror it came from") }
                #expect(
                    (try? FileManager.default.contentsOfDirectory(atPath: h.store.downloads.path)) == [
                        e.source.sha1! + ".ipsw"
                    ],
                    "only the IPSW is left in the downloads"
                )
            case .failure:
                #expect(
                    h.failed(e.id) && h.devices(e.id).isEmpty,
                    "no source served the IPSW, so the job failed: \(h.seen)"
                )
                #expect(h.store.existing(e.source.sha1!) == nil, "nothing in the store")
            }
            #expect(server.log == c.paths)
        }
    }

    // MARK: - A sibling's ramdisk

    /// iPad 4.3.1–4.3.5 boot 4.3's ramdisk (recipe.keybag_ramdisk_from); a catalog of 4.3 and 4.3.1 over small file:// IPSWs
    /// (4.3's from `baseURL` instead, if given).
    @MainActor func siblings(_ tmp: URL, baseURL: String? = nil, mode: String = "ok") throws -> (
        Harness, point: FirmwareCatalog.Entry, base: FirmwareCatalog.Entry, argv: URL, pointIPSW: URL
    ) {
        var point = Self.entry("k48ap-8G4")
        var base = Self.entry("k48ap-8F190")
        let ipsws = tmp.appendingPathComponent("ipsws")
        try FileManager.default.createDirectory(at: ipsws, withIntermediateDirectories: true)
        for (i, size) in [(0, 3 << 20), (1, 5 << 20)] {
            let id = (i == 0 ? point : base)["id"] as! String
            let url = ipsws.appendingPathComponent("\(id).ipsw")
            let data = LibraryFixtures.randomData(size)
            try data.write(to: url)
            let source: [String: Any] = [
                "kind": "ipsw", "url": i == 1 ? baseURL ?? url.absoluteString : url.absoluteString,
                "sha1": IPSWStoreTests.sha1Hex(data), "bytes": size
            ]
            if i == 0 {
                point["source"] = source
                point["estimates"] = Self.smallEstimates
            } else {
                base["source"] = source
                base["estimates"] = Self.smallEstimates
            }
        }
        let catalog = try Self.catalog([base, point], in: tmp)
        let argv = tmp.appendingPathComponent("argv.json")
        let h = try Harness(
            tmp,
            catalog: catalog,
            preparer: try LibraryFixtures.fakePreparer(in: tmp, mode: mode, argv: argv)
        )
        return (
            h, catalog.entry(id: "k48ap-8G4")!, catalog.entry(id: "k48ap-8F190")!, argv,
            ipsws.appendingPathComponent("k48ap-8G4.ipsw")
        )
    }
    func argv(_ url: URL) -> [String] {
        (try? JSONSerialization.jsonObject(with: Data(contentsOf: url))) as? [String] ?? []
    }

    // MARK: - Skip Setup Assistant

    /// The preparation screen's Skip Setup Assistant choice reaches firmwarekit create as --skip-setup: for an iOS 5
    /// entry chosen, not for one left off, and not for a 4.x entry (no Setup Assistant) even when chosen. Its Jailbreak
    /// choice reaches it as --jailbreak, on a 2.0 or later build chosen.
    @Test func theSkipSetupAndJailbreakChoicesReachThePreparer() async throws {
        try await LibraryFixtures.withScratch { tmp in
            var entries: [[String: Any]] = []
            for id in ["k48ap-9B206", "k48ap-8C148", "k48ap-7B500"] {
                var e = Self.entry(id)
                let data = LibraryFixtures.randomData(1 << 20)
                let url = tmp.appendingPathComponent("\(id).ipsw")
                try data.write(to: url)
                e["source"] = [
                    "kind": "ipsw", "url": url.absoluteString, "sha1": IPSWStoreTests.sha1Hex(data), "bytes": 1 << 20
                ]
                e["estimates"] = Self.smallEstimates
                e.removeValue(forKey: "bundled")
                entries.append(e)
            }
            let catalog = try Self.catalog(entries, in: tmp)
            var seen: [String: [String]] = [:]
            for (id, chosen) in [
                ("k48ap-9B206", true), ("k48ap-8C148", true), ("k48ap-9B206", false), ("k48ap-8C148", false),
                ("k48ap-7B500", false)
            ] {
                let argvURL = tmp.appendingPathComponent("argv-\(UUID().uuidString).json")
                let h = try Harness(
                    tmp.appendingPathComponent(UUID().uuidString),
                    catalog: catalog,
                    preparer: try LibraryFixtures.fakePreparer(in: tmp, argv: argvURL)
                )
                // Skip Setup is off unless chosen; Jailbreak is on unless turned off where the sandbox patch resolves
                // and can't be turned on elsewhere (iOS 3). "Not chosen" flips each one's Jailbreak checkbox.
                if chosen { h.jobs.skipsSetup = [id] } else { h.jobs.setJailbreaks(id, !h.jobs.jailbreaks(id)) }
                h.jobs.downloadAndPrepare(try #require(catalog.entry(id: id)))
                await h.settle(id)
                #expect(h.devices(id).count == 1, "\(id) prepared: \(h.seen)")
                seen["\(id) \(chosen)"] = argv(argvURL)
            }
            #expect(seen["k48ap-9B206 true"]?.contains("--skip-setup") == true, "5.1.1, chosen")
            #expect(seen["k48ap-9B206 false"]?.contains("--skip-setup") == false, "5.1.1, not chosen")
            #expect(seen["k48ap-8C148 true"]?.contains("--skip-setup") == false, "4.2.1 has no Setup Assistant")
            #expect(seen["k48ap-9B206 true"]?.contains("--jailbreak") == true, "5.1.1, untouched")
            #expect(seen["k48ap-8C148 true"]?.contains("--jailbreak") == true, "4.2.1 iPad, untouched")
            #expect(seen["k48ap-9B206 false"]?.contains("--jailbreak") == false, "5.1.1, turned off")
            #expect(seen["k48ap-8C148 false"]?.contains("--jailbreak") == false, "4.2.1 iPad, turned off")
            #expect(seen["k48ap-7B500 false"]?.contains("--jailbreak") == false, "3.2.2 iPad, turned on")
        }
    }

    /// Launch (the sweep): a decrypt cache holding anything a quit, crash or older build left is pruned whole; an empty
    /// one runs nothing.
    @Test func launchPrunesADecryptCacheLeftBehind() async throws {
        try await LibraryFixtures.withScratch { tmp in
            let catalog = try Self.catalog([Self.entry("k48ap-9B206")], in: tmp)
            let argvURL = tmp.appendingPathComponent("argv.json")
            let prune = URL(fileURLWithPath: argvURL.path + ".prune")
            let preparer = try LibraryFixtures.fakePreparer(in: tmp, argv: argvURL)
            let empty = try Harness(
                tmp.appendingPathComponent("empty"), catalog: catalog, preparer: preparer, sweep: true)
            try await Task.sleep(for: .milliseconds(300))
            #expect(!FileManager.default.fileExists(atPath: prune.path), "an empty cache: nothing run")
            let left = tmp.appendingPathComponent("left")
            try FileManager.default.createDirectory(
                at: left.appendingPathComponent("Caches/Decrypted/decrypted-v2/stale"),
                withIntermediateDirectories: true
            )
            let leftOver = try Harness(left, catalog: catalog, preparer: preparer, sweep: true)
            try await until("the prune") { FileManager.default.fileExists(atPath: prune.path) }
            let arguments = try String(contentsOf: prune, encoding: .utf8)
            #expect(arguments.contains("Caches/Decrypted") && !arguments.contains("--ipsw"), "\(arguments)")
            withExtendedLifetime((empty, leftOver)) {}
        }
    }

    /// A prepared device's IPSW leaves the decrypt cache (firmwarekit cache-prune --ipsw), as only a retry reuses it.
    @Test func aPreparedDevicesIPSWIsPrunedFromTheDecryptCache() async throws {
        try await LibraryFixtures.withScratch { tmp in
            let id = "k48ap-9B206"
            var e = Self.entry(id)
            let data = LibraryFixtures.randomData(1 << 20)
            let url = tmp.appendingPathComponent("\(id).ipsw")
            try data.write(to: url)
            let sha1 = IPSWStoreTests.sha1Hex(data)
            e["source"] = ["kind": "ipsw", "url": url.absoluteString, "sha1": sha1, "bytes": 1 << 20]
            e["estimates"] = Self.smallEstimates
            e.removeValue(forKey: "bundled")
            let catalog = try Self.catalog([e], in: tmp)
            let argvURL = tmp.appendingPathComponent("argv.json")
            let prune = URL(fileURLWithPath: argvURL.path + ".prune")
            let h = try Harness(
                tmp.appendingPathComponent("state"),
                catalog: catalog,
                preparer: try LibraryFixtures.fakePreparer(in: tmp, argv: argvURL)
            )
            h.jobs.downloadAndPrepare(try #require(catalog.entry(id: id)))
            await h.settle(id)
            #expect(h.devices(id).count == 1, "prepared: \(h.seen)")
            try await until("the prune") { FileManager.default.fileExists(atPath: prune.path) }
            let arguments = try String(contentsOf: prune, encoding: .utf8)
            #expect(arguments.contains("--ipsw \(sha1)"), "\(arguments)")
            #expect(arguments.contains("/Decrypted"), "\(arguments)")
        }
    }

    /// Settings ▸ General ▸ Prepare devices without mounting disk images reaches firmwarekit create as --hfs writer when
    /// it is on, and nothing (firmwarekit's default, mounted) when it is off or was never set.
    @Test func theWithoutMountingSettingReachesThePreparer() async throws {
        try await LibraryFixtures.withScratch { tmp in
            let id = "k48ap-9B206"
            var e = Self.entry(id)
            let data = LibraryFixtures.randomData(1 << 20)
            let url = tmp.appendingPathComponent("\(id).ipsw")
            try data.write(to: url)
            e["source"] = [
                "kind": "ipsw", "url": url.absoluteString, "sha1": IPSWStoreTests.sha1Hex(data), "bytes": 1 << 20
            ]
            e["estimates"] = Self.smallEstimates
            e.removeValue(forKey: "bundled")
            let catalog = try Self.catalog([e], in: tmp)
            for setting in [true, false, nil] {
                let argvURL = tmp.appendingPathComponent("argv-\(UUID().uuidString).json")
                let h = try Harness(
                    tmp.appendingPathComponent(UUID().uuidString),
                    catalog: catalog,
                    preparer: try LibraryFixtures.fakePreparer(in: tmp, argv: argvURL)
                )
                if let setting { h.defaults.set(setting, forKey: FirmwareJobs.withoutMountingKey) }
                h.jobs.downloadAndPrepare(try #require(catalog.entry(id: id)))
                await h.settle(id)
                #expect(h.devices(id).count == 1, "prepared: \(h.seen)")
                let arguments = argv(argvURL)
                let hfs = arguments.firstIndex(of: "--hfs").map { arguments[$0 + 1] }
                #expect(hfs == (setting == true ? "writer" : nil), "setting \(String(describing: setting))")
            }
        }
    }

    /// Jailbreak is offered from iPhone OS 2.0 on: 1.0's afcd serves no path through afc2.
    @Test func jailbreakIsOfferedFromIPhoneOS2() throws {
        let catalog = try FirmwareCatalog.load(from: LibraryFixtures.shippedCatalog)
        for (id, offered) in [
            ("m68ap-1A543a", false), ("n45ap-4B1", false), ("n72ap-5F138", true), ("n90ap-8C148", true)
        ] {
            #expect(FirmwareJobs.offersJailbreak(try #require(catalog.entry(id: id))) == offered, "\(id)")
        }
    }

    @Test func everyIPad43PointReleaseBootsTheRamdiskOf43() {
        let shipped = (Self.shipped["entries"] as! [[String: Any]])
        for e in shipped where e["board"] as? String == "k48ap" && (e["version"] as! String).hasPrefix("4.3.") {
            #expect((e["recipe"] as? [String: Any])?["keybag_ramdisk_from"] as? String == "k48ap-8F190", "\(e["id"]!)")
        }
    }

    @Test func downloadAndPrepareFetchesTheSiblingAsOneJob() async throws {
        try await LibraryFixtures.withScratch { tmp in
            let (h, point, base, argvURL, _) = try siblings(tmp)
            #expect(point.recipe?.keybagRamdiskFrom == base.id)
            h.jobs.downloadAndPrepare(point)
            #expect(Self.files(h.jobs.jobs[point.id]) == 2, "one job, two downloads")
            await h.settle(point.id)
            #expect(h.devices(point.id).count == 1 && h.jobs.jobs[point.id] == nil, "4.3.1 prepared: \(h.seen)")
            let downloads = h.downloads(point.id)
            #expect(
                !downloads.isEmpty && downloads.allSatisfy { Self.files($0) == 2 },
                "every download report is the two-IPSW job"
            )
            let fractions = downloads.map(Self.fraction)
            #expect(fractions == fractions.sorted(), "the one bar only grows: \(fractions)")
            #expect(
                (h.seen[point.id] ?? []).contains { if case .preparing = $0 { true } else { false } },
                "then the preparation"
            )
            #expect(h.changes[base.id] == nil && h.devices(base.id).isEmpty, "4.3 gets no job and no device of its own")
            let sibling = try #require(h.store.existing(base.source.sha1!))
            #expect(h.store.existing(point.source.sha1!) != nil, "both IPSWs in the store")
            let a = argv(argvURL)
            #expect(
                a.firstIndex(of: "--sibling-ipsw").map { a[$0 + 1] } == sibling.path,
                "the preparer boots 4.3's ramdisk"
            )
            #expect(a.contains("--sibling-entry"))
            #expect(
                (try? FileManager.default.contentsOfDirectory(atPath: PreparationJob.preparing(h.state).path)) == [],
                "nothing of the job is left in Preparing/, its sibling's entry file included"
            )
        }
    }

    /// Remove IPSW leaves every IPSW a job under way reads or waits for, its keybag sibling's included (state audit
    /// B-6): 4.3.1 preparing keeps 4.3's IPSW in use, and nothing is once the job ends.
    @Test func aJobKeepsItsSiblingsIPSWInUse() async throws {
        try await LibraryFixtures.withScratch { tmp in
            let (h, point, base, _, _) = try siblings(tmp, mode: "slow")
            let both: Set = [point.source.sha1!, base.source.sha1!]
            h.jobs.downloadAndPrepare(point)
            #expect(h.jobs.ipswsInUse == both, "while downloading")
            await FirmwareJobLifecycleTests.until { FirmwareJobLifecycleTests.step(h.jobs.jobs[point.id]) == 2 }
            #expect(h.jobs.ipswsInUse == both, "while preparing: \(h.seen)")
            h.jobs.cancel(point)
            await FirmwareJobLifecycleTests.until { h.jobs.jobs[point.id] == nil && h.jobs.ipswsInUse.isEmpty }
            #expect(h.jobs.ipswsInUse.isEmpty)
        }
    }

    @Test func anImportQueuesTheMissingSibling() async throws {
        try await LibraryFixtures.withScratch { tmp in
            let (h, point, base, argvURL, pointIPSW) = try siblings(tmp)
            h.jobs.importIPSW(pointIPSW, for: point)
            await h.settle(point.id)
            #expect(h.devices(point.id).count == 1, "4.3.1 prepared after its sibling's download: \(h.seen)")
            let downloads = h.downloads(point.id)
            #expect(
                !downloads.isEmpty && downloads.allSatisfy { Self.files($0) == 1 },
                "the import queued only 4.3's IPSW"
            )
            #expect(
                h.store.existing(base.source.sha1!) != nil && h.changes[base.id] == nil,
                "4.3's IPSW fetched under 4.3.1's job"
            )
            #expect(argv(argvURL).contains("--sibling-ipsw"))
        }
    }

    @Test func aCancelledTwoIPSWJobPreparesNothing() async throws {
        try await LibraryFixtures.withScratch { tmp in
            let (h, point, base, _, _) = try siblings(tmp)
            h.jobs.downloadAndPrepare(point)
            h.jobs.cancel(point)
            #expect(h.jobs.jobs[point.id] == nil)
            try await Task.sleep(for: .seconds(1))
            #expect(h.devices(point.id).isEmpty && h.jobs.jobs[point.id] == nil && h.changes[base.id] == nil)
        }
    }

    // MARK: - The built-in iPod

    /// A packed base in the n72 shape (pack-base, as scripts/vendor does with a real one: its NAND an image store, four
    /// sparse chip files with one page written) in a fake bundle's Resources/Device/n72ap-7E18.itbase; the real
    /// firmwarekit unpacks it.
    @MainActor func builtIn(_ tmp: URL) async throws -> (Harness, FirmwareCatalog.Entry) {
        let fk = try await FirmwareKitTool.path()
        let template = tmp.appendingPathComponent("template")
        let fm = FileManager.default
        let nand = template.appendingPathComponent("nand")
        try fm.createDirectory(at: nand, withIntermediateDirectories: true)
        try Data(#"{"blank": "n72-generated", "storage_format": "nand-xor-blank-v2"}"#.utf8)
            .write(to: nand.appendingPathComponent("geometry.json"))
        for cs in 0..<4 {
            let chip = nand.appendingPathComponent("cs\(cs).pages")
            fm.createFile(atPath: chip.path, contents: nil)
            let handle = try FileHandle(forWritingTo: chip)
            try handle.truncate(atOffset: 4096 * 128 * 4160)
            try handle.seek(toOffset: 4160)
            try handle.write(contentsOf: Data(repeating: 7, count: 4160))
            try handle.close()
        }
        for (name, data) in [
            ("iBoot.bin", Data("ibot".utf8)), ("gid-blobs.bin", Data(count: 64)), ("nor.bin", Data(count: 0x100000))
        ] {
            try data.write(to: template.appendingPathComponent(name))
        }
        try JSONSerialization.data(withJSONObject: [
            "seed": "lighttouch-built-in", "model-number": "MB528", "region-info": "LL/A",
            "serial-number": "X", "udid": "u"
        ]).write(to: template.appendingPathComponent("identity.json"))
        try JSONSerialization.data(withJSONObject: [
            "board": "n72ap", "boot_strategy": "iboot", "entry": ["id": "n72ap-7E18"],
            "identity": ["seed": "lighttouch-built-in", "udid": "u", "sha256": "x"], "machine": ["aes-uid": "engine"],
            "outputs": ["nor": ["path": "nor.bin", "sha256": "x"]],
            "inputs": ["ipsw": ["path": NSHomeDirectory() + "/Library/Caches/x.ipsw"], "guest_tools": template.path],
            "tool": ["helper": template.appendingPathComponent("LightTouchDevice").path]
        ]).write(to: template.appendingPathComponent("device.lock.json"))
        try LibraryFixtures.run(
            "/bin/chmod",
            [
                "-R", "a-w", template.appendingPathComponent("nand").path,
                template.appendingPathComponent("nor.bin").path
            ]
        )
        let resources = tmp.appendingPathComponent("Resources")
        try fm.createDirectory(at: resources.appendingPathComponent("Device"), withIntermediateDirectories: true)
        try LibraryFixtures.run(
            fk.path,
            [
                "pack-base", "--base", template.path, "--out",
                resources.appendingPathComponent("Device/n72ap-7E18.itbase").path
            ]
        )
        let catalog = try FirmwareCatalog.load(from: LibraryFixtures.shippedCatalog)
        let iPod = try #require(catalog.entry(id: "n72ap-7E18"))
        #expect(
            catalog.bundledEntry?.id == iPod.id && FirmwareJobs.bundledBlob(iPod, resources: resources) != nil,
            "the bundle has the built-in iPod's blob"
        )
        return (try Harness(tmp, catalog: catalog, preparer: fk, resources: resources), iPod)
    }

    /// The published device: what the n72 boot wants, a locked base, its own identity seeded with the device id,
    /// no build-machine path. Returns the identity's values.
    @MainActor func published(_ h: Harness, _ iPod: FirmwareCatalog.Entry) throws -> [String: String] {
        let fm = FileManager.default
        let device = try #require(h.devices(iPod.id).first)
        #expect(device.base.kind == .prepared)
        let base = DeviceInstance.directory(device.id, state: h.state).appendingPathComponent("base")
        let boot = try iPod.profile!.requiredFiles(strategy: "iboot")
        for name in [boot.boot, "nand", "identity.json", "device.lock.json"] + boot.files {
            #expect(fm.fileExists(atPath: base.appendingPathComponent(name).path), "base has \(name)")
        }
        let lockData = try Data(contentsOf: base.appendingPathComponent("device.lock.json"))
        let lock = try JSONSerialization.jsonObject(with: lockData) as! [String: Any]
        let identity =
            try JSONSerialization.jsonObject(with: Data(contentsOf: base.appendingPathComponent("identity.json")))
            as! [String: String]
        let locked = lock["identity"] as! [String: String]
        let machine = lock["machine"] as! [String: String]
        #expect(
            identity["seed"] == device.id.uuidString && locked["seed"] == device.id.uuidString,
            "seeded with the device id"
        )
        #expect(
            device.identity?.udid == identity["udid"] && locked["udid"] == identity["udid"],
            "the record's UDID is the identity's"
        )
        #expect(
            machine["wifi-mac"] == identity["wifi-mac"] && machine["bt-mac"] == identity["bt-mac"]
                && machine["ecid"] == identity["unique-chip-id"],
            "the machine boots this unit"
        )
        #expect(!String(decoding: lockData, as: UTF8.self).contains("/Users/"), "no build-machine path in the lock")
        #expect((try fm.attributesOfItem(atPath: base.path)[.immutable] as? Bool) == true, "the base is locked")
        #expect(device.format == DeviceRecord.imageFormat, "an image store: record format 2")
        let chip = try Data(contentsOf: base.appendingPathComponent("nand/cs3.pages"), options: .alwaysMapped)
        #expect(chip.count == 4096 * 128 * 4160 && chip[4160..<8320].allSatisfy { $0 == 7 }, "the NAND as packed")
        let nor = try Data(contentsOf: base.appendingPathComponent("nor.bin"))
        return [
            "udid": identity["udid"]!, "serial": identity["serial-number"]!, "wifi": identity["wifi-mac"]!,
            "bt": identity["bt-mac"]!,
            "ecid": identity["unique-chip-id"]!, "seed": identity["seed"]!,
            "syscfg": nor[0x4000..<0x4068].map { String(format: "%02x", $0) }.joined()
        ]
    }

    @Test func aFreshInstallUnpacksTheBuiltInIPodWithItsOwnIdentityEachTime() async throws {
        try await LibraryFixtures.withScratch { tmp in
            var identities: [[String: String]] = []
            for run in ["a", "b"] {
                let (h, iPod) = try await builtIn(tmp.appendingPathComponent(run))
                #expect(
                    h.jobs.prepareBundledIfFresh(sidebarSaved: false)?.id == iPod.id,
                    "a fresh install unpacks the built-in iPod"
                )
                #expect(
                    { if case .preparing? = h.jobs.jobs[iPod.id] { true } else { false } }(),
                    "a preparing job the sidebar shows"
                )
                await h.settle(iPod.id)
                #expect(h.devices(iPod.id).count == 1 && h.jobs.jobs[iPod.id] == nil, "published: \(h.seen)")
                let steps = (h.seen[iPod.id] ?? []).compactMap {
                    if case .preparing(let p) = $0 { p.name } else { nil }
                }
                #expect(steps.contains("Unpacking"))
                let fractions = (h.seen[iPod.id] ?? []).compactMap {
                    if case .preparing(let p) = $0, p.name == "Unpacking" { p.fraction } else { nil }
                }
                #expect(fractions == fractions.sorted() && fractions.count > 1, "a growing bar: \(fractions)")
                identities.append(try published(h, iPod))
            }
            let same = identities[0].keys.filter { identities[0][$0] == identities[1][$0] }
            #expect(same.isEmpty, "two unpacks share \(same)")
        }
    }

    @Test func aLibraryWithADeviceOrASavedSidebarGetsNothingNew() async throws {
        try await LibraryFixtures.withScratch { tmp in
            let (h, _) = try await builtIn(tmp.appendingPathComponent("saved"))
            #expect(
                h.jobs.prepareBundledIfFresh(sidebarSaved: true) == nil && h.jobs.jobs.isEmpty
                    && DeviceInstance.all(state: h.state).isEmpty
            )

            let (e, _) = try await builtIn(tmp.appendingPathComponent("existing"))
            // An iPad prepared earlier: the Mac already has a library.
            let iPad = try #require(
                try FirmwareCatalog.load(from: LibraryFixtures.shippedCatalog).entry(id: "k48ap-7B500")
            )
            let staging = e.state.appendingPathComponent("Preparing/ipad")
            let fm = FileManager.default
            try fm.createDirectory(at: staging.appendingPathComponent("nand"), withIntermediateDirectories: true)
            for name in ["iBoot.bin", "nor.bin", "gid-blobs.bin", "identity.json"] {
                fm.createFile(atPath: staging.appendingPathComponent(name).path, contents: Data("{}".utf8))
            }
            try Data(#"{"boot_strategy": "iboot"}"#.utf8).write(to: staging.appendingPathComponent("device.lock.json"))
            _ = try PreparationJob.publish(staging: staging, entry: iPad, id: UUID(), state: e.state)
            #expect(
                e.jobs.prepareBundledIfFresh(sidebarSaved: false) == nil && e.jobs.jobs.isEmpty,
                "a Mac with a device gets no built-in iPod"
            )
            #expect(e.jobs.prepareBundledIfFresh(sidebarSaved: true) == nil && e.jobs.jobs.isEmpty)
            try await Task.sleep(for: .seconds(1))
            #expect(DeviceInstance.all(state: e.state).map(\.firmware) == ["k48ap-7B500"], "still only the iPad")
        }
    }

    @Test func theRowsPrepareUnpacksTheBuiltInIPod() async throws {
        try await LibraryFixtures.withScratch { tmp in
            let (h, iPod) = try await builtIn(tmp)
            h.jobs.downloadAndPrepare(iPod)
            await h.settle(iPod.id)
            #expect(h.devices(iPod.id).count == 1 && h.jobs.jobs[iPod.id] == nil, "published: \(h.seen)")
            _ = try published(h, iPod)
        }
    }
}

extension IPSWStoreTests {
    nonisolated static func sha1Hex(_ data: Data) -> String {
        Insecure.SHA1.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

/// The checkout's firmwarekit (Packages/FirmwareKit, debug), built once per test run under .build/offline-firmwarekit.
enum FirmwareKitTool {
    private nonisolated static let built: Result<URL, any Error> = Result {
        let package = LibraryFixtures.repo.appendingPathComponent("Packages/FirmwareKit").path
        let scratch = LibraryFixtures.repo.appendingPathComponent(".build/offline-firmwarekit").path
        let swift = "/usr/bin/xcrun"
        try LibraryFixtures.run(
            swift,
            ["swift", "build", "--package-path", package, "--scratch-path", scratch, "--product", "firmwarekit"]
        )
        let bin = try LibraryFixtures.run(
            swift,
            ["swift", "build", "--package-path", package, "--scratch-path", scratch, "--show-bin-path"]
        )
        return URL(fileURLWithPath: bin.trimmingCharacters(in: .whitespacesAndNewlines)).appendingPathComponent(
            "firmwarekit"
        )
    }
    /// Off the main actor: a no-op `swift build` still takes seconds, and the tests share the main actor.
    static func path() async throws -> URL { try await Task.detached { try built.get() }.value }
}

/// A loopback HTTP server: GET of a known path answers its bytes, a `hanging` one never answers, anything else 404;
/// every path asked is logged.
nonisolated final class TestHTTPServer: @unchecked Sendable {
    private let listener: NWListener
    private let files: [String: Data]
    private let hanging: Set<String>
    /// The hanging paths' connections, held open until stop.
    private var held: [NWConnection] = []
    private let queue = DispatchQueue(label: "test-http")
    private let lock = NSLock()
    private var requests: [String] = []
    private(set) var base = ""
    var log: [String] { lock.withLock { requests } }

    init(_ files: [String: Data], hanging: Set<String> = []) async throws {
        self.files = files
        self.hanging = hanging
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters)
        listener.newConnectionHandler = { [unowned self] connection in
            connection.start(queue: queue)
            receive(connection, Data())
        }
        let port: UInt16 = try await withCheckedThrowingContinuation { continuation in
            let resumed = OSAllocatedUnfairLock(initialState: false)
            listener.stateUpdateHandler = { [listener] state in
                resumed.withLock { resumed in
                    guard !resumed else { return }
                    switch state {
                    case .ready:
                        resumed = true
                        continuation.resume(returning: listener.port!.rawValue)
                    case .failed(let error):
                        resumed = true
                        continuation.resume(throwing: error)
                    default: break
                    }
                }
            }
            listener.start(queue: queue)
        }
        base = "http://127.0.0.1:\(port)"
    }

    func stop() {
        listener.cancel()
        for connection in lock.withLock({ held }) { connection.cancel() }
    }

    private func receive(_ connection: NWConnection, _ buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [self] data, _, done, error in
            let buffer = buffer + (data ?? Data())
            guard buffer.range(of: Data("\r\n\r\n".utf8)) != nil else {
                if done || error != nil { connection.cancel() } else { receive(connection, buffer) }
                return
            }
            let words =
                String(decoding: buffer, as: UTF8.self).split(separator: "\r\n").first?.split(separator: " ") ?? []
            let path = words.count > 1 ? String(words[1]) : ""
            lock.withLock { requests.append(path) }
            guard !hanging.contains(path) else { return lock.withLock { held.append(connection) } }
            let body = words.first == "GET" ? files[path] : nil
            let head =
                "HTTP/1.1 \(body == nil ? "404 Not Found" : "200 OK")\r\nContent-Length: \((body ?? Data("gone".utf8)).count)\r\nConnection: close\r\n\r\n"
            connection.send(
                content: Data(head.utf8) + (body ?? Data("gone".utf8)),
                completion: .contentProcessed { _ in connection.cancel() }
            )
        }
    }
}
