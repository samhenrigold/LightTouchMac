import Foundation
import Testing
@testable import FirmwareKit

/// The oracle's inputs: the Python cache's rootfs.dmg, the qemu-ios helper build outputs (contrib/*/build.sh),
/// the dispatch TSVs and the user's activation hooks. Everything is read in place; outputs go to temp dirs.
enum K48Oracle {
    static let qemu = Oracle.path("Developer/qemu-ios-ipad1")
    static let hooks = ["k48ap-7B500": Oracle.path("Developer/qemu-ios-files/ipad1/offline-activation/patch_lockdownd.py"),
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

    @Test func hookChecks() throws {
        try Oracle.withTemp { dir in
            let target = dir.appendingPathComponent("t")
            try Data("not a mach-o".utf8).write(to: target)
            let same = dir.appendingPathComponent("same.sh"), edit = dir.appendingPathComponent("edit.sh")
            try Data("#!/bin/sh\nexit 0\n".utf8).write(to: same)
            try Data("#!/bin/sh\necho x >> \"$1\"\n".utf8).write(to: edit)
            chmod(same.path, 0o755); chmod(edit.path, 0o755)
            #expect { try ActivationHook.run(same, on: target) } throws: { ($0 as? HookFailure)?.message.contains("unchanged") == true }
            #expect { try ActivationHook.run(edit, on: target, displayPath: "/t") } throws: {
                ($0 as? HookFailure)?.message == "activation hook left /t unsigned"
            }
            #expect(try Data(contentsOf: target) == Data("not a mach-o".utf8))
        }
    }

    /// Level 2: the Swift-built system and data volumes against ipad1_rootfs.py build + bake --seal
    /// --activation-hook on the same rootfs.dmg: every path with owner, mode, flags, size, content sha256 and
    /// symlink target; plists written by either side compared parsed. Expected difference: lockdownd, which
    /// the oracle re-signs with ldid after the hook and FirmwareKit does not.
    @Test(arguments: HFSOracle.ipads) func volumesMatchPython(_ fw: Oracle.Firmware) throws {
        guard K48Oracle.available, let dmg = fw.cache?.appendingPathComponent("rootfs.dmg"), Oracle.exists(dmg),
              let hook = K48Oracle.hooks[fw.entryID], Oracle.exists(hook) else { return }
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
                                  K48Oracle.qemu.appendingPathComponent("build/ipad1-guest").path, "--seal", "--activation-hook", hook.path],
                                 cwd: K48Oracle.qemu)
            }
            let swift = dir.appendingPathComponent("swift")
            try FileManager.default.createDirectory(at: swift, withIntermediateDirectories: true)
            let helpers = try K48Oracle.helpers(in: dir)
            let r = try Oracle.time("SystemEdits.buildK48 \(fw.entryID)") {
                try SystemEdits.buildK48(rootfs: dmg, work: swift, systemBytes: parts[0] * 4096, dataBytes: Int64(parts[1]) * 4096,
                                         options: .init(recipe: recipe), helpers: helpers, gliDispatch: recipe.gliDispatch,
                                         activationHook: hook) { print("  \($0)") }
            }
            #expect(r.hook?.hookSHA256 == Oracle.sha256(try Data(contentsOf: hook)))

            // lockdownd: re-signed by the oracle only; .journal: each volume's own journal
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
            // the hook's output is lockdownd as installed (unsigned-by-us: its original signature is kept)
            let lockd = try HFSPlusVolume(swift.appendingPathComponent("system.img")).listing(under: "usr/libexec/lockdownd")
            #expect(lockd.first?.sha256 == r.hook?.outputSHA256 && lockd.first?.mode == 0o100755 && lockd.first?.uid == 0)
        }
    }
}
