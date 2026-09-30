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

        struct Source: Codable, Sendable, Equatable {
            enum Kind: String, Codable, Sendable { case ipsw }
            var kind: Kind
            /// A user_ipsw entry pins sha1 without a URL.
            var url: URL?
            var sha1: String?
            var bytes: Int64?
        }

        /// An img3's IV/key, or a root filesystem's VFDecrypt key (no IV).
        /// `file` is the name inside the IPSW, which is how qemu-ios' key
        /// text is looked up.
        struct Key: Codable, Sendable, Equatable {
            var file: String
            var iv: String?
            var key: String
        }

        struct Recipe: Codable, Sendable, Equatable {
            struct Guest: Codable, Sendable, Equatable {
                var arch: String
                var glEngine: String?
                enum CodingKeys: String, CodingKey { case arch, glEngine = "gl_engine" }
            }
            var name: String
            var version: Int
            var storage: String
            var systemMiB: Int
            var dataSize: String
            var options: [String: Bool]
            var guest: Guest?
            /// The entry whose restore ramdisk boots the keybag one-shot (no public ramdisk keys for this build).
            var keybagRamdiskFrom: String?
            /// Preserve explicit boot policy when forwarding the entry to FirmwareKit.
            var boot: String?
            enum CodingKeys: String, CodingKey {
                case name, version, storage, options, guest, boot
                case systemMiB = "system_mib", dataSize = "data_size", keybagRamdiskFrom = "keybag_ramdisk_from"
            }
        }

        struct Emulator: Codable, Sendable, Equatable { var minProtocol: Int
            enum CodingKeys: String, CodingKey { case minProtocol = "min_protocol" } }

        struct Estimates: Codable, Sendable, Equatable {
            var preparedBytes: Int64
            var peakBytes: Int64
            var seconds: Int
            enum CodingKeys: String, CodingKey { case seconds, preparedBytes = "prepared_bytes", peakBytes = "peak_bytes" }
        }

        /// A developer build: a beta or a golden master (docs/matrix.md, Betas).
        enum Prerelease: String, Codable, Sendable { case beta, gm }

        var id: String
        var board: String
        var productType: String
        var version: String
        var build: String
        /// Apple's release date ("2010-09-08"), or a developer build's; the order within a version.
        var released: String?
        var status: Status
        var statusNote: String?
        var prerelease: Prerelease?
        /// Which beta/GM of its version (absent: the first).
        var prereleaseNumber: Int?
        var source: Source
        var keys: [String: Key]
        var recipe: Recipe?
        /// "none" or "optional": whether a user-configured hook may run.
        var emulator: Emulator
        var estimates: Estimates

        enum CodingKeys: String, CodingKey {
            case id, board, version, build, released, status, source, keys, recipe, emulator, estimates, prerelease
            case productType = "product_type", statusNote = "status_note", prereleaseNumber = "prerelease_number"
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
