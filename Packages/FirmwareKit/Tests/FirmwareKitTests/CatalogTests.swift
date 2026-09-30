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
}
