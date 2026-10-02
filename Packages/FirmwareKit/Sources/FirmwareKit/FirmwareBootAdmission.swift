import Foundation
import HostRuntime
import FirmwareSchema

/// Common stopped storage admission used before any host launches a helper.
/// Format-specific preparation can borrow the existing stopped authority;
/// admission itself only validates storage ownership and current paths.
public nonisolated enum FirmwareBootAdmission {
    public struct Result: Sendable {
        public let changed: Bool
        public let record: Data?
        public let paths: StorageRecordPaths?

        public func jsonData() throws -> Data {
            let header = try JSONEncoder().encode(FirmwareWire.BootAdmission(changed: changed))
            guard var output = try JSONSerialization.jsonObject(with: header) as? [String: Any] else {
                throw StorageRecordPaths.Failure.invalidRecord
            }
            output["record"] = NSNull()
            output["paths"] = NSNull()
            if let record { output["record"] = try JSONSerialization.jsonObject(with: record) }
            if let paths {
                var selected = ["base": paths.base.path, "overlay": paths.overlay.path]
                if let nor = paths.writableNOR { selected["writableNOR"] = nor.path }
                if let snapshot = paths.snapshot { selected["snapshot"] = snapshot.path }
                output["paths"] = selected
            }
            return try JSONSerialization.data(withJSONObject: output, options: [.sortedKeys, .withoutEscapingSlashes])
        }
    }

    nonisolated(nonsending) public static func admit(device: URL, policy: StorageRecordPolicy = .standalone,
                                                    allowRaw: Bool = false) async throws -> Result {
        try await admit(device: device, policy: policy, allowRaw: allowRaw, prepare: { _ in false })
    }

    nonisolated(nonsending) static func admit(device: URL, policy: StorageRecordPolicy = .standalone,
                                             allowRaw: Bool = false,
                                             prepare: @Sendable (StoppedRecordOwner) async throws -> Bool) async throws -> Result {
        try Task.checkCancellation()
        let owner = try OwnedStorageRecord.acquire(device: device, policy: policy, allowRaw: allowRaw)
        guard let paths = owner.paths, owner.bytes != nil else {
            return Result(changed: false, record: nil, paths: nil)
        }
        // Keep the shared lease live through preparation, record reread and
        // refreshed ownership validation, including cancellation/error paths.
        defer { withExtendedLifetime(owner.lease) {} }
        let changed = try await prepare(owner)
        try Task.checkCancellation()
        // Keep the stopped authority across the reread and ownership validation.
        // Publication invalidates the original owner's path snapshot.
        let current = try Data(contentsOf: owner.device.appendingPathComponent("device.json"))
        let selected = try StorageRecordPaths(bytes: current, relativeRoot: paths.relativeRoot)
        try selected.validate(policy, device: owner.device)
        return Result(changed: changed, record: current, paths: selected)
    }
}
