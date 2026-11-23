// A cached Home-screen snapshot's identity (`sessions … --from-snapshot`): which snapshot a check may resume, and
// whether the machine it would resume on is the one that saved it.
import CryptoKit
import Foundation

public enum SnapshotKey {
    /// The key: SHA-256 over every part, each length-prefixed so no two lists of parts run together. The parts are
    /// what must match for a resume to stand in for a cold boot: the base's lock, the dylib (its snapshot version with
    /// it), the helper, the guest package offered, the board and the steps that reached Home.
    public static func key(_ parts: [Data]) -> String {
        var hash = SHA256()
        for part in parts {
            hash.update(data: withUnsafeBytes(of: UInt64(part.count).littleEndian) { Data($0) })
            hash.update(data: part)
        }
        return hash.finalize().prefix(10).map { String(format: "%02x", $0) }.joined()
    }

    /// The QEMU command line as the machine sees it: the device's own folder (overlay, serial log, guest offer) as
    /// `$DEVICE`, a usbmuxd's random socket name as `ltm-mux-*`, and no `-incoming`. Equal for the boot that saved a
    /// snapshot and one that resumes it only when the machine options agree.
    public static func normalized(argv: [String], device: String) -> [String] {
        var out: [String] = []
        var skip = false
        for arg in argv {
            if skip {
                skip = false
                continue
            }
            if arg == "-incoming" {
                skip = true
                continue
            }
            out.append(
                arg.replacingOccurrences(of: device, with: "$DEVICE")
                    .replacingOccurrences(
                        of: #"ltm-mux-[0-9A-Fa-f]{8}"#, with: "ltm-mux-*", options: .regularExpression)
            )
        }
        return out
    }
}
