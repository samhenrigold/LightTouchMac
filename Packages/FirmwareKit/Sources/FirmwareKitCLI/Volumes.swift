// firmwarekit mount | export | unmount (see main.swift).
import FirmwareKit
import Foundation

func volumeCommand(_ command: String, _ argv: [String]) -> Never {
    func line(_ o: [String: Any]) {
        let d = try! JSONSerialization.data(withJSONObject: o, options: [.sortedKeys, .withoutEscapingSlashes])
        FileHandle.standardOutput.write(d + Data("\n".utf8))
    }
    func fail(_ message: String) -> Never {
        FileHandle.standardError.write(Data("firmwarekit: \(message)\n".utf8))
        line(["error": message])
        exit(1)
    }
    var flags: [String: String] = [:]
    var it = argv.makeIterator()
    while let a = it.next() {
        guard ["--device", "--volume", "--out"].contains(a), let v = it.next() else { fail("bad argument \(a)") }
        flags[a] = v
    }
    let url = { (p: String) in URL(fileURLWithPath: (p as NSString).expandingTildeInPath).standardizedFileURL }
    do {
        if command == "unmount" {
            guard let out = flags["--out"] else { fail("--out is required") }
            try VolumeExport.unmount(out: url(out))
            line(["unmounted": url(out).path])
            exit(0)
        }
        guard let device = flags["--device"] else { fail("--device is required") }
        let volumes: Set<String>? = switch flags["--volume"] ?? "all" {
        case "all": nil
        case "system", "data": [flags["--volume"]!]
        default: fail("--volume must be system, data or all")
        }
        let out = flags["--out"].map(url) ?? FileManager.default.temporaryDirectory
            .appendingPathComponent("firmwarekit-\(command)-\(UUID().uuidString)")
        let src = try VolumeExport.Source(device: url(device))
        let log = { (s: String) in FileHandle.standardError.write(Data("firmwarekit: \(s)\n".utf8)) }
        let vols = command == "mount" ? try VolumeExport.mount(src, volumes: volumes, out: out, log: log)
            : try VolumeExport.export(src, volumes: volumes, out: out, log: log)
        for v in vols {
            let o = try JSONSerialization.jsonObject(with: JSONEncoder().encode(v)) as! [String: Any]
            line(o.merging(["out": out.path]) { a, _ in a })
        }
        exit(0)
    } catch { fail("\(error)") }
}
