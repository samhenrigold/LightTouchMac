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

    /// Every firmware the catalog prepares with a shim has its dispatch fields in the shipped name table, and the
    /// gld plugin check still sees what 4.x's libGFXShared wants (a stand-in lacking the first name).
    @Test(arguments: ["7B500", "8C148", "9B206", "7E18", "8C148-ipod"]) func firmwareFieldsAreNamed(_ build: String) throws {
        guard Fixtures.hasRootfs(build), Fixtures.exists(Self.names.appendingPathComponent(SystemEdits.Helpers.glesNames)) else { return }
        let dir = try Fixtures.tempDir("gli")
        defer { try? FileManager.default.removeItem(at: dir) }
        let cache = try DyldSharedCache(contentsOf: try Fixtures.cache(build, to: dir))
        let line = SystemEdits.glesSanity(cache.data, helpers: Self.names)
        print("\(build): \(line)")
        #expect(line.hasSuffix(" 0 unknown to the name table"))
        let wanted = cache.image(GLIDispatch.libGFXShared).map { cache.cStrings(in: $0, section: "__cstring") }?
            .filter { $0.wholeMatch(of: /gld[A-Z]\w+/) != nil } ?? []
        let fake = dir.appendingPathComponent("fake-gld")
        try Data(wanted.dropFirst().map { "\0_" + $0 + "\0" }.joined().utf8).write(to: fake)
        let gld = GLIDispatch.gldProblem(cache, plugin: fake)
        let needed = build.hasPrefix("8C148") || build.hasPrefix("9")
        #expect(gld.needed == needed)
        if needed { #expect(gld.why == "gldshim lacks " + wanted[0]) }
        // 5.x's libGFXShared (gld interface 4.0.44) names 113 gld* strings, and the shipped plugin exports each
        if build.hasPrefix("9") { #expect(wanted.count == 113, "\(wanted.count): \(wanted)") }
        let plugin = Oracle.guestPackages.appendingPathComponent(SystemEdits.Helpers.gld)
        if needed, Fixtures.exists(plugin) { #expect(GLIDispatch.gldProblem(cache, plugin: plugin).why == nil) }
    }
}
