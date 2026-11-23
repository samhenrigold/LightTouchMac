import Foundation
import HostServiceClient
import SessionKit

@testable import LightTouchCore

// `sessions single --media FILE…` on iPhone OS 1.x, which has no guest agent: the files go in through the app's
// FirstGenLibrary (AFC while the device runs), the iTunesDB is read back over AFC, and Music (the iPhone's iPod) and
// Photos are opened from their Home icons, found by their labels, with what they show read off the screen.

/// What lockdown tells iTunes (`firstGenFacts`), Music opened once before the import (so the second opening says
/// whether a running Music takes a database written under it), each file imported (`mediaImport`), the database read
/// back (`firstGenLibrary`), and Music's and Photos' screens (`firstGenScreen`). `hash` "wrong" signs the database
/// for another device after the import (the negative check: 1.1.x must not list it), "none" leaves it unsigned;
/// LTM_FIRSTGEN_DB_VERSION writes it again at another mhbd version (the boot probe's). `titles`: boot 1's imports.
@MainActor func firstGenMedia(_ d: Device, files: [String], generation: Int, hash: String?, titles: inout [String])
    async
{
    let version = ProcessInfo.processInfo.environment["LTM_FIRSTGEN_DB_VERSION"].flatMap { UInt32($0, radix: 16) }
    let library = FirstGenLibrary(services: d.services)
    if generation == 1 {
        var facts: [String: Any] = ["device": d.name]
        for (key, domain) in [
            ("UniqueDeviceID", nil), ("ProductVersion", nil), ("FairPlayID", "com.apple.mobile.iTunes"),
            ("DBVersion", "com.apple.mobile.iTunes"), ("FireWireGUID", nil)
        ] {
            do { facts[key] = try await d.services.lockdownValue(key, domain: domain) ?? "(not a string)" } catch {
                facts[key] = "error: \(error)"
            }
        }
        for folder in ["", "iTunes_Control", "iTunes_Control/iTunes", "DCIM"] {
            facts["afc:" + folder] = (try? await d.services.files(in: folder).map(\.name).sorted()) ?? ["(none)"]
        }
        emit("firstGenFacts", facts)
        await firstGenScreen(d, app: ["iPod", "Music"], stage: "before", titles: [])
        for file in files {
            var fields: [String: Any] = ["device": d.name, "file": file]
            do {
                let media = try await PreparedMedia.prepare(URL(fileURLWithPath: file), profile: d.profile)
                fields["destination"] = media.destination
                fields["title"] = media.title
                if media.destination != "Photos" { titles.append(media.title) }
                try await library.add(media) { _ in }
                fields["ok"] = true
            } catch {
                fields["ok"] = false
                fields["error"] = "\(error)"
            }
            emit("mediaImport", fields)
        }
        if version != nil || hash != nil, let tracks = try? await library.tracks() {
            // the probe's variants: another database version, unsigned, or signed for another device
            var database = ITunesDB.make(tracks, version: version ?? ITunesDB.defaultVersion, databaseID: 7)
            if hash != "none" {
                let id = hash == "wrong" ? [1, 2, 3, 4, 5, 6, 7, 8] : try? await library.fireWireID()
                if let id { database = ITunesDB.signed(database, fireWireID: id) }
            }
            do { try await library.publish(database, signing: false) } catch {
                emit("firstGenVariant", ["device": d.name, "error": "\(error)"])
            }
        }
    }
    var read: [String: Any] = ["device": d.name, "generation": generation]
    var movies: Set<String> = []
    do {
        let tracks = try await library.tracks()
        read["titles"] = tracks.map(\.title)
        movies = Set(tracks.filter { $0.mediaType == ITunesDB.Track.movie }.map(\.title))
    } catch { read["error"] = "\(error)" }
    read["photos"] = (try? await d.services.files(in: FirstGenLibrary.photos).map(\.name).sorted()) ?? []
    emit("firstGenLibrary", read)
    let songs = titles.filter { !movies.contains($0) }
    if !songs.isEmpty || movies.isEmpty {
        await firstGenScreen(d, app: ["iPod", "Music"], stage: "music\(generation)", titles: songs)
    }
    // the iPod touch's Videos app, the iPhone's iPod's Videos tab
    let videos = titles.filter(movies.contains)
    if !videos.isEmpty {
        let app = d.profile == .m68 ? ["iPod"] : ["Videos"]
        await firstGenScreen(d, app: app, stage: "videos\(generation)", titles: videos, tabs: ["Videos", "Movies"])
    }
    if files.contains(where: { PreparedMedia.destination(forExtension: ($0 as NSString).pathExtension) == "Photos" }) {
        await firstGenScreen(d, app: ["Photos"], stage: "photos\(generation)", titles: [])
    }
}

/// One app opened from its Home icon (the first of `app`'s labels on the screen; the iPhone's dock label "iPod", which
/// the reader misses on the dock, at its dock slot; a tab named "Songs" tapped where the first screen doesn't show a
/// title, or another of `tabs`; Photos' first album opened), its screen read, then Home. Emits `firstGenScreen`.
@MainActor func firstGenScreen(
    _ d: Device,
    app: [String],
    stage: String,
    titles: [String],
    tabs: [String] = ["Songs", "Camera Roll", "Saved Photos"]
) async {
    var event: [String: Any] = ["device": d.name, "app": app[0], "stage": stage]
    func labels(_ shot: String) -> [(text: String, x: Double, y: Double)] {
        TextReader.read(URL(fileURLWithPath: shot), languageCorrection: false).map {
            ($0.text.trimmingCharacters(in: .whitespaces), $0.x, $0.y)
        }
    }
    // SpringBoard's "Sync in Progress" stays up a few seconds past syncDidFinish
    var home: [(text: String, x: Double, y: Double)] = []
    for attempt in 0..<6 {
        if attempt > 0 { try? await Task.sleep(for: .seconds(5)) }
        home = await d.wakeForShot("fg-\(stage)-home").map(labels) ?? []
        if !home.contains(where: { $0.text == "Sync in Progress" }) { break }
    }
    let dock = d.profile == .m68 && app.contains("iPod") ? (text: "iPod", x: 0.875, y: 0.985) : nil
    guard let icon = home.first(where: { app.contains($0.text) }) ?? dock else {
        event["error"] = "no \(app.joined(separator: "/")) icon on the Home screen"
        emit("firstGenScreen", event)
        return
    }
    // the label sits under its icon
    await d.tap(icon.x, icon.y - 0.05)
    try? await Task.sleep(for: .seconds(12))
    var seen: [String] = []
    for attempt in 0..<3 {
        guard let shot = d.screenshot("fg-\(stage)-\(app[0])-\(attempt)") else { break }
        let found = labels(shot)
        seen += found.map(\.text)
        if attempt > 0, app == ["Photos"] {
            guard attempt == 1 else { break }
            // the album's first photo, opened full size
            await d.tap(0.13, 0.22)
            try? await Task.sleep(for: .seconds(5))
            continue
        }
        if !titles.isEmpty, titles.allSatisfy({ title in seen.contains { $0.contains(title) } }) { break }
        guard
            let tab = found.first(where: { label in tabs.contains { label.text.hasPrefix($0) } })
        else { break }
        await d.tap(tab.x, tab.y)
        try? await Task.sleep(for: .seconds(5))
    }
    event["text"] = seen
    event["shows"] = titles.filter { title in seen.contains { $0.contains(title) } }
    emit("firstGenScreen", event)
    await d.home()
    try? await Task.sleep(for: .seconds(4))
}
