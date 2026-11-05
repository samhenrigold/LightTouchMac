import Crypto
import DeviceRuntime
import Foundation
import HostRuntime
import Testing

@testable import LightTouchCore

/// GuestPackage.compose over an itpack of three families (a stub, the 7E18 package, one for a host protocol the app
/// doesn't speak), the UI status for each report, the verdicts, and the device record and preparer lock decoding.
/// The offer text is qemu-ios contrib/guest-package/mkpkg.py's (`offer`, its reader it_boot), frozen below.
struct GuestPackageOfferTests {
    static let mbx = "/System/Library/Frameworks/OpenGLES.framework/MBXGLEngine.bundle/MBXGLEngine"
    typealias Entry = (name: String, data: Data)

    /// A package as mkpkg.assemble writes one: its manifest and files, each file's bytes its family and name repeated.
    static func package(
        _ family: String,
        builds: [String],
        board: String = "n72ap",
        serial: Int,
        stub: Bool = false,
        host: [String: [Int]] = ["guest-package": [1, 1], "gles": [1, 1]]
    ) -> [Entry] {
        var files: [[String: Any]] = []
        var entries: [Entry] = []
        for (name, mode) in [
            ("bin/it_agent", 0o755), ("bin/itmedia", 0o755), ("jobs/com.qemu.it-agent.plist", 0o644),
            ("hooks/MBXGLEngine", 0o755), ("hooks/libappsync.dylib", 0o755)
        ] {
            let data = Data(String(repeating: family + name, count: 50).utf8)
            entries.append((family + "/" + name, data))
            files.append([
                "name": name, "mode": String(mode, radix: 8), "size": data.count,
                "sha256": SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            ])
        }
        let manifest: [String: Any] = [
            "format": 1, "serial": serial, "version": "1.\(serial).0", "family": family, "arch": "armv6", "stub": stub,
            "requires": ["boards": [board], "builds": builds, "link": "modern", "host": host],
            "provides": ["it_agent", "itmedia"], "files": files, "jobs": ["jobs/com.qemu.it-agent.plist"],
            "hooks": [
                ["file": "hooks/MBXGLEngine", "target": mbx, "respring": true],
                ["file": "hooks/libappsync.dylib", "target": "/usr/lib/libappsync.dylib", "respring": false]
            ]
        ]
        return [(family + "/manifest.json", try! JSONSerialization.data(withJSONObject: manifest))] + entries
    }

    /// "ITPACK01", a little-endian u32 index length, the JSON index, a zlib stream (header, raw deflate).
    static func itpack(_ url: URL, _ entries: [Entry]) throws {
        let index = try JSONSerialization.data(withJSONObject: [
            "format": 1, "entries": entries.map { ["name": $0.name, "size": $0.data.count] }
        ])
        let stream = try (entries.reduce(Data()) { $0 + $1.data } as NSData).compressed(using: .zlib) as Data
        var length = UInt32(index.count).littleEndian
        try (GuestPack.magic + Data(bytes: &length, count: 4) + index + Data([0x78, 0x9c]) + stream).write(to: url)
    }

    static func files(_ dir: URL) -> [String: Data] {
        var out: [String: Data] = [:]
        for rel in (try? FileManager.default.subpathsOfDirectory(atPath: dir.path)) ?? [] {
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: dir.appendingPathComponent(rel).path, isDirectory: &isDir),
                !isDir.boolValue
            {
                out[rel] = try? Data(contentsOf: dir.appendingPathComponent(rel))
            }
        }
        return out
    }

    /// mkpkg.py offer_text for the 7E18 package (serial 7) with verdicts good 5 and bad 6, and for a lock that kept only
    /// the GL hook, as mkpkg.py wrote them on 2026-10-07 (qemu-ios 097505cd30).
    static let offer7E18 = """
        ltpkg 1
        build 7E18
        serial 7 1.7.0
        verdict good 5
        verdict bad 6
        file 0 bin/it_agent 755 1000 7f179b008649bad3a94bd8ed4f93589470bfcefb54db01831df0644f4cf1fbad
        file 1 bin/itmedia 755 950 57a9add8869efb297f72c5db9c5d95b5f55e89397f0aae2d5b71f7452e4ed663
        job 2 jobs/com.qemu.it-agent.plist 644 1800 89f2b62421fd8166525d243c1c607c72849de4fba7cf03b32c848867f3a7168b
        hook 3 hooks/MBXGLEngine 755 1250 2ccd99a8b39c7566733226c4c71ce4d81ea194f2d8e0c56cc36e995c59ff53b1 /System/Library/Frameworks/OpenGLES.framework/MBXGLEngine.bundle/MBXGLEngine respring
        hook 4 hooks/libappsync.dylib 755 1500 1d6d8c4bbbd21833bade5c54372ab07983cdebff1ee675c900fddbf981958624 /usr/lib/libappsync.dylib

        """
    static let offer7E18GLOnly = """
        ltpkg 1
        build 7E18
        serial 7 1.7.0
        file 0 bin/it_agent 755 1000 7f179b008649bad3a94bd8ed4f93589470bfcefb54db01831df0644f4cf1fbad
        file 1 bin/itmedia 755 950 57a9add8869efb297f72c5db9c5d95b5f55e89397f0aae2d5b71f7452e4ed663
        job 2 jobs/com.qemu.it-agent.plist 644 1800 89f2b62421fd8166525d243c1c607c72849de4fba7cf03b32c848867f3a7168b
        hook 3 hooks/MBXGLEngine 755 1250 2ccd99a8b39c7566733226c4c71ce4d81ea194f2d8e0c56cc36e995c59ff53b1 /System/Library/Frameworks/OpenGLES.framework/MBXGLEngine.bundle/MBXGLEngine respring

        """

    @Test func composeStatusVerdictsAndRecords() throws {
        try withTemporaryDirectory { t in
            let entries =
                Self.package("n72-ios2", builds: ["5F138"], serial: 3, stub: true)
                + Self.package("n72-ios3", builds: ["7E18"], serial: 7)
                + Self.package(
                    "n72-ios9",
                    builds: ["9A1"],
                    serial: 7,
                    host: ["guest-package": [2, 3], "gles": [0, 0]]
                )
                + [
                    ("loader/it_boot", Data([0xce, 0xfa, 0xed, 0xfe])),
                    ("loader/com.qemu.it-boot.plist", Data("<plist/>".utf8))
                ]
            let pack = t.appendingPathComponent("armv6.itpack")
            try Self.itpack(pack, entries)
            #expect(try GuestPack.read(pack).count == entries.count)
            // The offer and its payloads at their package paths, with the record's verdicts (mkpkg.py offer).
            var record = DeviceInstance.Guest()
            record.lastGood = 5
            record.bad = [6]
            let dir = t.appendingPathComponent("work/guest-offer")
            let offer = try GuestPackage.compose(
                itpack: pack,
                board: "n72ap",
                build: "7E18",
                lock: nil,
                guest: record,
                into: dir
            )
            #expect(offer == GuestPackage.Offer(bundled: 7, version: "1.7.0", serial: 7, glHook: true))
            let payloads = Dictionary(
                uniqueKeysWithValues: entries.filter {
                    $0.name.hasPrefix("n72-ios3/") && !$0.name.hasSuffix("manifest.json")
                }
                .map { (String($0.name.dropFirst("n72-ios3/".count)), $0.data) }
            )
            #expect(
                Self.files(dir) == payloads.merging(["offer": Data(Self.offer7E18.utf8)]) { $1 },
                "the offer directory isn't mkpkg.py offer's"
            )
            // Recomposing replaces the directory and leaves no staging behind.
            _ = try GuestPackage.compose(itpack: pack, board: "n72ap", build: "7E18", lock: nil, guest: nil, into: dir)
            let text = String(decoding: try Data(contentsOf: dir.appendingPathComponent("offer")), as: UTF8.self)
            let left = try FileManager.default.contentsOfDirectory(atPath: dir.deletingLastPathComponent().path)
            #expect(!text.contains("verdict") && left == ["guest-offer"])
            // A lock that kept only the GL hook drops the other and its file, as the seed did.
            var lock = GuestPackage.LockRecord(seed: 1, gles: true, hooks: [Self.mbx])
            _ = try GuestPackage.compose(itpack: pack, board: "n72ap", build: "7E18", lock: lock, guest: nil, into: dir)
            let trimmed = String(decoding: try Data(contentsOf: dir.appendingPathComponent("offer")), as: UTF8.self)
            #expect(trimmed == Self.offer7E18GLOnly, "\(trimmed)")
            #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent("hooks/libappsync.dylib").path))
            // No shim installed (gles false): the GL hook goes, and the offer has none.
            lock = GuestPackage.LockRecord(seed: 1, gles: false, hooks: nil)
            let noGL = try #require(
                try GuestPackage.compose(itpack: pack, board: "n72ap", build: "7E18", lock: lock, guest: nil, into: dir)
            )
            #expect(
                !noGL.glHook
                    && !FileManager.default.fileExists(atPath: dir.appendingPathComponent("hooks/MBXGLEngine").path)
            )
            // Built-in tools: serial 0, no payloads, while the bundled serial is the one chosen; never augmented.
            record.builtIn = 7
            let builtIn = try #require(
                try GuestPackage.compose(
                    itpack: pack,
                    board: "n72ap",
                    build: "7E18",
                    lock: nil,
                    guest: record,
                    into: dir
                )
            )
            #expect(builtIn.serial == 0 && Self.files(dir).keys.sorted() == ["offer"])
            #expect(
                String(decoding: try Data(contentsOf: dir.appendingPathComponent("offer")), as: UTF8.self)
                    == "ltpkg 1\nbuild 7E18\nserial 0 1.7.0\nverdict good 5\nverdict bad 6\n"
            )
            var augmented = false
            let safe = try #require(
                try GuestPackage.compose(
                    itpack: pack,
                    board: "n72ap",
                    build: "7E18",
                    lock: nil,
                    guest: record,
                    into: dir,
                    augment: { _, _ in
                        augmented = true
                        return (1007, "developer")
                    }
                )
            )
            #expect(safe.serial == 0 && !augmented, "built-in safe mode must never augment the package")
            let developer = try #require(
                try GuestPackage.compose(
                    itpack: pack,
                    board: "n72ap",
                    build: "7E18",
                    lock: nil,
                    guest: nil,
                    into: dir,
                    augment: { staged, bundled in
                        #expect(
                            bundled == 7 && Self.files(staged).count > 1,
                            "augmentation receives the validated complete package"
                        )
                        augmented = true
                        return (1007, "developer")
                    }
                )
            )
            #expect(augmented && developer.serial == 1007 && developer.version == "developer" && developer.bundled == 7)
            record.builtIn = 6
            #expect(
                try GuestPackage.compose(
                    itpack: pack,
                    board: "n72ap",
                    build: "7E18",
                    lock: nil,
                    guest: record,
                    into: dir
                )?.serial == 7,
                "a newer bundled package ends the built-in choice"
            )
            // Nothing (and no directory) for a stub, another build, another board or an unspoken host protocol.
            for (board, build) in [("n72ap", "5F138"), ("n72ap", "8C148"), ("k48ap", "7E18"), ("n72ap", "9A1")] {
                #expect(
                    try GuestPackage.compose(itpack: pack, board: board, build: build, lock: nil, guest: nil, into: dir)
                        == nil,
                    "\(build)"
                )
                #expect(!FileManager.default.fileExists(atPath: dir.path))
            }
            #expect(throws: (any Error).self, "not an itpack") { try GuestPack.read(dir.deletingLastPathComponent()) }
            // An index size past the stream is refused, not an overflow trap.
            let huge = t.appendingPathComponent("huge.itpack")
            let index = try JSONSerialization.data(withJSONObject: [
                "format": 1, "entries": [["name": "a", "size": 1], ["name": "b", "size": Int.max]]
            ])
            var length = UInt32(index.count).littleEndian
            let stream = try (Data([0]) as NSData).compressed(using: .zlib) as Data
            try (GuestPack.magic + Data(bytes: &length, count: 4) + index + Data([0x78, 0x9c]) + stream).write(to: huge)
            #expect(throws: (any Error).self, "size past the stream") { try GuestPack.read(huge) }
            // A payload that doesn't match its manifest is never offered.
            let bent = entries.map {
                $0.name == "n72-ios3/bin/itmedia" ? ($0.name, $0.data.dropLast() + [($0.data.last! ^ 1)]) : $0
            }
            let corrupt = t.appendingPathComponent("corrupt.itpack")
            try Self.itpack(corrupt, bent)
            #expect(throws: (any Error).self) {
                try GuestPackage.compose(
                    itpack: corrupt,
                    board: "n72ap",
                    build: "7E18",
                    lock: nil,
                    guest: nil,
                    into: dir
                )
            }
            #expect(!FileManager.default.fileExists(atPath: dir.path))

            // The preparer's record (device.lock.json guest_package).
            let lockFile = t.appendingPathComponent("device.lock.json")
            func lockRecord(_ url: URL) -> GuestPackage.LockRecord? {
                GuestPackage.lockRecord((try? DeviceLock.read(url)) ?? nil)
            }
            try Data(
                #"{"guest_package": {"family": "n72-ios3", "seed": 1, "gles": false, "hooks": ["/usr/lib/libappsync.dylib"]}}"#
                    .utf8
            ).write(to: lockFile)
            #expect(
                lockRecord(lockFile)
                    == GuestPackage.LockRecord(seed: 1, gles: false, hooks: ["/usr/lib/libappsync.dylib"])
            )
            try Data(#"{"guest_package": {"seed": 1, "gli": "7E18"}}"#.utf8).write(to: lockFile, options: .atomic)
            #expect(lockRecord(lockFile)?.gles == true, "a lock from before gl-runtime: a gli id is a shim")
            #expect(lockRecord(t.appendingPathComponent("missing.json")) == nil)
        }
    }

    @Test func statusTexts() {
        let o = GuestPackage.Offer(bundled: 7, version: "1.7.0", serial: 7, glHook: true)
        typealias S = GuestPackage.Status
        #expect(GuestPackage.status(report: nil, offer: nil, record: nil, glesProtocol: 0) == S.unknown)
        #expect(
            GuestPackage.status(report: .init(serial: 7, result: 1), offer: o, record: nil, glesProtocol: 0)
                == S.current(serial: 7)
        )
        #expect(
            GuestPackage.status(report: .init(serial: 7, result: 0), offer: o, record: nil, glesProtocol: 0)
                == S.current(serial: 7)
        )
        #expect(
            GuestPackage.status(report: .init(serial: 5, result: -2), offer: o, record: nil, glesProtocol: 0)
                == S.outOfDate
        )
        #expect(
            GuestPackage.status(report: .init(serial: 7, result: 0), offer: o, record: nil, glesProtocol: 1)
                == S.current(serial: 7),
            "the name-keyed GL wire"
        )
        #expect(
            GuestPackage.status(report: .init(serial: 7, result: 0), offer: o, record: nil, glesProtocol: 3)
                == S.outOfDate,
            "GL wire out of range"
        )
        #expect(
            GuestPackage.status(report: .init(serial: 5, result: 3), offer: o, record: nil, glesProtocol: 0)
                == S.reverted(serial: 5, why: .revertedBad)
        )
        #expect(
            GuestPackage.status(report: .init(serial: 5, result: 5), offer: o, record: nil, glesProtocol: 0)
                == S.reverted(serial: 5, why: .refused)
        )
        #expect(
            GuestPackage.status(
                report: .init(serial: 1, result: 2),
                offer: GuestPackage.Offer(bundled: 7, version: "", serial: 0, glHook: false),
                record: nil,
                glesProtocol: 0
            ) == S.builtIn(serial: 1)
        )
        var restored = DeviceInstance.Guest()
        restored.active = 5
        #expect(
            GuestPackage.status(report: nil, offer: o, record: restored, glesProtocol: 0) == S.outOfDate,
            "a restored session on older tools"
        )
        restored.bad = [7]
        #expect(GuestPackage.status(report: nil, offer: o, record: restored, glesProtocol: 0) == S.unknown)
        #expect(
            S.outOfDate.text == "Out of date — restart to update"
                && S.legacy.text == "Won’t update — erase and prepare again to get updates"
        )
        #expect(S.current(serial: 3).text == "Up to date" && S.builtIn(serial: 1).text == "Built in")
        #expect(S.reverted(serial: 1, why: .revertedBad).text == "Using an earlier version — the update didn’t work")
        #expect(
            S.reverted(serial: 1, why: .revertedTries).text.hasSuffix("kept failing")
                && S.reverted(serial: 1, why: .refused).text.hasSuffix("was refused")
        )
        // The status line names the guest tools only when they need attention ("Running" otherwise).
        #expect(
            S.outOfDate.needsAttention && S.notResponding.needsAttention
                && S.reverted(serial: 1, why: .revertedBad).needsAttention
        )
        #expect(
            ![S.current(serial: 3), .builtIn(serial: 1), .legacy, .unknown, .notBooted, .recovery].contains {
                $0.needsAttention
            }
        )
        #expect(
            S.unknown.text == "Unknown" && S.notResponding.text == "Not responding"
                && S.recovery.text == "Unavailable in recovery mode"
                && S.notBooted.text == "Waiting for iOS"
        )
    }

    @Test func verdictsAndTheDeviceRecord() throws {
        typealias V = GuestPackage.Verdict
        let r7 = GuestPackageReport(serial: 7, result: 1)
        var seen = DeviceInstance.Guest()
        seen.seed = 1
        seen.lastGood = 5
        #expect(
            GuestPackage.verdict(
                report: r7,
                healthyFor: .seconds(10),
                elapsed: .seconds(40),
                record: seen,
                restored: false
            ) == V.good(7)
        )
        #expect(
            GuestPackage.verdict(
                report: r7,
                healthyFor: .seconds(9),
                elapsed: .seconds(40),
                record: seen,
                restored: false
            ) == nil
        )
        #expect(
            GuestPackage.verdict(
                report: nil,
                healthyFor: .seconds(30),
                elapsed: .seconds(60),
                record: seen,
                restored: false
            ) == V.legacy
        )
        #expect(
            GuestPackage.verdict(
                report: nil,
                healthyFor: .seconds(30),
                elapsed: .seconds(60),
                record: seen,
                restored: true
            ) == V.undecided
        )
        #expect(
            GuestPackage.verdict(report: r7, healthyFor: .zero, elapsed: .seconds(300), record: seen, restored: false)
                == V.bad(7)
        )
        #expect(
            GuestPackage.verdict(
                report: .init(serial: 5, result: 0),
                healthyFor: .zero,
                elapsed: .seconds(300),
                record: seen,
                restored: false
            ) == V.undecided,
            "the last good package is not judged bad"
        )
        #expect(
            GuestPackage.verdict(
                report: .init(serial: 1, result: 3),
                healthyFor: .zero,
                elapsed: .seconds(300),
                record: seen,
                restored: false
            ) == V.undecided,
            "the seed is the floor"
        )
        #expect(
            GuestPackage.verdict(report: nil, healthyFor: .zero, elapsed: .seconds(300), record: seen, restored: false)
                == V.undecided
        )
        // device.plist `guest`: missing keys decode; a record round-trips.
        let g = try JSONDecoder().decode(DeviceInstance.Guest.self, from: Data(#"{"active": 3}"#.utf8))
        #expect(g.active == 3 && g.bad == [] && g.seed == nil)
        let round = try JSONDecoder().decode(DeviceInstance.Guest.self, from: JSONEncoder().encode(seen))
        #expect(round == seen)
    }
}
