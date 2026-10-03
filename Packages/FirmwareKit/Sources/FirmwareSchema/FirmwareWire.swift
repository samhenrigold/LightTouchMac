// Flat catalog wire data shared by preparation and the GUI. Foundation only;
// presentation policy and firmware operations belong to their own layers.
import Foundation

nonisolated public enum FirmwareWire {
    /// Devices/<uuid>/<this>: {"recipe": N}, the recipe a stopped device's storage was migrated up to in place
    /// (boot admission), so a base whose lock names an older recipe is still current. Survives Erase on purpose:
    /// admission re-applies the migration's pages to a fresh overlay on every start.
    public static let migratedRecipeFile = "migrated-recipe.json"

    /// Stopped launch admission reply shared by all host clients. Generation
    /// paths remain durable record data, rather than a second GUI device schema.
    public struct BootAdmission: Codable, Sendable, Equatable {
        public let event: String
        public let changed: Bool
        public init(event: String = "admitted", changed: Bool) {
            self.event = event
            self.changed = changed
        }
    }

    public struct Entry: Codable, Sendable, Equatable {
        public struct Source: Codable, Sendable, Equatable {
            public var kind: String
            public var url: URL?
            public var sha1: String?
            public var bytes: Int64?
            public var resource: String?
        }

        /// An img3's IV/key, or a root filesystem's VFDecrypt key (no IV). `file` is the name inside the IPSW.
        public struct Key: Codable, Sendable, Equatable {
            public var file: String
            public var iv: String?
            public var key: String
            public init(file: String, iv: String?, key: String) { self.file = file; self.iv = iv; self.key = key }
        }

        public struct Recipe: Codable, Sendable, Equatable {
            public struct Guest: Codable, Sendable, Equatable {
                public var arch: String
                public var glEngine: String?
                enum CodingKeys: String, CodingKey { case arch, glEngine = "gl_engine" }
            }
            public var name: String
            public var version: Int
            public var storage: String
            public var systemMiB: Int
            public var dataSize: String
            public var options: [String: Bool]
            public var guest: Guest?
            /// The k48 boot chain: "iboot" (iBoot -> kernel; default when absent) or "kboot"
            /// (direct-kernel, for debugging). Ignored by n72ap.
            public var boot: String?
            /// A sibling entry (same iOS major, ramdisk keys known) whose restore ramdisk boots the data-protection
            /// keybag one-shot when this build has no public ramdisk keys (iPad 4.3.1-4.3.5 -> k48ap-8F190). The caller
            /// supplies that entry and its IPSW (firmwarekit create --sibling-entry/--sibling-ipsw).
            public var keybagRamdiskFrom: String?
            enum CodingKeys: String, CodingKey {
                case name, version, storage, options, guest, boot
                case systemMiB = "system_mib", dataSize = "data_size", keybagRamdiskFrom = "keybag_ramdisk_from"
            }
        }

        public struct Emulator: Codable, Sendable, Equatable {
            public var minProtocol: Int
            enum CodingKeys: String, CodingKey { case minProtocol = "min_protocol" }
        }

        public struct Estimates: Codable, Sendable, Equatable {
            public var preparedBytes: Int64
            public var peakBytes: Int64
            public var seconds: Int
            enum CodingKeys: String, CodingKey { case seconds, preparedBytes = "prepared_bytes", peakBytes = "peak_bytes" }
        }

        public var id: String
        public var board: String
        public var productType: String
        public var version: String
        public var build: String
        public var released: String?
        public var prerelease: String?
        public var prereleaseNumber: Int?
        public var status: String
        public var statusNote: String?
        public var source: Source
        public var keys: [String: Key]
        public var recipe: Recipe?
        public var emulator: Emulator
        public var estimates: Estimates

        enum CodingKeys: String, CodingKey {
            case id, board, version, build, released, prerelease, status, source, keys, recipe, emulator, estimates
            case productType = "product_type", statusNote = "status_note", prereleaseNumber = "prerelease_number"
        }

    }
}
