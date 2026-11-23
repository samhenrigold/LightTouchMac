// `single --package` on 1.x (FirmwareKit Package1x): each package installed into the stopped managed device by
// firmwarekit edit --action install-package before it boots, then what it installed listed through afc2
// (session-driver packages1x.swift).

import Foundation
import SessionKit

/// The packages into the stopped `device`, in order; the device paths the boot must list: each app, the receipt
/// and the package's first file. Dies when one is refused.
func installPackages1x(_ packages: [URL], device: URL, tools: Tools, work: URL) -> [String] {
    var expected: [String] = []
    for package in packages {
        let log = work.appendingPathComponent("install-\(package.lastPathComponent).log")
        let out = work.appendingPathComponent("install-\(package.lastPathComponent).json")
        let status = run(
            "/bin/sh",
            [
                "-c",
                #""$0" edit --device "$1" --action install-package --package "$2" --record-policy managed > "$3""#,
                tools.firmwarekit.path, device.path, package.path, out.path
            ],
            log: log
        )
        struct Installed: Decodable { let identifier: String, apps: [String], files: [String] }
        guard status == 0, let done = try? JSONDecoder().decode(Installed.self, from: Data(contentsOf: out)) else {
            die("install-package \(package.lastPathComponent) exited \(status) (\(log.path))", code: 1)
        }
        print("installed \(done.identifier): \(done.apps.joined(separator: ", ")) (\(done.files.count) items)")
        let first = done.files.first { !$0.hasSuffix("/") && !done.apps.contains($0) }
        expected += done.apps + ["/Library/PXL/DB/\(done.identifier).plist"] + (first.map { [$0] } ?? [])
    }
    return expected
}

/// afc2 lists every path `installPackages1x` named.
func packages1x(_ r: Report, _ events: Events, _ d: String) {
    for e in events.find("package1x", ["device": d]) {
        r.check(
            e.bool("found"),
            "\(d): afc2 lists \(e.string("path") ?? "?")" + (e.string("error").map { ": \($0)" } ?? "")
        )
    }
    r.check(events.any("package1x"), "\(d): the installed packages were looked for")
}
