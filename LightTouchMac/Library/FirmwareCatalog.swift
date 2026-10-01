// The firmware the app knows how to turn into a device: Resources/firmware-catalog.json.
// Distinct from CatalogClient's app catalog. Field names follow qemu-ios
// manifests/*.json; see docs/multi-device-plan.md section B.

import Foundation

nonisolated struct FirmwareCatalog: Codable, Sendable {
    var format: Int
    var entries: [Entry]
    /// The entry a first launch selects (firstRunEntry).
    var firstRun: String?
    enum CodingKeys: String, CodingKey { case format, entries, firstRun = "first_run" }

    struct Entry: Codable, Sendable, Identifiable, Equatable {
        /// `untested`: enumerated from Apple's list with public keys, never run through the pipeline (docs/matrix.md).
        enum Status: String, Codable, Sendable { case available, experimental, comingSoon = "coming_soon", userIPSW = "user_ipsw", untested }

        typealias Source = FirmwareWire.Entry.Source
        typealias Key = FirmwareWire.Entry.Key
        typealias Recipe = FirmwareWire.Entry.Recipe
        typealias Emulator = FirmwareWire.Entry.Emulator
        typealias Estimates = FirmwareWire.Entry.Estimates
        enum Prerelease: String, Codable, Sendable { case beta, gm }

        private var wire: FirmwareWire.Entry
        init(from decoder: Decoder) throws {
            wire = try FirmwareWire.Entry(from: decoder)
            guard Status(rawValue: wire.status) != nil, wire.source.kind == "ipsw",
                  wire.prerelease == nil || Prerelease(rawValue: wire.prerelease!) != nil else {
                throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath,
                    debugDescription: "Unknown firmware presentation status, prerelease or source kind"))
            }
        }
        func encode(to encoder: Encoder) throws { try wire.encode(to: encoder) }

        var status: Status {
            get { Status(rawValue: wire.status)! }
            set { wire.status = newValue.rawValue }
        }
        var prerelease: Prerelease? {
            get { wire.prerelease.flatMap(Prerelease.init(rawValue:)) }
            set { wire.prerelease = newValue?.rawValue }
        }
        var id: String {
            get { wire.id }
            set { wire.id = newValue }
        }
        var board: String {
            get { wire.board }
            set { wire.board = newValue }
        }
        var productType: String {
            get { wire.productType }
            set { wire.productType = newValue }
        }
        var version: String {
            get { wire.version }
            set { wire.version = newValue }
        }
        var build: String {
            get { wire.build }
            set { wire.build = newValue }
        }
        var released: String? {
            get { wire.released }
            set { wire.released = newValue }
        }
        var statusNote: String? {
            get { wire.statusNote }
            set { wire.statusNote = newValue }
        }
        var prereleaseNumber: Int? {
            get { wire.prereleaseNumber }
            set { wire.prereleaseNumber = newValue }
        }
        var source: Source {
            get { wire.source }
            set { wire.source = newValue }
        }
        var keys: [String: Key] {
            get { wire.keys }
            set { wire.keys = newValue }
        }
        var recipe: Recipe? {
            get { wire.recipe }
            set { wire.recipe = newValue }
        }
        var emulator: Emulator {
            get { wire.emulator }
            set { wire.emulator = newValue }
        }
        var estimates: Estimates {
            get { wire.estimates }
            set { wire.estimates = newValue }
        }

        var profile: DeviceProfile? { DeviceProfile(boardID: board) }

        /// The sidebar's badge, always numbered: "Beta 1", "Beta 3", "GM 1", "GM 2"; nil for a release.
        var prereleaseBadge: String? {
            prerelease.map { "\($0 == .beta ? "Beta" : "GM") \(prereleaseNumber ?? 1)" }
        }
    }

    static func load(from url: URL) throws -> FirmwareCatalog {
        let catalog = try JSONDecoder().decode(FirmwareCatalog.self, from: Data(contentsOf: url))
        guard catalog.format == 1, Set(catalog.entries.map(\.id)).count == catalog.entries.count else {
            throw CocoaError(.fileReadCorruptFile, userInfo: [NSFilePathErrorKey: url.path])
        }
        return catalog.sortedByVersion()
    }

    /// Boards in the order the file introduces them; each board's entries in version order. By
    /// marketing version ascending, and within a version its betas and GMs, then the release, by
    /// `released` date (betas by number, then GMs by number, where undated), build as the last
    /// tiebreak: 4.3.x stays together and 5.0 Beta 1 lists after 4.3.5, just before 5.0.
    /// Every listing (sidebar, settings) shows this order.
    func sortedByVersion() -> FirmwareCatalog {
        var boards: [String] = []
        for entry in entries where !boards.contains(entry.board) { boards.append(entry.board) }
        func board(_ e: Entry) -> Int { boards.firstIndex(of: e.board)! }
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
    static let bundled: FirmwareCatalog = {
        guard let url = Bundle.main.url(forResource: "firmware-catalog", withExtension: "json") else {
            fatalError("firmware-catalog.json is missing from the app bundle")
        }
        do { return try load(from: url) } catch { fatalError("firmware-catalog.json: \(error)") }
    }()

    func entry(id: String) -> Entry? { entries.first { $0.id == id } }

    /// What a first launch selects: an `available` build whose IPSW Apple's servers still serve (`first_run`).
    var firstRunEntry: Entry? { firstRun.flatMap(entry(id:)) }
}

nonisolated extension DeviceProfile {
    init?(boardID: String) {
        switch boardID {
        case DeviceProfile.iPodTouch2G.boardID: self = .iPodTouch2G
        case DeviceProfile.iPad1.boardID: self = .iPad1
        case DeviceProfile.iPodTouch1G.boardID: self = .iPodTouch1G
        default: return nil
        }
    }
}
