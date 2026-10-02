import Foundation
import HostRuntime

/// Dormant format-specific preparation. No production caller selects this
/// converter until the complete firmware/native migration corpus is qualified.
nonisolated enum N72BootAdmission {
    static let qualifiedN72Builds: Set<String> = []

    nonisolated(nonsending) static func admit(device: URL, policy: StorageRecordPolicy = .standalone,
                                             allowRaw: Bool = false, qualifiedBuilds: Set<String> = qualifiedN72Builds,
                                             afterMigration: @Sendable () throws -> Void = {}) async throws -> FirmwareBootAdmission.Result {
        try await FirmwareBootAdmission.admit(device: device, policy: policy, allowRaw: allowRaw, prepare: { owner in
            guard let record = owner.bytes, let paths = owner.paths,
                  let object = try JSONSerialization.jsonObject(with: record) as? [String: Any] else {
                throw StorageRecordPaths.Failure.invalidRecord
            }
            var changed = false
            if object["board"] as? String == "n72ap", !qualifiedBuilds.isEmpty {
                let lock = try Data(contentsOf: paths.base.appendingPathComponent("device.lock.json"))
                guard let metadata = try JSONSerialization.jsonObject(with: lock) as? [String: Any] else {
                    throw N72NORFormat.Failure.malformedNOR
                }
                if let build = metadata["build"] as? String, qualifiedBuilds.contains(build) {
                    changed = try await N72NORMigration.migrate(owner: owner)
                }
            }
            try afterMigration()
            return changed
        })
    }
}
