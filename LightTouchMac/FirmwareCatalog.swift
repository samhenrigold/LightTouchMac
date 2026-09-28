// The firmware the app knows how to turn into a device: Resources/firmware-catalog.json.
// Distinct from CatalogClient's app catalog. Field names follow qemu-ios
// manifests/*.json; see docs/multi-device-plan.md section B.

import Foundation

nonisolated struct FirmwareCatalog: Codable, Sendable {
    var format: Int
    var entries: [Entry]

    struct Entry: Codable, Sendable, Identifiable, Equatable {
        enum Status: String, Codable, Sendable { case available, experimental, comingSoon = "coming_soon", userIPSW = "user_ipsw" }

        struct Source: Codable, Sendable, Equatable {
            enum Kind: String, Codable, Sendable { case ipsw, bundled }
            var kind: Kind
            /// kind ipsw. A user_ipsw entry pins sha1 without a URL.
            var url: URL?
            var sha1: String?
            var bytes: Int64?
            /// kind bundled: a path under the app's Resources.
            var resource: String?
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
            enum CodingKeys: String, CodingKey {
                case name, version, storage, options, guest
                case systemMiB = "system_mib", dataSize = "data_size", gliDispatch = "gli_dispatch"
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
        var keys: [String: Key]
        var recipe: Recipe?
        /// "none" or "optional": whether a user-configured hook may run.
        var emulator: Emulator
        var estimates: Estimates

        enum CodingKeys: String, CodingKey {
            case id, board, version, build, status, source, keys, recipe, emulator, estimates
            case productType = "product_type", statusNote = "status_note"
        }

        var profile: DeviceProfile? { DeviceProfile(boardID: board) }
    }

    static func load(from url: URL) throws -> FirmwareCatalog {
        let catalog = try JSONDecoder().decode(FirmwareCatalog.self, from: Data(contentsOf: url))
        guard catalog.format == 1, Set(catalog.entries.map(\.id)).count == catalog.entries.count else {
            throw CocoaError(.fileReadCorruptFile, userInfo: [NSFilePathErrorKey: url.path])
        }
        return catalog
    }

    /// The catalog this build ships. A build without it is broken, not empty.
    static let bundled: FirmwareCatalog = {
        guard let url = Bundle.main.url(forResource: "firmware-catalog", withExtension: "json") else {
            fatalError("firmware-catalog.json is missing from the app bundle")
        }
        do { return try load(from: url) } catch { fatalError("firmware-catalog.json: \(error)") }
    }()

    func entry(id: String) -> Entry? { entries.first { $0.id == id } }

    /// Catalog ids the legacy devices are adopted as.
    static let legacyIPodID = "n72ap-7E18"
    static let developmentIPadID = "k48ap-7B500"
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
