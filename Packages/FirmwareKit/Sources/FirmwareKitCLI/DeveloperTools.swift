import FirmwareKit
import Foundation

func developerOfferCommand(_ argv: [String]) -> Never {
    do {
        var flags: [String: String] = [:]
        var args = argv.makeIterator()
        while let name = args.next() {
            guard ["--offer", "--payload", "--state", "--instance", "--public-key", "--serial"].contains(name),
                  flags[name] == nil, let value = args.next() else { throw FirmwareError(.unsupported, "bad developer-offer argument: \(name)") }
            flags[name] = value
        }
        guard let offer = flags["--offer"], let payload = flags["--payload"], let state = flags["--state"],
              let id = flags["--instance"].flatMap(UUID.init(uuidString:)),
              let serial = flags["--serial"].flatMap(Int.init) else {
            throw FirmwareError(.unsupported, "developer-offer --offer DIR --payload DIR --state PRIVATE_DIR --instance UUID [--public-key FILE] --serial N")
        }
        let result = try DeveloperTools.augment(offer: URL(fileURLWithPath: offer), payload: URL(fileURLWithPath: payload),
            state: URL(fileURLWithPath: state), instance: id,
            authorizedPublicKey: try flags["--public-key"].map { try String(contentsOfFile: $0, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines) }, serial: serial)
        FileHandle.standardOutput.write(try JSONEncoder().encode(result) + Data("\n".utf8))
        exit(0)
    } catch {
        FileHandle.standardError.write(Data("developer-offer: \(error)\n".utf8)); exit(1)
    }
}
