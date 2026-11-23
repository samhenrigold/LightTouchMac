import Foundation
import HostRuntime

extension StoppedVolumeEdit {
    /// The jailbreak option on an existing, stopped device (firmwarekit edit --action jailbreak): the edits a
    /// jailbroken preparation makes (SystemEdits.installJailbreak from `bootstrap`, Cydia.bootstrap's; on 1.x
    /// installJailbreak1x with the Installer.app beside `guestTools`, and no bootstrap fetched), in one stopped edit, so the device keeps its
    /// apps and data. The new generation's lock says `jailbroken` (DeviceLock.jailbroken), and on the K48 family its
    /// boot files carry the jailbroken boot-args (K48Board.jailbreakBootFiles).
    nonisolated(nonsending) public static func jailbreak(
        device: URL,
        bootstrap: @autoclosure () throws -> URL,
        guestTools: () throws -> URL? = { nil },
        policy: StorageRecordPolicy = .standalone,
        log: (String) -> Void = { _ in }
    ) async throws {
        let lock = try {
            let owner = try OwnedStorageRecord.acquire(device: device, policy: policy)
            defer { withExtendedLifetime(owner) {} }
            return try DeviceLock.read(base: VolumeExport.ResolvedSource(owner: owner).base.deletingLastPathComponent())
        }()
        guard let lock, let major = Int(lock.productVersion?.split(separator: ".").first ?? "") else {
            throw FirmwareError(.unsupported, "the jailbreak: no iPhone OS version in the device's lock")
        }
        guard !lock.jailbroken else { throw FirmwareError(.unsupported, "this device is jailbroken already") }
        if major < 2 {
            guard let tools = try guestTools() else { throw FirmwareError(.internal, "jailbreak: no guest tools") }
            return try await jailbreak1x(
                device: device,
                installer: SystemEdits.InstallerApp.bundled(guestTools: tools),
                policy: policy,
                log: log
            )
        }
        let bootstrap = try bootstrap()
        let session = try await begin(device: device, policy: policy, log: log)
        do {
            guard let point = try await mount(device: device, id: session.id, policy: policy).mountPoint else {
                throw FirmwareError(.internal, "jailbreak: the volume isn't mounted")
            }
            let jb = try SystemEdits.installJailbreak(
                MountedVolume(root: URL(fileURLWithPath: point)),
                bootstrap: bootstrap,
                typeinBySubstrate: lock.board == "n72ap"
            )
            log(jb.afc2)
            log(jb.cydia)
            var bootFile: String?
            try await commit(device: device, id: session.id, policy: policy, log: log) { system, base in
                let volume = try HFSPlusVolume(system, writable: true)
                for (path, mode) in jb.modes { try volume.setOwner([path], uid: 0, gid: 0, mode: mode) }
                // The N72 machine boots every device with what Substrate needs; the K48 family's boot-args say it.
                if lock.board != "n72ap" { bootFile = try K48Board.jailbreakBootFiles(base: base) }
                return ["jailbroken": true]
            }
            if let bootFile { log("\(bootFile): boot-args += \(K48Board.jailbreakBootArg)") }
        } catch {
            try? await discard(device: device, id: session.id, policy: policy)
            throw error
        }
    }

    /// 1.x (SystemEdits.installJailbreak1x): its files made root's, as the recipe owns them, and the lock's
    /// `jailbroken` through the 1.x commit's amend.
    nonisolated(nonsending) static func jailbreak1x(
        device: URL,
        installer: URL,
        policy: StorageRecordPolicy,
        log: (String) -> Void
    ) async throws {
        let session = try await begin(device: device, policy: policy, log: log)
        do {
            // the session image edited in place, as Preferences1x edits it
            let point = session.image.deletingLastPathComponent().appendingPathComponent("jailbreak-mount")
            let jb = try await VolumeMount.withVolume(session.image, at: point) { v in
                try SystemEdits.installJailbreak1x(v, installer: installer)
            }
            jb.lines.forEach(log)
            try await commit(device: device, id: session.id, policy: policy, log: log) { system, _ in
                let volume = try HFSPlusVolume(system, writable: true)
                if !jb.root.isEmpty { _ = try volume.setOwner(jb.root, uid: 0, gid: 0) }
                return ["jailbroken": true]
            }
        } catch {
            try? await discard(device: device, id: session.id, policy: policy)
            throw error
        }
    }
}
