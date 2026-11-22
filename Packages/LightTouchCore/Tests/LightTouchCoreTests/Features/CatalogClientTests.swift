import Crypto
import Foundation
import Testing

@testable import LightTouchCore

extension SharedState {
    /// CatalogClient against an in-process Legacy Store (LegacyStoreStub): decoding, downloads into scratch, checksum
    /// and HTTP failures, cancellation, the IPA library's reuse, and API 2.1's per-device compatibility in both
    /// response shapes (tests/fixtures/store-compat).
    @Suite struct CatalogClientTests {
        nonisolated static let body = Data(String(repeating: "catalog download fixture\n", count: 4096).utf8)
        /// Copies whose download_url is neither the store's own origin nor the Internet Archive over https.
        nonisolated static let refusedDownloads = [
            "881": "https://elsewhere.test/ipa/881", "882": "http://ia800.us.archive.org/ipa/882",
            "883": "file:///ipa/883"
        ]
        /// Copies whose download_url is the store's own, which redirects: 884 and 885 where no download may come
        /// from, 886 to the Internet Archive, as the live store does.
        nonisolated static let redirects = [
            "884": "https://elsewhere.test/ipa/884", "885": "file:///ipa/885",
            "886": "https://ia800.us.archive.org/ipa/886"
        ]

        /// tests/fixtures/catalog-server.py: one fixture app per ipa_id, its copy record, two versions and the archive.
        nonisolated static func fixtureServer(_ request: URLComponents) -> LegacyStoreStub.Reply {
            let ident = request.items["ipa_id"] ?? "123"
            func app(_ id: String) -> [String: Any] {
                [
                    "name": "Fixture App", "bundle_id": "test.fixture", "developer": "Fixture", "version": "1.0",
                    "min_os": "3.0",
                    "size": body.count, "ipa_id": Int(id)!,
                    "download_url": refusedDownloads[id] ?? "http://catalog.test/ipa/" + id,
                    "app_url": "http://catalog.test/app/test.fixture"
                ]
            }
            let path = request.path
            if path == "/api/emulator/apps" {
                return ident == "999" ? .error(503) : .json(["apps": [app(ident)]])
            }
            if path.hasPrefix("/api/v1/copies/") {
                let id = String(path.split(separator: "/").last!)
                let md5 =
                    id == "666"
                    ? String(repeating: "0", count: 32)
                    : Insecure.MD5.hash(data: body).map { String(format: "%02x", $0) }.joined()
                return .json([
                    "ipa_id": id, "filename": "fixture-\(id).ipa", "size": body.count, "md5": md5, "available": true,
                    "version": id == "123" ? "1.0" : "0.9", "bundle_id": "test.fixture",
                    "binary": [
                        "install_status": "installable", "architectures": ["armv6"], "macho_min_os": "3.0",
                        "device_family_macho": ["1"]
                    ]
                ])
            }
            if path.hasSuffix("/versions") {
                return .json([
                    "data": [("123", "1.0"), ("456", "0.9")].map { id, version in
                        [
                            "version": version, "minimum_os_version": "3.0",
                            "copies": [
                                [
                                    "ipa_id": id, "size": body.count, "install_status": "installable",
                                    "architectures": ["armv6"], "macho_min_os": "3.0"
                                ]
                            ]
                        ]
                    }
                ])
            }
            if request.host == "catalog.test", path.hasPrefix("/ipa/"),
                let to = redirects[String(path.dropFirst(5))]
            {
                return .redirect(URL(string: to)!)
            }
            if path.hasPrefix("/ipa/") {
                return LegacyStoreStub.Reply(body: body, chunk: 4096, pause: path.hasSuffix("/777") ? 0.05 : 0)
            }
            return .error(404)
        }

        @Test func decodeDownloadRejectAndCancel() async throws {
            try await withTemporaryState { state in
                try await LegacyStoreStub.serving(state: state, { Self.fixtureServer($0) }) {
                    let found = try await CatalogClient.search("fixture")
                    #expect(found.count == 1)
                    #expect(try await CatalogClient.versions(for: found[0]).count == 2)
                    let work = state.appendingPathComponent("work")
                    func scratch() -> Set<String> {
                        Set(
                            ((try? FileManager.default.contentsOfDirectory(atPath: work.path)) ?? []).filter {
                                $0.hasPrefix("catalog-")
                            }
                        )
                    }
                    let file = try await CatalogClient.download(found[0]) { _ in }
                    #expect(try Data(contentsOf: file) == Self.body)
                    #expect(file.path.hasPrefix(work.appendingPathComponent("catalog-123-").path))
                    try FileManager.default.removeItem(at: file.deletingLastPathComponent())

                    for id in Self.refusedDownloads.keys.sorted() {
                        let copy = try await CatalogClient.compatibleCopy(Int(id)!)
                        do {
                            _ = try await CatalogClient.download(copy) { _ in }
                            Issue.record("\(copy.downloadURL) was downloaded")
                        } catch CatalogError.invalidCopy {}
                    }
                    #expect(
                        !LegacyStoreStub.requests.contains { $0.path.hasPrefix("/ipa/88") },
                        "a refused download_url was requested"
                    )

                    let bad = try await CatalogClient.compatibleCopy(666)
                    await #expect(throws: CatalogError.self) { try await CatalogClient.download(bad) { _ in } }
                    do {
                        _ = try await CatalogClient.compatibleCopy(999)
                        Issue.record("a 503 was accepted")
                    } catch CatalogError.badStatus(503) {}

                    let slow = try await CatalogClient.compatibleCopy(777)
                    let task = Task { try await CatalogClient.download(slow) { _ in } }
                    try await Task.sleep(for: .milliseconds(150))
                    task.cancel()
                    await #expect(throws: (any Error).self) { try await task.value }
                    #expect(scratch().isEmpty, "a failed or cancelled transfer owns no scratch directory")
                }
            }
        }

        /// Every hop of a download is held to acceptsDownload, not only the download_url the catalog names: a
        /// redirect from the store to another host or scheme is not followed.
        @Test func aRedirectOutsideTheAcceptedDownloadsIsRefused() async throws {
            try await withTemporaryState { state in
                try await LegacyStoreStub.serving(state: state, { Self.fixtureServer($0) }) {
                    for id in ["884", "885"] {
                        let copy = try await CatalogClient.compatibleCopy(Int(id)!)
                        do {
                            _ = try await CatalogClient.download(copy) { _ in }
                            Issue.record("\(id)'s redirect was followed")
                        } catch CatalogError.invalidCopy {}
                    }
                    #expect(LegacyStoreStub.requests.contains { $0.path == "/ipa/884" })
                    #expect(
                        !LegacyStoreStub.requests.contains { $0.host != "catalog.test" },
                        "a refused redirect was followed: \(LegacyStoreStub.requests.map(\.string))"
                    )
                    let file = try await CatalogClient.download(try await CatalogClient.compatibleCopy(886)) { _ in }
                    #expect(try Data(contentsOf: file) == Self.body)
                    #expect(LegacyStoreStub.requests.last?.host == "ia800.us.archive.org")
                }
            }
        }

        // MARK: API 2.1 compatibility, against recorded responses of both shapes

        nonisolated static let compatFiles = [
            "iPod2,1": "new-ipod2-3.1.3-enigmo", "iPad1,1": "new-ipad1-3.2-enigmo", "iPod1,1": "new-ipod1-1.1.5-enigmo"
        ]

        /// The live (2.0) server ignores device/os; the 2.1 one judges and 404s incompatible copies.
        nonisolated static func compatServer(new: Bool) -> @Sendable (URLComponents) -> LegacyStoreStub.Reply {
            { request in
                func load(_ name: String) -> [String: Any] {
                    try! JSONSerialization.jsonObject(with: Data(contentsOf: fixture("store-compat/" + name)))
                        as! [String: Any]
                }
                let query = request.items
                let device = new ? query["device"] : nil
                if device == "iPhone9,9" {
                    return .json(["error": "device must be one of iPod1,1, iPod2,1, iPad1,1"], status: 400)
                }
                switch request.path {
                case "/api/emulator/apps":
                    var data =
                        device.map {
                            load(
                                compatFiles[$0]!
                                    + (query["ipa_id"] != nil || query["incompatible"] != nil ? "-include" : "")
                                    + ".json"
                            )
                        }
                        ?? load("old-enigmo.json")
                    if let id = query["ipa_id"] {
                        let apps = (data["apps"] as! [[String: Any]]).filter { "\($0["ipa_id"]!)" == id }
                        if let first = apps.first, let compat = first["compat"] as? [String: Any],
                            compat["compatible"] as? Bool == false
                        {
                            return .json(["error": "not_compatible"], status: 404)
                        }
                        data["apps"] = apps
                    }
                    return .json(data)
                case "/api/v1/copies/7": return .json(["ipa_id": [7]])  // an ipa_id that isn't a string: unreadable
                case "/api/v1/copies/195588":
                    return .file(fixture("store-compat/" + (new ? "new" : "old") + "-copy-195588.json"))
                default: return .error(500)  // /ipa/…: every download here must come from the library
                }
            }
        }

        /// The library already holds Enigmo 3.3-H's bytes, indexed by an earlier build (index.json): the first read converts it.
        static func seedLibrary() throws -> Data {
            let blob = Data("enigmo fixture bytes".utf8)
            try FileManager.default.createDirectory(at: IPALibrary.directory, withIntermediateDirectories: true)
            try blob.write(to: IPALibrary.blob("feed"))
            try JSONSerialization.data(withJSONObject: [
                "feed": [
                    "bundleID": "com.pangea.Enigmo", "size": blob.count,
                    "md5": "1ce61d09f89df054e99b72eabffbd640"
                ]
            ])
            .write(to: IPALibrary.directory.appendingPathComponent("index.json"))
            #expect(
                IPALibrary.index["feed"]?.md5 == "1ce61d09f89df054e99b72eabffbd640",
                "the earlier build's index is read"
            )
            #expect(
                !FileManager.default.fileExists(atPath: IPALibrary.directory.appendingPathComponent("index.json").path)
            )
            let plist = try PropertyListSerialization.propertyList(
                from: Data(contentsOf: IPALibrary.directory.appendingPathComponent("index.plist")),
                format: nil
            )
            #expect((plist as? [String: Any])?["feed"] != nil, "index.json became index.plist")
            return blob
        }

        /// Every search names the device when there is one; only a query asks for the excluded apps too; no family.
        static func checkSearches(_ requests: [URLComponents]) -> [[String: String]] {
            let searches = requests.filter { $0.path == "/api/emulator/apps" && $0.items["ipa_id"] == nil }.map(\.items)
            #expect(!requests.contains { $0.path.hasPrefix("/ipa/") }, "a download left the library")
            for query in searches {
                #expect(
                    (query["q"] != nil) == (query["incompatible"] == "include") && query["family"] == nil,
                    "\(query)"
                )
                if query["device"] != nil { #expect(query["os"]?.isEmpty == false, "\(query)") }
            }
            return searches
        }

        @Test func liveShapeDecodesUnchangedAndReusesTheLibraryThroughTheCopyRecord() async throws {
            try await withTemporaryState { state in
                try await LegacyStoreStub.serving(state: state, Self.compatServer(new: false)) {
                    let blob = try Self.seedLibrary()
                    for device in [nil, "iPod2,1"] {
                        let found = try await CatalogClient.search("enigmo", device: device, os: "3.1.3")
                        #expect(
                            found.count == 4
                                && found.allSatisfy { $0.compat == nil && $0.md5 == nil && $0.incompatibility == nil }
                        )
                        #expect(found.first?.subtitle == "Pangea Software, Inc., 5.1 MB")
                    }
                    let enigmo = try await CatalogClient.compatibleCopy(195588, device: "iPod2,1", os: "3.1.3")
                    let file = try await CatalogClient.download(enigmo, device: "iPod2,1") { _ in }
                    #expect(try Data(contentsOf: file) == blob, "the library copy, found by the copy record's md5")
                    _ = Self.checkSearches(LegacyStoreStub.requests)
                    #expect(LegacyStoreStub.requests.filter { $0.path == "/api/v1/copies/195588" }.count == 1)
                }
            }
        }

        @Test func apiTwoOneJudgesPerDevice() async throws {
            let log = LogLines()
            try await withTemporaryState { state in
                try await LegacyStoreStub.serving(state: state, log: log.add, Self.compatServer(new: true)) {
                    let blob = try Self.seedLibrary()
                    func names(_ apps: [CatalogApp]) -> [String: String?] {
                        Dictionary(uniqueKeysWithValues: apps.map { ($0.name, $0.incompatibility) })
                    }

                    // A response that doesn't decode: unreadable in plain words; the log has the coding path.
                    do {
                        _ = try await CatalogClient.copyDetails(7)
                        Issue.record("decoded a garbled copy record")
                    } catch CatalogError.unreadable {}
                    #expect(
                        log.all.contains {
                            $0.contains("Legacy Store: couldn’t read /api/v1/copies/7") && $0.contains("typeMismatch")
                                && $0.contains("ipa_id")
                        },
                        "\(log.all)"
                    )

                    // A device the server doesn't take yet: its 400 is "doesn't support <name> yet", not "try again later".
                    do {
                        _ = try await CatalogClient.search("", device: "iPhone9,9", os: "4.0")
                        Issue.record("an unknown device was served")
                    } catch CatalogError.unsupportedDevice {}

                    // iPod touch 2G: Enigmo 3.3-H's armv6 slice is ARMv7 code, grayed with the reason; the other three run.
                    let ipod2 = try await CatalogClient.search("enigmo", device: "iPod2,1", os: "3.1.3")
                    #expect(
                        names(ipod2) == [
                            "Enigmo": "Needs a newer processor", "Enigmo 2": nil, "Enigmo!": nil, "Enigmous": nil
                        ]
                    )
                    #expect(
                        ipod2[0].subtitle == "Needs a newer processor" && ipod2[1].subtitle.hasPrefix("Pangea Software")
                    )
                    #expect(ipod2[0].md5 == "1ce61d09f89df054e99b72eabffbd640")
                    do {
                        _ = try await CatalogClient.compatibleCopy(195588, device: "iPod2,1", os: "3.1.3")
                        Issue.record("iPod took Enigmo")
                    } catch CatalogError.badStatus(404) {}
                    #expect(
                        log.all.contains { $0.hasPrefix("Legacy Store: HTTP 404 for /api/emulator/apps?") },
                        "the HTTP status is logged"
                    )
                    // the suggested list: compatible only
                    _ = try await CatalogClient.search("", device: "iPod2,1", os: "3.1.3")

                    // iPad: the same copy runs; the search record's md5 is in the library: no copy record, no transfer.
                    let ipad = try await CatalogClient.search("enigmo", device: "iPad1,1", os: "3.2")
                    #expect(
                        ipad.count == 4
                            && ipad.allSatisfy { $0.compat?.compatible == true && $0.incompatibility == nil }
                    )
                    let enigmo = try await CatalogClient.compatibleCopy(195588, device: "iPad1,1", os: "3.2")
                    let file = try await CatalogClient.download(
                        enigmo,
                        device: "iPad1,1",
                        deviceOS: "3.2",
                        arch: "armv7"
                    ) { _ in }
                    #expect(try Data(contentsOf: file) == blob)

                    // iPod touch 1G on 1.1.5: nothing qualifies; a search says why.
                    #expect(try await CatalogClient.search("", device: "iPod1,1", os: "1.1.5").isEmpty)
                    let ipod1 = try await CatalogClient.search("enigmo", device: "iPod1,1", os: "1.1.5")
                    #expect(
                        names(ipod1) == [
                            "Enigmo": "Needs a newer processor", "Enigmo 2": "Requires iOS 3.0",
                            "Enigmo!": "Requires iOS 3.0", "Enigmous": "Requires iOS 2.0"
                        ]
                    )

                    let requests = LegacyStoreStub.requests
                    #expect(
                        Self.checkSearches(requests).map { $0["device"] } == [
                            "iPhone9,9", "iPod2,1", "iPod2,1", "iPad1,1", "iPod1,1", "iPod1,1"
                        ]
                    )
                    for lookup in requests.filter({ $0.path == "/api/emulator/apps" && $0.items["ipa_id"] != nil }).map(
                        \.items
                    ) {
                        #expect(
                            lookup["device"] != nil && lookup["os"] != nil && lookup["incompatible"] == nil,
                            "\(lookup)"
                        )
                    }
                    #expect(
                        !requests.contains { $0.path == "/api/v1/copies/195588" },
                        "a known md5 still fetched the copy record"
                    )
                }
            }
        }
    }
}
