import CryptoKit
import Darwin
import Foundation

/// Immutable, versioned decrypt results. Publication and inspection share a
/// cross-process lock; a failed producer never replaces a completed result.
enum DecryptionCache {
    // Bump when decrypt output conventions change, independently of app versions.
    static let format = 2
    struct Identity: Codable, Equatable, Sendable {
        let format: Int
        let tool, ipsw, board, productType: String
        let keys: [String: FirmwareEntry.Key]
        init(ipsw: String, entry: FirmwareEntry) {
            format = DecryptionCache.format; tool = FirmwareKit.version
            self.ipsw = ipsw; board = entry.board; productType = entry.productType; keys = entry.keys
        }
        var digest: String {
            get throws { SHA256.hash(data: try DecryptionCache.encode(self)).map { String(format: "%02x", $0) }.joined() }
        }
    }
    struct FileRecord: Codable {
        let bytes: Int64
        let sha256: String
    }
    struct Manifest: Codable {
        let identity: Identity
        let files: [String: FileRecord]
    }
    static func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(value)
    }

    static func resolve(root: URL, identity: Identity,
                        produce: (URL) throws -> [String], reused: () -> Void = {}) throws -> URL {
        let fm = FileManager.default
        let parent = root.appendingPathComponent("decrypted-v\(format)", isDirectory: true).appendingPathComponent(identity.ipsw, isDirectory: true)
        try fm.createDirectory(at: parent, withIntermediateDirectories: true)
        let key = try identity.digest
        let result = parent.appendingPathComponent(key, isDirectory: true)
        let lockFile = parent.appendingPathComponent(key + ".lock")
        let fd = open(lockFile.path, O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { close(fd) }
        while flock(fd, LOCK_EX) != 0 {
            if errno == EINTR { continue }
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        defer { flock(fd, LOCK_UN) }
        let marker = result.appendingPathComponent("manifest.json")
        if let data = try? Data(contentsOf: marker),
           let manifest = try? JSONDecoder().decode(Manifest.self, from: data),
           manifest.identity == identity, !manifest.files.isEmpty,
           manifest.files.allSatisfy({ name, record in
               guard validName(name), let actual = try? fm.attributesOfItem(atPath: result.appendingPathComponent(name).path)[.size] as? NSNumber else { return false }
               return actual.int64Value == record.bytes &&
                    (try? Preparer.digest(result.appendingPathComponent(name), SHA256())) == record.sha256
           }) {
            reused(); return result
        }
        let staged = parent.appendingPathComponent(".\(key)-\(UUID().uuidString).tmp", isDirectory: true)
        try fm.createDirectory(at: staged, withIntermediateDirectories: false)
        defer { try? fm.removeItem(at: staged) }
        var files: [String: FileRecord] = [:]
        for name in try produce(staged) {
            guard validName(name), let size = try fm.attributesOfItem(atPath: staged.appendingPathComponent(name).path)[.size] as? NSNumber else {
                throw FirmwareError(.internal, "decrypt cache: invalid output \(name)")
            }
            files[name] = FileRecord(bytes: size.int64Value, sha256: try Preparer.digest(staged.appendingPathComponent(name), SHA256()))
        }
        guard !files.isEmpty else { throw FirmwareError(.internal, "decrypt cache: no outputs") }
        try encode(Manifest(identity: identity, files: files)).write(to: staged.appendingPathComponent("manifest.json"), options: .atomic)
        // An invalid result is quarantined only after its replacement is ready.
        let old = parent.appendingPathComponent(".\(key)-\(UUID().uuidString).old", isDirectory: true)
        let hadOld = fm.fileExists(atPath: result.path)
        if hadOld { try fm.moveItem(at: result, to: old) }
        do { try fm.moveItem(at: staged, to: result) }
        catch {
            if hadOld { try? fm.moveItem(at: old, to: result) }
            throw error
        }
        if hadOld { try? fm.removeItem(at: old) }
        return result
    }

    static func validName(_ name: String) -> Bool {
        !name.isEmpty && name != "." && name != ".." && !name.contains("/") && name != "manifest.json"
    }
}
