import FirmwareKit
import Foundation

@concurrent func bootAdmissionCommand(_ argv: [String]) async -> Int32 {
    var flags: [String: String] = [:]
    var allowRaw = false
    var args = argv.makeIterator()
    while let flag = args.next() {
        if flag == "--allow-raw" { allowRaw = true; continue }
        guard ["--device", "--record-policy"].contains(flag), let value = args.next(), flags[flag] == nil else {
            FirmwareDiagnostics.write(Data("firmwarekit boot-admit: bad argument \(flag)\n".utf8))
            return 64
        }
        flags[flag] = value
    }
    do {
        guard let path = flags["--device"] else { throw FirmwareError(.internal, "boot-admit requires --device DIR") }
        let device = URL(fileURLWithPath: (path as NSString).expandingTildeInPath).standardizedFileURL
        let policy: VolumeRecordPolicy
        switch flags["--record-policy"] ?? "standalone" {
        case "standalone": policy = .standalone
        case "managed": policy = try .managedDeviceDirectory(device)
        default: throw FirmwareError(.internal, "--record-policy must be standalone or managed")
        }
        let admitted = try await FirmwareBootAdmission.admit(device: device, policy: policy, allowRaw: allowRaw)
        commandOutput.write(try admitted.jsonData() + Data("\n".utf8))
        return 0
    } catch {
        if Task.isCancelled { return 143 }
        let message = String(describing: error)
        FirmwareDiagnostics.write(Data("firmwarekit boot-admit: \(message)\n".utf8))
        if let output = try? JSONSerialization.data(withJSONObject: ["error": message], options: [.sortedKeys]) {
            commandOutput.write(output + Data("\n".utf8))
        }
        return 1
    }
}
