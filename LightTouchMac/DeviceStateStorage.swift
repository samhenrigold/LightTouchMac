import Foundation
import Darwin
import CryptoKit

/// Disk operations shared by the controller and the device-free regression check.
enum DeviceStateStorage {
    /// An SSH disconnect or a stopped VM alone does not establish an unmount.
    @MainActor
    static func waitForShutdown(until deadline: Date, confirmed: () -> Bool,
                                stopped: () -> Bool) async -> Bool {
        while !Task.isCancelled {
            if confirmed() { return true }
            if stopped() || Date() >= deadline { return false }
            try? await Task.sleep(for: .milliseconds(200))
        }
        return false
    }

    /// Publish a complete private NOR copy beside the NAND pages. Keeping it
    /// inside the overlay also includes it in erase and snapshot freshness.
    static func writableNOR(base: URL, overlay: URL) throws -> URL {
        let fm = FileManager.default
        let destination = overlay.appendingPathComponent("nor.bin")
        try fm.createDirectory(at: overlay, withIntermediateDirectories: true)
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
              (attributes[.size] as? NSNumber)?.intValue == 1_048_576 else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return destination
    }

    struct SnapshotIdentity: Codable, Equatable {
        let emulatorBuild: String
        let nand: String
    }

    private struct SnapshotMetadata: Codable {
        let version: Int
        let identity: SnapshotIdentity
        let fileNumber: UInt64
        let size: UInt64
    }

    /// Packed images use their content manifest. Development images also record
    /// every page's identity/mtime so rebaking a directory invalidates old RAM.
    static func developmentImageIdentity(at root: URL, key: String) throws -> String {
        let fm = FileManager.default
        var failure: Error?
        guard let files = fm.enumerator(at: root, includingPropertiesForKeys: nil,
                                       errorHandler: { _, error in failure = error; return false }) else {
            throw CocoaError(.fileReadUnknown)
        }
        var records = [key]
        for case let url as URL in files {
            let attributes = try fm.attributesOfItem(atPath: url.path)
            guard let date = attributes[.modificationDate] as? Date,
                  let inode = attributes[.systemFileNumber] as? NSNumber,
                  let size = attributes[.size] as? NSNumber else {
                throw CocoaError(.fileReadCorruptFile)
            }
            records.append("\(url.path.dropFirst(root.path.count))\t\(inode)\t\(size)\t\(date.timeIntervalSince1970)")
        }
        if let failure { throw failure }
        guard records.count > 1 else { throw CocoaError(.fileReadCorruptFile) }
        return SHA256.hash(data: Data(records.sorted().joined(separator: "\n").utf8))
            .map { String(format: "%02x", $0) }.joined()
    }

    private static func snapshotAttributes(_ url: URL) throws -> (number: UInt64, size: UInt64) {
        let values = try FileManager.default.attributesOfItem(atPath: url.path)
        guard let number = values[.systemFileNumber] as? NSNumber,
              let size = values[.size] as? NSNumber, size.uint64Value > 0 else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return (number.uint64Value, size.uint64Value)
    }

    static func promoteSnapshot(from temporary: URL, to saved: URL,
                                identity: SnapshotIdentity) throws {
        let attributes = try snapshotAttributes(temporary)
        let metadata = SnapshotMetadata(version: 1, identity: identity,
                                        fileNumber: attributes.number, size: attributes.size)
        let stagedMetadata = temporary.appendingPathExtension("meta")
        defer { try? FileManager.default.removeItem(at: stagedMetadata) }
        try JSONEncoder().encode(metadata).write(to: stagedMetadata, options: .atomic)
        // If a crash separates the renames, the metadata's inode/size will not
        // match the snapshot. Restore rejects the pair instead of guessing.
        guard rename(temporary.path, saved.path) == 0,
              rename(stagedMetadata.path, saved.appendingPathExtension("meta").path) == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
    }

    static func snapshotMatches(_ saved: URL, identity: SnapshotIdentity) -> Bool {
        guard let data = try? Data(contentsOf: saved.appendingPathExtension("meta")),
              let metadata = try? JSONDecoder().decode(SnapshotMetadata.self, from: data),
              let attributes = try? snapshotAttributes(saved) else { return false }
        return metadata.version == 1 && metadata.identity == identity
            && metadata.fileNumber == attributes.number && metadata.size == attributes.size
    }

    static func overlayIsNewer(_ overlay: URL, than snapshot: URL) -> Bool {
        let fm = FileManager.default
        do {
            func modified(_ url: URL) throws -> Date {
                guard let date = try fm.attributesOfItem(atPath: url.path)[.modificationDate] as? Date else {
                    throw CocoaError(.fileReadCorruptFile)
                }
                return date
            }
            let saved = try modified(snapshot)
            if try modified(overlay) > saved { return true }
            // FMSS atomically renames each page into its cs directory, updating
            // that directory's mtime even when replacing an existing page.
            for child in try fm.contentsOfDirectory(at: overlay, includingPropertiesForKeys: nil) {
                if try modified(child) > saved { return true }
            }
            return false
        } catch {
            // Missing/unreadable metadata cannot establish a coherent pair.
            return true
        }
    }

    struct PackedImage: Codable, Equatable {
        let key: String
        let directory: String
    }

    /// Keep an existing device on its original base until an explicit reset.
    /// The active pointer is independent of the app's installation path.
    static func packedImage(state: URL, nand: String, legacyKey: String,
                            manifest: URL) throws -> (image: PackedImage, retained: Bool) {
        let fm = FileManager.default
        let digest = try String(contentsOf: manifest, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard digest.count == 64, digest.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        let latest = PackedImage(key: "\(nand)-\(digest)", directory: "device/\(nand)-\(digest)")
        let pointer = state.appendingPathComponent("device/active-\(nand).json")
        var active: PackedImage
        if fm.fileExists(atPath: pointer.path) {
            active = try JSONDecoder().decode(PackedImage.self, from: Data(contentsOf: pointer))
        } else if fm.fileExists(atPath: state.appendingPathComponent("device/\(nand)").path) {
            let names = try fm.contentsOfDirectory(atPath: state.path)
            let candidates = names.filter { $0 == "nandrw-\(nand)" || $0.hasPrefix("nandrw-\(nand)-") }
            let key: String
            if candidates.contains("nandrw-\(legacyKey)") {
                key = legacyKey
            } else if candidates.count == 1 {
                key = String(candidates[0].dropFirst("nandrw-".count))
            } else if candidates.isEmpty {
                key = legacyKey
            } else {
                // Multiple historical roots cannot be attributed to this base.
                throw CocoaError(.fileReadCorruptFile)
            }
            active = PackedImage(key: key, directory: "device/\(nand)")
        } else {
            // Never silently abandon an overlay whose original base is missing.
            for key in [legacyKey, nand] where fm.fileExists(atPath: state.appendingPathComponent("nandrw-\(key)").path) {
                throw CocoaError(.fileNoSuchFile, userInfo: [NSLocalizedDescriptionKey:
                    "The existing device overlay has no extracted base image. Restore its device/\(nand) directory before launching."])
            }
            active = latest
        }
        let oldReset = state.appendingPathComponent(".reset-\(active.key)")
        let resetting = fm.fileExists(atPath: oldReset.path)
            || fm.fileExists(atPath: state.appendingPathComponent(".reset-\(nand)").path)
        if resetting {
            // Preserve old base + overlay as a pair. Reset applies to the new
            // image too if this build has previously been used on this Mac.
            try Data().write(to: state.appendingPathComponent(".reset-\(latest.key)"), options: .atomic)
            active = latest
        } else if active != latest, !fm.fileExists(atPath: state.appendingPathComponent(active.directory).path) {
            throw CocoaError(.fileNoSuchFile)
        }
        try fm.createDirectory(at: pointer.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(active).write(to: pointer, options: .atomic)
        if resetting, active == latest {
            for marker in Set([oldReset, state.appendingPathComponent(".reset-\(nand)")])
            where marker.lastPathComponent != ".reset-\(latest.key)" && fm.fileExists(atPath: marker.path) {
                try fm.removeItem(at: marker)
            }
        }
        return (active, active != latest)
    }
}
