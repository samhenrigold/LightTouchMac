import FirmwareKit
import FirmwareSchema
import Foundation

@concurrent func stoppedEditCommand(_ command: FirmwareCommand.Edit) async -> Int32 {
    do {
        let device = fileURL(command.device)
        let policy = try VolumeRecordPolicy(command.recordPolicy, device: device)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        func emit<T: Encodable>(_ value: T) throws { commandOutput.write(try encoder.encode(value) + Data("\n".utf8)) }
        let log = { (s: String) in FirmwareDiagnostics.write(Data("firmwarekit edit: \(s)\n".utf8)) }
        if command.action == .begin {
            try emit(try await StoppedVolumeEdit.begin(device: device, policy: policy, log: log))
            return 0
        }
        if command.action == .trustAnchor {  // begin, mount, the 1.x anchor row, commit; nothing when already trusted
            guard let cert = command.cert else {
                throw FirmwareError(.internal, "trust-anchor requires --cert DER")
            }
            let changed = try await TrustStore1x.trust(
                device: device,
                certificate: Data(contentsOf: URL(fileURLWithPath: cert)),
                policy: policy,
                log: log
            )
            try emit(["trusted": true, "changed": changed])
            return 0
        }
        if command.action == .preferences {  // begin, mount, the 1.x plists, commit; nothing when already there
            guard let prefs = command.prefs,
                let changes = try PropertyListSerialization.propertyList(
                    from: Data(contentsOf: URL(fileURLWithPath: prefs)),
                    format: nil
                ) as? [[String: Any]]
            else { throw FirmwareError(.internal, "preferences requires --prefs, a plist array") }
            let changed = try await Preferences1x.write(device: device, changes: changes, policy: policy, log: log)
            try emit(["changed": changed])
            return 0
        }
        if command.action == .jailbreak {  // Cydia's bootstrap beside the decrypt cache, as create keeps it (2.0 on)
            guard let cache = command.cache else { throw FirmwareError(.internal, "jailbreak requires --cache DIR") }
            try await StoppedVolumeEdit.jailbreak(
                device: device,
                bootstrap: try SystemEdits.Cydia.bootstrap(
                    in: fileURL(cache).deletingLastPathComponent().appendingPathComponent("Jailbreak"),
                    log: log
                ),
                guestTools: {  // 1.x's Installer.app, as create finds the guest tools
                    try command.guestTools.map(fileURL)
                        ?? Bundle.main.executableURL.flatMap {
                            try GuestArchive.unpacked(
                                resources: $0.resolvingSymlinksInPath().deletingLastPathComponent()
                                    .appendingPathComponent("../Resources").standardizedFileURL
                            )?.appendingPathComponent("guest-tools")
                        }
                },
                policy: policy,
                log: log
            )
            try emit(["jailbroken": true])
            return 0
        }
        if command.action == .installPackage {  // begin, mount, the package's files, commit
            guard let package = command.package else {
                throw FirmwareError(.internal, "install-package requires --package")
            }
            let done = try await StoppedVolumeEdit.installPackage1x(
                device: device,
                package: fileURL(package),
                policy: policy,
                log: log
            )
            struct Installed: Encodable { let identifier: String, apps: [String], files: [String] }
            try emit(Installed(identifier: done.identifier, apps: done.apps, files: done.files))
            return 0
        }
        if command.action == .uninstallPackage {  // begin, mount, its preremove and files, commit
            guard let identifier = command.identifier else {
                throw FirmwareError(.internal, "uninstall-package requires --identifier")
            }
            try await StoppedVolumeEdit.uninstallPackage1x(
                device: device, identifier: identifier, policy: policy, log: log)
            try emit(["uninstalled": identifier])
            return 0
        }
        if command.action == .listPackages {  // begin, mount, the receipts, discard
            try emit(try await StoppedVolumeEdit.installedPackages1x(device: device, policy: policy, log: log))
            return 0
        }
        guard let session = command.session.flatMap(UUID.init(uuidString:)) else {
            throw FirmwareError(.internal, "edit requires its --session UUID")
        }
        switch command.action {
        case .mount:
            try emit(
                try await StoppedVolumeEdit.mount(
                    device: device,
                    id: session,
                    policy: policy,
                    mountPoint: command.mountPoint.map(fileURL)
                )
            )
        case .commit:
            try await StoppedVolumeEdit.commit(device: device, id: session, policy: policy, log: log)
            try emit(["committed": session.uuidString])
        case .discard:
            try await StoppedVolumeEdit.discard(device: device, id: session, policy: policy)
            try emit(["discarded": session.uuidString])
        case .recover:
            try await StoppedVolumeEdit.recover(device: device, id: session, policy: policy)
            try emit(["recovered": session.uuidString])
        case .begin, .trustAnchor, .jailbreak, .preferences, .installPackage, .uninstallPackage, .listPackages: break
        }
        return 0
    } catch {
        if Task.isCancelled { return 143 }
        let message = String(describing: error)
        FirmwareDiagnostics.write(Data("firmwarekit edit: \(message)\n".utf8))
        if let data = try? JSONSerialization.data(withJSONObject: ["error": message], options: [.sortedKeys]) {
            commandOutput.write(data + Data("\n".utf8))
        }
        return 1
    }
}
