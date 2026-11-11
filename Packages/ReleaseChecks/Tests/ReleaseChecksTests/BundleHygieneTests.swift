import BuildSupport
import Foundation
import Testing
import zlib

@testable import ReleaseChecks

/// Fixture bundles, each broken one way (was tests/release/test-bundle-hygiene.py's self-test).
struct BundleHygieneTests {
    let guest = BundleHygiene.guest

    struct Fixture {
        let root: URL, stripped: Data, debug: Data
        init(root: URL) throws {
            self.root = root
            let main = root.appendingPathComponent("main.c")
            try "int main(void) { return 0; }\n".write(to: main, atomically: true, encoding: .utf8)
            for args in [
                ["-g", "-c", main.path, "-o", root.appendingPathComponent("main.o").path],
                [root.appendingPathComponent("main.o").path, "-o", root.appendingPathComponent("debug").path]
            ] {
                try #require(try Shell.run(["cc"] + args).succeeded)
            }
            try FileManager.default.copyItem(
                at: root.appendingPathComponent("debug"),
                to: root.appendingPathComponent("stripped")
            )
            try #require(try Shell.run(["strip", "-S", "-x", root.appendingPathComponent("stripped").path]).succeeded)
            stripped = try Data(contentsOf: root.appendingPathComponent("stripped"))
            debug = try Data(contentsOf: root.appendingPathComponent("debug"))
        }

        func write(_ data: Data, _ path: String, in app: URL) throws {
            let url = app.appendingPathComponent(path)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try data.write(to: url)
        }

        func guest(_ members: [String: Data], into app: URL) throws {
            let staged = root.appendingPathComponent(app.lastPathComponent + "-guest")
            try? FileManager.default.removeItem(at: staged)
            for (name, data) in members { try write(data, name, in: staged) }
            let archive = app.appendingPathComponent(BundleHygiene.guest)
            try FileManager.default.createDirectory(
                at: archive.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try? FileManager.default.removeItem(at: archive)
            try #require(try Shell.run(["aa", "archive", "-d", staged.path, "-o", archive.path]).succeeded)
        }

        func bundle(_ label: String) throws -> URL {
            let app = root.appendingPathComponent("\(label).app")
            for (name, salt) in [
                ("Contents/MacOS/usbmuxd", "u"), ("Contents/Frameworks/libplist-2.0.4.dylib", "p"),
                ("Contents/MacOS/inetcat", "i"), ("Contents/MacOS/LightTouchServices", "w")
            ] {
                try write(stripped + Data(salt.utf8), name, in: app)  // distinct contents, still a Mach-O
            }
            try guest(["guest-tools/it_agent": stripped + Data("a".utf8)], into: app)
            for directory in [
                "usbmuxd", "libimobiledevice-glue", "libplist", "qemu", "inetcat", "libusbmuxd"
            ] {
                try write(Data("license text".utf8), "Contents/Resources/licenses/\(directory)/COPYING", in: app)
                try write(
                    Data("\(directory): https://example.invalid/\(directory).tar.gz".utf8),
                    "Contents/Resources/licenses/\(directory)/SOURCE.txt",
                    in: app
                )
            }
            try write(Data("MIT".utf8), "Contents/Resources/licenses/swift/Example/LICENSE.txt", in: app)
            try write(
                Data(
                    "Licenses: usbmuxd, libimobiledevice-glue, libplist, QEMU, inetcat, libusbmuxd"
                        .utf8
                ),
                "Contents/Resources/Help.txt",
                in: app
            )
            return app
        }

        /// A packed device (firmwarekit pack-base): index.json, files/, one NAND image chunk holding `extra`.
        func packed(_ app: URL, seed: String, extra: Data = Data()) throws {
            let root = "Contents/Resources/Device/n72ap-7E18.itbase"
            let files: [(String, Data)] = [
                ("device.lock.json", try JSONSerialization.data(withJSONObject: ["identity": ["seed": seed]])),
                ("identity.json", try JSONSerialization.data(withJSONObject: ["seed": seed]))
            ]
            for (name, data) in files { try write(data, "\(root)/files/\(name)", in: app) }
            let chunk = Data(repeating: UInt8(ascii: "p"), count: 5000) + extra
            try write(deflate(chunk), "\(root)/nand/cs0/000000.z", in: app)
            let index: [String: Any] = [
                "format": 2, "chunkBytes": 1 << 20,
                "files": files.map { ["name": $0.0, "size": $0.1.count, "mode": 0o444, "sha256": ""] },
                "images": [["name": "nand/cs0.pages", "size": chunk.count, "mode": 0o444, "chunks": ["000000": ""]]]
            ]
            try write(try JSONSerialization.data(withJSONObject: index), "\(root)/index.json", in: app)
        }

        func deflate(_ data: Data) -> Data {
            var size = compressBound(uLong(data.count))
            var out = [UInt8](repeating: 0, count: Int(size))
            data.withUnsafeBytes {
                _ = compress(&out, &size, $0.bindMemory(to: Bytef.self).baseAddress, uLong(data.count))
            }
            return Data(out.prefix(Int(size)))
        }
    }

    func problems(_ app: URL) throws -> [String] {
        try BundleHygiene.problems(app: app, packages: ["example"], localMarkers: ["/Users/someone"])
    }

    func expect(_ app: URL, _ text: String, sourceLocation: SourceLocation = #_sourceLocation) throws {
        let found = try problems(app)
        #expect(
            found.contains { $0.contains(text) },
            "\(app.lastPathComponent): expected “\(text)”, got \(found)",
            sourceLocation: sourceLocation
        )
    }

    /// Every build copies the guest tools (guest.aar), not only Archive: without them a Debug build couldn't prepare
    /// any device ("guest helper it_agent missing from …/Resources/guest-tools").
    /// ReleaseAppStaticTests.noBinaryNamesADebugOverride's scan: a binary naming an override is reported with it.
    @Test func theOverrideScanNamesABinaryThatHonorsOne() throws {
        try withScratch { root in
            let clean = root.appendingPathComponent("clean")
            let named = root.appendingPathComponent("named")
            try Data("LTM_SERVICE_UDID\0bundled only\0".utf8).write(to: clean)
            try Data("\0LTM_HOST_SERVICE_WORKER\0LTM_STATE_DIR\0".utf8).write(to: named)
            #expect(
                try ReleaseApp.overrideNames(in: [clean, named])
                    == ["named": ["LTM_HOST_SERVICE_WORKER", "LTM_STATE_DIR"]]
            )
        }
    }

    @Test func everyBuildCopiesTheGuestTools() throws {
        let project = try String(
            contentsOf: repository.appendingPathComponent("LightTouchMac.xcodeproj/project.pbxproj"),
            encoding: .utf8
        )
        // Xcode 27 names the file by its path (Resources/Guest) and leaves out a phase's flag when it's 0.
        let guestFile = try #require(
            project.firstMatch(of: /(\w+) \/\* (?:Resources\/)?Guest in [^*]+\*\/ = \{isa = PBXBuildFile/)
        )
        let phases = project.split(separator: "isa = PBXCopyFilesBuildPhase;").dropFirst()
            .map { $0.prefix { $0 != "}" } }
            .filter { $0.contains("files = (") && $0.split(separator: "files = (")[1].contains(guestFile.1) }
        #expect(phases.count == 1, "one phase copies Guest")
        #expect(
            phases.first?.contains("runOnlyForDeploymentPostprocessing = 1;") == false,
            "and not only when archiving"
        )
    }

    @Test func aCompleteBundlePassesAndEachBreakageIsNamed() throws {
        try withScratch { root in
            let f = try Fixture(root: root)
            let good = try f.bundle("good")
            #expect(try problems(good) == [])
            try f.packed(good, seed: BundleHygiene.placeholderSeed)
            #expect(try problems(good) == [])

            var broken = try f.bundle("no-license")
            try FileManager.default.removeItem(
                at: broken.appendingPathComponent("Contents/Resources/licenses/libimobiledevice-glue/COPYING")
            )
            try expect(broken, "no license text for libimobiledevice-glue")
            broken = try f.bundle("no-source")
            try FileManager.default.removeItem(
                at: broken.appendingPathComponent("Contents/Resources/licenses/usbmuxd/SOURCE.txt")
            )
            try expect(broken, "no SOURCE.txt naming the source of usbmuxd")
            broken = try f.bundle("local-path")
            try f.write(
                Data(#"{"path": "/Users/someone/Developer/qemu-ios"}"#.utf8),
                "Contents/Resources/build-inputs.json",
                in: broken
            )
            try expect(broken, "names a local path: Contents/Resources/build-inputs.json")
            broken = try f.bundle("packed-local-path")
            try f.packed(
                broken,
                seed: BundleHygiene.placeholderSeed,
                extra: Data("/Users/someone/Library/Caches/x.ipsw".utf8)
            )
            try expect(broken, "names a local path: Contents/Resources/Device/n72ap-7E18.itbase (packed)")
            broken = try f.bundle("packed-identity")
            try f.packed(broken, seed: "6A1F0E2B-0000-4000-8000-000000000000")
            try expect(broken, "carries a unit identity")
            broken = try f.bundle("unattributed")
            try f.write(f.stripped + Data("n".utf8), "Contents/MacOS/newtool", in: broken)
            try expect(broken, "unattributed Mach-O (add it to binaries with its licenses): Contents/MacOS/newtool")
            broken = try f.bundle("unstripped")
            try f.write(f.debug, "Contents/MacOS/usbmuxd", in: broken)
            try expect(broken, "not stripped (has a debug map): Contents/MacOS/usbmuxd")
            broken = try f.bundle("dsym")
            try FileManager.default.createDirectory(
                at: broken.appendingPathComponent("Contents/Resources/usbmuxd.dSYM/Contents"),
                withIntermediateDirectories: true
            )
            try expect(broken, "a dSYM ships")
            broken = try f.bundle("twice")
            try f.guest(
                ["guest-tools/it_agent": f.stripped + Data("a".utf8), "tools/it_agent": f.stripped + Data("a".utf8)],
                into: broken
            )
            try expect(broken, "ships twice: \(guest)/guest-tools/it_agent and \(guest)/tools/it_agent")
            broken = try f.bundle("loose")
            try f.write(f.stripped + Data("g".utf8), "Contents/Resources/guest-tools/it_pbd", in: broken)
            try expect(broken, "nested code under Resources (pack it into")
            broken = try f.bundle("packed-local")
            try f.guest(
                [
                    "guest-tools/it_agent": f.stripped + Data("a".utf8),
                    "guest-tools/it.plist": Data("/Users/someone/x".utf8)
                ],
                into: broken
            )
            try expect(broken, "names a local path: \(guest)/guest-tools/it.plist")
            broken = try f.bundle("swift")
            try FileManager.default.removeItem(
                at: broken.appendingPathComponent("Contents/Resources/licenses/swift/Example")
            )
            try expect(broken, "no license text for the Swift package example")
            broken = try f.bundle("help")
            try f.write(Data("Licenses: usbmuxd".utf8), "Contents/Resources/Help.txt", in: broken)
            try expect(broken, "Help.txt does not name libimobiledevice-glue")
        }
    }
}
