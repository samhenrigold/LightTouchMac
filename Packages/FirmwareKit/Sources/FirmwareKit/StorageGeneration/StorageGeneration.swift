import Crypto
import Darwin
import Foundation
import HostRuntime

/// A stopped-device transaction. The record is the atomic generation pointer;
/// old flash/NOR and saved states remain intact until a validated candidate is
/// published. Persistent intent blocks helper boot even after this owner dies.
public actor StorageGeneration {
    public enum Phase: String, Codable, Sendable { case editing, ready, published }
    public struct Intent: Codable, Sendable {
        public let id: UUID
        public let originalRecord: String
        public var phase: Phase
        public var candidateRecord: String?
        public var storageManifest: String? = nil
    }
    nonisolated public let device: URL
    nonisolated public let id: UUID
    nonisolated public let root: URL
    nonisolated public var base: URL { root.appendingPathComponent("base") }
    nonisolated public var overlay: URL { root.appendingPathComponent("overlay") }
    nonisolated public var volumes: URL { root.appendingPathComponent("volumes") }
    private var lease: StorageLease?
    private nonisolated let paths: StorageRecordPaths?
    private let original: Data
    private var operationActive = false
    private var intent: Intent
    private var recordURL: URL { device.appendingPathComponent(DeviceRecord.name) }
    private var intentURL: URL { device.appendingPathComponent("work/edit.json") }
    private var candidateURL: URL { root.appendingPathComponent(DeviceRecord.name) }

    /// Existing app records only. Format-specific editing is a separate adapter.
    public static func begin(device: URL, policy: StorageRecordPolicy = .standalone) throws -> StorageGeneration {
        try StorageGeneration(owner: OwnedStorageRecord.acquire(device: device, policy: policy), resume: nil)
    }
    static func begin(owner: StoppedRecordOwner) throws -> StorageGeneration {
        try StorageGeneration(owner: owner, resume: nil)
    }
    public static func resume(device: URL, id: UUID, policy: StorageRecordPolicy = .standalone) throws
        -> StorageGeneration
    {
        let owner = try OwnedStorageRecord.acquire(device: device, policy: policy, resume: true)
        let intent = try JSONDecoder().decode(
            Intent.self,
            from: Data(contentsOf: owner.device.appendingPathComponent("work/edit.json"))
        )
        guard intent.id == id else { throw FirmwareError(.internal, "edit session does not match this device") }
        return try StorageGeneration(owner: owner, resume: intent)
    }
    private init(owner: StoppedRecordOwner, resume: Intent?) throws {
        let device = owner.device
        guard !owner.lease.isClosed else { throw FirmwareError(.internal, "storage transaction is closed") }
        guard let snapshot = owner.bytes,
            let object = try? DeviceRecord.object(snapshot),
            object["id"] is String, object["base"] is [String: Any], object["storage"] is [String: Any]
        else {
            throw FirmwareError(.unsupported, "storage transactions require a valid device record")
        }
        let intent: Intent
        if let resume {
            intent = resume
        } else {
            intent = Intent(id: UUID(), originalRecord: Self.hash(snapshot), phase: .editing)
        }
        let root = device.appendingPathComponent("generations/\(intent.id.uuidString)")
        guard root.resolvingSymlinksInPath().path.hasPrefix(device.path + "/generations/") else {
            throw FirmwareError(.internal, "invalid storage generation path")
        }
        if resume == nil {
            guard !FileManager.default.fileExists(atPath: root.path) else {
                throw FirmwareError(.internal, "storage generation already exists")
            }
        }
        // Keep failed admission out of a partially initialized class owner.
        lease = owner.lease
        paths = owner.paths
        self.device = device
        original = snapshot
        self.intent = intent
        id = intent.id
        self.root = root
        if resume == nil {
            try FileManager.default.createDirectory(
                at: root,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            try Self.write(snapshot, to: root.appendingPathComponent("original-\(DeviceRecord.name)"))
            try Self.write(JSONEncoder().encode(intent), to: device.appendingPathComponent("work/edit.json"))
            try Self.sync(root.deletingLastPathComponent())
            try Self.sync(device)
        }
    }

    /// Explicit actor ownership boundary: await before returning to another
    /// owner. Pending intent and the lease inode remain for exact recovery.
    public func close() throws {
        guard !operationActive else {
            throw FirmwareError(.internal, "storage transaction operation is already in progress")
        }
        lease?.close()
        lease = nil
    }

    nonisolated(nonsending) static func withOwner<T>(
        _ transaction: StorageGeneration,
        body: (StorageGeneration) async throws -> T
    ) async throws -> T {
        do {
            let value = try await body(transaction)
            try await transaction.close()
            return value
        } catch {
            do { try await transaction.close() } catch {
                FirmwareDiagnostics.write(Data("storage transaction release failed: \(error)\n".utf8))
            }
            throw error
        }
    }

    /// Finish a transaction borrowed by common boot admission without releasing
    /// its shared stopped authority before the published record is reread.
    private func returnAuthority(to owner: StoppedRecordOwner) throws {
        guard !operationActive, let lease, lease === owner.lease, !lease.isClosed,
            device == owner.device
        else {
            throw FirmwareError(.internal, "storage admission does not own this transaction")
        }
        self.lease = nil
    }

    nonisolated(nonsending) static func withOwner<T>(
        _ transaction: StorageGeneration,
        retaining owner: StoppedRecordOwner,
        body: (StorageGeneration) async throws -> T
    ) async throws -> T {
        do {
            let value = try await body(transaction)
            try await transaction.returnAuthority(to: owner)
            return value
        } catch {
            do { try await transaction.returnAuthority(to: owner) } catch {
                FirmwareDiagnostics.write(Data("storage transaction authority return failed: \(error)\n".utf8))
            }
            throw error
        }
    }

    private func requireOwner() throws {
        guard let lease, !lease.isClosed else { throw FirmwareError(.internal, "storage transaction is closed") }
    }

    /// Preserve unknown record fields. All mutable storage and snapshots move as
    /// one generation. A snapshot of the old flash cannot be selected afterward.
    /// `format`: the record format the candidate's storage needs (an image store's 2), when it changes.
    public func candidateRecord(provenance: sending [String: Any]? = nil, format: Int? = nil) throws -> Data {
        try requireOwner()
        guard !operationActive else {
            throw FirmwareError(.internal, "storage transaction operation is already in progress")
        }
        let data = try Data(contentsOf: root.appendingPathComponent("original-\(DeviceRecord.name)"))
        var record = try Self.object(data)
        guard var base = record["base"] as? [String: Any], var storage = record["storage"] as? [String: Any] else {
            throw FirmwareError(.unsupported, "storage transactions require a valid device record")
        }
        base["path"] = try recordPath(self.base)
        storage["overlay"] = try recordPath(overlay)
        storage["key"] = id.uuidString
        storage["snapshot"] = try recordPath(root.appendingPathComponent("snapshot"))
        if storage["writableNOR"] != nil {
            storage["writableNOR"] = try recordPath(root.appendingPathComponent("nor.bin"))
        }
        record["base"] = base
        record["storage"] = storage
        if let provenance { record["provenance"] = provenance }
        if let format { record["format"] = format }
        return try DeviceRecord.data(record)
    }

    /// Preserve the record's state-root-relative convention so a device library
    /// remains movable. Legacy absolute records keep their original convention.
    nonisolated public func recordPath(_ url: URL) throws -> String {
        guard let paths else { throw FirmwareError(.unsupported, "missing record paths") }
        return try paths.recordPath(url)
    }
    private func resolves(_ path: String?, to url: URL) -> Bool {
        guard let path, let paths else { return false }
        let candidate = StorageRecordPaths.resolve(path, relativeRoot: paths.relativeRoot)
        return candidate.standardizedFileURL.resolvingSymlinksInPath()
            == url.standardizedFileURL.resolvingSymlinksInPath()
    }

    public func publish(record: Data) async throws { try await publish(record: record, checkpoint: { _ in }) }
    enum Checkpoint: Sendable, Equatable { case ready, recordPublished }
    func publish(record: Data, checkpoint: @Sendable (Checkpoint) async throws -> Void) async throws {
        try beginOperation()
        defer { operationActive = false }
        try await publishCore(record: record, checkpoint: checkpoint)
    }
    private func beginOperation() throws {
        try requireOwner()
        guard !operationActive else {
            throw FirmwareError(.internal, "storage transaction operation is already in progress")
        }
        operationActive = true
    }
    private func publishCore(record: Data, checkpoint: @Sendable (Checkpoint) async throws -> Void) async throws {
        guard intent.phase == .editing || intent.phase == .ready else {
            throw FirmwareError(.internal, "edit generation has already been published")
        }
        guard Self.hash(try Data(contentsOf: recordURL)) == intent.originalRecord else {
            throw FirmwareError(.internal, "device record changed during editing; original generation retained")
        }
        try validate(record)
        try await ensureDetached()
        try requireOwner()
        try Task.checkCancellation()
        guard Self.hash(try Data(contentsOf: recordURL)) == intent.originalRecord else {
            throw FirmwareError(.internal, "device record changed while checking attachment state")
        }
        try Self.syncTree(base)
        try Self.syncTree(overlay)
        if FileManager.default.fileExists(atPath: root.appendingPathComponent("nor.bin").path) {
            try Self.sync(root.appendingPathComponent("nor.bin"))
        }
        if intent.phase == .ready {
            try verifyStorage()
        } else {
            let certificate = try storageCertificate()
            try Self.write(certificate, to: root.appendingPathComponent("storage-manifest.json"))
            intent.storageManifest = Self.hash(certificate)
        }
        try Self.write(record, to: candidateURL)
        intent.phase = .ready
        intent.candidateRecord = Self.hash(record)
        try saveIntent()
        try await checkpoint(.ready)
        try requireOwner()
        try Task.checkCancellation()
        guard Self.hash(try Data(contentsOf: recordURL)) == intent.originalRecord else {
            throw FirmwareError(.internal, "device record changed before publication; original generation retained")
        }
        try verifyStorage()
        try Self.write(record, to: recordURL)
        try await checkpoint(.recordPublished)
        try await finishPublished()
    }

    /// A crash may occur before or after the one record rename. Resume either
    /// finishes that exact validated publication or retains the old generation.
    public func recoverPublication() async throws {
        try beginOperation()
        defer { operationActive = false }
        try Task.checkCancellation()
        guard let expected = intent.candidateRecord, intent.phase != .editing else {
            throw FirmwareError(.internal, "edit is not ready to publish; resume editing or discard it")
        }
        let current = Self.hash(try Data(contentsOf: recordURL))
        if current == expected {
            try validate(Data(contentsOf: recordURL))
            try verifyStorage()
            try await finishPublished()
            return
        }
        guard current == intent.originalRecord else {
            throw FirmwareError(.internal, "device record is neither transaction generation; manual recovery required")
        }
        let record = try Data(contentsOf: candidateURL)
        guard Self.hash(record) == expected else { throw FirmwareError(.internal, "candidate record changed") }
        try await publishCore(record: record, checkpoint: { _ in })
    }

    public func discard() async throws {
        try beginOperation()
        defer { operationActive = false }
        try Task.checkCancellation()
        guard Self.hash(try Data(contentsOf: recordURL)) == intent.originalRecord else {
            throw FirmwareError(.internal, "published edits cannot be discarded; finish recovery instead")
        }
        try await ensureDetached()
        try requireOwner()
        try Task.checkCancellation()
        guard Self.hash(try Data(contentsOf: recordURL)) == intent.originalRecord else {
            throw FirmwareError(.internal, "device record changed while checking attachment state")
        }
        // Clear intent first, keeping the lease until return. Crash afterward
        // leaves an orphan candidate, never a half-applied current generation.
        try Self.writableDirectories(root)
        try FileManager.default.removeItem(at: intentURL)
        try Self.sync(intentURL.deletingLastPathComponent())
        try FileManager.default.removeItem(at: root)
    }

    private func validate(_ data: Data) throws {
        let record = try Self.object(data)
        let previous = try Self.object(Data(contentsOf: root.appendingPathComponent("original-\(DeviceRecord.name)")))
        guard
            ["id", "board", "firmware", "identity", "created"].allSatisfy({ key in
                NSDictionary(dictionary: ["value": record[key] ?? NSNull()]).isEqual(to: [
                    "value": previous[key] ?? NSNull()
                ])
            }),
            let storage = record["storage"] as? [String: Any], storage["key"] as? String == id.uuidString,
            resolves((record["base"] as? [String: Any])?["path"] as? String, to: base),
            resolves(storage["overlay"] as? String, to: overlay),
            resolves(storage["snapshot"] as? String, to: root.appendingPathComponent("snapshot"))
        else {
            throw FirmwareError(.internal, "candidate must preserve device identity and select its complete generation")
        }
        let previousNOR = (previous["storage"] as? [String: Any])?["writableNOR"] is String
        guard (storage["writableNOR"] is String) == previousNOR else {
            throw FirmwareError(.internal, "candidate must retain its NOR storage contract")
        }
        for directory in [base, overlay] {
            let values = try directory.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey])
            guard values.isDirectory == true, values.isSymbolicLink != true else {
                throw FirmwareError(.internal, "candidate storage must be owned directories")
            }
        }
        if let nor = storage["writableNOR"] as? String {
            guard resolves(nor, to: root.appendingPathComponent("nor.bin")),
                FileManager.default.fileExists(atPath: root.appendingPathComponent("nor.bin").path)
            else {
                throw FirmwareError(.internal, "candidate NOR must belong to its generation")
            }
        }
        guard FileManager.default.fileExists(atPath: base.path), FileManager.default.fileExists(atPath: overlay.path)
        else {
            throw FirmwareError(.internal, "candidate storage is incomplete")
        }
    }
    /// The ready record certifies actual flash/NOR bytes, not only filenames.
    /// Recovery refuses damaged/replaced candidates on either side of rename.
    private func storageCertificate() throws -> Data {
        var hashes: [String: String] = [:]
        func walk(_ directory: URL) throws {
            for child in try FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey]
            ) {
                let values = try child.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                guard values.isSymbolicLink != true else {
                    throw FirmwareError(.internal, "candidate contains a symlink")
                }
                if values.isDirectory == true {
                    try walk(child)
                } else {
                    hashes[String(child.path.dropFirst(root.path.count + 1))] = try Self.sparseDigest(child)
                }
            }
        }
        try walk(base)
        try walk(overlay)
        let nor = root.appendingPathComponent("nor.bin")
        if FileManager.default.fileExists(atPath: nor.path) { hashes["nor.bin"] = try Preparer.digest(nor, SHA256()) }
        return try JSONSerialization.data(withJSONObject: hashes, options: [.sortedKeys])
    }
    private func verifyStorage() throws {
        guard let expected = intent.storageManifest,
            Self.hash(try Data(contentsOf: root.appendingPathComponent("storage-manifest.json"))) == expected,
            Self.hash(try storageCertificate()) == expected
        else {
            throw FirmwareError(.internal, "candidate storage changed or is damaged; original generation retained")
        }
    }
    private func ensureDetached() async throws {
        guard
            try await DiskImage.checkedAttachedImages().allSatisfy({
                !URL(fileURLWithPath: $0.image).resolvingSymlinksInPath().path.hasPrefix(root.path + "/")
            })
        else { throw FirmwareError(.internal, "eject edit volumes before committing or discarding") }
    }
    private func finishPublished() async throws {
        try await ensureDetached()
        try requireOwner()
        try Task.checkCancellation()
        guard let expected = intent.candidateRecord, Self.hash(try Data(contentsOf: recordURL)) == expected else {
            throw FirmwareError(.internal, "published device record changed while checking attachment state")
        }
        try Self.sync(recordURL)
        try Self.sync(device)
        intent.phase = .published
        try saveIntent()
        try FileManager.default.removeItem(at: intentURL)
        try Self.sync(intentURL.deletingLastPathComponent())
    }
    private func saveIntent() throws { try Self.write(JSONEncoder().encode(intent), to: intentURL) }
    private static func object(_ data: Data) throws -> [String: Any] {
        guard let object = try? DeviceRecord.object(data) else {
            throw FirmwareError(.internal, "invalid device record")
        }
        return object
    }
    static func hash(_ data: Data) -> String { Preparer.sha256(data) }
    /// SHA-256 of a file's size and of each data extent's offset, length and bytes (SEEK_DATA/SEEK_HOLE), its holes
    /// unread: they read as zeros, so the extents decide every byte. A NAND chip file is gigabytes of holes (an erased
    /// page) around the megabytes the volumes use, and every publish certified the generation twice, reading all of it.
    /// A filesystem without holes (or without SEEK_DATA) is read from there to the end as one extent.
    static func sparseDigest(_ url: URL) throws -> String {
        let fd = open(url.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { Darwin.close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        var sha = SHA256()
        func add(_ value: off_t) { withUnsafeBytes(of: Int64(value).littleEndian) { sha.update(bufferPointer: $0) } }
        add(info.st_size)
        var buffer = [UInt8](repeating: 0, count: 1 << 22)
        var at: off_t = 0
        while at < info.st_size {
            var start = lseek(fd, at, SEEK_DATA)
            if start < 0 && errno == ENXIO { break }  // only a hole is left
            var end = start < 0 ? -1 : lseek(fd, start, SEEK_HOLE)
            if start < 0 || end <= start || end > info.st_size { (start, end) = (at, info.st_size) }
            add(start)
            add(end - start)
            var offset = start
            while offset < end {
                let count = buffer.withUnsafeMutableBytes {
                    pread(fd, $0.baseAddress, min($0.count, Int(end - offset)), offset)
                }
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else {
                    throw FirmwareError(.internal, "\(url.lastPathComponent) changed while it was read")
                }
                buffer.withUnsafeBytes { sha.update(bufferPointer: UnsafeRawBufferPointer(rebasing: $0.prefix(count))) }
                offset += off_t(count)
            }
            at = end
        }
        return sha.finalize().hexString
    }
    static func sync(_ url: URL) throws {
        let fd = open(url.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { Darwin.close(fd) }
        guard fsync(fd) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    }
    private static func writableDirectories(_ directory: URL) throws {
        let fm = FileManager.default
        let values = try directory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard values.isDirectory == true, values.isSymbolicLink != true else { return }
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        for child in try fm.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey]
        ) {
            try writableDirectories(child)
        }
    }
    private static func syncTree(_ directory: URL) throws {
        let fm = FileManager.default
        let entries = try fm.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey]
        )
        for item in entries {
            let values = try item.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard values.isSymbolicLink != true else {
                throw FirmwareError(.internal, "storage candidate contains a symlink")
            }
            if values.isDirectory == true { try syncTree(item) } else { try sync(item) }
        }
        try sync(directory)
    }
    static func write(_ data: Data, to destination: URL) throws {
        let temporary = destination.deletingLastPathComponent().appendingPathComponent(".\(UUID().uuidString).tmp")
        let fd = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer {
            Darwin.close(fd)
            unlink(temporary.path)
        }
        try data.withUnsafeBytes { bytes in
            guard let start = bytes.baseAddress else { return }  // empty: nothing to write
            var offset = 0
            while offset < bytes.count {
                let count = Darwin.write(fd, start.advanced(by: offset), bytes.count - offset)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
                offset += count
            }
        }
        guard fullSync(fd), rename(temporary.path, destination.path) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        try sync(destination.deletingLastPathComponent())
    }
    /// Every write here publishes (a record, an intent) by the rename after it. fsync only hands data to the
    /// drive; F_FULLFSYNC also empties the drive's cache, so this file and everything synced before it (the
    /// generation's pages) reach the medium before the rename can, and a power cut leaves the old generation or
    /// the new one whole. A volume without F_FULLFSYNC (some network shares) gets fsync.
    static func fullSync(_ fd: Int32) -> Bool { fcntl(fd, F_FULLFSYNC) == 0 || fsync(fd) == 0 }
}
