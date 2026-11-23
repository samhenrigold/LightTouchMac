// Which libraries a device's firmware can take media into, decided before
// anything is prepared, staged or spawned: itmedia adds to Music and Videos,
// itphoto to Saved Photos (qemu-ios contrib/it-media); on iPhone OS 1.x, which has
// no agent, FirstGenLibrary writes the iTunesDB and DCIM over AFC. A firmware outside
// what they have been qualified on gets a plain refusal on the job row.

import Foundation

public nonisolated enum MediaSupport {
    /// A device's firmware as the gate reads it: its marketing version, the name the sidebar shows, and the libraries
    /// the catalog qualifies its helpers on (the entry's `media`).
    public struct Firmware: Sendable, Equatable {
        public init(version: String, name: String, media: [String] = [], prerelease: Bool = false) {
            self.version = version
            self.name = name
            self.media = media
            self.prerelease = prerelease
        }
        public var version: String
        /// "iOS 5.0 beta 1"
        public var name: String
        /// The catalog entry's `media`: "Music", "Videos", "Photos".
        public var media: [String] = []
        /// A beta or GM: the helpers were qualified on releases only.
        public var prerelease = false
    }

    /// Whether this firmware's helpers can add to `destination` ("Music", "Videos", "Photos"): MusicLibrary's
    /// purchase-folder insert over the iTunes Library.itlp library (3.x to 4.2.1, where the helper writes as Music
    /// does), ML3's importer (4.3 over the itlp library, 5.x to 7.x), PLCameraAlbum's save with the saved path (3.x) and AssetsLibrary's, which
    /// names the saved asset (4.x on) (qemu-ios contrib/it-media/README.md); on 1.x FirstGenLibrary's iTunesDB (Music,
    /// Videos) and, for Photos, DCIM on the iPhone (its Camera Roll) and iTunes' Photo Database on the iPod touch. The catalog lists what a booted import has
    /// shown on each firmware.
    public static func supports(_ destination: String, on firmware: Firmware) -> Bool {
        !firmware.prerelease && firmware.media.contains(destination)
    }

    /// Whether any media can be added (the Import Media… command).
    public static func supportsAny(_ firmware: Firmware) -> Bool {
        ["Music", "Videos", "Photos"].contains { supports($0, on: firmware) }
    }

    /// nil when `destination` can be added to on this firmware; else the row's words.
    public static func refusal(_ destination: String, on firmware: Firmware) -> String? {
        guard !supports(destination, on: firmware) else { return nil }
        let what = ["Music": "music", "Videos": "videos", "Photos": "photos"][destination] ?? "media"
        return "Adding \(what) isn’t supported on \(firmware.name) yet."
    }
}
