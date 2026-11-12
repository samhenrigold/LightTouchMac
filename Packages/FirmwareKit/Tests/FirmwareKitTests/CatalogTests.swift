import Foundation
import Testing

@testable import FirmwareKit

struct CatalogTests {
    @Test func lookupRequiresOneEntryAndKnownFormat() throws {
        let entry = try FirmwareEntry.load(id: "k48ap-7B500", fromCatalog: Oracle.catalog)
        #expect(entry.board == "k48ap" && entry.build == "7B500")
        #expect(throws: FirmwareError.self) {
            try FirmwareEntry.load(id: "unknown", fromCatalog: Oracle.catalog)
        }
        try Oracle.withTemp { dir in
            let url = dir.appendingPathComponent("catalog.json")
            struct Catalog: Encodable {
                var format: Int
                var entries: [FirmwareEntry]
            }
            for invalid in [Catalog(format: 1, entries: [entry, entry]), Catalog(format: 2, entries: [entry])] {
                try JSONEncoder().encode(invalid).write(to: url)
                #expect(throws: FirmwareError.self) {
                    try FirmwareEntry.load(id: entry.id, fromCatalog: url)
                }
            }
        }
    }

    /// Every row with a data partition (the k48 recipe's boards) composites through the GL bridge: with ca_ogl off
    /// CoreAnimation draws in software, which on the Retina panels scrolls at a fraction of the frame rate (6.0 beta 1
    /// shipped that way), and the iPhone 3GS's 3.0 and 3.0.1 had it off untried.
    @Test func everyRowCompositesThroughTheGLBridge() throws {
        struct Catalog: Decodable { var entries: [FirmwareEntry] }
        let entries = try JSONDecoder().decode(Catalog.self, from: Data(contentsOf: Oracle.catalog)).entries
        let rows = entries.filter { $0.recipe?.dataSize == "partition" }
        #expect(rows.count > 250)
        let software = rows.filter { $0.recipe?.options["ca_ogl"] != true }.map(\.id)
        #expect(software.isEmpty, "\(software)")
    }

    /// Every row of a recipe has the recipe's options: the per-row flags left (appsync, web_proxy, ca_ogl, gles_shim)
    /// are facts of the recipe's board and preparation, so a row copied from a sibling can't quietly differ.
    /// The exceptions, each with its reason (none today):
    static let optionExceptions: [String: [String: Bool]] = [:]
    @Test func rowsOfARecipeShareItsOptions() throws {
        struct Catalog: Decodable { var entries: [FirmwareEntry] }
        let entries = try JSONDecoder().decode(Catalog.self, from: Data(contentsOf: Oracle.catalog)).entries
        var recipes: [String: [String: Bool]] = [:]
        var differ: [String] = []
        for e in entries where Self.optionExceptions[e.id] == nil {
            let name = try #require(e.recipe?.name)
            recipes[name] = recipes[name] ?? e.recipe?.options
        }
        for e in entries {
            let excepted = Self.optionExceptions[e.id] ?? [:]
            for (k, v) in excepted {
                #expect(e.recipe?.options[k] == v, "\(e.id): the exception \(k) \(v) no longer holds")
            }
            let mine = (e.recipe?.options ?? [:]).filter { excepted[$0.key] == nil }
            let shared = (recipes[e.recipe?.name ?? ""] ?? [:]).filter { excepted[$0.key] == nil }
            if mine != shared { differ.append("\(e.id) \(mine) vs \(shared)") }
        }
        #expect(differ.isEmpty, "\(differ)")
        #expect(recipes.count == 9)
    }

    /// Whether a device keeps BTServer is the board's machine's, never a row's: BTServer is kept where the machine
    /// answers the HCI on the DT's Bluetooth UART (KBoot.Board.bluetoothHCI, qemu-ios bt_uart), disabled elsewhere.
    /// A per-row `bluetooth` flag left the N18's 3.1.x without BTServer, and its status bar waited out two 5 s
    /// BTSessionAttach timeouts on every turn. The table is the emulator's (the A4 boards' UART is silent).
    static let machineAnswersHCI = ["k48ap": false, "n81ap": false, "n90ap": false, "n88ap": true, "n18ap": true]
    @Test func bluetoothIsTheBoardsMachine() throws {
        struct Catalog: Decodable { var entries: [FirmwareEntry] }
        let entries = try JSONDecoder().decode(Catalog.self, from: Data(contentsOf: Oracle.catalog)).entries
        let flagged = entries.filter { $0.recipe?.options["bluetooth"] != nil }.map(\.id)
        #expect(flagged.isEmpty, "\(flagged)")
        var judged = 0
        try Oracle.withTemp { dir in
            // the k48 recipe's boards (the iPhone 5's A6Preparation keeps its qualified options)
            for e in entries where e.recipe?.dataSize == "partition" && e.recipe?.name != "n42" {
                let o = Preparer.Options(entry: e, ipsw: dir, out: dir, helper: nil, guestTools: dir)
                let expected = try #require(Self.machineAnswersHCI[e.board], "\(e.id): no board fact")
                #expect(try K48Board(o).systemOptions.bluetooth == expected, "\(e.id)")
                judged += 1
            }
        }
        #expect(judged > 250)
    }

    /// What a release's iOS decides is decided by its version, as the boards that prepare the rows read it, never by a
    /// row's flag (which a new or copied row can get wrong; issue 97: six n88ap 3.1.x rows lacked data_journal false,
    /// mount_hfs refused their journaled data volume and /private/var stayed on the system volume for months). Every
    /// 3.0 and 3.1.x data volume is unjournaled, every later one journaled; data protection (its keybag one-shot and
    /// writable NOR) from 4.0 on, as the iPod touch 2G's and every k48-recipe board's; no row restates either.
    @Test func versionRulesDecideEveryRow() throws {
        struct Catalog: Decodable { var entries: [FirmwareEntry] }
        let entries = try JSONDecoder().decode(Catalog.self, from: Data(contentsOf: Oracle.catalog)).entries
        let restated = entries.filter { e in
            ["data_journal", "writable_nor", "data_protection"].contains { e.recipe?.options[$0] != nil }
        }
        #expect(restated.isEmpty, "\(restated.map(\.id))")
        var unjournaled: [String] = []
        var judged = 0
        try Oracle.withTemp { dir in
            for e in entries {
                let recipe = try #require(e.recipe)
                let o = Preparer.Options(entry: e, ipsw: dir, out: dir, helper: nil, guestTools: dir)
                let protected = !(e.version.hasPrefix("2.") || e.version.hasPrefix("3."))
                if recipe.name == "n72" {
                    #expect(try N72Board(o).dataProtection == protected, "\(e.id)")
                    judged += 1
                } else if recipe.dataSize == "partition" {
                    #expect(try K48Board(o).dataProtection == protected, "\(e.id)")
                    let journaled = SystemEdits.Options(recipe: recipe, version: e.version).dataJournal
                    if !journaled { unjournaled.append(e.id) }
                    #expect(
                        journaled == !(e.version.hasPrefix("3.0") || e.version.hasPrefix("3.1")),
                        "\(e.id) \(e.version): data volume journaled \(journaled)"
                    )
                    judged += 1
                }
            }
        }
        #expect(judged > 250 && unjournaled.count == 12, "\(judged) rows, unjournaled \(unjournaled)")
    }

    @Test func sharedWireKeepsMetadataAndFutureTags() throws {
        let original = try Oracle.entry("k48ap-7B500")
        var object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(original)) as! [String: Any]
        object["released"] = "2011-06-07"
        object["prerelease"] = "future-preview"
        object["prerelease_number"] = 4
        object["status"] = "future-status"
        var source = object["source"] as! [String: Any]
        source["resource"] = "embedded.ipsw"
        object["source"] = source
        var recipe = object["recipe"] as! [String: Any]
        recipe["boot"] = "kboot"
        recipe["keybag_ramdisk_from"] = "k48ap-sibling"
        object["recipe"] = recipe
        try Oracle.withTemp { dir in
            let url = dir.appendingPathComponent("entry.json")
            try JSONSerialization.data(withJSONObject: object).write(to: url)
            let entry = try FirmwareEntry.load(from: url)
            #expect(entry.status == "future-status" && entry.prerelease == "future-preview")
            #expect(entry.source.resource == "embedded.ipsw" && entry.recipe?.boot == "kboot")
            let again = try JSONSerialization.jsonObject(with: JSONEncoder().encode(entry)) as! NSDictionary
            #expect(again == object as NSDictionary)
        }
    }
}
