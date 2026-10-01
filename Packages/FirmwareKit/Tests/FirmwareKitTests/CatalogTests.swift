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
            struct Catalog: Encodable { var format: Int; var entries: [FirmwareEntry] }
            for invalid in [Catalog(format: 1, entries: [entry, entry]), Catalog(format: 2, entries: [entry])] {
                try JSONEncoder().encode(invalid).write(to: url)
                #expect(throws: FirmwareError.self) {
                    try FirmwareEntry.load(id: entry.id, fromCatalog: url)
                }
            }
        }
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
