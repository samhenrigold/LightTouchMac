// One device the user owns: State/Devices/<uuid>/device.json.
// See docs/multi-device-plan.md section B.
//
// Storage paths are relative to the state directory (like the packed-image
// pointer, so the record survives the state root moving) unless absolute. An
// adopted device's paths are the legacy names it already lives under, frozen
// here with its state key: nothing derives them again, so a later change to
// key derivation cannot orphan it.

import Foundation

nonisolated struct DeviceInstance: Codable, Equatable, Identifiable, Sendable {
    struct Base: Codable, Equatable, Sendable {
        enum Kind: String, Codable, Sendable {
            /// Read-only prepared output in Devices/<uuid>/base.
            case prepared
            /// The iPod image the app ships (nand.itnand), unpacked into
            /// State/device/<nand>-<digest> and chosen by active-<nand>.json.
            case legacyBundled
            /// A raw image in a development checkout (LTM_FILES).
            case development
        }
        var kind: Kind
        var path: String
    }

    struct Storage: Codable, Equatable, Sendable {
        /// The key the overlay, snapshot and image identity were made under.
        var key: String
        var overlay: String
        var writableNOR: String?
        /// Also .meta, .tmp and .bad beside it.
        var snapshot: String
        /// Legacy erase marker; removed, never acted on.
        var resetMarker: String?
        var usbmuxConf: String
    }

    struct Identity: Codable, Equatable, Sendable {
        var seed: String?
        var udid: String?
        var dieID: String?
        enum CodingKeys: String, CodingKey { case seed, udid, dieID = "die_id" }
    }

    struct Provenance: Codable, Equatable, Sendable {
        var lock: String?
        var sha256: String?
    }

    /// What adoption resolved from, kept to match the device again when a
    /// development launch names the same files root.
    struct Legacy: Codable, Equatable, Sendable {
        var filesRoot: String
        var nand: String
        /// State-relative active-<nand>.json, for legacyBundled.
        var pointer: String?
    }

    /// device.json `guest`: the guest package serials this device has run.
    struct Guest: Codable, Equatable, Sendable {
        /// Baked at prepare time (device.lock.json), when known.
        var seed: Int64?
        /// The last serial it_boot reported current.
        var active: Int64?
        /// The last serial a healthy session ran; offered as `verdict good`.
        var lastGood: Int64?
        /// Serials judged bad; offered as `verdict bad`, never installed again.
        var bad: [Int64] = []
        /// Offer the built-in package (serial 0) while the bundled serial is this.
        var builtIn: Int64?

        init() {}
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            seed = try c.decodeIfPresent(Int64.self, forKey: .seed)
            active = try c.decodeIfPresent(Int64.self, forKey: .active)
            lastGood = try c.decodeIfPresent(Int64.self, forKey: .lastGood)
            bad = try c.decodeIfPresent([Int64].self, forKey: .bad) ?? []
            builtIn = try c.decodeIfPresent(Int64.self, forKey: .builtIn)
        }
    }

    var format = 1
    let id: UUID
    var name: String
    var board: String
    /// A FirmwareCatalog entry id.
    var firmware: String
    var created: Date
    var base: Base
    var storage: Storage
    var identity: Identity?
    var provenance: Provenance?
    var lastEmulatorBuild: String?
    var legacy: Legacy?
    /// Guest-package serials and verdicts (GuestPackage).
    var guest: Guest?

    var profile: DeviceProfile? { DeviceProfile(boardID: board) }

    static let recordName = "device.json"

    /// `created` is stored as ISO 8601 whole seconds; a record made with a
    /// finer date would not equal itself read back.
    static var now: Date { Date(timeIntervalSince1970: Date().timeIntervalSince1970.rounded(.down)) }

    // MARK: - Paths

    /// Resolves a record path against the state directory.
    static func url(_ path: String, state: URL) -> URL {
        path.hasPrefix("/") ? URL(fileURLWithPath: path) : state.appendingPathComponent(path)
    }

    static func directory(_ id: UUID, state: URL) -> URL {
        state.appendingPathComponent("Devices/\(id.uuidString)", isDirectory: true)
    }

    /// Runtime paths, which are per instance for every device, adopted or
    /// not, so two running devices never share a pid file, session file or log.
    struct Paths: Sendable {
        let directory: URL
        let base: URL
        let overlay: URL
        let writableNOR: URL?
        let snapshot: URL
        let resetMarker: URL
        let usbmuxConf: URL
        /// usbmuxd.pid and session.env.
        let work: URL
        /// serial.log, usbmuxd.log.
        let logs: URL

        var snapshotMeta: URL { snapshot.appendingPathExtension("meta") }
        var snapshotTmp: URL { snapshot.appendingPathExtension("tmp") }
        var snapshotBad: URL { snapshot.appendingPathExtension("bad") }
        var usbmuxPID: URL { work.appendingPathComponent("usbmuxd.pid") }
        var sessionFile: URL { work.appendingPathComponent("session.env") }
        /// The helper's flock while it runs this device (LightTouchDevice --lease).
        var lease: URL { work.appendingPathComponent("lease") }
        /// Retained .ipa copies of the apps installed on this device (IPALibrary).
        var ipas: URL { directory.appendingPathComponent("IPAs", isDirectory: true) }
    }

    /// `logs` is the app's log root (Bundled.logsDirectory).
    func paths(state: URL, logs: URL) -> Paths {
        let directory = Self.directory(id, state: state)
        return Paths(directory: directory,
                     base: Self.url(base.path, state: state),
                     overlay: Self.url(storage.overlay, state: state),
                     writableNOR: storage.writableNOR.map { Self.url($0, state: state) },
                     snapshot: Self.url(storage.snapshot, state: state),
                     resetMarker: Self.url(storage.resetMarker ?? "Devices/\(id.uuidString)/.reset", state: state),
                     usbmuxConf: Self.url(storage.usbmuxConf, state: state),
                     work: directory.appendingPathComponent("work", isDirectory: true),
                     logs: logs.appendingPathComponent("Devices/\(id.uuidString)", isDirectory: true))
    }

    /// The preparer records what activated the volume in device.lock.json
    /// `inputs.activation`; a base made without that step has null or nothing
    /// there (a device.py base: `activation_hook: null`). False for an
    /// unreadable lock: nothing to claim.
    static func lockLacksActivation(_ lock: URL) -> Bool {
        guard let data = try? Data(contentsOf: lock),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let inputs = json["inputs"] as? [String: Any] else { return false }
        return !(inputs["activation"] is [String: Any])
    }

    // MARK: - UserDefaults

    /// Per-device UserDefaults key, e.g. "deviceNotice.<uuid>". Adoption
    /// copies the single-device value to the adopted iPod's key.
    func defaultsKey(_ name: String) -> String { "\(name).\(id.uuidString)" }

    // MARK: - Record I/O

    static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    /// Atomic: a crash leaves the old record or the new one, never half.
    func write(state: URL) throws {
        let directory = Self.directory(id, state: state)
        try StorageLocations.privateDirectory(directory)
        try Self.encoder.encode(self).write(to: directory.appendingPathComponent(Self.recordName), options: .atomic)
    }

    static func read(_ url: URL) throws -> DeviceInstance {
        try decoder.decode(DeviceInstance.self, from: Data(contentsOf: url))
    }

    /// Every readable record under State/Devices, oldest first. A directory
    /// without a readable record is skipped, not deleted.
    static func all(state: URL) -> [DeviceInstance] {
        let devices = state.appendingPathComponent("Devices", isDirectory: true)
        let names = (try? FileManager.default.contentsOfDirectory(atPath: devices.path)) ?? []
        return names.compactMap { name in
            guard let id = UUID(uuidString: name),
                  let record = try? read(devices.appendingPathComponent("\(name)/\(recordName)")),
                  record.id == id else { return nil }
            return record
        }.sorted { ($0.created, $0.id.uuidString) < ($1.created, $1.id.uuidString) }
    }
}
