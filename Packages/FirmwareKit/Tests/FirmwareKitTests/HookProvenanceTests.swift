import Foundation
import Testing
@testable import FirmwareKit

struct HookProvenanceTests {
    @Test func originalAndAbsenceAreImmutable() async throws {
        try await Oracle.withTemp { dir in
            let target = "framework/Engine", at = dir.appendingPathComponent(target)
            try SystemEdits.mkdirs(at.deletingLastPathComponent())
            try SystemEdits.put(Data("original".utf8), at, mode: 0o751)
            let backup = try GuestPackage.preserveHook(volume: dir, target: target)
            #expect(backup == target + ".baked")
            try SystemEdits.put(Data("frontend".utf8), at, mode: 0o755)
            #expect(try GuestPackage.preserveHook(volume: dir, target: target) == backup)
            #expect(try Data(contentsOf: dir.appendingPathComponent(backup)) == Data("original".utf8))
            #expect(try SystemEdits.permissions(dir.appendingPathComponent(backup)) == 0o751)

            let missing = "framework/Missing"
            let marker = try GuestPackage.preserveHook(volume: dir, target: missing)
            #expect(marker == missing + ".baked-absent")
            try SystemEdits.put(Data("override".utf8), dir.appendingPathComponent(missing), mode: 0o755)
            #expect(try GuestPackage.preserveHook(volume: dir, target: missing) == marker)
            #expect(try Data(contentsOf: dir.appendingPathComponent(marker)).isEmpty)
            #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent(missing + ".baked").path) == false)
            try SystemEdits.put(Data("conflict".utf8), dir.appendingPathComponent(missing + ".baked"), mode: 0o755)
            #expect(throws: (any Error).self) { try GuestPackage.preserveHook(volume: dir, target: missing) }
            #expect(try Data(contentsOf: dir.appendingPathComponent(missing)) == Data("override".utf8))
        }
    }

    @Test(.serialized, .enabled(if: FixtureRequirements.corpusEnabled, "Set FK_TEST_CORPUS=1"),
          arguments: ["n72ap-5F138", "n72ap-7A341", "n72ap-7E18", "n72ap-8C148", "k48ap-7B500"])
    func installerThenSeedPreservesStock(_ id: String) async throws {
        let helpers = Oracle.guestPackages, arch = FitFixture.arch(id)
        let pack = helpers.appendingPathComponent(arch + ".itpack")
        guard Oracle.exists(pack), Oracle.exists(helpers.appendingPathComponent(SystemEdits.Helpers.openGLES)) else {
            try FixtureRequirements.missing("actual guest export/pack for \(id)")
        }
        try await Oracle.withTemp { dir in
            let files = ["usr/lib/dyld", FitCheck.openGLES, FitCheck.quartzCore, FitCheck.coreImage, FitCheck.ioSurface,
                         FitCheck.ioMobileFramebuffer, FitCheck.sgxEngine,
                         "System/Library/Frameworks/CoreFoundation.framework/CoreFoundation",
                         "System/Library/Frameworks/Foundation.framework/Foundation", "usr/lib/libobjc.A.dylib"] + FitCheck.coreSurfaces
            guard let stock = try await FitFixture.volume(id, FitFixture.stock(id) + files, in: dir) else {
                try FixtureRequirements.missing("stock firmware \(id)")
            }
            let target = FitCheck.openGLES, original = stock.appendingPathComponent(target)
            let present = FileManager.default.fileExists(atPath: original.path)
            let originalBytes = present ? try Data(contentsOf: original) : nil
            let originalMode = present ? try SystemEdits.permissions(original) : nil
            let py = dir.appendingPathComponent("python")
            try FileManager.default.copyItem(at: stock, to: py)
            let fw = FitCheck.Firmware(root: stock, arch: arch)
            // A rejected frontend never changes either the true file or absence.
            let invalid = dir.appendingPathComponent("invalid-helpers")
            try SystemEdits.mkdirs(invalid)
            try SystemEdits.put(Data("invalid Mach-O".utf8), invalid.appendingPathComponent(SystemEdits.Helpers.openGLES))
            #expect(throws: (any Error).self) {
                try SystemEdits.installCAOGL(stock, helpers: invalid, arch: arch, fw: fw, fit: FitCheck.Log(), log: { _ in })
            }
            #expect(FileManager.default.fileExists(atPath: original.path) == present)
            if let originalBytes { #expect(try Data(contentsOf: original) == originalBytes) }
            #expect(FileManager.default.fileExists(atPath: stock.appendingPathComponent(target + ".baked").path) == false)
            #expect(FileManager.default.fileExists(atPath: stock.appendingPathComponent(target + ".baked-absent").path) == false)
            let installed = try SystemEdits.installCAOGL(stock, helpers: helpers, arch: arch, fw: fw, fit: FitCheck.Log(), log: { _ in })
            let provenance = target + (present ? ".baked" : ".baked-absent")
            #expect(installed.owned.contains(provenance))
            let baseline = try Data(contentsOf: stock.appendingPathComponent(provenance))
            #expect(baseline == (originalBytes ?? Data()))
            if let originalMode { #expect(try SystemEdits.permissions(stock.appendingPathComponent(provenance)) == originalMode) }
            // Reentrancy keeps provenance even though the target is now our frontend.
            _ = try SystemEdits.installCAOGL(stock, helpers: helpers, arch: arch, fw: fw, fit: FitCheck.Log(), log: { _ in })
            let oldPack = dir.appendingPathComponent("old/" + arch + ".itpack")
            try SystemEdits.mkdirs(oldPack.deletingLastPathComponent())
            try K48Oracle.sh(["python3", "-c", """
                import sys
                sys.path.insert(0, sys.argv[1]); import mkpkg
                mkpkg.pack([(n,b) for n,b in mkpkg.read_pack(sys.argv[2]) if n != "loader/hook-provenance"], sys.argv[3])
                """, Oracle.qemuIOS.appendingPathComponent("contrib/guest-package").path, pack.path, oldPack.path], cwd: dir)
            if present {
                let oldVolume = dir.appendingPathComponent("old-present")
                try FileManager.default.copyItem(at: stock, to: oldVolume)
                _ = try GuestPackage.seed(volume: oldVolume, itpack: oldPack, gles: true)
                #expect(try Data(contentsOf: oldVolume.appendingPathComponent(provenance)) == baseline)
            } else if id != "n72ap-8C148" { // 4.x is a hookless stub; it does not consume absence.
                do {
                    _ = try GuestPackage.seed(volume: stock, itpack: oldPack, gles: true)
                    Issue.record("old pack accepted absence contract")
                } catch let error as FirmwareError {
                    #expect(error.code == .unsupported && error.message.contains("rebuild the guest exports"))
                }
                #expect(FileManager.default.fileExists(atPath: stock.appendingPathComponent(GuestPackage.root + "/state").path) == false)
            }
            let (_, seeded) = try GuestPackage.seed(volume: stock, itpack: pack, gles: true)
            #expect(try Data(contentsOf: stock.appendingPathComponent(provenance)) == baseline)
            #expect(FileManager.default.fileExists(atPath: stock.appendingPathComponent(target + (present ? ".baked-absent" : ".baked")).path) == false)

            // The maintained Python installer followed by mkpkg.seed must preserve
            // the same original representation, not a copy of the installed frontend.
            try K48Oracle.sh(["python3", "-c", """
                import sys
                sys.path.insert(0, sys.argv[1]); import ipad1_rootfs
                ipad1_rootfs.install_gles_frontend(sys.argv[2], sys.argv[3])
                ipad1_rootfs.install_gles_frontend(sys.argv[2], sys.argv[3])
                ipad1_rootfs.mkpkg.seed(sys.argv[2], sys.argv[4], True)
                """, Oracle.qemuIOS.appendingPathComponent("imgtools").path, py.path,
                helpers.appendingPathComponent(SystemEdits.Helpers.openGLES).path, pack.path], cwd: dir)
            #expect(try Data(contentsOf: py.appendingPathComponent(provenance)) == baseline)
            #expect(try SystemEdits.permissions(py.appendingPathComponent(provenance)) == SystemEdits.permissions(stock.appendingPathComponent(provenance)))
            #expect(try Data(contentsOf: py.appendingPathComponent(GuestPackage.root + "/state")) == Data(contentsOf: stock.appendingPathComponent(GuestPackage.root + "/state")))
            print("\(id): install→seed; original \(present ? "file/stub" : "absent/cache"), provenance \(provenance), seed \(seeded.seed)")
        }
    }
}
