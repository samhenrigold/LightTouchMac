// firmwarekit fit --root DIR --arch armv6|armv7 FILE...: FitCheck.loads for each guest Mach-O against the firmware
// whose system volume is mounted (read-only is enough) at DIR. One JSON line per file; exit 1 if any does not fit.
import FirmwareKit
import Foundation

func fitCommand(_ argv: [String]) -> Never {
    var root: String?, arch = "armv7", host: String?, files: [String] = []
    var it = argv.makeIterator()
    while let a = it.next() {
        switch a {
        case "--root": root = it.next()
        case "--arch": arch = it.next() ?? arch
        case "--host": host = it.next()
        default: files.append(a)
        }
    }
    guard let root else { FileHandle.standardError.write(Data("usage: firmwarekit fit --root DIR [--arch A] FILE...\n".utf8)); exit(64) }
    let fw = FitCheck.Firmware(root: URL(fileURLWithPath: root), arch: arch)
    var ok = true
    for f in files {
        let fit = FitCheck.loads((f as NSString).lastPathComponent, (try? Data(contentsOf: URL(fileURLWithPath: f))) ?? Data(), on: fw, host: host)
        ok = ok && fit.fits
        let d = try! JSONSerialization.data(withJSONObject: fit.object, options: [.sortedKeys, .withoutEscapingSlashes])
        FileHandle.standardOutput.write(d + Data("\n".utf8))
    }
    exit(ok ? 0 : 1)
}
