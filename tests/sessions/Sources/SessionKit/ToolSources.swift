import BuildSupport
import Foundation

/// The inputs to the session helpers' shared build. Test edits don't change the tools that boot a device, so they
/// must not discard an otherwise reusable build. Manifests, resolutions, sources and build configuration do.
public enum ToolSources {
    private static let roots = [
        "LightTouchDevice", "LightTouchServices", "Configuration", "LightTouchMac.xcodeproj", "build-support"
    ]
    private static let paths =
        roots + [
            ":(glob)Packages/*/Package.swift", ":(glob)Packages/*/Package.resolved", ":(glob)Packages/*/Sources/**"
        ]

    /// Git's committed blobs and modes, or nil for dirty inputs or a Git failure. Ignored Local.xcconfig is keyed
    /// separately by the caller. NUL-separated paths keep spaces and newlines unambiguous.
    public static func committedTree(in repository: URL) -> String? {
        let git = ["/usr/bin/git", "-C", repository.path]
        guard let status = try? Shell.run(git + ["status", "--porcelain", "--untracked-files=all", "--"] + paths),
            status.succeeded, status.output.isEmpty,
            let tree = try? Shell.run(git + ["ls-tree", "-r", "-z", "HEAD", "--", "Packages"] + roots),
            tree.succeeded, !tree.output.isEmpty
        else { return nil }
        // ls-tree accepts literal paths, whereas status accepts wildcard pathspecs. Filter its package entries
        // by the same inputs instead of handing it a wildcard it cannot expand.
        let inputs = tree.output.split(separator: "\0").filter { entry in
            guard let path = entry.split(separator: "\t", maxSplits: 1).last else { return false }
            let parts = path.split(separator: "/")
            guard parts.first == "Packages" else { return true }
            return parts.count >= 3 && ["Sources", "Package.swift", "Package.resolved"].contains(parts[2])
        }
        return inputs.isEmpty ? nil : inputs.joined(separator: "\0")
    }
}
