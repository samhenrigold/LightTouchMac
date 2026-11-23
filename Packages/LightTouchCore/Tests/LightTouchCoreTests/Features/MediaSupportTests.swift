import Foundation
import Testing

@testable import LightTouchCore

/// Which libraries each catalog firmware may add media to (MediaSupport), against the builds the guest helpers have
/// been verified on (qemu-ios contrib/it-media/README.md and its booted round trips). Fails when an unverified
/// firmware is offered an import, a verified one is refused, or the refusal loses its plain words.
struct MediaSupportTests {
    /// Every catalog entry's verified destinations; anything not listed takes none. Booted round trips (`sessions
    /// single --media`: a song, a movie and a photo imported and read back from the libraries' databases, with Music
    /// open; on 3.1.3, 4.2.1, 4.3, 4.3.5, 5.1.1, 6.1.6 and 7.1.2 also after a reboot) on n72ap 7E18 and 8C148, n88ap
    /// and n18ap 7E18, k48ap 7B500, 8C148, 8L1 and 9B206, n88ap 8A293 to 8C148a, 8F190, 8L1, 9A334 to 9B206 and 10A403
    /// to 10B500, n18ap 8C148, 9A334 and 9B206, n81ap 9A334 and 10A523 to 10B500, n90ap 8C148, 9B206, 10B329, 11A465
    /// and 11D257; a build's other boards and the releases between those take the same helpers. qemu-ios
    /// contrib/it-media/README.md.
    static let all: Set<String> = ["Music", "Videos", "Photos"]
    static let verified: [String: Set<String>] = Dictionary(
        uniqueKeysWithValues: [
            "k48ap-7B367", "k48ap-7B405", "k48ap-7B500", "n72ap-7C145", "n72ap-7D11", "n72ap-7E18",
            "n88ap-7C144", "n88ap-7D11", "n88ap-7E18", "n18ap-7C145", "n18ap-7C146", "n18ap-7D11", "n18ap-7E18",
            "k48ap-8C148", "n72ap-8A293", "n72ap-8A400", "n72ap-8B117", "n72ap-8C148", "n18ap-8A293", "n18ap-8A400",
            "n18ap-8B117", "n18ap-8C148", "n81ap-8B117", "n81ap-8B118", "n81ap-8C148", "n88ap-8A293", "n88ap-8A306",
            "n88ap-8A400", "n88ap-8B117", "n88ap-8C148", "n88ap-8C148a", "n90ap-8A293", "n90ap-8A306", "n90ap-8A400",
            "n90ap-8B117", "n90ap-8C148",
            "k48ap-8F190", "k48ap-8G4", "k48ap-8H7", "k48ap-8J3", "k48ap-8K2", "k48ap-8L1", "n18ap-8F190", "n18ap-8G4",
            "n18ap-8H7", "n18ap-8J2", "n18ap-8K2", "n18ap-8L1", "n81ap-8F190", "n81ap-8G4", "n81ap-8H7", "n81ap-8J2",
            "n81ap-8K2", "n81ap-8L1", "n88ap-8F190", "n88ap-8G4", "n88ap-8H7", "n88ap-8J2", "n88ap-8K2", "n88ap-8L1",
            "n90ap-8F190", "n90ap-8G4", "n90ap-8H7", "n90ap-8J2", "n90ap-8K2", "n90ap-8L1",
            "k48ap-9A334", "k48ap-9A405", "k48ap-9B176", "k48ap-9B206", "n18ap-9A334", "n18ap-9A405", "n18ap-9B176",
            "n18ap-9B206", "n81ap-9A334", "n81ap-9A405", "n81ap-9B176", "n81ap-9B206", "n88ap-9A334", "n88ap-9A405",
            "n88ap-9B176", "n88ap-9B206", "n90ap-9A334", "n90ap-9A405", "n90ap-9B176", "n90ap-9B206", "n90ap-9B208",
            "n81ap-10A403", "n81ap-10A523", "n81ap-10B144", "n81ap-10B146", "n81ap-10B329", "n81ap-10B400",
            "n81ap-10B500", "n88ap-10A403", "n88ap-10A523", "n88ap-10B141", "n88ap-10B146", "n88ap-10B329",
            "n88ap-10B500", "n90ap-10A403", "n90ap-10A523", "n90ap-10B144", "n90ap-10B146", "n90ap-10B329",
            "n90ap-11A465", "n90ap-11A501", "n90ap-11B511", "n90ap-11B554a", "n90ap-11B651", "n90ap-11D169",
            "n90ap-11D201", "n90ap-11D257"
        ].map { ($0, all) }
    )
    /// iPhone OS 1.x through FirstGenLibrary (`sessions single --media` with a song, a movie and a photo, each shown
    /// in Music, Videos or Photos: the iPhone's Camera Roll, the iPod touch's Photo Library, iTunes' Photo Database).
    static let firstGeneration: [String: Set<String>] = ["m68ap-1A543a": all, "n45ap-4A102": all]
    static let nouns = ["Music": "music", "Videos": "videos", "Photos": "photos"]

    struct Entry: Decodable {
        let id: String
        let version: String
        let media: [String]?
        let prerelease: String?
    }
    struct Catalog: Decodable { let entries: [Entry] }

    @Test func everyCatalogFirmware() throws {
        let entries = try JSONDecoder().decode(
            Catalog.self,
            from: Data(
                contentsOf: repositoryRoot.appendingPathComponent("LightTouchMac/Resources/firmware-catalog.json")
            )
        ).entries
        #expect(entries.count > 10)
        #expect(
            Set(Self.verified.keys).union(Self.firstGeneration.keys).isSubset(of: Set(entries.map(\.id))),
            "a verified firmware left the catalog"
        )
        for entry in entries {
            let firmware = MediaSupport.Firmware(
                version: entry.version,
                name: "iOS \(entry.version)",
                media: entry.media ?? [],
                prerelease: entry.prerelease != nil
            )
            let want = Self.verified[entry.id] ?? Self.firstGeneration[entry.id] ?? []
            for destination in ["Music", "Videos", "Photos"] {
                #expect(
                    MediaSupport.supports(destination, on: firmware) == want.contains(destination),
                    "\(entry.id) \(destination)"
                )
                #expect(
                    MediaSupport.refusal(destination, on: firmware)
                        == (want.contains(destination)
                            ? nil : "Adding \(Self.nouns[destination]!) isn’t supported on iOS \(entry.version) yet."),
                    "\(entry.id) \(destination)"
                )
            }
            #expect(MediaSupport.supportsAny(firmware) == !want.isEmpty, "\(entry.id): Import Media…")
        }
    }
}
