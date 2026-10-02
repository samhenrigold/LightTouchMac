import CryptoKit
import Darwin
import Foundation
import HostRuntime

/// Stopped-device envelope conversion. The existing storage transaction owns
/// exclusion, atomic publication and recovery; no live flash is rewritten.
public enum N72NORMigration {
    enum Checkpoint: Sendable { case planned, staged, ready, published }

    /// Experimental conversion for the stock-restored 5F138 envelope policy.
    /// Launch admission must remain gated until generated devices and the
    /// corrected hardware pass the corresponding guest regressions.
    @discardableResult
    nonisolated(nonsending) public static func migrate(device: URL, policy: StorageRecordPolicy = .standalone) async throws -> Bool {
        try await migrate(device: device, policy: policy, checkpoint: { _ in })
    }

    nonisolated(nonsending) static func migrate(device: URL, policy: StorageRecordPolicy = .standalone,
                                               checkpoint: @Sendable (Checkpoint) throws -> Void) async throws -> Bool {
        let owner = try OwnedStorageRecord.acquire(device: device, policy: policy)
        return try await migrate(owner: owner, checkpoint: checkpoint)
    }

    /// The common boot admission retains this same stopped authority throughout
    /// publication. Reacquiring would contend with the admission's own lease.
    nonisolated(nonsending) static func migrate(owner: StoppedRecordOwner,
                                               checkpoint: @Sendable (Checkpoint) throws -> Void = { _ in }) async throws -> Bool {
        let device = owner.device
        guard let paths = owner.paths, let recordBytes = owner.bytes else { throw N72NORFormat.Failure.malformedNOR }
        let record = try object(recordBytes)
        guard record["board"] as? String == "n72ap" else { throw N72NORFormat.Failure.unsupportedBuild }
        let lockURL = paths.base.appendingPathComponent("device.lock.json")
        let lockBytes = try Data(contentsOf: lockURL)
        var lock = try object(lockBytes)
        var derived = lock["derived"] as? [String: Any] ?? [:]
        if derived["nor_format"] as? String == N72NORFormat.canonical { return false }
        guard derived["nor_format"] == nil,
              let build = lock["build"] as? String, let wrapped = derived["wrap_shsh_types"] as? [String],
              let expectedTypes = derived["nor_images"] as? [String],
              let recordedSHA = ((lock["outputs"] as? [String: Any])?["nor"] as? [String: Any])?["sha256"] as? String,
              let working = paths.writableNOR else { throw N72NORFormat.Failure.unknownWrapping }
        let baseNOR = paths.base.appendingPathComponent("nor.bin")
        let baseBytes = try Data(contentsOf: baseNOR)
        guard StorageGeneration.hash(baseBytes) == recordedSHA else { throw N72NORFormat.Failure.changedFirmware }
        let workingBytes = FileManager.default.fileExists(atPath: working.path) ? try Data(contentsOf: working) : baseBytes
        let plan = try N72NORFormat.migrate(build: build, base: baseBytes, writable: workingBytes, legacyWrappedTypes: wrapped, expectedImageTypes: expectedTypes)
        try checkpoint(.planned)
        try Task.checkCancellation()
        let edit = try StorageGeneration.begin(owner: owner)
        return try await StorageGeneration.withOwner(edit, retaining: owner) { edit in
            do {
                try clone(paths.base, to: edit.base)
                // A clone preserves all NAND data and permissions. Only the
                // specific cloned files changed below become writable.
                let clonedNOR = edit.base.appendingPathComponent("nor.bin")
                let clonedLock = edit.base.appendingPathComponent("device.lock.json")
                for url in [edit.base, clonedNOR, clonedLock] {
                    guard chflags(url.path, 0) == 0, chmod(url.path, url == edit.base ? 0o700 : 0o600) == 0 else { throw POSIXError(.EIO) }
                }
                if FileManager.default.fileExists(atPath: paths.overlay.path) { try clone(paths.overlay, to: edit.overlay) }
                else { try FileManager.default.createDirectory(at: edit.overlay, withIntermediateDirectories: false) }
                let identity = edit.overlay.appendingPathComponent(".base-identity")
                try StorageGeneration.write(Data(edit.id.uuidString.utf8), to: identity)
                try StorageGeneration.write(plan.base, to: clonedNOR)
                try StorageGeneration.write(plan.writable, to: edit.root.appendingPathComponent("nor.bin"))
                derived["nor_format"] = N72NORFormat.canonical
                derived["wrap_shsh"] = true
                derived["wrap_shsh_types"] = expectedTypes
                lock["derived"] = derived
                var outputs = lock["outputs"] as? [String: Any] ?? [:]
                outputs["nor"] = ["path": "nor.bin", "sha256": StorageGeneration.hash(plan.base)]
                lock["outputs"] = outputs
                lock["maintenance"] = ["kind": "nor-envelope-migration", "original_lock_sha256": StorageGeneration.hash(lockBytes)]
                let updatedLock = try JSONSerialization.data(withJSONObject: lock, options: [.sortedKeys, .prettyPrinted])
                try StorageGeneration.write(updatedLock, to: clonedLock)
                try checkpoint(.staged)
                try Task.checkCancellation()
                try Preparer.readOnly(edit.base)
                let provenance: [String: Any] = ["lock": try edit.recordPath(clonedLock), "sha256": StorageGeneration.hash(updatedLock)]
                try await edit.publish(record: edit.candidateRecord(provenance: provenance)) { point in
                    switch point {
                    case .ready: try checkpoint(.ready)
                    case .recordPublished: try checkpoint(.published)
                    }
                }
                return true
            } catch {
                // A publication-ready intent must survive for exact recovery.
                // Before that point a failed candidate can be safely discarded.
                if let bytes = try? Data(contentsOf: device.appendingPathComponent("work/edit.json")),
                   let intent = try? JSONDecoder().decode(StorageGeneration.Intent.self, from: bytes), intent.phase == .editing {
                    // Cancellation must not strand an unpublished edit intent.
                    try await Task.detached { try await edit.discard() }.value
                }
                throw error
            }
        }
    }
    private static func object(_ data: Data) throws -> [String: Any] {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw N72NORFormat.Failure.malformedNOR }
        return object
    }
    private static func clone(_ source: URL, to destination: URL) throws {
        guard clonefile(source.path, destination.path, 0) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    }
}
