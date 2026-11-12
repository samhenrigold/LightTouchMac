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

public import FirmwareSchema
import Foundation

/// One entry of the app's Resources/firmware-catalog.json (the app's FirmwareCatalog.Entry schema).
public typealias FirmwareEntry = FirmwareWire.Entry

extension FirmwareEntry {
    public static func load(from url: URL) throws -> FirmwareEntry {
        try JSONDecoder().decode(FirmwareEntry.self, from: Data(contentsOf: url))
    }

    /// Resolve one entry from the shared catalog, rejecting ambiguous or unknown ids.
    public static func load(id: String, fromCatalog url: URL) throws -> FirmwareEntry {
        struct Catalog: Decodable {
            var format: Int
            var entries: [FirmwareEntry]
        }
        let catalog = try JSONDecoder().decode(Catalog.self, from: Data(contentsOf: url))
        guard catalog.format == 1 else { throw FirmwareError(.unsupported, "unknown catalog format \(catalog.format)") }
        let matches = catalog.entries.filter { $0.id == id }
        guard matches.count == 1 else {
            throw FirmwareError(.unsupported, "catalog must contain exactly one entry named \(id)")
        }
        return matches[0]
    }

    // What a release's own iOS needs of its device, ruled by the version where the row's recipe option says nothing
    // (a row's option is an exception to the rule; CatalogTests keeps the catalog free of them unless documented).

    /// data_journal: 3.0 and 3.1's mount_hfs refuse the journaled HFSX the Mac makes (EINVAL, "Invalid content in
    /// Journal"), so /private/var would stay on the system volume (issue 97); 3.2 on mount it.
    public static func journaledData(version: String) -> Bool { release(version) >= (3, 2) }
    /// writable_nor (the k48 recipe's boards) and data_protection (n72): 4.0 on, the first with data protection: the
    /// keybag one-shot and the writable NOR that keeps it.
    public static func dataProtection(version: String) -> Bool { release(version).major >= 4 }
    /// "3.1.3" -> (3, 1).
    static func release(_ version: String) -> (major: Int, minor: Int) {
        let parts = version.split(separator: ".").map { Int($0) ?? 0 }
        return (parts.first ?? 0, parts.count > 1 ? parts[1] : 0)
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
    /// MinimumSystemPartition and this board's SystemPartitionPadding ({capacity GB: MiB}): what a restore sizes
    /// the system partition to (3.x+; nil and empty before).
    public var minimumSystemMiB: Int?
    public var systemPaddingMiB: [String: Int] = [:]
    /// A universal IPSW's other devices (the 32-bit 10.3.4's, iPhone5,1 to 5,4): its DeviceMap's boards and its
    /// SupportedProductTypes. Restore.plist's ProductType and first board name only the first of them.
    public var boards: [String] = [], supportedProductTypes: [String] = []

    public init(_ ipsw: IPSWArchive) throws { try self.init(plistData: ipsw.read("Restore.plist")) }

    public init(plistData: Data) throws {
        guard let p = try PropertyListSerialization.propertyList(from: plistData, format: nil) as? [String: Any],
            let type = p["ProductType"] as? String, let build = p["ProductBuildVersion"] as? String,
            let version = p["ProductVersion"] as? String,
            let maps = p["DeviceMap"] as? [[String: Any]],
            // 1.x lists the platform's DFU-only "s5l8900xall" first; the device's own board follows
            let map = maps.first(where: { !($0["BoardConfig"] as? String ?? "").hasSuffix("xall") }) ?? maps.first,
            let board = map["BoardConfig"] as? String
        else {
            throw FirmwareError(.unsupported, "Restore.plist lacks ProductType/ProductBuildVersion/DeviceMap")
        }
        kernelCache =
            ((p["KernelCachesByPlatform"] as? [String: Any])?[map["Platform"] as? String ?? ""] as? [String: Any])?[
                "Release"
            ] as? String
            ?? (p["RestoreKernelCaches"] as? [String: Any])?["Release"] as? String  // 1.x
        systemImage = (p["SystemRestoreImages"] as? [String: Any])?["User"] as? String
        restoreRamDisk = (p["RestoreRamDisks"] as? [String: Any])?["User"] as? String
        updateRamDisk = (p["RestoreRamDisks"] as? [String: Any])?["Update"] as? String
        productType = type
        productBuildVersion = build
        productVersion = version
        boardConfig = board
        platform = map["Platform"] as? String ?? ""
        minimumSystemMiB =
            ((p["MinimumSystemPartition"] as? [String: Any])?.values.first as? NSNumber)?.intValue
            ?? (p["MinimumSystemPartition"] as? NSNumber)?.intValue
        let padding =
            (p["SystemPartitionPadding"] as? [String: Any])?[String(board.dropLast(2))] as? [String: Any] ?? [:]
        systemPaddingMiB = padding.compactMapValues { ($0 as? NSNumber)?.intValue }
        boards = maps.compactMap { $0["BoardConfig"] as? String }
        supportedProductTypes = p["SupportedProductTypes"] as? [String] ?? []
    }

    /// The system partition a restore of this IPSW gives a `storage` ("16g") unit, in MiB: minimum plus padding.
    public func systemPartitionMiB(storage: String) -> Int? {
        minimumSystemMiB.map { $0 + (systemPaddingMiB[String(storage.dropLast())] ?? 0) }
    }

    /// device.py's check: (ProductType, ProductBuildVersion, BoardConfig) must be the entry's. The 1.1.2 beta
    /// (3B48b) gives ProductType as the board name ("N45AP"), which stands for the entry's product type.
    /// A universal IPSW passes for any device it lists both the board and the product type of.
    public func verify(against entry: FirmwareEntry) throws {
        let listed = boards.contains(entry.board) && supportedProductTypes.contains(entry.productType)
        let board = listed ? entry.board : boardConfig
        let type =
            listed || productType.caseInsensitiveCompare(entry.board) == .orderedSame ? entry.productType : productType
        let found = [productType, productBuildVersion, boardConfig]
        let want = [entry.productType, entry.build, entry.board]
        guard [type, productBuildVersion, board] == want else {
            throw FirmwareError(
                .unsupported,
                "IPSW is \(found.joined(separator: " ")), \(entry.id) wants \(want.joined(separator: " "))"
            )
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
        let r = try RestoreInfo(ipsw)
        let af = "Firmware/all_flash/all_flash.\(r.boardConfig).production/"
        let comp = try fromRestore(r, img2: names.contains(af + "iBoot.\(r.boardConfig).RELEASE.img2"))
        let missing = comp.values.filter { !names.contains($0) }.sorted()
        guard missing.isEmpty else {
            throw FirmwareError(
                .unsupported,
                "no BuildManifest.plist, and Restore.plist-derived paths are missing: \(missing)"
            )
        }
        return comp
    }

    /// Only `board`'s identities (Info.DeviceClass): the 4.3 betas list the k48dev development board's first.
    public static func fromBuildManifest(_ data: Data, board: String) throws -> [String: String] {
        guard let p = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
            let all = p["BuildIdentities"] as? [[String: Any]]
        else {
            throw FirmwareError(.unsupported, "BuildManifest.plist has no BuildIdentities")
        }
        func info(_ bi: [String: Any], _ k: String) -> String? { (bi["Info"] as? [String: Any])?[k] as? String }
        let ids = all.filter { info($0, "DeviceClass")?.lowercased() == board.lowercased() }
        guard let first = ids.first(where: { info($0, "RestoreBehavior") != "Update" }) ?? ids.first,
            let manifest = first["Manifest"] as? [String: [String: Any]]
        else {
            throw FirmwareError(.unsupported, "BuildManifest.plist has no \(board) identity")
        }
        func path(_ v: [String: Any]?) -> String? { (v?["Info"] as? [String: Any])?["Path"] as? String }
        var comp = manifest.compactMapValues { path($0) }
        for bi in ids where info(bi, "RestoreBehavior") == "Update" {
            if let rd = path((bi["Manifest"] as? [String: [String: Any]])?["RestoreRamDisk"]) {
                comp["UpdateRamDisk"] = rd
            }
        }
        return comp
    }

    /// 1.x/2.x: Restore.plist names the kernelcache, rootfs and ramdisks; the rest follow the board's names
    /// (1.x: `.img2` all_flash members, and the logo carries no platform).
    public static func fromRestore(_ r: RestoreInfo, img2: Bool = false) throws -> [String: String] {
        let board = r.boardConfig
        let plat = r.platform
        let af = "Firmware/all_flash/all_flash.\(board).production/"
        // 1.0 (1A543a) has no update ramdisk and no iBEC: a restore was the only install path
        guard let kc = r.kernelCache, let os = r.systemImage, let user = r.restoreRamDisk,
            img2 || r.updateRamDisk != nil
        else {
            throw FirmwareError(.unsupported, "no BuildManifest.plist, and Restore.plist lacks the 2.x component keys")
        }
        let x = img2 ? "img2" : "img3"
        var comp = [
            "iBSS": "Firmware/dfu/iBSS.\(board).RELEASE.dfu",
            "iBoot": af + "iBoot.\(board).RELEASE.\(x)", "LLB": af + "LLB.\(board).RELEASE.\(x)",
            "DeviceTree": af + "DeviceTree.\(board).\(x)",
            "AppleLogo": af + (img2 ? "applelogo.img2" : "applelogo.\(plat).img3"),
            "KernelCache": kc, "OS": os, "RestoreRamDisk": user
        ]
        if let update = r.updateRamDisk {
            comp["UpdateRamDisk"] = update
            comp["iBEC"] = "Firmware/dfu/iBEC.\(board).RELEASE.dfu"
        }
        return comp
    }
}
