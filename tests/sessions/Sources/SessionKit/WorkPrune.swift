import Foundation

/// What a passed run leaves of its work directory: its logs, events and summary (text, by extension, up to `maxBytes`
/// each); overlays, NAND copies, the unpacked guest archive and frames go. A failed run keeps everything but its NAND
/// copies (nandCopies).
public enum WorkPrune {
    public static let kept: Set<String> = ["log", "jsonl", "json", "txt", "out", "err"]
    public static let maxBytes = 32 << 20

    public static func keeps(_ relativePath: String, bytes: Int) -> Bool {
        kept.contains((relativePath as NSString).pathExtension.lowercased()) && bytes <= maxBytes
    }

    /// The NAND copies under `work`, each directory named nand (a base's, an overlay's; symlinks not followed), sorted:
    /// what a failed run drops, a few GB each, where its logs, events and frames say what happened.
    public static func nandCopies(under work: URL) -> [URL] {
        guard let walk = FileManager.default.enumerator(at: work, includingPropertiesForKeys: [.isDirectoryKey]) else {
            return []
        }
        var out: [URL] = []
        for case let url as URL in walk where url.lastPathComponent == "nand" {
            guard (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true else { continue }
            out.append(url)
            walk.skipDescendants()
        }
        return out.sorted { $0.path < $1.path }
    }

    /// The regular files under `work` a passed run keeps, as paths relative to it (symlinks not followed), sorted.
    public static func kept(under work: URL) -> [String] {
        let root = work.resolvingSymlinksInPath().path + "/"
        guard
            let walk = FileManager.default.enumerator(
                at: work,
                includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey]
            )
        else { return [] }
        var out: [String] = []
        for case let url as URL in walk {
            let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            guard values?.isRegularFile == true else { continue }
            let path = url.resolvingSymlinksInPath().path
            guard path.hasPrefix(root) else { continue }
            let relative = String(path.dropFirst(root.count))
            if keeps(relative, bytes: values?.fileSize ?? .max) { out.append(relative) }
        }
        return out.sorted()
    }
}
