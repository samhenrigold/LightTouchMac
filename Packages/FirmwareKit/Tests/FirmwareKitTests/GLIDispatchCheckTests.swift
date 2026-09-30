import Foundation
import Testing
@testable import FirmwareKit

struct GLIDispatchCheckTests {
    static let names = Fixtures.qemu.appendingPathComponent("include/hw/arm/guest-services")

    @Test func fieldsAndSanityLine() throws {
        #expect(GLIDispatch.fields(in: Data("xx{__GLIFunctionDispatchRec=\"foo\"^?\"\"\"bar\"^?}".utf8)) == ["foo", "bar"])
        #expect(GLIDispatch.fields(in: Data("no encode".utf8)) == nil)
        let dir = try Fixtures.tempDir("gles-names")
        defer { try? FileManager.default.removeItem(at: dir) }
        try Data("GLES_FN(glFoo,  foo,  0, 1, 0)\n".utf8).write(to: dir.appendingPathComponent(SystemEdits.Helpers.glesNames))
        let cache = Data("{__GLIFunctionDispatchRec=\"foo\"^?\"bar\"^?}".utf8)
        #expect(SystemEdits.glesSanity(cache, helpers: dir) == "GLI dispatch: 2 slots, 1 unknown to the name table (bar)")
    }

    /// Every firmware the catalog prepares with GL has its dispatch fields in the shipped name table (the MBX engine
    /// reads them at load; the front end's 5.x macro context does, and its fit check requires it).
    @Test(arguments: ["7B500", "8C148", "9B206", "7E18", "8C148-ipod"]) func firmwareFieldsAreNamed(_ build: String) throws {
        guard Fixtures.hasRootfs(build), Fixtures.exists(Self.names.appendingPathComponent(SystemEdits.Helpers.glesNames)) else { return }
        let dir = try Fixtures.tempDir("gli")
        defer { try? FileManager.default.removeItem(at: dir) }
        let cache = try DyldSharedCache(contentsOf: try Fixtures.cache(build, to: dir))
        let line = SystemEdits.glesSanity(cache.data, helpers: Self.names)
        print("\(build): \(line)")
        #expect(line.hasSuffix(" 0 unknown to the name table"))
    }

    /// A ca_ogl recipe on a firmware the GL front end does not fit (here: a front end with one of the stock OpenGLES's
    /// exports renamed away) fails the prepare instead of quietly producing a software-CoreAnimation device, and
    /// installs nothing.
    @Test func caOGLRefusesAMisfitFrontEnd() throws {
        let real = Oracle.guestPackages.appendingPathComponent(SystemEdits.Helpers.openGLES)
        guard Fixtures.hasRootfs("8C148"), Fixtures.exists(real) else { return }
        let dir = try Fixtures.tempDir("caogl")
        defer { try? FileManager.default.removeItem(at: dir) }
        let m = dir.appendingPathComponent("mnt"), helpers = dir.appendingPathComponent("helpers")
        let at = m.appendingPathComponent(SystemEdits.dyldCache("armv7"))
        try FileManager.default.createDirectory(at: at.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: helpers, withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: try Fixtures.cache("8C148", to: dir), to: at)
        var b = [UInt8](try Data(contentsOf: real))
        while let r = b.firstRange(of: Array("\0_glClear\0".utf8)) { b.replaceSubrange(r, with: Array("\0_glClxar\0".utf8)) }
        try Data(b).write(to: helpers.appendingPathComponent(SystemEdits.Helpers.openGLES))
        let log = FitCheck.Log()
        #expect {
            try SystemEdits.installCAOGL(m, helpers: helpers, arch: "armv7", fw: FitCheck.Firmware(root: m, arch: "armv7"), fit: log) { _ in }
        } throws: { e in
            (e as? FirmwareError)?.code == .unsupported && "\(e)".contains("ca_ogl") && "\(e)".contains("_glClear")
        }
        #expect(log.fits.first.map { !$0.fits } == true)
        #expect(!FileManager.default.fileExists(atPath: m.appendingPathComponent(FitCheck.openGLES).path))
    }
}
