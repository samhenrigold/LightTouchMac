import Crypto
import Foundation
import Testing
import zlib

@testable import FirmwareKit

/// The built-in device's packed base: pack, unpack and a fresh identity give what `create --seed` gives, and a rebuild
/// changes only the files and chunks whose content changed.
struct PreparedBaseTests {
    static let images = ["illb": Data(repeating: 0xAB, count: 0x123)]

    static func identity(_ seed: String) throws -> UnitIdentity {
        try UnitIdentity.synthesizeIPod(seed: seed, modelNumber: "MB528", regionInfo: "LL/A")
    }

    static func nor(_ seed: String) throws -> Data {
        try N72NOR.build(identity: identity(seed), images: images, types: ["illb"], wrapTypes: [])
    }

    /// A base in the shape the n72 recipe leaves, made with `seed`, its lock naming this Mac's paths as create's do;
    /// `pages` go into its NAND image.
    static func base(_ dir: URL, seed: String, pages: [N72NAND.Page: UInt8] = [.init(cs: 0, page: 1): 7]) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let store = try N72NANDImage.create(dir.appendingPathComponent("nand"))
        for (p, byte) in pages { try store.write(p, [UInt8](repeating: byte, count: N72NANDImage.stride)) }
        try store.sync()
        try Data("ibot".utf8).write(to: dir.appendingPathComponent("iBoot.bin"))
        try Data().write(to: dir.appendingPathComponent("empty"))
        try nor(seed).write(to: dir.appendingPathComponent("nor.bin"))
        let id = try identity(seed)
        try id.write(to: dir.appendingPathComponent("identity.json"))
        let lock: [String: Any] = [
            "board": "n72ap", "boot_strategy": "iboot", "created": ISO8601DateFormatter().string(from: Date()),
            "identity": ["seed": seed, "udid": id.udid!, "sha256": "x"],
            "machine": [
                "aes-uid": "engine", "wifi-mac": id["wifi-mac"]!, "bt-mac": id["bt-mac"]!,
                "ecid": id["unique-chip-id"]!
            ],
            "outputs": [
                "nor": ["path": "nor.bin", "sha256": Preparer.sha256(try nor(seed))], "nand": ["listing_sha256": "l"]
            ],
            "inputs": [
                "ipsw": ["path": "/Users/someone/Library/Caches/x/5f4f.ipsw", "sha1": "5f4f"],
                "decrypted": "/tmp/cache/abc",
                "guest_tools": "/Users/someone/out/ipad-guest-tools", "identity": "identity.json"
            ],
            "tool": ["name": "firmwarekit", "helper": "/Users/someone/app/LightTouchDevice"],
            "guest_package": [
                "seed": 15, "itpack": ["path": "/Users/someone/out/ipad-guest-tools/armv6.itpack", "sha256": "s"],
                "hooks": ["/usr/lib/libappsync.dylib"]
            ]
        ]
        try Preparer.lockData(lock).write(to: dir.appendingPathComponent("device.lock.json"))
        for name in ["nand", "nor.bin", "iBoot.bin"] { try Preparer.readOnly(dir.appendingPathComponent(name)) }
    }

    static func lock(_ dir: URL) throws -> [String: Any] {
        try JSONSerialization.jsonObject(with: Data(contentsOf: dir.appendingPathComponent("device.lock.json")))
            as! [String: Any]
    }

    @Test func reidentifiedNORIsTheBuildForThatIdentity() throws {
        #expect(try N72NOR.reidentify(Self.nor("template"), identity: Self.identity("A")) == Self.nor("A"))
        #expect(try Self.nor("A") != Self.nor("B"))
    }

    @Test func unpackGivesEachDeviceTheIdentityCreateWould() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("prepared-base-\(UUID().uuidString)")
        defer {
            _ = try? Process.run(URL(fileURLWithPath: "/bin/chmod"), arguments: ["-R", "u+w", tmp.path]).waitUntilExit()
            try? FileManager.default.removeItem(at: tmp)
        }
        let template = tmp.appendingPathComponent("template")
        let blob = tmp.appendingPathComponent("base.itbase")
        try Self.base(template, seed: "lighttouch-built-in")
        try PreparedBase.pack(base: template, to: blob)
        #expect(
            try !Data(contentsOf: blob.appendingPathComponent("files/device.lock.json")).contains(Data("/Users/".utf8))
        )

        var udids: Set<String> = []
        for seed in ["6A1F0E2B-1111-4000-8000-000000000001", "6A1F0E2B-2222-4000-8000-000000000002"] {
            let out = tmp.appendingPathComponent(seed)
            var fractions: [Double] = []
            try PreparedBase.unpack(blob, into: out) { fractions.append($0) }
            #expect(fractions.last == 1 && fractions == fractions.sorted())
            try PreparedBase.reseed(out, seed: seed)
            // What `create --seed` would have written for this seed.
            let want = tmp.appendingPathComponent("want-\(seed)")
            try Self.base(want, seed: seed)
            for name in [
                "identity.json", "nor.bin", "nand/cs0.pages", "nand/cs3.pages", "nand/geometry.json", "iBoot.bin",
                "empty"
            ] {
                #expect(
                    try Data(contentsOf: out.appendingPathComponent(name))
                        == Data(contentsOf: want.appendingPathComponent(name)),
                    "\(name)"
                )
            }
            let got = try Self.lock(out)
            let wanted = try Self.lock(want)
            #expect(
                NSDictionary(dictionary: got["machine"] as! [String: Any])
                    == NSDictionary(dictionary: wanted["machine"] as! [String: Any])
            )
            #expect(
                NSDictionary(dictionary: got["outputs"] as! [String: Any])
                    == NSDictionary(dictionary: wanted["outputs"] as! [String: Any])
            )
            let identity = got["identity"] as! [String: Any]
            #expect(try identity["seed"] as? String == seed && identity["udid"] as? String == Self.identity(seed).udid)
            #expect(
                identity["sha256"] as? String
                    == (try Preparer.digest(out.appendingPathComponent("identity.json"), SHA256()))
            )
            #expect((got["inputs"] as! [String: Any])["guest_tools"] as? String == "ipad-guest-tools")
            #expect(
                !String(decoding: try Data(contentsOf: out.appendingPathComponent("device.lock.json")), as: UTF8.self)
                    .contains("/Users/")
            )
            let mode = { (name: String) in
                (try FileManager.default.attributesOfItem(atPath: out.appendingPathComponent(name).path)[
                    .posixPermissions
                ] as! Int)
            }
            #expect(
                try mode("identity.json") == 0o600 && mode("nor.bin") == 0o444 && mode("nand/cs0.pages") & 0o222 == 0
            )
            udids.insert(identity["udid"] as! String)
        }
        #expect(udids.count == 2)

        // A damaged chunk or a name leaving the directory is refused.
        let index =
            try JSONSerialization.jsonObject(with: Data(contentsOf: blob.appendingPathComponent("index.json")))
            as! [String: Any]
        let chunk = blob.appendingPathComponent("nand/cs0/000000.z")
        let torn = tmp.appendingPathComponent("torn.itbase")
        try FileManager.default.copyItem(at: blob, to: torn)
        let bytes = try Data(contentsOf: chunk)
        try bytes.prefix(bytes.count - 4).write(to: torn.appendingPathComponent("nand/cs0/000000.z"))
        #expect(throws: (any Error).self) { try PreparedBase.unpack(torn, into: tmp.appendingPathComponent("torn")) }
        var outside = index
        outside["files"] = [["name": "../outside", "size": 0, "mode": 0o644, "sha256": Preparer.sha256(Data())]]
        let escaping = tmp.appendingPathComponent("escaping.itbase")
        try FileManager.default.createDirectory(at: escaping, withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: outside).write(to: escaping.appendingPathComponent("index.json"))
        #expect(throws: (any Error).self) {
            try PreparedBase.unpack(escaping, into: tmp.appendingPathComponent("escaping"))
        }
        #expect(!FileManager.default.fileExists(atPath: tmp.appendingPathComponent("outside").path))
    }

    /// Every file of a packed base, relative path to bytes.
    static func tree(_ dir: URL) throws -> [String: Data] {
        var out: [String: Data] = [:]
        for case let name as String in FileManager.default.enumerator(atPath: dir.path)! {
            let url = dir.appendingPathComponent(name)
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), !isDir.boolValue {
                out[name] = try Data(contentsOf: url)
            }
        }
        return out
    }

    /// Two builds of the same content pack byte for byte the same (the lock's date and paths are not packed); a changed
    /// page changes its own chunk, the index and nothing else; a previous build's chunks are reused as they are.
    @Test func packingIsByteStableAndChangesOnlyTheChunksThatChanged() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("prepared-base-\(UUID().uuidString)")
        defer {
            _ = try? Process.run(URL(fileURLWithPath: "/bin/chmod"), arguments: ["-R", "u+w", tmp.path]).waitUntilExit()
            try? FileManager.default.removeItem(at: tmp)
        }
        // a page in each of two chunks of cs0, and one on cs2
        let pages: [N72NAND.Page: UInt8] = [
            .init(cs: 0, page: 1): 7, .init(cs: 0, page: 700): 9, .init(cs: 2, page: 3): 5
        ]
        try Self.base(tmp.appendingPathComponent("a"), seed: "lighttouch-built-in", pages: pages)
        Thread.sleep(forTimeInterval: 1.1)  // a lock created a second later
        try Self.base(tmp.appendingPathComponent("b"), seed: "lighttouch-built-in", pages: pages)
        var changed = pages
        changed[.init(cs: 0, page: 700)] = 10
        try Self.base(tmp.appendingPathComponent("c"), seed: "lighttouch-built-in", pages: changed)
        for name in ["a", "b", "c"] {
            try PreparedBase.pack(
                base: tmp.appendingPathComponent(name),
                to: tmp.appendingPathComponent("\(name).itbase")
            )
        }
        let a = try Self.tree(tmp.appendingPathComponent("a.itbase"))
        #expect(
            Set(a.keys.filter { $0.hasSuffix(".z") }) == [
                "nand/cs0/000000.z", "nand/cs0/000002.z", "nand/cs2/000000.z"
            ]
        )
        #expect(try Self.tree(tmp.appendingPathComponent("b.itbase")) == a)
        let c = try Self.tree(tmp.appendingPathComponent("c.itbase"))
        #expect(Set(a.keys) == Set(c.keys))
        #expect(Set(a.keys.filter { a[$0] != c[$0] }) == ["index.json", "nand/cs0/000002.z"])

        // A chunk compressed differently by an earlier build (here: at another level) is taken as it is.
        let previous = tmp.appendingPathComponent("a.itbase/nand/cs2/000000.z")
        let raw = try Data(contentsOf: tmp.appendingPathComponent("a/nand/cs2.pages"), options: .alwaysMapped).prefix(
            1 << 20
        )
        var size = compressBound(uLong(raw.count))
        var other = [UInt8](repeating: 0, count: Int(size))
        _ = [UInt8](raw).withUnsafeBufferPointer { compress2(&other, &size, $0.baseAddress, uLong(raw.count), 1) }
        try Data(other.prefix(Int(size))).write(to: previous)
        try PreparedBase.pack(
            base: tmp.appendingPathComponent("c"),
            to: tmp.appendingPathComponent("d.itbase"),
            reuse: tmp.appendingPathComponent("a.itbase")
        )
        let d = try Self.tree(tmp.appendingPathComponent("d.itbase"))
        #expect(d["nand/cs2/000000.z"] == Data(other.prefix(Int(size))))
        #expect(d["nand/cs0/000002.z"] == c["nand/cs0/000002.z"])
        try PreparedBase.unpack(tmp.appendingPathComponent("d.itbase"), into: tmp.appendingPathComponent("d"))
        for chip in [0, 2] {
            #expect(
                try Data(contentsOf: tmp.appendingPathComponent("d/nand/cs\(chip).pages"), options: .alwaysMapped)
                    == Data(contentsOf: tmp.appendingPathComponent("c/nand/cs\(chip).pages"), options: .alwaysMapped)
            )
        }
    }
}

/// The packed base was prepared in en-US whatever the building Mac's: unpacked, it takes the language and region create
/// would seed (issue 97), in its store and its lock.
@Suite(.detachesItsImages) struct PreparedBaseLanguageTests {
    @Test func unpackedBaseTakesTheLanguage() async throws {
        let fm = FileManager.default
        let root = try Fixtures.tempDir("prepared-base-language")
        defer { try? fm.removeItem(at: root) }
        let base = root.appendingPathComponent("base")
        try fm.createDirectory(at: base, withIntermediateDirectories: true)
        let image = root.appendingPathComponent("volume.img")
        let prefs = "private/var/mobile/Library/Preferences/.GlobalPreferences.plist"
        try Fixtures.makeVolume(image, size: 16 << 20, name: "System") { v in
            try v.makeDirectory((prefs as NSString).deletingLastPathComponent)
            let global: [String: Any] = ["AppleLanguages": ["en", "fr", "uk"], "AppleLocale": "en_US"]
            try v.put(PropertyListSerialization.data(fromPropertyList: global, format: .binary, options: 0), at: prefs)
        }
        let hfs = try HFSPlusVolume(image)
        let nand = base.appendingPathComponent("nand")
        try N72NAND.write(volume: image, blocks: hfs.totalBlocks * hfs.blockSize / N72NAND.page, epoch: 1, out: nand)
        try Preparer.readOnly(nand)
        try JSONSerialization.data(withJSONObject: ["derived": ["nand_epoch": 1]]).write(
            to: base.appendingPathComponent("device.lock.json")
        )

        try await PreparedBase.seedLanguage(base, tag: "uk-UA", keyboards: [])

        let volume = try #require(
            VolumeRebuild.rebuild(base: nand, overlay: nil, into: root.appendingPathComponent("out")).first?.image
        )
        let check = try HFSPlusVolume(volume)
        let global =
            try PropertyListSerialization.propertyList(from: check.contents(check.record(at: prefs)), format: nil)
            as? [String: Any]
        #expect(global?["AppleLanguages"] as? [String] == ["uk", "en", "fr"])
        #expect(global?["AppleLocale"] as? String == "uk_UA")
        let lock =
            try JSONSerialization.jsonObject(with: Data(contentsOf: base.appendingPathComponent("device.lock.json")))
            as? [String: Any]
        #expect((lock?["derived"] as? [String: Any])?["language"] as? String == "uk, region uk_UA, keyboards []")
        let nandRecord = (lock?["outputs"] as? [String: Any])?["nand"] as? [String: Any]
        #expect(
            nandRecord?["listing_sha256"] as? String
                == (try Preparer.nandListing(nand, files: Recipe.nandFiles(nand)).sha256)
        )
    }
}
