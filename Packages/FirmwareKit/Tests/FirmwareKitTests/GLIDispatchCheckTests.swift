import Foundation
import Testing
@testable import FirmwareKit

struct GLIDispatchCheckTests {
    static let docs = Fixtures.qemu.appendingPathComponent("docs/ipad1")
    static let base = docs.appendingPathComponent("gli-dispatch-7B500.tsv")
    static let gles = Fixtures.qemu.appendingPathComponent("contrib/ipad1-gles")
    static let ipodDocs = Fixtures.qemu.appendingPathComponent("docs/ipod")
    static let wire = ipodDocs.appendingPathComponent("gli-dispatch-7E18.tsv")
    static var tsvs: [URL] {
        ((try? FileManager.default.contentsOfDirectory(at: docs, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.lastPathComponent.wholeMatch(of: /gli-dispatch-\w+\.tsv/) != nil }
    }

    @Test func verdictOnSyntheticTable() throws {
        let t = GLIDispatch.Table(tsv: "# h\nslot\tx\n0\ta\tb\tfoo\n1\ta\tb\tbar\n")
        #expect(t.fields == ["foo", "bar"] && t.header == ["# h", "slot\tx"])
        #expect(GLIDispatch.fields(in: Data("xx{__GLIFunctionDispatchRec=\"foo\"^?\"\"\"bar\"^?}".utf8)) == ["foo", "bar"])
        #expect(GLIDispatch.compatibility(t, shim: t) == .compatible)
        let other = GLIDispatch.Table(header: [], rows: [["0", "", "", "foo"], ["1", "", "", "baz"], ["2", "", "", "q"]])
        #expect(GLIDispatch.compatibility(t, shim: other, shimName: "s.tsv").reason == "dispatch table differs from s.tsv at slot 1 (2 vs 3 slots)")
    }

    /// Verdicts (every shipped TSV), the engine pick, gld_problem, and the generated TSV, all against Python.
    @Test(arguments: [("7B500", "7B500"), ("7B367", "7B367"), ("8C148", "iOS 4.2.1 (8C148)")])
    func matchesPython(build: String, label: String) throws {
        guard Fixtures.hasRootfs(build), Fixtures.hasPython, Fixtures.exists(Self.base) else { return }
        let dir = try Fixtures.tempDir("gli")
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = try Fixtures.cache(build, to: dir)
        let cache = try DyldSharedCache(contentsOf: path)

        let plugin = Self.gles.appendingPathComponent("GLRendererFloatQEMU.bundle/GLRendererFloatQEMU")
        // a stand-in gld plugin exporting every gld* name libGFXShared wants but the first
        let fake = dir.appendingPathComponent("fake-gld")
        let wanted = cache.image(GLIDispatch.libGFXShared).map { cache.cStrings(in: $0, section: "__cstring") }?
            .filter { $0.wholeMatch(of: /gld[A-Z]\w+/) != nil } ?? []
        try Data(wanted.dropFirst().map { "\0_" + $0 + "\0" }.joined().utf8).write(to: fake)
        let py = """
            import sys, json; sys.path.insert(0, sys.argv[1]); import ipad1_rootfs as r
            c = sys.argv[2]
            print(json.dumps({"verdicts": [r.gli_abi_problem(c, t) for t in r.GLI_TSVS], "tsvs": r.GLI_TSVS,
                              "engine": r.gli_engine(c)[1], "gld": list(r.gld_problem(c, sys.argv[3])), "fake": list(r.gld_problem(c, sys.argv[4]))}))
            """
        let r = try Fixtures.run(["python3", "-c", py, Fixtures.imgtools.path, path.path, plugin.path, fake.path])
        #expect(r.status == 0, "\(r.err)")
        let want = try JSONSerialization.jsonObject(with: r.out) as! [String: Any]
        let tsvs = (want["tsvs"] as! [String]).map { URL(fileURLWithPath: $0) }
        let verdicts = try tsvs.map { try GLIDispatch.abiProblem(cache: cache.data, cachePath: path.path, tsv: $0) }
        #expect(verdicts.map { $0 ?? "<nil>" } == (want["verdicts"] as! [Any]).map { $0 as? String ?? "<nil>" })
        let engine = try GLIDispatch.engine(cache: cache.data, cachePath: path.path, tsvs: tsvs)
        #expect(engine.why == want["engine"] as? String)
        let gld = GLIDispatch.gldProblem(cache, plugin: plugin), wantGld = want["gld"] as! [Any]
        #expect(gld.needed == wantGld[0] as! Bool && gld.why == wantGld[1] as? String)
        let gldFake = GLIDispatch.gldProblem(cache, plugin: fake), wantFake = want["fake"] as! [Any]
        #expect(gldFake.needed == wantFake[0] as! Bool && gldFake.why == wantFake[1] as? String)
        if build == "8C148" { #expect(gldFake.why == "gldshim lacks " + wanted[0]) }
        print("\(build): verdicts \(verdicts.map { $0 ?? "match" }); engine \(engine.tsv?.lastPathComponent ?? "none"); gld \(gld)")
        if build != "8C148" { #expect(verdicts[tsvs.firstIndex { $0.lastPathComponent == "gli-dispatch-7B500.tsv" }!] == nil) }

        // generated TSV: identical to glitsv.py's
        let t0 = Date()
        let table = try GLIDispatch.generate(sharedCache: cache, build: label, base: try .init(contentsOf: Self.base), wire: try .init(contentsOf: Self.wire))
        let swiftTime = Date().timeIntervalSince(t0)
        let out = dir.appendingPathComponent("py.tsv")
        let t1 = Date()
        let g = try Fixtures.run(["python3", Self.gles.appendingPathComponent("glitsv.py").path, path.path, label, out.path])
        print("\(build): generate swift \(String(format: "%.2f", swiftTime)) s, glitsv.py \(String(format: "%.2f", Date().timeIntervalSince(t1))) s")
        #expect(g.status == 0, "\(g.err)")
        #expect(table.tsv == (try String(contentsOf: out, encoding: .utf8)))
        #expect(try GLIDispatch.verify(cache, tsv: table) == nil)
        if build == "8C148" {    // the shipped 8C148 table is glitsv.py output
            #expect(table.tsv == (try String(contentsOf: Self.docs.appendingPathComponent("gli-dispatch-8C148.tsv"), encoding: .utf8)))
        } else {                 // 7B500's shipped table is the hand-made base: same ABI and export column
            let shipped = try GLIDispatch.Table(contentsOf: Self.base)
            #expect(GLIDispatch.compatibility(table, shim: shipped) == .compatible && table.exports == shipped.exports)
        }
    }

    /// The iPod's armv6 tables (glitsv.py's trampoline forms: ldr pc as a call or tail call, blxne, ip base, the
    /// 3.1.3 slot fallback): generated from each firmware's cache, equal to glitsv.py and to docs/ipod's table.
    @Test(arguments: [("7E18", "iOS 3.1.3 (7E18)", "7E18"), ("8C148-ipod", "iOS 4.2.1 (8C148)", "8C148")])
    func ipodMatchesPython(fixture: String, label: String, build: String) throws {
        guard Fixtures.hasRootfs(fixture), Fixtures.hasPython, Fixtures.exists(Self.wire) else { return }
        let dir = try Fixtures.tempDir("gli-ipod")
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = try Fixtures.cache(fixture, to: dir)
        let cache = try DyldSharedCache(contentsOf: path)
        let table = try GLIDispatch.generate(sharedCache: cache, build: label, base: try .init(contentsOf: Self.base), wire: try .init(contentsOf: Self.wire))
        let out = dir.appendingPathComponent("py.tsv")
        let g = try Fixtures.run(["python3", Self.gles.appendingPathComponent("glitsv.py").path, path.path, label, out.path])
        #expect(g.status == 0, "\(g.err)")
        #expect(table.tsv == (try String(contentsOf: out, encoding: .utf8)))
        #expect(table.tsv == (try String(contentsOf: Self.ipodDocs.appendingPathComponent("gli-dispatch-\(build).tsv"), encoding: .utf8)))
        #expect(try GLIDispatch.verify(cache, tsv: table) == nil)
        let tsvs = try FileManager.default.contentsOfDirectory(at: Self.ipodDocs, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.wholeMatch(of: /gli-dispatch-\w+\.tsv/) != nil }
        #expect(try GLIDispatch.engine(cache: cache.data, cachePath: path.path, tsvs: tsvs).tsv?.lastPathComponent == "gli-dispatch-\(build).tsv")
        print("\(fixture): \(table.rows.count) slots, \(table.exports.count) exports")
    }
}
