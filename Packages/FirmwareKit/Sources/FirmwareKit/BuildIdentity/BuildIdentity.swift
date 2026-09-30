// BuildIdentity: what an IPSW is and where its components live.
//
//   let entry = try FirmwareEntry.load(from: entryJSON)     // one firmware-catalog.json entry, keys included
//   let restore = try RestoreInfo(ipsw)                     // Restore.plist
//   try restore.verify(against: entry)                      // ProductType / ProductBuildVersion / BoardConfig
//   let comp = try BuildComponents.load(ipsw, board: entry.board)  // {component: IPSW path}
//   comp["KernelCache"], comp["OS"], comp["UpdateRamDisk"]
//   try entry.key(forPath: comp["iBoot"]!)                  // IV/key by the member's file name
//
// Ports ipad1_fw.components (BuildManifest's board identity plus the Update identity's RestoreRamDisk as
// "UpdateRamDisk"; 2.x IPSWs have no BuildManifest, so the paths come from Restore.plist and the board's
// all_flash/dfu naming) and device.py's verify step.

import Foundation

/// One entry of the app's Resources/firmware-catalog.json (the app's FirmwareCatalog.Entry schema).
public struct FirmwareEntry: Codable, Sendable, Equatable {
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
        /// The k48 boot chain: "iboot" (SecureROM -> LLB -> iBoot -> kernel; default when absent) or "kboot"
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
    public var status: String
    public var statusNote: String?
    public var source: Source
    public var keys: [String: Key]
    public var recipe: Recipe?
    public var emulator: Emulator
    public var estimates: Estimates

    enum CodingKeys: String, CodingKey {
        case id, board, version, build, status, source, keys, recipe, emulator, estimates
        case productType = "product_type", statusNote = "status_note"
    }

    public static func load(from url: URL) throws -> FirmwareEntry {
        try JSONDecoder().decode(FirmwareEntry.self, from: Data(contentsOf: url))
    }

    /// The key for an IPSW member, looked up by its file name (as qemu-ios' key pages are).
    public func key(forPath path: String) throws -> Key {
        let name = (path as NSString).lastPathComponent
        guard let k = keys.values.first(where: { $0.file == name }) else {
            throw FirmwareError(.keyMissing, "\(id): no key for \(name)")
        }
        return k
    }
}

/// The Restore.plist fields the preparer reads.
public struct RestoreInfo: Sendable, Equatable {
    public var productType: String
    public var productBuildVersion: String
    public var productVersion: String
    public var boardConfig: String
    public var platform: String
    /// KernelCachesByPlatform[platform].Release, SystemRestoreImages.User, RestoreRamDisks.User/Update:
    /// the 2.x component paths (3.x+ read them from the BuildManifest).
    public var kernelCache, systemImage, restoreRamDisk, updateRamDisk: String?

    public init(_ ipsw: IPSWArchive) throws { try self.init(plistData: ipsw.read("Restore.plist")) }

    public init(plistData: Data) throws {
        guard let p = try PropertyListSerialization.propertyList(from: plistData, format: nil) as? [String: Any],
              let type = p["ProductType"] as? String, let build = p["ProductBuildVersion"] as? String,
              let version = p["ProductVersion"] as? String,
              let maps = p["DeviceMap"] as? [[String: Any]],
              // 1.x lists the platform's DFU-only "s5l8900xall" first; the device's own board follows
              let map = maps.first(where: { !($0["BoardConfig"] as? String ?? "").hasSuffix("xall") }) ?? maps.first,
              let board = map["BoardConfig"] as? String else {
            throw FirmwareError(.unsupported, "Restore.plist lacks ProductType/ProductBuildVersion/DeviceMap")
        }
        kernelCache = ((p["KernelCachesByPlatform"] as? [String: Any])?[map["Platform"] as? String ?? ""] as? [String: Any])?["Release"] as? String
            ?? (p["RestoreKernelCaches"] as? [String: Any])?["Release"] as? String   // 1.x
        systemImage = (p["SystemRestoreImages"] as? [String: Any])?["User"] as? String
        restoreRamDisk = (p["RestoreRamDisks"] as? [String: Any])?["User"] as? String
        updateRamDisk = (p["RestoreRamDisks"] as? [String: Any])?["Update"] as? String
        productType = type; productBuildVersion = build; productVersion = version
        boardConfig = board; platform = map["Platform"] as? String ?? ""
    }

    /// device.py's check: (ProductType, ProductBuildVersion, BoardConfig) must be the entry's. The 1.1.2 beta
    /// (3B48b) gives ProductType as the board name ("N45AP"), which stands for the entry's product type.
    public func verify(against entry: FirmwareEntry) throws {
        let type = productType.caseInsensitiveCompare(entry.board) == .orderedSame ? entry.productType : productType
        let found = [productType, productBuildVersion, boardConfig], want = [entry.productType, entry.build, entry.board]
        guard [type, productBuildVersion, boardConfig] == want else {
            throw FirmwareError(.unsupported, "IPSW is \(found.joined(separator: " ")), \(entry.id) wants \(want.joined(separator: " "))")
        }
    }
}

public enum BuildComponents {
    /// {component: IPSW path}. With a BuildManifest: `board`'s first (Erase) identity, plus its Update
    /// identity's RestoreRamDisk as "UpdateRamDisk". Without (2.x): derived from Restore.plist.
    public static func load(_ ipsw: IPSWArchive, board: String) throws -> [String: String] {
        let names = Set(try ipsw.names())
        if names.contains("BuildManifest.plist") {
            return try fromBuildManifest(ipsw.read("BuildManifest.plist"), board: board)
        }
        let r = try RestoreInfo(ipsw), af = "Firmware/all_flash/all_flash.\(r.boardConfig).production/"
        let comp = try fromRestore(r, img2: names.contains(af + "iBoot.\(r.boardConfig).RELEASE.img2"))
        let missing = comp.values.filter { !names.contains($0) }.sorted()
        guard missing.isEmpty else {
            throw FirmwareError(.unsupported, "no BuildManifest.plist, and Restore.plist-derived paths are missing: \(missing)")
        }
        return comp
    }

    /// Only `board`'s identities (Info.DeviceClass): the 4.3 betas list the k48dev development board's first.
    public static func fromBuildManifest(_ data: Data, board: String) throws -> [String: String] {
        guard let p = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let all = p["BuildIdentities"] as? [[String: Any]] else {
            throw FirmwareError(.unsupported, "BuildManifest.plist has no BuildIdentities")
        }
        func info(_ bi: [String: Any], _ k: String) -> String? { (bi["Info"] as? [String: Any])?[k] as? String }
        let ids = all.filter { info($0, "DeviceClass")?.lowercased() == board.lowercased() }
        guard let first = ids.first(where: { info($0, "RestoreBehavior") != "Update" }) ?? ids.first,
              let manifest = first["Manifest"] as? [String: [String: Any]] else {
            throw FirmwareError(.unsupported, "BuildManifest.plist has no \(board) identity")
        }
        func path(_ v: [String: Any]?) -> String? { (v?["Info"] as? [String: Any])?["Path"] as? String }
        var comp = manifest.compactMapValues { path($0) }
        for bi in ids where info(bi, "RestoreBehavior") == "Update" {
            if let rd = path((bi["Manifest"] as? [String: [String: Any]])?["RestoreRamDisk"]) { comp["UpdateRamDisk"] = rd }
        }
        return comp
    }

    /// 1.x/2.x: Restore.plist names the kernelcache, rootfs and ramdisks; the rest follow the board's names
    /// (1.x: `.img2` all_flash members, and the logo carries no platform).
    public static func fromRestore(_ r: RestoreInfo, img2: Bool = false) throws -> [String: String] {
        let board = r.boardConfig, plat = r.platform
        let af = "Firmware/all_flash/all_flash.\(board).production/"
        guard let kc = r.kernelCache, let os = r.systemImage, let user = r.restoreRamDisk, let update = r.updateRamDisk else {
            throw FirmwareError(.unsupported, "no BuildManifest.plist, and Restore.plist lacks the 2.x component keys")
        }
        let x = img2 ? "img2" : "img3"
        return ["iBSS": "Firmware/dfu/iBSS.\(board).RELEASE.dfu", "iBEC": "Firmware/dfu/iBEC.\(board).RELEASE.dfu",
                "iBoot": af + "iBoot.\(board).RELEASE.\(x)", "LLB": af + "LLB.\(board).RELEASE.\(x)",
                "DeviceTree": af + "DeviceTree.\(board).\(x)", "AppleLogo": af + (img2 ? "applelogo.img2" : "applelogo.\(plat).img3"),
                "KernelCache": kc, "OS": os, "RestoreRamDisk": user, "UpdateRamDisk": update]
    }
}
