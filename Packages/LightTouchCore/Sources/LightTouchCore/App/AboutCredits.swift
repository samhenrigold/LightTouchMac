import Foundation

/// About Light Touch's credits: the bundled components with their versions (build-inputs.json `components`, written
/// by scripts/vendor; a development build has none), the open-source projects it includes, each linked to its site
/// with its license, and a link that opens the Licenses window (`licensesLink`). The app styles the runs (AboutPanel).
public enum AboutCredits {
    public struct Run: Equatable {
        public var text: String
        public var isHeading = false
        public var link: URL?
        /// Secondary text (a project's license).
        public var isDetail = false
    }

    /// An open-source project Light Touch includes. `directory`: its folder under the bundled licenses/.
    public struct Project: Equatable, Sendable {
        public let name: String
        public let site: URL
        public let license: String
        public let directory: String
    }

    public static let projects: [Project] = [
        Project("QEMU", "https://www.qemu.org", "GPL-2.0", "qemu"),
        Project("qemu-ios", "https://github.com/devos50/qemu-ios", "GPL-2.0", "qemu"),
        Project("libimobiledevice", "https://libimobiledevice.org", "LGPL-2.1", "libimobiledevice"),
        Project(
            "libimobiledevice-glue",
            "https://github.com/libimobiledevice/libimobiledevice-glue",
            "LGPL-2.1",
            "libimobiledevice-glue"
        ),
        Project("libusbmuxd", "https://github.com/libimobiledevice/libusbmuxd", "LGPL-2.1", "libusbmuxd"),
        Project("inetcat", "https://github.com/libimobiledevice/libusbmuxd", "GPL-2.0-or-later", "inetcat"),
        Project("libplist", "https://github.com/libimobiledevice/libplist", "LGPL-2.1", "libplist"),
        Project("libtatsu", "https://github.com/libimobiledevice/libtatsu", "LGPL-2.1", "libtatsu"),
        Project("usbmuxd (Light Touch’s fork)", "https://github.com/samhenrigold/usbmuxd", "GPL-3.0", "usbmuxd"),
        Project("GLib", "https://gitlab.gnome.org/GNOME/glib", "LGPL-2.1", "glib"),
        Project("proxy-libintl", "https://github.com/frida/proxy-libintl", "LGPL-2.0", "proxy-libintl"),
        Project("FFmpeg", "https://ffmpeg.org", "LGPL-2.1", "ffmpeg"),
        Project("libslirp", "https://gitlab.freedesktop.org/slirp/libslirp", "BSD-3-Clause", "libslirp"),
        Project("PCRE2", "https://github.com/PCRE2Project/pcre2", "BSD-3-Clause", "pcre2"),
        Project("pixman", "https://pixman.org", "MIT", "pixman"),
        Project("OpenSSL", "https://www.openssl.org", "Apache-2.0", "openssl"),
        Project(
            "Nettle",
            "https://www.lysator.liu.se/~nisse/nettle/",
            "LGPL-3.0-or-later or GPL-2.0-or-later",
            "nettle"
        ),
        Project("PowerVR SDK", "https://github.com/powervr-graphics/Native_SDK", "MIT", "powervr"),
        Project("ANGLE", "https://chromium.googlesource.com/angle/angle", "BSD-3-Clause", "angle"),
        Project("Abseil", "https://abseil.io", "Apache-2.0", "angle"),
        Project("zlib", "https://zlib.net", "Zlib", "angle"),
        Project("iBoot32Patcher", "https://github.com/LukeZGD/iBoot32Patcher", "GPL-3.0", "iBoot32Patcher"),
        Project("Unrar.swift", "https://github.com/mtgto/Unrar.swift", "MIT", "swift/Unrar.swift"),
        Project("UnRAR", "https://www.rarlab.com/rar_add.htm", "UnRAR license", "swift/Unrar.swift"),
        Project("ZIPFoundation", "https://github.com/weichsel/ZIPFoundation", "MIT", "swift/ZIPFoundation"),
        Project("Swift Crypto", "https://github.com/apple/swift-crypto", "Apache-2.0", "swift/swift-crypto"),
        Project("SwiftASN1", "https://github.com/apple/swift-asn1", "Apache-2.0", "swift/swift-asn1"),
        Project(
            "Swift Argument Parser",
            "https://github.com/apple/swift-argument-parser",
            "Apache-2.0",
            "swift/swift-argument-parser"
        ),
        Project(
            "Swift Binary Parsing",
            "https://github.com/apple/swift-binary-parsing",
            "Apache-2.0",
            "swift/swift-binary-parsing"
        ),
        Project("Swift System", "https://github.com/apple/swift-system", "Apache-2.0", "swift/swift-system"),
        Project("Subprocess", "https://github.com/swiftlang/swift-subprocess", "Apache-2.0", "swift/swift-subprocess"),
        Project("Sparkle", "https://github.com/sparkle-project/Sparkle", "MIT", "swift/Sparkle"),
        Project("TelemetryDeck SDK", "https://github.com/TelemetryDeck/SwiftSDK", "MIT", "swift/SwiftSDK")
    ]

    /// The credits' last link: the app opens its Licenses window for it.
    public static let licensesLink: URL = {
        guard let url = URL(string: "x-lighttouch-about:licenses") else {
            preconditionFailure("The licenses link is a constant, valid URL")
        }
        return url
    }()

    /// `licenses`: the bundle has its licenses/ (a release does; a development build may not), for Show Licenses.
    public static func runs(buildInputs: Data?, licenses: Bool) -> [Run] {
        var out: [Run] = []
        let components =
            buildInputs.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }?["components"]
            as? [String: String] ?? [:]
        if !components.isEmpty {
            let first = ["qemu-ios", "usbmuxd", "guest tools"]
            let names =
                first.filter { components[$0] != nil }
                + components.keys.filter { !first.contains($0) }.sorted {
                    $0.localizedCaseInsensitiveCompare($1) == .orderedAscending
                }
            out.append(Run(text: "Components\n", isHeading: true))
            out.append(
                Run(
                    text: names.compactMap { name in components[name].map { "\(name) \($0)" } }.joined(separator: "\n")
                        + "\n\n"
                )
            )
        }
        out.append(Run(text: "Open-Source Software\n", isHeading: true))
        for project in projects {
            out.append(Run(text: project.name, link: project.site))
            out.append(Run(text: "\t\(project.license)\n", isDetail: true))
        }
        if licenses { out.append(Run(text: "\nShow Licenses", link: licensesLink)) }
        return out
    }

    // MARK: - The Licenses window

    /// One entry of the Licenses window: a folder of licenses/ and its files' text.
    public struct License: Identifiable, Equatable, Sendable {
        public var id: String { directory }
        public let name: String
        public let directory: String
        /// Each license or source note, under its file name.
        public let text: String
    }

    /// Every folder of `root` (licenses/, and each package of licenses/swift) with its licenses and source notes,
    /// named after the projects it covers; the patches, scripts and sources beside them are left out.
    public static func licenses(in root: URL) -> [License] {
        let fm = FileManager.default
        func folders(_ url: URL) -> [String] {
            ((try? fm.contentsOfDirectory(atPath: url.path)) ?? []).filter {
                var isDirectory: ObjCBool = false
                return fm.fileExists(atPath: url.appendingPathComponent($0).path, isDirectory: &isDirectory)
                    && isDirectory.boolValue
            }
        }
        let directories = folders(root).flatMap {
            $0 == "swift" ? folders(root.appendingPathComponent("swift")).map { "swift/" + $0 } : [$0]
        }
        let code: Set = ["patch", "c", "h", "cpp", "sh", "swift"]
        return directories.compactMap { directory -> License? in
            let folder = root.appendingPathComponent(directory)
            let files = ((try? fm.contentsOfDirectory(atPath: folder.path)) ?? [])
                .filter { !code.contains(($0 as NSString).pathExtension.lowercased()) && !$0.hasPrefix(".") }
                .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
            let text = files.compactMap { name in
                (try? String(contentsOf: folder.appendingPathComponent(name), encoding: .utf8)).map {
                    "\(name)\n\n\($0)"
                }
            }.joined(separator: "\n\n")
            guard !text.isEmpty else { return nil }
            let names = projects.filter { $0.directory == directory }.map(\.name)
            return License(
                name: names.isEmpty ? (directory as NSString).lastPathComponent : names.joined(separator: " and "),
                directory: directory,
                text: text
            )
        }
        .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
}

extension AboutCredits.Project {
    fileprivate init(_ name: String, _ site: String, _ license: String, _ directory: String) {
        guard let url = URL(string: site) else { preconditionFailure("\(name)'s site is a constant, valid URL") }
        self.init(name: name, site: url, license: license, directory: directory)
    }
}
