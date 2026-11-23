import Foundation
import HostRuntime

extension StoppedVolumeEdit {
    /// firmwarekit edit --action install-package: the iPhone OS 1.x package at `package` (Package1x: a .pxl, an
    /// Installer-era .zip or an .app) into a stopped 1.x device, in one stopped edit, its files made root's (mobile's
    /// in mobile's home). The package is read and refused before the device is opened. Returns the package's
    /// identifier and the apps it put in /Applications (device paths).
    nonisolated(nonsending) public static func installPackage1x(
        device: URL,
        package url: URL,
        policy: StorageRecordPolicy = .standalone,
        log: (String) -> Void = { _ in }
    ) async throws -> (identifier: String, apps: [String], files: [String]) {
        let package = try Package1x.load(url)
        try requireOneX(device: device, policy: policy)
        let session = try await begin(device: device, policy: policy, log: log)
        do {
            // edited as Preferences1x edits (the 1.x commit takes no amend), its owners set once it is unmounted
            let point = session.image.deletingLastPathComponent().appendingPathComponent("package-mount")
            let done = try await VolumeMount.withVolume(session.image, at: point) { try package.install($0) }
            done.lines.forEach(log)
            let volume = try HFSPlusVolume(session.image, writable: true)
            for (uid, paths) in done.owners.sorted(by: { $0.key < $1.key }) {
                _ = try volume.setOwner(paths, uid: uid, gid: uid)
            }
            try await commit(device: device, id: session.id, policy: policy, log: log)
            return (package.identifier, done.apps.map { "/" + $0 }, done.receipt.compactMap { $0["file"] as? String })
        } catch {
            try? await discard(device: device, id: session.id, policy: policy)
            throw error
        }
    }
}

extension StoppedVolumeEdit {
    /// firmwarekit edit --action uninstall-package: the package `identifier` out of a stopped 1.x device, as its
    /// receipt says (Package1x.uninstall), in one stopped edit.
    nonisolated(nonsending) public static func uninstallPackage1x(
        device: URL,
        identifier: String,
        policy: StorageRecordPolicy = .standalone,
        log: (String) -> Void = { _ in }
    ) async throws {
        try requireOneX(device: device, policy: policy)
        let session = try await begin(device: device, policy: policy, log: log)
        do {
            let point = session.image.deletingLastPathComponent().appendingPathComponent("package-mount")
            let done = try await VolumeMount.withVolume(session.image, at: point) {
                try Package1x.uninstall(identifier, $0)
            }
            done.lines.forEach(log)
            let volume = try HFSPlusVolume(session.image, writable: true)
            for (uid, paths) in done.owners.sorted(by: { $0.key < $1.key }) where !paths.isEmpty {
                _ = try volume.setOwner(paths, uid: uid, gid: uid)
            }
            try await commit(device: device, id: session.id, policy: policy, log: log)
        } catch {
            try? await discard(device: device, id: session.id, policy: policy)
            throw error
        }
    }

    /// firmwarekit edit --action list-packages: the packages installed in a stopped 1.x device, from their receipts
    /// (a stopped edit begun, read and discarded).
    nonisolated(nonsending) public static func installedPackages1x(
        device: URL,
        policy: StorageRecordPolicy = .standalone,
        log: (String) -> Void = { _ in }
    ) async throws -> [Package1x.Receipt] {
        try requireOneX(device: device, policy: policy)
        let session = try await begin(device: device, policy: policy, log: log)
        let point = session.image.deletingLastPathComponent().appendingPathComponent("package-mount")
        do {
            let installed = try await VolumeMount.withVolume(session.image, at: point) { Package1x.installed($0) }
            try await discard(device: device, id: session.id, policy: policy)
            return installed
        } catch {
            try? await discard(device: device, id: session.id, policy: policy)
            throw error
        }
    }

    private static func requireOneX(device: URL, policy: StorageRecordPolicy) throws {
        let owner = try OwnedStorageRecord.acquire(device: device, policy: policy)
        defer { withExtendedLifetime(owner) {} }
        let lock = try DeviceLock.read(base: VolumeExport.ResolvedSource(owner: owner).base.deletingLastPathComponent())
        guard lock?.productVersion?.hasPrefix("1.") == true else {
            throw FirmwareError(.unsupported, "packages install into iPhone OS 1.x devices only")
        }
    }
}
