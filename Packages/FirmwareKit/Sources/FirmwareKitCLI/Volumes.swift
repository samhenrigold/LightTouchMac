// firmwarekit mount | export | unmount (see main.swift).
import FirmwareKit
import Foundation

@concurrent func volumeCommand(_ command: String, _ argv: [String]) async -> Int32 {
    func line(_ o: [String: Any]) {
        let d = try! JSONSerialization.data(withJSONObject: o, options: [.sortedKeys, .withoutEscapingSlashes])
        commandOutput.write(d + Data("\n".utf8))
    }
    func fail(_ message: String) throws -> Never {
        throw FirmwareError(.internal, message)
    }
    do {
        var flags: [String: String] = [:]
        var it = argv.makeIterator()
        while let a = it.next() {
            guard ["--device", "--volume", "--out", "--record-policy"].contains(a), let v = it.next() else { try fail("bad argument \(a)") }
            flags[a] = v
        }
        let url = { (p: String) in URL(fileURLWithPath: (p as NSString).expandingTildeInPath).standardizedFileURL }
        if command == "unmount" {
            guard let out = flags["--out"] else { try fail("--out is required") }
            try await VolumeExport.unmount(out: url(out))
            line(["unmounted": url(out).path])
            return 0
        }
        guard let device = flags["--device"] else { try fail("--device is required") }
        let volumes: Set<String>? = switch flags["--volume"] ?? "all" {
        case "all": nil
        case "system", "data": [flags["--volume"]!]
        default: try fail("--volume must be system, data or all")
        }
        let out = flags["--out"].map(url) ?? FileManager.default.temporaryDirectory
            .appendingPathComponent("firmwarekit-\(command)-\(UUID().uuidString)")
        let policy: VolumeRecordPolicy
        switch flags["--record-policy"] ?? "standalone" {
        case "standalone": policy = .standalone
        case "managed": policy = try .managedDeviceDirectory(url(device))
        default: try fail("--record-policy must be standalone or managed")
        }
        let src = try VolumeExport.Source(device: url(device), policy: policy)
        let log = { (s: String) in FirmwareDiagnostics.write(Data("firmwarekit: \(s)\n".utf8)) }
        let vols = command == "mount" ? try await VolumeExport.mount(src, volumes: volumes, out: out, log: log)
            : try await VolumeExport.export(src, volumes: volumes, out: out, log: log)
        for v in vols {
            let o = try JSONSerialization.jsonObject(with: JSONEncoder().encode(v)) as! [String: Any]
            line(o.merging(["out": out.path]) { a, _ in a })
        }
        return 0
    } catch {
        if Task.isCancelled { return 143 }
        FirmwareDiagnostics.write(Data("firmwarekit: \(error)\n".utf8))
        line(["error": "\(error)"])
        return 1
    }
}
