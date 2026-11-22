import Foundation
import Testing

@testable import SessionKit

/// A passed run keeps its logs, events and summary; overlays, NAND pages, the guest archive and frames go.
struct WorkPruneTests {
    @Test func aPassedRunKeepsItsTextOnly() throws {
        let fm = FileManager.default
        let work = fm.temporaryDirectory.appendingPathComponent("prune-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: work) }
        let files: [String: Int] = [
            "summary.txt": 10, "xcodebuild.log": 10, "rotation/driver.jsonl": 10, "rotation/serial.log": 10,
            "rotation/scenario.json": 10, "create.err": 10,
            "rotation/overlay/bus0-ce0.pages": 10, "rotation/overlay/nor.bin": 10, "rotation/overlay/kboot.bin": 10,
            "rotation/home.png": 10, "guest/guest-tools/armv7.itpack": 10, "guest/guest-tools/it_agent": 10,
            "single/guest.wav": 10, "rotation/huge.log": WorkPrune.maxBytes + 1
        ]
        for (path, bytes) in files {
            let url = work.appendingPathComponent(path)
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(count: bytes).write(to: url)
        }
        try fm.createSymbolicLink(
            at: work.appendingPathComponent("rotation/link.log"),
            withDestinationURL: work.appendingPathComponent("summary.txt")
        )
        #expect(
            WorkPrune.kept(under: work) == [
                "create.err", "rotation/driver.jsonl", "rotation/scenario.json", "rotation/serial.log", "summary.txt",
                "xcodebuild.log"
            ]
        )
    }

    /// A failed run drops every nand directory (a base's, an overlay's) and nothing else; a link to one stays.
    @Test func aFailedRunDropsItsNANDCopies() throws {
        let fm = FileManager.default
        let work = fm.temporaryDirectory.appendingPathComponent("nand-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: work) }
        for path in [
            "n90/base/nand/bus0-ce0.pages", "n90/base/device.lock.json", "n90/run/keyboard/overlay/nand/bus1-ce3.pages",
            "n90/run/keyboard/home.png", "n90/run/driver.jsonl", "nandless/nand.log"
        ] {
            let url = work.appendingPathComponent(path)
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(count: 10).write(to: url)
        }
        try fm.createSymbolicLink(
            at: work.appendingPathComponent("nandless/nand"),
            withDestinationURL: work.appendingPathComponent("n90/base/nand")
        )
        let root = work.resolvingSymlinksInPath().path.count + 1  // the enumerator's /private/var for /var
        let copies = WorkPrune.nandCopies(under: work).map { String($0.resolvingSymlinksInPath().path.dropFirst(root)) }
        #expect(copies == ["n90/base/nand", "n90/run/keyboard/overlay/nand"])
    }
}
