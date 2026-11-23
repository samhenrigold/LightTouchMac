import Foundation
import Testing

@testable import SessionKit

/// `--from-snapshot`'s cache: a key that changes with any part, and command lines compared without the device's
/// folder, the usbmuxd socket's name or the restore's -incoming.
struct SnapshotKeyTests {
    @Test func keyChangesWithEveryPart() {
        let parts = [Data("lock".utf8), Data("dylib".utf8), Data("steps".utf8)]
        let key = SnapshotKey.key(parts)
        #expect(key.count == 20)
        #expect(SnapshotKey.key(parts) == key)
        #expect(SnapshotKey.key([Data("lock".utf8), Data("dylib2".utf8), Data("steps".utf8)]) != key)
        // Parts don't run together: "ab"+"c" is not "a"+"bc".
        #expect(
            SnapshotKey.key([Data("ab".utf8), Data("c".utf8)]) != SnapshotKey.key([Data("a".utf8), Data("bc".utf8)]))
    }

    @Test func commandLinesCompareWithoutTheirFolders() {
        let saved = [
            "qemu", "-M", "iPod-Touch,nand-overlay=/w/home-snapshot/overlay,usb-tcp=/t/ltm-mux-1A2B3C4D-g.sock",
            "-serial", "file:/w/home-snapshot/serial.log"
        ]
        let resumed = [
            "qemu", "-M", "iPod-Touch,nand-overlay=/r/told/overlay,usb-tcp=/t/ltm-mux-99AA00FF-g.sock",
            "-serial", "file:/r/told/serial.log", "-incoming", "file:/c/state.bin"
        ]
        #expect(
            SnapshotKey.normalized(argv: saved, device: "/w/home-snapshot")
                == SnapshotKey.normalized(argv: resumed, device: "/r/told")
        )
        // Another machine option is another machine: refused.
        let other = resumed.map { $0.replacingOccurrences(of: "iPod-Touch,", with: "iPod-Touch,audio-hw=off,") }
        #expect(
            SnapshotKey.normalized(argv: saved, device: "/w/home-snapshot")
                != SnapshotKey.normalized(argv: other, device: "/r/told")
        )
    }
}
