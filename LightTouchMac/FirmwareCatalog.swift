// The firmware the app knows how to turn into a device: Resources/firmware-catalog.json.
// Distinct from CatalogClient's app catalog. Field names follow qemu-ios
// manifests/*.json; see docs/multi-device-plan.md section B.

import Foundation

nonisolated struct FirmwareCatalog: Codable, Sendable {
    var format: Int
    var entries: [Entry]

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
            var gliDispatch: String?
            var guest: Guest?
            /// The entry whose restore ramdisk boots the keybag one-shot (no public ramdisk keys for this build).
            var keybagRamdiskFrom: String?
            enum CodingKeys: String, CodingKey {
                case name, version, storage, options, guest
                case systemMiB = "system_mib", dataSize = "data_size", gliDispatch = "gli_dispatch", keybagRamdiskFrom = "keybag_ramdisk_from"
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

        var id: String
        var board: String
        var productType: String
        var version: String
        var build: String
        var status: Status
        var statusNote: String?
        var source: Source
        /// The built-in device: a prepared base packed under the app's Resources
        /// (scripts/pack-base.py), published on first launch (FirmwareJobs.prepareBundled).
        var bundled: String?
        var keys: [String: Key]
        var recipe: Recipe?
        /// "none" or "optional": whether a user-configured hook may run.
        var emulator: Emulator
        var estimates: Estimates

        enum CodingKeys: String, CodingKey {
            case id, board, version, build, status, source, bundled, keys, recipe, emulator, estimates
            case productType = "product_type", statusNote = "status_note"
        }

        var profile: DeviceProfile? { DeviceProfile(boardID: board) }
    }

    static func load(from url: URL) throws -> FirmwareCatalog {
        let catalog = try JSONDecoder().decode(FirmwareCatalog.self, from: Data(contentsOf: url))
        guard catalog.format == 1, Set(catalog.entries.map(\.id)).count == catalog.entries.count else {
            throw CocoaError(.fileReadCorruptFile, userInfo: [NSFilePathErrorKey: url.path])
        }
        return catalog.sortedByVersion()
    }

    /// Boards in the order the file introduces them; each board's entries by version ascending
    /// (2.1.1, 3.1.3, 4.2.1), build as the tiebreak. Every listing (sidebar, settings) shows this order.
    func sortedByVersion() -> FirmwareCatalog {
        var boards: [String] = []
        for entry in entries where !boards.contains(entry.board) { boards.append(entry.board) }
        func key(_ e: Entry) -> ([Int], String) { (e.version.split(separator: ".").map { Int($0) ?? 0 }, e.build) }
        var sorted = self
        sorted.entries = entries.sorted {
            let (a, b) = (boards.firstIndex(of: $0.board)!, boards.firstIndex(of: $1.board)!)
            if a != b { return a < b }
            let (ka, kb) = (key($0), key($1))
            return ka.0 != kb.0 ? ka.0.lexicographicallyPrecedes(kb.0) : ka.1 < kb.1
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

    /// The entry the app ships a prepared base for (the iPod 3.1.3), if any.
    var bundledEntry: Entry? { entries.first { $0.bundled != nil } }
}

nonisolated extension DeviceProfile {
    init?(boardID: String) {
        switch boardID {
        case DeviceProfile.iPodTouch2G.boardID: self = .iPodTouch2G
        case DeviceProfile.iPad1.boardID: self = .iPad1
        default: return nil
        }
    }
}
