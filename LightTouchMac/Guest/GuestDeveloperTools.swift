import Foundation

/// Developer access uses the same package loader and health verdicts as other
/// guest additions. Safe mode deliberately composes the built-in offer instead.
nonisolated enum GuestDeveloperTools {
    static var state: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Light Touch/DeveloperSSH", isDirectory: true)
    }

    static func augmentation(instance: DeviceInstance, build: String) -> ((URL, Int64) throws -> (serial: Int64, version: String))? {
        let id = instance.id
        let enabled = state.appendingPathComponent(id.uuidString.lowercased()).appendingPathComponent("enabled")
        guard FileManager.default.fileExists(atPath: enabled.path) else { return nil }
        return { offer, bundled in
            guard ["7E18", "7B500"].contains(build), bundled > 0, bundled <= (Int64(Int32.max) - 1_000_001) / 100 else {
                throw DeviceToolsError.failed("Developer SSH is currently supported for 7E18 and 7B500 packages")
            }
            let payload = Bundle.main.resourceURL?.appendingPathComponent("developer-tools")
                ?? state.appendingPathComponent("payload")
            let resolved = FileManager.default.fileExists(atPath: payload.appendingPathComponent("developer-tools.json").path)
                ? payload : state.appendingPathComponent("payload")
            // Distinct, stable serials retain the loader's good/bad verdict and
            // rollback contract. Increment the revision when this recipe changes.
            let serial = Int(1_000_001 + bundled * 100)
            let result = try DeveloperTools.augment(offer: offer, payload: resolved, state: state,
                instance: id, serial: serial)
            return (Int64(result.serial), "developer-openssh-6.7p1")
        }
    }
}
