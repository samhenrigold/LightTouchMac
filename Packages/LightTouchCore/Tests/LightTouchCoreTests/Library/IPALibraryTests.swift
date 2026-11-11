import Crypto
import Foundation
import HostServiceWire
import Testing

@testable import LightTouchCore

extension SharedState {
    /// The IPA library (IPALibrary): one blob per archive, a clone per device, uninstall per device (AppInstaller),
    /// Legacy Store reuse with no transfer, Remove Unused and the idempotent launch sweep.
    @Suite struct IPALibraryTests {
        func hex(_ digest: some Sequence<UInt8>) -> String { digest.map { String(format: "%02x", $0) }.joined() }
        func bytes(_ url: URL?) -> Data { url.flatMap { try? Data(contentsOf: $0) } ?? Data() }
        func blobs() -> [String] {
            ((try? FileManager.default.contentsOfDirectory(atPath: IPALibrary.directory.path)) ?? []).filter {
                $0.hasSuffix(".ipa")
            }.sorted()
        }

        /// The fixture Legacy Store, whose archive route fails and records: every transfer the library should have
        /// skipped shows up.
        nonisolated final class Transfers: @unchecked Sendable {
            private let lock = NSLock()
            private var paths: [String] = []
            func add(_ path: String) { lock.withLock { paths.append(path) } }
            var all: [String] { lock.withLock { paths } }
        }

        /// Settings ▸ Storage's Add App…: an archive kept in the store with no device, named from its own Info.plist,
        /// and left by Remove Unused, as is the user's file.
        @Test func anAddedAppIsKeptThroughRemoveUnused() async throws {
            let a = FakeDevice("a")
            let devices: () -> [DeviceInstance] = { [a.instance] }
            try await withInstallerState(devices: devices) { state, _ in
                let ipa = state.appendingPathComponent("Kept.ipa")
                try makeIPA(at: ipa, bundleID: "test.kept", name: "Kept", info: ["CFBundleShortVersionString": "2.1"])
                try await IPALibrary.keep(ipa)
                let entry = try #require(IPALibrary.index.values.first { $0.bundleID == "test.kept" })
                #expect(entry.kept == true && entry.version == "2.1" && blobs().count == 1, "\(entry)")
                #expect(IPALibrary.unused(devices: [a.instance]).isEmpty, "kept, so not unused")
                try IPALibrary.removeUnused(devices: [a.instance])
                #expect(blobs().count == 1 && FileManager.default.fileExists(atPath: ipa.path))
            }
        }

        @Test func blobsCopiesUninstallReuseAndSweep() async throws {
            let a = FakeDevice("a")
            let b = FakeDevice("b")
            let c = FakeDevice("c")
            let devices: () -> [DeviceInstance] = { [a.instance, b.instance, c.instance] }
            try await withInstallerState(named: ["test.fixture"], devices: devices) { state, _ in
                let fm = FileManager.default
                let work = state.appendingPathComponent("scratch", isDirectory: true)
                try fm.createDirectory(at: work, withIntermediateDirectories: true)
                let fixtureBytes = CatalogClientTests.body
                let ipa = work.appendingPathComponent("Fixture App.ipa")
                try fixtureBytes.write(to: ipa)
                let sha = hex(SHA256.hash(data: fixtureBytes))
                let md5 = hex(Insecure.MD5.hash(data: fixtureBytes))

                // The same archive on two devices: one blob, one entry, a copy each.
                await IPALibrary.adopt(
                    ipa,
                    .init(
                        bundleID: "test.fixture",
                        name: "Fixture App",
                        version: "1.0",
                        minOS: "3.0",
                        catalogIpaID: 123
                    ),
                    device: a.instance
                )
                await IPALibrary.adopt(ipa, .init(bundleID: "test.fixture", name: "Fixture App"), device: b.instance)
                #expect(blobs() == ["\(sha).ipa"], "one blob named by its sha256")
                #expect(
                    IPALibrary.index == [
                        sha: .init(
                            bundleID: "test.fixture",
                            name: "Fixture App",
                            version: "1.0",
                            minOS: "3.0",
                            size: Int64(fixtureBytes.count),
                            md5: md5,
                            catalogIpaID: 123
                        )
                    ]
                )
                let onDisk = try PropertyListSerialization.propertyList(
                    from: Data(contentsOf: IPALibrary.directory.appendingPathComponent("index.plist")),
                    format: nil
                )
                #expect((onDisk as? [String: Any])?.keys.sorted() == [sha], "index.plist holds that entry")
                let copyA = try #require(IPALibrary.url(for: "test.fixture", device: a.instance))
                let copyB = try #require(IPALibrary.url(for: "test.fixture", device: b.instance))
                func ipas(_ device: FakeDevice) -> URL {
                    device.instance.paths(state: state, logs: state.appendingPathComponent("Logs")).ipas
                }
                #expect(
                    copyA.path.hasPrefix(ipas(a).path) && copyB.path.hasPrefix(ipas(b).path),
                    "copies live under each device"
                )
                #expect(bytes(copyA) == fixtureBytes && bytes(copyB) == fixtureBytes)
                // A missing source changes nothing; re-adopting the device's own copy keeps it.
                await IPALibrary.adopt(
                    ipa.appendingPathExtension("missing"),
                    .init(bundleID: "test.fixture"),
                    device: a.instance
                )
                await IPALibrary.adopt(copyA, .init(bundleID: "test.fixture"), device: a.instance)
                #expect(bytes(copyA) == fixtureBytes && blobs().count == 1 && IPALibrary.index.count == 1)

                // Legacy Store: the copy's checksum is in the library, so no transfer; a copy it lacks still fetches.
                let transfers = Transfers()
                try await LegacyStoreStub.serving(
                    state: state,
                    { request in
                        guard request.path.hasPrefix("/ipa/") else { return CatalogClientTests.fixtureServer(request) }
                        transfers.add(request.path)
                        return .error(500)
                    }
                ) {
                    @MainActor func app(_ id: Int) -> CatalogApp {
                        CatalogApp(
                            bundleID: "test.fixture",
                            name: "Fixture App",
                            version: "1.0",
                            minOS: "3.0",
                            size: Int64(fixtureBytes.count),
                            ipaID: id,
                            downloadURL: CatalogClient.baseURL.appendingPathComponent("ipa/\(id)")
                        )
                    }
                    let reused = try await CatalogClient.download(app(123)) { _ in }
                    #expect(
                        reused.path.hasPrefix(state.appendingPathComponent("work/catalog-123-").path)
                            && reused.lastPathComponent == "Fixture App.ipa",
                        "the library copy is handed over as the usual scratch file"
                    )
                    #expect(bytes(reused) == fixtureBytes)
                    try fm.removeItem(at: reused.deletingLastPathComponent())
                    do {
                        _ = try await CatalogClient.download(app(666)) { _ in }
                        Issue.record("a copy the library lacks was not fetched")
                    } catch CatalogError.badStatus(500) {}
                    #expect(
                        !((try? fm.contentsOfDirectory(atPath: state.appendingPathComponent("work").path)) ?? [])
                            .contains { $0.hasPrefix("catalog-666-") },
                        "a failed transfer owns no scratch directory"
                    )
                }
                #expect(transfers.all == ["/ipa/666"])

                // Uninstall on A: A's copy goes, B's copy and the app-wide name stay; the blob stays.
                @MainActor func uninstall(_ device: FakeDevice) async throws {
                    var finished = false
                    AppInstaller.remove(
                        [InstalledApp(id: "test.fixture", name: "Fixture App", version: "1.0")],
                        with: device,
                        presenting: nil,
                        willRemove: { _ in },
                        didRemove: { _ in }
                    ) { finished = true }
                    try await until { device.started == ["test.fixture"] }
                    device.finish("test.fixture")
                    try await until { finished }
                }
                try await uninstall(a)
                #expect(IPALibrary.url(for: "test.fixture", device: a.instance) == nil, "A's copy is gone")
                #expect(
                    bytes(copyB) == fixtureBytes && AppMetadataCache.shared.name(for: "test.fixture") != nil,
                    "B keeps its copy and the icon"
                )
                #expect(blobs() == ["\(sha).ipa"], "the blob stays")
                #expect(
                    IPALibrary.unused(devices: [a.instance, b.instance, c.instance]).isEmpty,
                    "a blob B references is not unused"
                )
                try await uninstall(b)
                #expect(
                    IPALibrary.url(for: "test.fixture", device: b.instance) == nil
                        && AppMetadataCache.shared.name(for: "test.fixture") == nil,
                    "the last device's uninstall drops the name and icon"
                )
                #expect(
                    blobs() == ["\(sha).ipa"] && IPALibrary.index.count == 1,
                    "the blob and its entry outlive every device copy"
                )

                // Remove Unused takes only the blobs no device references.
                let otherBytes = Data(String(repeating: "another archive\n", count: 1000).utf8)
                let other = work.appendingPathComponent("Other.ipa")
                try otherBytes.write(to: other)
                await IPALibrary.adopt(other, .init(bundleID: "test.other"), device: a.instance)
                let otherSha = hex(SHA256.hash(data: otherBytes))
                let devices = [a.instance, b.instance, c.instance]
                #expect(blobs() == ["\(otherSha).ipa", "\(sha).ipa"].sorted())
                #expect(IPALibrary.unused(devices: devices).keys.sorted() == [sha], "only the fixture is unused")
                try IPALibrary.removeUnused(devices: devices)
                #expect(blobs() == ["\(otherSha).ipa"] && IPALibrary.index.keys.sorted() == [otherSha])
                #expect(
                    bytes(IPALibrary.url(for: "test.other", device: a.instance)) == otherBytes,
                    "A's copy is untouched"
                )

                // The launch sweep: a device copy from before the store is hashed in once; a directory of copies from
                // the old layout is adopted the same way. Running the sweep again changes nothing.
                let handBytes = Data(String(repeating: "hand-made copy\n", count: 500).utf8)
                let legacyBytes = Data(String(repeating: "legacy shared copy\n", count: 500).utf8)
                try StorageLocations.privateDirectory(ipas(c))
                try handBytes.write(to: ipas(c).appendingPathComponent("hand.made.ipa"))
                let shared = state.appendingPathComponent("IPAs", isDirectory: true)
                try fm.createDirectory(at: shared, withIntermediateDirectories: true)
                try legacyBytes.write(to: shared.appendingPathComponent("legacy.app.ipa"))
                IPALibrary.sweep(devices: devices)
                await IPALibrary.adopt(copies: shared)
                let handSha = hex(SHA256.hash(data: handBytes))
                let legacySha = hex(SHA256.hash(data: legacyBytes))
                #expect(blobs() == ["\(otherSha).ipa", "\(handSha).ipa", "\(legacySha).ipa"].sorted())
                #expect(
                    IPALibrary.index[handSha]?.bundleID == "hand.made"
                        && IPALibrary.index[handSha]?.size == Int64(handBytes.count)
                        && IPALibrary.index[legacySha]?.bundleID == "legacy.app",
                    "indexed by their file names"
                )
                #expect(bytes(ipas(c).appendingPathComponent("hand.made.ipa")) == handBytes, "C's copy is untouched")
                let indexFile = IPALibrary.directory.appendingPathComponent("index.plist").path
                let before = try fm.attributesOfItem(atPath: indexFile)[.modificationDate] as? Date
                let indexBefore = IPALibrary.index
                try await Task.sleep(for: .milliseconds(20))
                IPALibrary.sweep(devices: devices)
                let after = try fm.attributesOfItem(atPath: indexFile)[.modificationDate] as? Date
                #expect(
                    IPALibrary.index == indexBefore && blobs().count == 3 && before == after,
                    "the second sweep changes nothing"
                )
            }
        }
    }
}
