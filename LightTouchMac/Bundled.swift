// Created by Sam on 2026-08-05.
//
// Where the things the app ships actually live.
//
// A packaged LightTouchMac is meant to be self-contained: someone who has never
// heard of Homebrew should be able to drag it to /Applications and have app
// installs, the SSH terminal and the home-screen placeholder all work. So every
// external binary and library is looked for INSIDE the bundle first —
// Contents/Resources/tools for executables and scripts, Contents/Frameworks for
// dylibs — and only then in the places a development checkout keeps them.
//
// Run from Xcode there is nothing in the bundle and the checkout answers every
// time; scripts/package.sh is what fills it in for a shippable build. Keeping
// the search order the same in both means the packaged app exercises the same
// code paths the dev build does, rather than a packaging-only branch nobody
// runs until it breaks.

import Foundation

/// Nonisolated: the project defaults to MainActor, and these are read from the
/// detached tasks that do the blocking device work as well as from the UI.
nonisolated enum Bundled {

    /// Executables and scripts shipped with the app.
    static let toolsDirectory = Bundle.main.resourceURL?
        .appendingPathComponent("tools", isDirectory: true).path

    /// Dylibs shipped with the app, where package.sh repoints @rpath.
    static let frameworksDirectory = Bundle.main.privateFrameworksPath

    /// A shipped executable or script, or nil when this build has none — in
    /// which case the caller falls back to a checkout path.
    static func tool(_ name: String) -> String? {
        guard let toolsDirectory else { return nil }
        let path = "\(toolsDirectory)/\(name)"
        return FileManager.default.isExecutableFile(atPath: path) ? path : nil
    }

    /// The first of `candidates` that exists, bundle copy first.
    static func resolve(_ name: String, fallbacks candidates: [String]) -> String? {
        tool(name) ?? candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// Directories to search for command-line tools, ours before anyone's.
    static var binarySearchPaths: [String] {
        [toolsDirectory, "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin"].compactMap { $0 }
    }
}
