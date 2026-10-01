import FirmwareKit
import Foundation

func stoppedEditCommand(_ argv: [String]) -> Never {
    var flags: [String: String] = [:]
    var args = argv.makeIterator()
    while let flag = args.next() {
        guard ["--device", "--action", "--session"].contains(flag), let value = args.next() else {
            FileHandle.standardError.write(Data("firmwarekit edit: bad argument \(flag)\n".utf8)); exit(64)
        }
        flags[flag] = value
    }
    do {
        guard let path = flags["--device"], let action = flags["--action"] else {
            throw FirmwareError(.internal, "edit requires --device DIR --action begin|mount|commit|discard|recover")
        }
        let device = URL(fileURLWithPath: (path as NSString).expandingTildeInPath).standardizedFileURL
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        func emit<T: Encodable>(_ value: T) throws { try FileHandle.standardOutput.write(contentsOf: encoder.encode(value) + Data("\n".utf8)) }
        let log = { (s: String) in FileHandle.standardError.write(Data("firmwarekit edit: \(s)\n".utf8)) }
        if action == "begin" { try emit(StoppedVolumeEdit.begin(device: device, log: log)); exit(0) }
        guard let session = flags["--session"].flatMap(UUID.init(uuidString:)) else {
            throw FirmwareError(.internal, "edit requires its --session UUID")
        }
        switch action {
        case "mount": try emit(StoppedVolumeEdit.mount(device: device, id: session))
        case "commit": try StoppedVolumeEdit.commit(device: device, id: session, log: log); try emit(["committed": session.uuidString])
        case "discard": try StoppedVolumeEdit.discard(device: device, id: session); try emit(["discarded": session.uuidString])
        case "recover": try StoppedVolumeEdit.recover(device: device, id: session); try emit(["recovered": session.uuidString])
        default: throw FirmwareError(.internal, "unknown edit action \(action)")
        }
        exit(0)
    } catch {
        let message = String(describing: error)
        FileHandle.standardError.write(Data("firmwarekit edit: \(message)\n".utf8))
        if let data = try? JSONSerialization.data(withJSONObject: ["error": message], options: [.sortedKeys]) {
            FileHandle.standardOutput.write(data + Data("\n".utf8))
        }
        exit(1)
    }
}
