// What a crash's call stack says with nothing about the Mac or its user in it: the crashed thread's top frame and its
// first frame in Light Touch's own code, each image+offset, which the release's dSYMs symbolicate. Two sources: the
// app's hangs and CPU spikes from MetricKit (MXCallStackTree.jsonRepresentation(), where a root frame's first subframe
// is its caller), and every one of its processes' crashes from macOS's crash reports (.ips), which macOS writes for a
// sandboxed child too: MetricKit sees the app's own process only.

import Foundation

public nonisolated enum CrashSummary {
    /// "frame" (the crashed thread's top) and "appFrame" (its first in `binary`), each "name+0xoffset"; either is
    /// missing when the tree has none.
    public static func frames(callStackTree json: Data, binary: String) -> [String: String] {
        guard let tree = try? JSONSerialization.jsonObject(with: json) as? [String: Any],
            let stacks = tree["callStacks"] as? [[String: Any]],
            let crashed = stacks.first(where: { $0["threadAttributed"] as? Bool == true }) ?? stacks.first
        else { return [:] }
        var frames: [[String: Any]] = []
        var next = (crashed["callStackRootFrames"] as? [[String: Any]])?.first
        while let frame = next {
            frames.append(frame)
            next = (frame["subFrames"] as? [[String: Any]])?.first
        }
        func text(_ frame: [String: Any]) -> String? {
            guard let name = frame["binaryName"] as? String,
                let offset = frame["offsetIntoBinaryTextSegment"] as? Int
            else { return nil }
            return "\(name)+0x\(String(offset, radix: 16))"
        }
        var summary: [String: String] = [:]
        summary["frame"] = frames.first.flatMap(text)
        summary["appFrame"] = frames.first { $0["binaryName"] as? String == binary }.flatMap(text)
        return summary
    }

    /// A macOS crash report (a JSON header line, then the JSON report): "process" (the executable's name),
    /// "exceptionType" and "signal", and "frame" and "appFrame" as above, from the uncaught exception's backtrace when
    /// there was one, else the faulting thread, its first in one of `ours`, each with its symbol when the report has
    /// one. Nothing else of the report (its paths, its crash reporter key, its abort message) is read.
    public static func report(ips: Data, ours: Set<String>) -> [String: String] {
        guard let contents = String(data: ips, encoding: .utf8), let newline = contents.firstIndex(of: "\n"),
            let report = try? JSONSerialization.jsonObject(with: Data(contents[contents.index(after: newline)...].utf8))
                as? [String: Any],
            let threads = report["threads"] as? [[String: Any]]
        else { return [:] }
        let images = (report["usedImages"] as? [[String: Any]] ?? []).map { $0["name"] as? String }
        let faulting = report["faultingThread"] as? Int ?? 0
        let frames =
            report["lastExceptionBacktrace"] as? [[String: Any]]
            ?? (threads.indices.contains(faulting) ? threads[faulting]["frames"] as? [[String: Any]] ?? [] : [])
        func image(_ frame: [String: Any]) -> String? {
            guard let index = frame["imageIndex"] as? Int, images.indices.contains(index) else { return nil }
            return images[index]
        }
        func text(_ frame: [String: Any]) -> String? {
            guard let name = image(frame), let offset = frame["imageOffset"] as? Int else { return nil }
            let symbol = (frame["symbol"] as? String).map { " \($0)" } ?? ""
            return String("\(name)+0x\(String(offset, radix: 16))\(symbol)".prefix(200))
        }
        let exception = report["exception"] as? [String: Any]
        var summary: [String: String] = [:]
        summary["process"] = report["procName"] as? String
        summary["build"] = (report["bundleInfo"] as? [String: Any])?["CFBundleVersion"] as? String
        summary["exceptionType"] = exception?["type"] as? String
        summary["signal"] = exception?["signal"] as? String
        summary["frame"] = frames.first.flatMap(text)
        summary["appFrame"] = frames.first { image($0).map(ours.contains) == true }.flatMap(text)
        return summary
    }
}
