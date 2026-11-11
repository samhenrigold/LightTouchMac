// The firmware the app knows how to turn into a device: Resources/firmware-catalog.json.
// Distinct from CatalogClient's app catalog. Field names follow qemu-ios
// manifests/*.json.

import FirmwareSchema
import Foundation
import HostRuntime

public nonisolated struct FirmwareCatalog: Codable, Sendable {
    public var format: Int
    public var entries: [Entry]
    /// The entry a first launch selects (firstRunEntry).
    public var firstRun: String?
    /// Entries the app ships prepared: entry id -> its packed base under the app's Resources (firmwarekit pack-base).
    public var bundled: [String: String]?
    public enum CodingKeys: String, CodingKey {
        case format
        case entries
        case bundled
        case firstRun = "first_run"
    }

    public struct Entry: Codable, Sendable, Identifiable, Equatable {
        /// `untested`: enumerated from Apple's list with public keys, never run through the pipeline.
        public enum Status: String, Codable, Sendable {
            case available, experimental
            case comingSoon = "coming_soon"
            case userIPSW = "user_ipsw"
            case untested
        }

        public typealias Source = FirmwareWire.Entry.Source
        public typealias Key = FirmwareWire.Entry.Key
        public typealias Recipe = FirmwareWire.Entry.Recipe
        public typealias Emulator = FirmwareWire.Entry.Emulator
        public typealias Estimates = FirmwareWire.Entry.Estimates
        public enum Prerelease: String, Codable, Sendable { case beta, gm }

        private var wire: FirmwareWire.Entry
        /// The packed base this app ships for the entry (the catalog's `bundled`), unpacked by FirmwareJobs.prepareBundled.
        /// Not part of the entry the preparer gets.
        public var bundled: String?
        /// The same entry whether or not this copy ships it prepared.
        public static func == (a: Entry, b: Entry) -> Bool { a.wire == b.wire }
        public init(from decoder: Decoder) throws {
            wire = try FirmwareWire.Entry(from: decoder)
            guard Status(rawValue: wire.status) != nil, ["ipsw", "rar"].contains(wire.source.kind),
                wire.prerelease == nil || wire.prerelease.flatMap(Prerelease.init(rawValue:)) != nil
            else {
                throw DecodingError.dataCorrupted(
                    .init(
                        codingPath: decoder.codingPath,
                        debugDescription: "Unknown firmware presentation status, prerelease or source kind"
                    )
                )
            }
        }
        public func encode(to encoder: Encoder) throws { try wire.encode(to: encoder) }

        public var status: Status {
            get {
                guard let status = Status(rawValue: wire.status) else {
                    preconditionFailure("init(from:) accepts only known statuses")
                }
                return status
            }
            set { wire.status = newValue.rawValue }
        }
        public var prerelease: Prerelease? {
            get { wire.prerelease.flatMap(Prerelease.init(rawValue:)) }
            set { wire.prerelease = newValue?.rawValue }
        }
        public var id: String {
            get { wire.id }
            set { wire.id = newValue }
        }
        public var board: String {
            get { wire.board }
            set { wire.board = newValue }
        }
        public var productType: String {
            get { wire.productType }
            set { wire.productType = newValue }
        }
        public var version: String {
            get { wire.version }
            set { wire.version = newValue }
        }
        public var build: String {
            get { wire.build }
            set { wire.build = newValue }
        }
        /// The libraries Import Media may add to on this build (MediaSupport).
        public var media: [String] { wire.media ?? [] }
        public var released: String? {
            get { wire.released }
            set { wire.released = newValue }
        }
        public var statusNote: String? {
            get { wire.statusNote }
            set { wire.statusNote = newValue }
        }
        public var prereleaseNumber: Int? {
            get { wire.prereleaseNumber }
            set { wire.prereleaseNumber = newValue }
        }
        public var source: Source {
            get { wire.source }
            set { wire.source = newValue }
        }
        public var keys: [String: Key] {
            get { wire.keys }
            set { wire.keys = newValue }
        }
        public var recipe: Recipe? {
            get { wire.recipe }
            set { wire.recipe = newValue }
        }
        public var emulator: Emulator {
            get { wire.emulator }
            set { wire.emulator = newValue }
        }
        public var estimates: Estimates {
            get { wire.estimates }
            set { wire.estimates = newValue }
        }

        public var profile: Board? { Board(rawValue: board) }
        /// What the user reads: "iPhone 4", never the model identifier ("iPhone3,1") unless the board is unknown.
        public var marketingName: String { profile?.marketingName ?? productType }
        /// The name Settings ▸ General's Device Names chose (Board.preferredName).
        public var preferredName: String { profile?.preferredName ?? productType }

        /// iPhone OS 1.x has no installation service (it came with 2.0): no apps to manage.
        public var managesApps: Bool { (Int(version.prefix { $0 != "." }) ?? 2) >= 2 }

        /// The sidebar's badge, always numbered: "beta 1", "beta 3", "GM 1", "GM 2"; nil for a release.
        public var prereleaseBadge: String? {
            prerelease.map { "\($0 == .beta ? "beta" : "GM") \(prereleaseNumber ?? 1)" }
        }
    }

    public static func load(from url: URL) throws -> FirmwareCatalog {
        var catalog = try JSONDecoder().decode(FirmwareCatalog.self, from: Data(contentsOf: url))
        for i in catalog.entries.indices { catalog.entries[i].bundled = catalog.bundled?[catalog.entries[i].id] }
        guard catalog.format == 1, Set(catalog.entries.map(\.id)).count == catalog.entries.count else {
            throw CocoaError(.fileReadCorruptFile, userInfo: [NSFilePathErrorKey: url.path])
        }
        return catalog.sortedByVersion()
    }

    /// Boards in the order the file introduces them; each board's entries in version order. By
    /// marketing version ascending, and within a version its betas and GMs, then the release, by
    /// `released` date (betas by number, then GMs by number, where undated), build as the last
    /// tiebreak: 4.3.x stays together and 5.0 beta 1 lists after 4.3.5, just before 5.0.
    /// Every listing (sidebar, settings) shows this order.
    public func sortedByVersion() -> FirmwareCatalog {
        var boards: [String] = []
        for entry in entries where !boards.contains(entry.board) { boards.append(entry.board) }
        func board(_ e: Entry) -> Int { boards.firstIndex(of: e.board) ?? boards.count }
        func version(_ e: Entry) -> [Int] { e.version.split(separator: ".").map { Int($0) ?? 0 } }
        func within(_ e: Entry) -> (Int, String, Int, Int) {
            (e.prerelease == nil ? 1 : 0, e.released ?? "", e.prerelease == .gm ? 1 : 0, e.prereleaseNumber ?? 1)
        }
        var sorted = self
        sorted.entries = entries.sorted { a, b in
            if board(a) != board(b) { return board(a) < board(b) }
            if version(a) != version(b) { return version(a).lexicographicallyPrecedes(version(b)) }
            return within(a) != within(b) ? within(a) < within(b) : a.build < b.build
        }
        return sorted
    }

    /// The catalog this build ships. A build without it is broken, not empty.
    public static let bundled: FirmwareCatalog = {
        guard let url = Bundle.main.url(forResource: "firmware-catalog", withExtension: "json") else {
            fatalError("firmware-catalog.json is missing from the app bundle")
        }
        do {
            var catalog = try load(from: url)
            // A build without the packed base (a development build) offers the entry as any other.
            for i in catalog.entries.indices {
                guard let resource = catalog.entries[i].bundled,
                    let url = Bundle.main.resourceURL?.appendingPathComponent(resource),
                    FileManager.default.fileExists(atPath: url.path)
                else {
                    catalog.entries[i].bundled = nil
                    continue
                }
            }
            return catalog
        } catch { fatalError("firmware-catalog.json: \(error)") }
    }()

    public func entry(id: String) -> Entry? { entries.first { $0.id == id } }

    /// What a first launch selects: an `available` build whose IPSW Apple's servers still serve (`first_run`).
    public var firstRunEntry: Entry? { firstRun.flatMap(entry(id:)) }

    /// The entry this app ships prepared (the iPod 3.1.3), if its base is here.
    public var bundledEntry: Entry? { entries.first { $0.bundled != nil } }
}
