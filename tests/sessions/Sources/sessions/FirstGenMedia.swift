import Foundation
import SessionKit

/// `single --media` on iPhone OS 1.x (session-driver firstgen.swift): every file imported over AFC; the iTunesDB read
/// back lists each song and video and DCIM each photo, at every boot; and Music shows each title, every time it is
/// opened after the import. `wrongHash`: the database was signed for another device, and Music must show none.
func judgeFirstGenMedia(_ r: Report, _ d: String, events: Events, wrongHash: Bool) {
    if let facts = events.find("firstGenFacts", ["device": d]).first {
        let keys = ["ProductVersion", "UniqueDeviceID", "FairPlayID", "DBVersion", "FireWireGUID"]
        print("   lockdown: " + keys.map { "\($0) \(facts.string($0) ?? "?")" }.joined(separator: ", "))
        print("   afc: \(facts["afc:"] ?? []) iTunes_Control \(facts["afc:iTunes_Control"] ?? [])")
    }
    let imports = events.find("mediaImport", ["device": d])
    for e in imports {
        r.check(
            e.bool("ok"),
            "\(d): \(e.string("destination") ?? "?") imports “\(e.string("title") ?? e.string("file") ?? "?")” over AFC"
                + (e.string("error").map { ": \($0)" } ?? "")
        )
    }
    let titles = imports.filter { $0.string("destination") != "Photos" }.compactMap { $0.string("title") }
    let photos = imports.filter { $0.string("destination") == "Photos" }.count
    let reads = events.find("firstGenLibrary", ["device": d])
    r.check(!reads.isEmpty, "\(d): the iTunesDB was read back")
    for e in reads {
        let listed = e["titles"] as? [String] ?? []
        let originals = (e["photos"] as? [String] ?? []).filter { $0.uppercased().hasSuffix(".JPG") }.count
        r.check(
            titles.allSatisfy(listed.contains) && originals >= photos && !e.has("error"),
            "\(d): boot \(e.int("generation") ?? 0): the iTunesDB lists \(listed), DCIM holds \(originals) photos"
                + (e.string("error").map { ": \($0)" } ?? "")
        )
    }
    // Each boot's song and video screens (session-driver firstGenMedia: Music, and Videos or the iPod's Videos tab)
    let screens = events.find("firstGenScreen", ["device": d]).filter { $0.string("stage") != "before" }
    let boots = Dictionary(grouping: screens.filter { $0.string("stage")?.hasPrefix("photos") == false }) {
        String(($0.string("stage") ?? "").drop { $0.isLetter })
    }
    for (boot, shown) in boots.sorted(by: { $0.key < $1.key }) {
        let shows = shown.flatMap { $0["shows"] as? [String] ?? [] }
        let errors = shown.compactMap { $0.string("error") }
        r.check(
            errors.isEmpty && (wrongHash ? shows.isEmpty : Set(shows) == Set(titles)),
            "\(d): boot \(boot): Music and Videos show \(shows)"
                + (wrongHash ? " (signed for another device: none)" : " of \(titles)")
                + (errors.isEmpty ? "" : ": " + errors.joined(separator: "; "))
        )
    }
    r.check(!boots.isEmpty, "\(d): Music was opened after the import")
    // the iPhone's Camera Roll is DCIM (the iPod touch's Photos on 1.x lists only what iTunes syncs, not DCIM)
    for e in screens where photos > 0 && e.string("stage")?.hasPrefix("photos") == true {
        let text = e["text"] as? [String] ?? []
        r.check(
            text.contains { $0.hasPrefix("Camera Roll") } && !text.contains("No Photos"),
            "\(d): \(e.string("stage") ?? "?"): Photos opens its Camera Roll (\(text.prefix(6).joined(separator: " | ")))"
        )
    }
}
