// What a file dropped from outside the app is, by what takes it: an IPSW goes
// to the library, an .ipa or importable media to a running device, anything
// else is named as unsupported. The device screen, the app list, the sidebar
// and the placeholder share it; the drag and the pasteboard stay theirs.

import Foundation

nonisolated enum DroppedFiles: Equatable {
    case ipsw, ipa, media, unsupported

    init(_ url: URL) {
        switch url.pathExtension.lowercased() {
        case "ipsw": self = .ipsw
        case "ipa": self = .ipa
        case let suffix where PreparedMedia.extensions.contains(suffix): self = .media
        default: self = .unsupported
        }
    }

    /// The file URLs among `urls` of `kind`, in drop order.
    static func files(_ urls: [URL], _ kind: DroppedFiles) -> [URL] {
        urls.filter { $0.isFileURL && DroppedFiles($0) == kind }
    }
}
