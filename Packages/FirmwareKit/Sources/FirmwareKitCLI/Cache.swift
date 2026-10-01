import FirmwareKit
import Foundation

func cacheCommand(_ argv: [String]) -> Never {
    do {
        guard argv.count == 2 || argv.count == 4, argv[0] == "--root",
              argv.count == 2 || argv[2] == "--ipsw" else {
            throw FirmwareError(.internal, "cache-prune requires --root DIR [--ipsw SHA1]")
        }
        try FirmwareCache.prune(root: URL(fileURLWithPath: argv[1]), ipsw: argv.count == 4 ? argv[3] : nil)
        exit(0)
    } catch {
        FileHandle.standardError.write(Data("firmwarekit cache-prune: \(error)\n".utf8)); exit(1)
    }
}
