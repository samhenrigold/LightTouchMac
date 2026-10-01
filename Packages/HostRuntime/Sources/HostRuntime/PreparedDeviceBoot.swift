import Foundation
import Darwin

/// Preparation and launch assembly shared by the GUI and headless session callers.
/// The caller must hold the device's storage lease before calling prepare.
/// Explicit URLs are caller-selected: this component does not authorize managed
/// record paths or enforce containment. Maintenance ownership checks stay with
/// the application's storage transaction boundary.
public struct PreparedDeviceBoot {
    public enum Board: String, Sendable, CaseIterable {
        case n45 = "n45ap", n72 = "n72ap", k48 = "k48ap"

        public func requiredFiles(strategy: String?) throws -> (boot: String, files: [String]) {
            switch self {
            case .k48:
                switch strategy {
                case nil, "kboot": return ("kboot.bin", [])
                case "iboot": return ("iBoot.bin", ["nor.bin", "gid-blobs.bin"])
                case "bootrom": return ("SecureROM.bin", ["nor.bin", "gid-blobs.bin"])
                default: throw PreparedDeviceBoot.unknownStrategy(strategy!)
                }
            case .n72:
                switch strategy {
                case nil, "iboot": return ("iBoot.bin", ["nor.bin", "gid-blobs.bin"])
                case "bootrom": return ("nor.bin", ["gid-blobs.bin"])
                default: throw PreparedDeviceBoot.unknownStrategy(strategy!)
                }
            case .n45:
                guard strategy == nil || strategy == "iboot" else { throw PreparedDeviceBoot.unknownStrategy(strategy!) }
                return ("iBoot.bin", ["nor.bin"])
            }
        }
    }

    public enum Failure: Error, Equatable { case baseMismatch }
    private let board: Board
    private let boot: URL
    private let nand: URL
    private let baseNOR: URL
    private let writableNOR: URL?
    private let overlay: URL
    private let bootrom: String
    private let strategy: String?
    private let gidBlobs: String?
    private let dieID: String?
    private let machine: [String: String]

    private static func unknownStrategy(_ strategy: String) -> CocoaError {
        CocoaError(.fileReadCorruptFile, userInfo: [NSLocalizedDescriptionKey: "Unknown boot strategy: \(strategy)"])
    }

    public static func prepare(board: Board, base: URL, overlay: URL, writableNOR: URL?,
                               storageKey: String?, bootrom: String, dieID: String? = nil) throws -> Self {
        let lock = base.appendingPathComponent("device.lock.json")
        let strategy = try BootRecipe.bootStrategy(lock)
        let required = try board.requiredFiles(strategy: strategy)
        let files = try BootRecipe.preparedFiles(base: base, overlay: overlay, writableNOR: writableNOR,
                                                  boot: required.boot, also: required.files)
        if board != .k48, files.writableNOR == nil {
            throw CocoaError(.fileNoSuchFile, userInfo: [NSFilePathErrorKey: "writable NOR"])
        }
        if board == .k48 {
            _ = try BootRecipe.preparedIPadBoot(strategy: strategy, image: files.boot.path,
                writableNOR: files.writableNOR?.path, gidBlobs: base.appendingPathComponent("gid-blobs.bin").path)
        }
        if let storageKey, try !pinOverlay(overlay, toBase: storageKey) { throw Failure.baseMismatch }
        let identityURL = base.appendingPathComponent("identity.json")
        let identity = (try? Data(contentsOf: identityURL))
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        let unitDieID = dieID ?? (identity?["die-id"] as? [String])?.joined(separator: ":")
        return Self(board: board, boot: files.boot, nand: files.nand,
                    baseNOR: base.appendingPathComponent("nor.bin"), writableNOR: files.writableNOR,
                    overlay: overlay, bootrom: bootrom, strategy: strategy,
                    gidBlobs: board == .n45 ? nil : base.appendingPathComponent("gid-blobs.bin").path,
                    dieID: unitDieID, machine: BootRecipe.lockMachine(lock))
    }

    /// Explicit adapter for pre-library N72 regression fixtures with separate images.
    /// Prepared device records always use prepare; no firmware policy is inferred here.
    public static func legacyN72(nand: URL, nor: URL, iBoot: String, gidBlobs: String?,
                                 machine: [String: String], overlay: URL, bootrom: String) throws -> Self {
        let destination = try writableNOR(base: nor, overlay: overlay)
        return Self(board: .n72, boot: URL(fileURLWithPath: iBoot.isEmpty ? "nor.bin" : iBoot), nand: nand,
                    baseNOR: nor, writableNOR: destination, overlay: overlay, bootrom: bootrom,
                    strategy: iBoot.isEmpty ? "bootrom" : "iboot", gidBlobs: gidBlobs, dieID: nil, machine: machine)
    }

    /// Legacy raw-image fixtures use an exact 1 MiB private NOR copy.
    public static func writableNOR(base: URL, overlay: URL) throws -> URL {
        let fm = FileManager.default
        try fm.createDirectory(at: overlay, withIntermediateDirectories: true)
        let destination = overlay.appendingPathComponent("nor.bin")
        if !fm.fileExists(atPath: destination.path) {
            let staged = overlay.appendingPathComponent(".nor-\(UUID().uuidString).tmp")
            defer { try? fm.removeItem(at: staged) }
            try fm.copyItem(at: base, to: staged)
            let size = try fm.attributesOfItem(atPath: staged.path)[.size] as? NSNumber
            guard size?.intValue == 1_048_576 else { throw CocoaError(.fileReadCorruptFile) }
            try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: staged.path)
            let handle = try FileHandle(forWritingTo: staged)
            defer { try? handle.close() }
            try handle.synchronize()
            try fm.moveItem(at: staged, to: destination)
        }
        let attributes = try fm.attributesOfItem(atPath: destination.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular,
              (attributes[.size] as? NSNumber)?.intValue == 1_048_576 else { throw CocoaError(.fileReadCorruptFile) }
        return destination
    }

    public static func pinOverlay(_ overlay: URL, toBase identity: String) throws -> Bool {
        let fm = FileManager.default
        let stamp = overlay.appendingPathComponent(".base-identity")
        let contents = (try? fm.contentsOfDirectory(atPath: overlay.path)) ?? []
        if contents.isEmpty {
            try fm.createDirectory(at: overlay, withIntermediateDirectories: true)
            try Data(identity.utf8).write(to: stamp, options: .atomic)
            return true
        }
        return (try? String(contentsOf: stamp, encoding: .utf8)) == identity
    }

    public func configuration(bootArgs: String, usbAddress: String?, wifi: Bool,
                              guestPackage: String?, serial: String, audio: [String],
                              netdev: String?, restore: [String] = [], webProxy: WebProxyEndpoint? = nil) throws -> BootConfig {
        var config: BootConfig
        switch board {
        case .n45:
            config = BootRecipe.iPod1G(.init(bootrom: bootrom, iBoot: boot.path, nand: nand.path,
                        writableNOR: writableNOR!.path, overlay: overlay.path, usbAddress: usbAddress,
                        wifi: wifi, guestPackage: guestPackage, machineOptions: machine),
                        serial: serial, audio: audio, netdev: netdev)
        case .n72:
            config = BootRecipe.iPod(.init(bootArgs: bootArgs, iBoot: strategy == "bootrom" ? "" : boot.path,
                        bootrom: bootrom, nand: nand.path, nor: baseNOR.path, writableNOR: writableNOR!.path,
                        overlay: overlay.path, usbAddress: usbAddress, wifi: wifi,
                        gidBlobs: gidBlobs, guestPackage: guestPackage, machineOptions: machine),
                        serial: serial, audio: audio, netdev: netdev, restore: restore)
        case .k48:
            let bootPath = try BootRecipe.preparedIPadBoot(strategy: strategy, image: boot.path,
                                                          writableNOR: writableNOR?.path, gidBlobs: gidBlobs)
            config = BootRecipe.iPad(.init(boot: bootPath, nand: nand.path, overlay: overlay.path,
                        dieID: dieID, usbAddress: usbAddress, wifi: wifi,
                        guestPackage: guestPackage, machineOptions: machine),
                        serial: serial, audio: audio, netdev: netdev, restore: restore)
        }
        config.webProxy = webProxy
        return config
    }
}
