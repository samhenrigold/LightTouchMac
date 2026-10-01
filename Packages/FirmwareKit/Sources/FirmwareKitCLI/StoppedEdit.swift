import FirmwareKit
import Foundation

@concurrent func stoppedEditCommand(_ argv: [String]) async -> Int32 {
    var flags: [String: String] = [:]
    var args = argv.makeIterator()
    while let flag = args.next() {
        guard ["--device", "--action", "--session", "--record-policy"].contains(flag), let value = args.next() else {
            FirmwareDiagnostics.write(Data("firmwarekit edit: bad argument \(flag)\n".utf8)); _ = await FirmwareDiagnostics.finish(); exit(64)
        }
        flags[flag] = value
    }
    do {
        guard let path = flags["--device"], let action = flags["--action"] else {
            throw FirmwareError(.internal, "edit requires --device DIR --action begin|mount|commit|discard|recover")
        }
        let device = URL(fileURLWithPath: (path as NSString).expandingTildeInPath).standardizedFileURL
        let policy: VolumeRecordPolicy
        switch flags["--record-policy"] ?? "standalone" {
        case "standalone": policy = .standalone
        case "managed": policy = try .managedDeviceDirectory(device)
        default: throw FirmwareError(.internal, "--record-policy must be standalone or managed")
        }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        func emit<T: Encodable>(_ value: T) throws { commandOutput.write(try encoder.encode(value) + Data("\n".utf8)) }
        let log = { (s: String) in FirmwareDiagnostics.write(Data("firmwarekit edit: \(s)\n".utf8)) }
        if action == "begin" { try emit(try await StoppedVolumeEdit.begin(device: device, policy: policy, log: log)); return 0 }
        guard let session = flags["--session"].flatMap(UUID.init(uuidString:)) else {
            throw FirmwareError(.internal, "edit requires its --session UUID")
        }
        switch action {
        case "mount": try emit(try await StoppedVolumeEdit.mount(device: device, id: session, policy: policy))
        case "commit": try await StoppedVolumeEdit.commit(device: device, id: session, policy: policy, log: log); try emit(["committed": session.uuidString])
        case "discard": try await StoppedVolumeEdit.discard(device: device, id: session, policy: policy); try emit(["discarded": session.uuidString])
        case "recover": try await StoppedVolumeEdit.recover(device: device, id: session, policy: policy); try emit(["recovered": session.uuidString])
        default: throw FirmwareError(.internal, "unknown edit action \(action)")
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
