import Foundation
@preconcurrency import ZIPFoundation

/// Original modem assets required by the iPhone 5's native BBUpdater.
/// This installs firmware, not an activation record or modified executable.
public enum BasebandFirmware {
    public static let mav5Directory = "usr/local/standalone/firmware/Baseband/Mav5"
    static let mav5Payloads = ["apps", "dsp1", "dsp2", "dsp3", "rpm", "sbl1", "sbl2", "restoresbl1"]
        .map { $0 + ".mbn" }

    /// iOS 7's folder-backed BBUpdater source needs the original unpacked images
    /// as well as the versioned archive and metadata. Keep iOS 6's proven layout.
    static func expandedMav5Assets(_ bytes: Data) throws -> [(String, Data)] {
        let archive = try Archive(data: bytes, accessMode: .read)
        return try mav5Payloads.map { name in
            guard let entry = archive[name], entry.type == .file,
                entry.uncompressedSize > 0, entry.uncompressedSize <= 64 << 20
            else {
                throw FirmwareError(.unsupported, "Missing or invalid Mav5 payload: \(name)")
            }
            var data = Data()
            _ = try archive.extract(entry) { data.append($0) }
            return (mav5Directory + "/" + name, data)
        }
    }

    static func mav5Members(components: [String: String], board: String) throws -> [String] {
        guard ["n41ap", "n42ap"].contains(board.lowercased()),
            let member = components["BasebandFirmware"],
            member.hasPrefix("Firmware/Mav5-"), member.hasSuffix(".Release.bbfw"),
            member.split(separator: "/", omittingEmptySubsequences: false).count == 2,
            !member.contains("\\"), !member.contains("..")
        else {
            throw FirmwareError(.unsupported, "No supported Mav5 firmware for \(board)")
        }
        return [member, String(member.dropLast(5)) + ".plist"]
    }

    /// Call while preparing an offline System volume with root ownership.
    /// Both archive members and existing destinations are checked before writes.
    /// Existing identical assets are accepted; conflicting assets are never replaced.
    @discardableResult
    public static func installMav5(
        from ipsw: IPSWArchive, board: String,
        system: any VolumeFiles
    ) throws -> [String] {
        let members = try mav5Members(components: BuildComponents.load(ipsw, board: board), board: board)
        var assets = try members.map { member -> (String, Data) in
            let bytes = try ipsw.read(member)
            guard !bytes.isEmpty else { throw FirmwareError(.unsupported, "Empty modem asset: \(member)") }
            if member.hasSuffix(".plist") {
                guard try PropertyListSerialization.propertyList(from: bytes, format: nil) is [String: Any] else {
                    throw FirmwareError(.unsupported, "Invalid modem metadata: \(member)")
                }
            }
            return (mav5Directory + "/" + URL(fileURLWithPath: member).lastPathComponent, bytes)
        }
        let version = try RestoreInfo(ipsw).productVersion
        guard let major = Int(version.split(separator: ".").first ?? ""), (6...10).contains(major) else {
            throw FirmwareError(.unsupported, "Unsupported Mav5 system version: \(version)")
        }
        if major >= 7 {
            assets += try expandedMav5Assets(assets[0].1)
        }
        for (path, bytes) in assets {
            if let item = try system.item(at: path) {
                guard item.kind == .file, try system.contents(at: path) == bytes else {
                    throw FirmwareError(.unsupported, "Conflicting modem asset: \(path)")
                }
            }
        }
        try system.makeDirectory(mav5Directory, mode: 0o755)
        for (path, bytes) in assets {
            try system.put(bytes, at: path, mode: 0o644)
        }
        return assets.map { $0.0 }
    }
}
