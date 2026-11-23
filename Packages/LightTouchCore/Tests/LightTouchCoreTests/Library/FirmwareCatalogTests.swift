import FirmwareSchema
import Foundation
import HostRuntime
import Testing

@testable import LightTouchCore

/// FirmwareCatalog: listing order, the flat wire it shares with preparation (FirmwareWire), and the GUI's own policy.
struct FirmwareCatalogTests {
    // MARK: Order

    static func entry(
        _ board: (String, String),
        _ version: String,
        _ build: String,
        _ prerelease: String? = nil,
        _ number: Int? = nil,
        released: String? = nil
    ) -> [String: Any] {
        var e: [String: Any] = [
            "id": "\(board.0)-\(build)", "board": board.0, "product_type": board.1, "version": version, "build": build,
            "status": "available", "source": ["kind": "ipsw"], "keys": [:] as [String: Any],
            "emulator": ["min_protocol": 1], "estimates": ["seconds": 1, "prepared_bytes": 1, "peak_bytes": 1]
        ]
        if let prerelease { e["prerelease"] = prerelease }
        if let number { e["prerelease_number"] = number }
        if let released { e["released"] = released }
        return e
    }

    /// Shuffled: per board, versions and a version's betas/GMs out of order; dated iPad entries where 5.0 beta 1
    /// came out between 4.3.3 and 4.3.4, and an undated 4.2.1 that keeps its version slot.
    static let shuffled: [[String: Any]] = {
        let ipod = ("n72ap", "iPod2,1")
        let ipad = ("k48ap", "iPad1,1")
        return [
            entry(ipod, "3.1.3", "7E18b"), entry(ipod, "4.1", "8B117"), entry(ipod, "3.1.3", "7E18"),
            entry(ipod, "4.1", "8B5091b", "beta", 2), entry(ipod, "4.2.1", "8C148"), entry(ipad, "3.2.2", "7B500"),
            entry(ipod, "4.2", "8C134b", "gm", 2), entry(ipod, "4.2", "8C134", "gm"),
            entry(ipod, "4.2", "8C5115c", "beta", 3),
            entry(ipod, "4.1", "8B5080c", "beta"), entry(ipod, "2.1.1", "5F138"), entry(ipad, "3.2", "7B367"),
            entry(ipad, "4.2.1", "8C148"),
            entry(ipad, "5.0", "9A334", released: "2011-10-12"), entry(ipad, "4.3.5", "8L1", released: "2011-07-25"),
            entry(ipad, "5.0", "9A5220p", "beta", 1, released: "2011-06-07"),
            entry(ipad, "4.3.4", "8K2", released: "2011-07-15"),
            entry(ipad, "4.3.3", "8J3", released: "2011-05-04")
        ]
    }()

    @Test func loadSortsPerBoardByVersionThenPrereleasesByDate() throws {
        try withTemporaryFile(named: "catalog.json") { file in
            try JSONSerialization.data(withJSONObject: ["format": 1, "entries": Self.shuffled]).write(to: file)
            let c = try FirmwareCatalog.load(from: file)
            #expect(
                c.entries.map { "\($0.board) \($0.version) \($0.build)" } == [
                    "n72ap 2.1.1 5F138", "n72ap 3.1.3 7E18", "n72ap 3.1.3 7E18b",
                    "n72ap 4.1 8B5080c", "n72ap 4.1 8B5091b", "n72ap 4.1 8B117",
                    "n72ap 4.2 8C5115c", "n72ap 4.2 8C134", "n72ap 4.2 8C134b", "n72ap 4.2.1 8C148",
                    "k48ap 3.2 7B367", "k48ap 3.2.2 7B500", "k48ap 4.2.1 8C148",
                    "k48ap 4.3.3 8J3", "k48ap 4.3.4 8K2", "k48ap 4.3.5 8L1", "k48ap 5.0 9A5220p", "k48ap 5.0 9A334"
                ]
            )
            #expect(
                c.entries.compactMap(\.prereleaseBadge) == ["beta 1", "beta 2", "beta 3", "GM 1", "GM 2", "beta 1"]
            )
        }
    }

    @Test func recipeForwardingKeepsAnExplicitBootPolicy() throws {
        let recipe = try JSONDecoder().decode(
            FirmwareCatalog.Entry.Recipe.self,
            from: Data(
                #"{"name":"k48","version":1,"storage":"nand","system_mib":1024,"data_size":"4G","options":{},"boot":"kernel"}"#
                    .utf8
            )
        )
        let forwarded = try JSONSerialization.jsonObject(with: JSONEncoder().encode(recipe)) as? [String: Any]
        #expect(forwarded?["boot"] as? String == "kernel")
    }

    /// The shipped catalog: every entry dated, versions ascending per board, dates ascending within a version, a
    /// version's betas and GMs before its release.
    @Test func shippedCatalogListsInVersionOrder() throws {
        let s = ShippedResources.catalog
        func version(_ v: String) -> [Int] { v.split(separator: ".").map { Int($0)! } }
        for board in Set(s.entries.map(\.board)) {
            let listed = s.entries.filter { $0.board == board }
            #expect(listed.allSatisfy { $0.released != nil }, "\(board): an undated entry")
            for (a, b) in zip(listed, listed.dropFirst()) {
                #expect(
                    !version(b.version).lexicographicallyPrecedes(version(a.version)),
                    "\(board): \(a.build) (\(a.version)) before \(b.build) (\(b.version))"
                )
                #expect(
                    a.version != b.version || a.released! <= b.released!,
                    "\(board) \(a.version): \(a.build) before \(b.build)"
                )
                #expect(
                    a.version != b.version || a.prerelease != nil || b.prerelease == nil,
                    "\(board) \(a.version): the release before \(b.build)"
                )
            }
        }
        let ipad = s.entries.filter { $0.board == "k48ap" }.map { "\($0.version) \($0.prereleaseBadge ?? "")" }
        #expect(
            Array(ipad.drop { $0 != "4.3.3 " }.prefix(5)) == ["4.3.3 ", "4.3.4 ", "4.3.5 ", "5.0 beta 1", "5.0 beta 5"]
        )
        #expect(
            s.entries.filter { $0.board == "n72ap" && $0.version == "4.1" }.map(\.build) == [
                "8B5080c", "8B5091b", "8B5097d", "8B117"
            ]
        )
        #expect(s.entries.allSatisfy { $0.prerelease == nil || $0.prereleaseBadge?.last?.isNumber == true })
    }

    // MARK: Schema

    static let raw =
        #"{"id":"k48ap-test","board":"k48ap","product_type":"iPad1,1","version":"5.0","build":"test","released":"2011-06-07","status":"experimental","status_note":"probe","prerelease":"beta","prerelease_number":3,"source":{"kind":"ipsw","url":"https://example.com/firmware.ipsw","sha1":"abc","bytes":123,"resource":"embedded.ipsw"},"keys":{"iBoot":{"file":"iBoot.img3","iv":"iv","key":"key"},"OS":{"file":"rootfs.dmg","key":"vf"}},"recipe":{"name":"k48","version":1,"storage":"nand","system_mib":100,"data_size":"1G","options":{"appsync":true},"guest":{"arch":"armv7","gl_engine":"native"},"boot":"iboot","keybag_ramdisk_from":"k48ap-sibling"},"emulator":{"min_protocol":9},"estimates":{"prepared_bytes":1234,"peak_bytes":5678,"seconds":90}}"#

    @Test func wireAndGUIProjectionKeepTheWholeFlatEntry() throws {
        let input = Data(Self.raw.utf8)
        let decoder = JSONDecoder()
        let encoder = JSONEncoder()
        let expected = try JSONSerialization.jsonObject(with: input) as! NSDictionary
        let wire = try decoder.decode(FirmwareWire.Entry.self, from: input)
        var gui = try decoder.decode(FirmwareCatalog.Entry.self, from: input)
        for data in [try encoder.encode(wire), try encoder.encode(gui)] {
            #expect(
                try JSONSerialization.jsonObject(with: data) as! NSDictionary == expected,
                "a flat wire field was lost"
            )
        }
        #expect(gui.profile == .k48 && gui.prereleaseBadge == "beta 3" && gui.status == .experimental)
        gui.recipe?.boot = "kboot"
        gui.source.resource = "other.ipsw"
        gui.status = .available
        let changed = try decoder.decode(FirmwareWire.Entry.self, from: encoder.encode(gui))
        #expect(
            changed.recipe?.boot == "kboot" && changed.source.resource == "other.ipsw" && changed.status == "available"
        )
    }

    /// Apps to manage from iPhone OS 2.0 through iOS 10; none on 1.x.
    @Test(arguments: [
        ("1.0", false), ("1.1.5", false), ("2.0", true), ("6.1.6", true), ("9.3.5", true), ("10.3.4", true)
    ])
    func managesAppsFromiPhoneOS2(_ version: String, _ manages: Bool) throws {
        var entry = try JSONDecoder().decode(FirmwareCatalog.Entry.self, from: Data(Self.raw.utf8))
        entry.version = version
        #expect(entry.managesApps == manages)
    }

    /// Preparation accepts future status and source tags; the GUI keeps its stricter presentation policy.
    @Test(arguments: [("experimental", "future"), ("\"kind\":\"ipsw\"", "\"kind\":\"future\"")])
    func futureTagsDecodeOnTheWireOnly(_ old: String, _ new: String) throws {
        let future = Data(Self.raw.replacingOccurrences(of: old, with: new).utf8)
        _ = try JSONDecoder().decode(FirmwareWire.Entry.self, from: future)
        #expect(throws: DecodingError.self) { try JSONDecoder().decode(FirmwareCatalog.Entry.self, from: future) }
    }

    @Test func shippedEntriesRoundTripThroughBothProjections() throws {
        for entry in ShippedResources.catalog.entries {
            let exported = try JSONEncoder().encode(entry)
            #expect(try JSONDecoder().decode(FirmwareCatalog.Entry.self, from: exported) == entry, "\(entry.id)")
            _ = try JSONDecoder().decode(FirmwareWire.Entry.self, from: exported)
        }
    }
}
