import Foundation
import Testing
@testable import FirmwareKit

/// The oracle's inputs: the Python cache's rootfs.dmg, the qemu-ios helper build outputs (contrib/*/build.sh),
/// the dispatch TSVs and the user's activation hooks. Everything is read in place; outputs go to temp dirs.
enum K48Oracle {
    static let qemu = Oracle.qemuIOS
    /// FIRMWAREKIT_ACTIVATION_HOOK (an executable) overrides both.
    static let hooks = ProcessInfo.processInfo.environment["FIRMWAREKIT_ACTIVATION_HOOK"].map { h in
        Dictionary(uniqueKeysWithValues: ["k48ap-7B500", "k48ap-8C148"].map { ($0, URL(fileURLWithPath: h)) })
    } ?? ["k48ap-7B500": Oracle.path("Developer/qemu-ios-files/ipad1/offline-activation/patch_lockdownd.py"),
          "k48ap-8C148": Oracle.path("Developer/qemu-ios-files/ipad1/offline-activation-8C148/patch_lockdownd.py")]

    /// helpers-dir name -> qemu-ios file.
    static var sources: [String: URL] {
        let guest = qemu.appendingPathComponent("build/ipad1-guest"), contrib = qemu.appendingPathComponent("contrib")
        var m: [String: URL] = [:]
        for t in SystemEdits.Helpers.tools.map(\.name) + ["it_seal", "it_gltest"] { m[t] = guest.appendingPathComponent(t) }
        for (j, d) in [("com.qemu.it-pbd.plist", "it-pasteboard"), ("com.qemu.it-ethlink.plist", "it-ethlink"),
                       ("com.qemu.it-prefs.plist", "it-prefs"), ("com.qemu.it-seal.plist", "it-seal"), ("com.qemu.it-gltest.plist", "it-gltest")] {
            m[j] = contrib.appendingPathComponent("\(d)/\(j)")
        }
        m["libappsync.dylib"] = qemu.appendingPathComponent("build/appsync/libappsync.dylib")
        for b in ["7B500", "8C148"] {
            m["GLEngine-\(b)"] = contrib.appendingPathComponent("ipad1-gles/GLEngine-\(b)")
            m["gli-dispatch-\(b).tsv"] = qemu.appendingPathComponent("docs/ipad1/gli-dispatch-\(b).tsv")
        }
        m["GLRendererFloatQEMU"] = contrib.appendingPathComponent("ipad1-gles/GLRendererFloatQEMU.bundle/GLRendererFloatQEMU")
        m[SystemEdits.Helpers.itpack] = qemu.appendingPathComponent("build/guest-package/armv7.itpack")
        return m
    }

    static var available: Bool { HFSOracle.available && sources.values.allSatisfy(Oracle.exists) }

    /// A helpers directory of symlinks to the qemu-ios build outputs.
    static func helpers(in dir: URL) throws -> URL {
        let h = dir.appendingPathComponent("helpers")
        try FileManager.default.createDirectory(at: h, withIntermediateDirectories: true)
        for (n, u) in sources { try FileManager.default.createSymbolicLink(at: h.appendingPathComponent(n), withDestinationURL: u) }
        return h
    }

    static func sh(_ args: [String], cwd: URL) throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        p.arguments = args
        p.currentDirectoryURL = cwd
        p.standardOutput = FileHandle.nullDevice
        let err = Pipe()
        p.standardError = err
        try p.run()
        let e = err.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { throw FirmwareError(.internal, "\(args.prefix(3)): \(String(decoding: e.suffix(2000), as: UTF8.self))") }
    }
}

@Suite(.serialized) struct SystemEditsTests {
    @Test func plistEdits() throws {
        let real = NSMutableDictionary(dictionary: ["CurrentSet": "/Sets/S", "NetworkServices": ["W": ["Interface": ["DeviceName": "en0"]]],
                                                    "Sets": ["S": ["Network": ["Global": ["IPv4": ["ServiceOrder": ["W"]]], "Service": ["W": [:]]]]]])
        let d = try PropertyListSerialization.propertyList(from: PropertyListSerialization.data(fromPropertyList: real, format: .xml, options: 0),
                                                           options: .mutableContainersAndLeaves, format: nil) as! NSMutableDictionary
        SystemEdits.usbNetPrefs(d); SystemEdits.usbNetPrefs(d)
        SystemEdits.wifiProxyPrefs(d); SystemEdits.wifiProxyPrefs(d)
        let net = ((d["Sets"] as! NSDictionary)["S"] as! NSDictionary)["Network"] as! NSDictionary
        #expect(((net["Global"] as! NSDictionary)["IPv4"] as! NSDictionary)["ServiceOrder"] as! [String]
                == [SystemEdits.wifiService, SystemEdits.usbEthService, "W"])
        let fresh = NSMutableDictionary()
        SystemEdits.usbNetPrefs(fresh)
        #expect(((fresh["Sets"] as! NSDictionary)[SystemEdits.netSet] as? NSDictionary)?["UserDefinedName"] as? String == "Automatic")
        let env = NSMutableDictionary(dictionary: ["EnvironmentVariables": NSMutableDictionary(dictionary: ["DYLD_INSERT_LIBRARIES": "/a.dylib"])])
        SystemEdits.dyldInsert(env, "/b.dylib"); SystemEdits.dyldInsert(env, "/b.dylib")
        #expect((env["EnvironmentVariables"] as! NSDictionary)["DYLD_INSERT_LIBRARIES"] as? String == "/a.dylib:/b.dylib")
        let ifs = NSMutableDictionary(dictionary: ["Interfaces": [["BSD Name": "en2", "IOInterfaceUnit": 2], ["BSD Name": "en0", "IOInterfaceUnit": 0]]])
        SystemEdits.usbNetInterfaces(ifs)
        #expect((ifs["Interfaces"] as! [NSDictionary]).map { $0["BSD Name"] as! String } == ["en0", "en1", "en2"])
    }

    /// GuestPackage.seed against mkpkg.seed on a plain directory with the real armv7.itpack: the same tree
    /// (paths, modes, bytes, symlinks) and the same record, for a shim image and a no-shim one.
    @Test(arguments: [("7B500", "7B500" as String?), ("8C148", nil)]) func seedMatchesPython(_ build: String, _ gli: String?) throws {
        let itpack = K48Oracle.qemu.appendingPathComponent("build/guest-package/armv7.itpack")
        guard Oracle.exists(itpack), Oracle.exists(K48Oracle.qemu.appendingPathComponent("contrib/guest-package/mkpkg.py")) else { return }
        try Oracle.withTemp { dir in
            func volume(_ name: String) throws -> URL {
                let v = dir.appendingPathComponent(name), sv = v.appendingPathComponent(GuestPackage.systemVersion)
                for rel in [SystemEdits.glEngine, SystemEdits.gldPath, "usr/local/lib/it_msmquiet.dylib"] {
                    try SystemEdits.mkdirs(v.appendingPathComponent(rel).deletingLastPathComponent())
                    try SystemEdits.put(Data("stock".utf8), v.appendingPathComponent(rel), mode: 0o755)
                }
                try SystemEdits.mkdirs(v.appendingPathComponent(SystemEdits.daemons))
                try SystemEdits.put(Data("job".utf8), v.appendingPathComponent(SystemEdits.daemons + "/com.qemu.it-pbd.plist"))
                try SystemEdits.mkdirs(sv.deletingLastPathComponent())
                try (["ProductBuildVersion": build] as NSDictionary).write(to: sv)
                return v
            }
            let a = try volume("swift"), b = try volume("python")
            let (written, record) = try GuestPackage.seed(volume: a, itpack: itpack, gli: gli)
            let out = dir.appendingPathComponent("py.json")
            try K48Oracle.sh(["python3", "-c", """
                import json, sys; sys.path.insert(0, sys.argv[1]); import mkpkg
                made, rec = mkpkg.seed(sys.argv[2], sys.argv[3], sys.argv[4] or None)
                json.dump({"written": made, "record": rec}, open(sys.argv[5], "w"))
                """, K48Oracle.qemu.appendingPathComponent("contrib/guest-package").path, b.path, itpack.path, gli ?? "", out.path],
                             cwd: dir)
            let py = try JSONSerialization.jsonObject(with: Data(contentsOf: out)) as! NSDictionary
            #expect(written == py["written"] as? [String])
            #expect(NSDictionary(dictionary: record.object) == py["record"] as? NSDictionary)
            #expect(record.gli == gli && record.hooks.contains("/" + SystemEdits.glEngine) == (gli != nil))
            func tree(_ v: URL) throws -> [String: String] {
                var t: [String: String] = [:]
                try SystemEdits.walk(v) { rel in
                    let p = v.appendingPathComponent(rel).path
                    var st = stat()
                    lstat(p, &st)
                    let link = try? FileManager.default.destinationOfSymbolicLink(atPath: p)
                    let body = st.st_mode & S_IFMT == S_IFREG ? Oracle.sha256(try Data(contentsOf: URL(fileURLWithPath: p))) : ""
                    t[rel] = "\(String(st.st_mode, radix: 8)) \(link ?? body)"
                }
                return t
            }
            let ta = try tree(a), tb = try tree(b)
            #expect(ta == tb, "\(Set(ta.map { "\($0) \($1)" }).symmetricDifference(tb.map { "\($0) \($1)" }).sorted().prefix(10))")
            // The seed leaves the baked it-pbd job alone since package serial 2 folded the pasteboard into it_agent
            // (qemu-ios ipad1 136cc59843); the tree comparison above already holds both seeds to the same jobs.
            #expect(ta["usr/local/lighttouch/state"] != nil)
        }
    }

    @Test func activationRejectsInvalidInputWithoutChangingIt() throws {
        try Oracle.withTemp { dir in
            let target = dir.appendingPathComponent("t")
            let original = Data("not a mach-o".utf8)
            try original.write(to: target)
            #expect(throws: ActivationFailure.self) { try Activation.run(on: target) }
            #expect(try Data(contentsOf: target) == original)
        }
    }

    /// Level 2: the Swift-built system and data volumes against ipad1_rootfs.py build + bake --seal
    /// --activation-hook on the same rootfs.dmg: every path with owner, mode, flags, size, content sha256 and
    /// symlink target; plists written by either side compared parsed. Expected difference: lockdownd, whose ad-hoc signature representation differs between signers.
    @Test(arguments: HFSOracle.ipads) func volumesMatchPython(_ fw: Oracle.Firmware) throws {
        guard K48Oracle.available, let dmg = fw.cache?.appendingPathComponent("rootfs.dmg"), Oracle.exists(dmg),
              let hook = K48Oracle.hooks[fw.entryID], FileManager.default.isExecutableFile(atPath: hook.path) else { return }
        try Oracle.withTemp { dir in
            let entry = try Oracle.entry(fw.entryID), recipe = try #require(entry.recipe)
            let parts = try JSONSerialization.jsonObject(with: HFSOracle.python("""
                import json, ipad1_nand as n
                m = n.make_mbr(n.Geo(name="k48-16g", **n.GEOMETRIES["k48-16g"]), int(sys.argv[2]))
                open(sys.argv[1], "wb").write(m)
                print(json.dumps([p[2] for p in n.mbr_parts(m)[:2]]))
                """, [dir.appendingPathComponent("mbr.bin").path, String(recipe.systemMiB)])) as! [Int]

            let py = dir.appendingPathComponent("py")
            try Oracle.time("python build + bake \(fw.entryID)") {
                let tool = K48Oracle.qemu.appendingPathComponent("imgtools/ipad1_rootfs.py").path
                try K48Oracle.sh(["python3", tool, "build", "--base", "pristine", "--rootfs", dmg.path, "--pristine", dmg.path,
                                  "--mbr", dir.appendingPathComponent("mbr.bin").path, "--out", py.path, "--lockdown", "none",
                                  "--stash", "none", "--data-size", "partition"] + (recipe.options["appsync"] == true ? ["--appsync"] : []),
                                 cwd: K48Oracle.qemu)
                try K48Oracle.sh(["python3", tool, "bake", py.appendingPathComponent("pristine").path, "--tools",
                                  K48Oracle.qemu.appendingPathComponent("build/ipad1-guest").path, "--guest-package",
                                  K48Oracle.sources[SystemEdits.Helpers.itpack]!.path, "--seal", "--activation-hook", hook.path],
                                 cwd: K48Oracle.qemu)
            }
            let swift = dir.appendingPathComponent("swift")
            try FileManager.default.createDirectory(at: swift, withIntermediateDirectories: true)
            let helpers = try K48Oracle.helpers(in: dir)
            let r = try Oracle.time("SystemEdits.buildK48 \(fw.entryID)") {
                try SystemEdits.buildK48(rootfs: dmg, work: swift, systemBytes: parts[0] * 4096, dataBytes: Int64(parts[1]) * 4096,
                                         options: .init(recipe: recipe), helpers: helpers, gliDispatch: recipe.gliDispatch) { print("  \($0)") }
            }
            #expect(r.activation != nil)
            // the seed record, as the Python bake wrote it for the lock (the itpack path differs: a symlink here)
            let pyRecord = try JSONSerialization.jsonObject(with: Data(contentsOf: py.appendingPathComponent("pristine/guest-package.json"))) as! NSDictionary
            var record = try #require(r.guestPackage?.object)
            record["itpack"] = pyRecord["itpack"]
            #expect(NSDictionary(dictionary: record) == pyRecord)
            #expect(r.guestPackage?.gli != nil && r.guestPackage?.gli == r.engine.map { String($0.dropFirst("GLEngine-".count)) })

            // lockdownd: different ad-hoc signature representation; .journal: each volume's own journal
            for (vol, expected) in [("system.img", ["usr/libexec/lockdownd"]), ("data.img", [".journal"])] {
                let a = try HFSPlusVolume(swift.appendingPathComponent(vol)), b = try HFSPlusVolume(py.appendingPathComponent("pristine/" + vol))
                #expect(try VolumeMount.size(a.url) == VolumeMount.size(b.url))
                #expect(a.totalBlocks == b.totalBlocks && a.blockSize == b.blockSize)
                let la = try Oracle.time("listing \(vol)") { try a.listing() }, lb = try b.listing()
                let ma = Dictionary(uniqueKeysWithValues: la.map { ($0.path, $0) }), mb = Dictionary(uniqueKeysWithValues: lb.map { ($0.path, $0) })
                var diffs: [String] = [], plists = 0, unexpected: [String] = []
                for p in Set(ma.keys).union(mb.keys).sorted() {
                    guard var x = ma[p], var y = mb[p] else { diffs.append("\(p): only in \(ma[p] == nil ? "python" : "swift")"); continue }
                    if x.sha256 != y.sha256, x.mode & 0o170000 == 0o100000,
                       let px = try? PropertyListSerialization.propertyList(from: a.contents(a.record(at: p)), format: nil) as? NSObject,
                       let py = try? PropertyListSerialization.propertyList(from: b.contents(b.record(at: p)), format: nil) as? NSObject, px.isEqual(py) {
                        plists += 1
                        x.sha256 = nil; y.sha256 = nil; x.size = 0; y.size = 0
                    }
                    if x != y {
                        if expected.contains(p) { unexpected.append("expected: \(p) sha256 \(x.sha256 ?? "-") vs \(y.sha256 ?? "-")") } else { diffs.append("\(p): swift \(x) python \(y)") }
                    }
                }
                print("\(fw.entryID) \(vol): \(la.count) paths, \(plists) plists equal parsed; \(unexpected)")
                #expect(diffs.isEmpty, "\(vol): \(diffs.prefix(30))")
                #expect(la.count == lb.count)
            }
            // the seeded network services really are there (on both sides, so the comparison above is not vacuous)
            let dv = try HFSPlusVolume(swift.appendingPathComponent("data.img"))
            let prefs = try PropertyListSerialization.propertyList(from: dv.contents(dv.record(at: "preferences/SystemConfiguration/preferences.plist")),
                                                                   format: nil) as! NSDictionary
            let order = (prefs.value(forKeyPath: "Sets.\(SystemEdits.netSet).Network.Global.IPv4.ServiceOrder") as? [String]) ?? []
            #expect(order.prefix(2) == [SystemEdits.wifiService, SystemEdits.usbEthService][...])
            #expect(try dv.record(at: "preferences/SystemConfiguration/NetworkInterfaces.plist").uid == 0)
            // the seed is there: loader, current -> pkgs/<serial>, its offer record, a hook and its .baked copy, no baked helper job
            let sv = try HFSPlusVolume(swift.appendingPathComponent("system.img")), seed = try #require(r.guestPackage)
            let tree = Dictionary(uniqueKeysWithValues: try sv.listing(under: "usr/local").map { ($0.path, $0) })
            #expect(tree["usr/local/bin/it_boot"]?.mode == 0o100755 && tree["usr/local/bin/it_boot"]?.uid == 0)
            #expect(tree["usr/local/lighttouch/current"]?.link == "pkgs/\(seed.seed)")
            #expect(tree["usr/local/lighttouch/pkgs/\(seed.seed)/offer"]?.uid == 0)
            #expect(seed.hooks.contains("/" + SystemEdits.glEngine))
            let engine = try sv.listing(under: SystemEdits.glEngine).first, baked = try sv.listing(under: SystemEdits.glEngine + ".baked").first
            #expect(engine?.sha256 != nil && engine?.sha256 == baked?.sha256 && baked?.uid == 0)
            #expect(try sv.listing(under: SystemEdits.daemons + "/com.qemu.it-pbd.plist").isEmpty)
            #expect(try sv.listing(under: SystemEdits.daemons + "/com.qemu.it-boot.plist").first?.uid == 0)
            // the activation's output is lockdownd as installed (re-signed ad hoc, entitlements kept)
            let lockd = try HFSPlusVolume(swift.appendingPathComponent("system.img")).listing(under: "usr/libexec/lockdownd")
            #expect(lockd.first?.sha256 == r.activation?.outputSHA256 && lockd.first?.mode == 0o100755 && lockd.first?.uid == 0)
        }
    }
}
