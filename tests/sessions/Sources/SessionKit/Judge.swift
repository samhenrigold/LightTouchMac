import Foundation

/// One line of a driver's JSON output.
public typealias Event = [String: Any]

extension Dictionary where Key == String, Value == Any {
    public func string(_ key: String) -> String? { self[key] as? String }
    public func double(_ key: String) -> Double? { (self[key] as? NSNumber)?.doubleValue }
    public func int(_ key: String) -> Int? { (self[key] as? NSNumber)?.intValue }
    public func bool(_ key: String) -> Bool { (self[key] as? NSNumber)?.boolValue ?? false }
    public func has(_ key: String) -> Bool { self[key] != nil && !(self[key] is NSNull) }
}

/// A driver run's events, with lookups by name and field values.
public struct Events {
    public var all: [Event]
    public init(_ all: [Event]) { self.all = all }

    /// The JSON lines of `text`; any other line becomes a `text` event.
    public init(jsonLines text: String) {
        all = text.split(separator: "\n").map { line in
            (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? Event ?? [
                "event": "text", "text": String(line)
            ]
        }
    }

    /// Events named `name` whose fields equal `match` (compared as their descriptions).
    public func find(_ name: String, _ match: [String: Any] = [:]) -> [Event] {
        all.filter { e in e.string("event") == name && match.allSatisfy { k, v in e[k].map { "\($0)" } == "\(v)" } }
    }
    public func one(_ name: String, _ match: [String: Any] = [:]) -> Event { find(name, match).first ?? [:] }
    public func any(_ name: String) -> Bool { !find(name).isEmpty }
}

/// ok/FAIL lines and the tally.
public final class Report {
    public private(set) var passed = 0, failed = 0
    /// Every line printed, for the run's summary.txt.
    public private(set) var lines: [String] = []
    public init() {}
    @discardableResult
    public func check(_ ok: Bool, _ what: @autoclosure () -> String) -> Bool {
        if ok { passed += 1 } else { failed += 1 }
        if !ok, firstFailure == nil { firstFailure = what() }
        lines.append("  \(ok ? "ok  " : "FAIL") \(what())")
        print(lines.last!)
        fflush(stdout)
        return ok
    }
    public func note(_ text: String) {
        lines.append("  --   \(text)")
        print(lines.last!)
        fflush(stdout)
    }
    public var allPassed: Bool { failed == 0 && passed > 0 }
    public var summary: String { "\(passed)/\(passed + failed) passed" }
    /// The first check that failed.
    public private(set) var firstFailure: String?
    /// The run's last line: `PASS <summary> <log>` or `FAIL <first failure> (<summary>) <log>`.
    public func verdict(log: String) -> String {
        allPassed
            ? "PASS \(summary) \(log)" : "FAIL \(firstFailure ?? "no check ran") (\(summary)) \(log)"
    }
}

/// The checks' own verdicts over a prepared base and its boot.
public enum SessionJudge {
    /// The Home screen judged independently of panel liveness: dark shots, a wrong frontmost app, the lock screen (the
    /// agent's screen name), an agent that never answered, a frame that differs from its reference (matrix-refs) all
    /// fail; a build without an agent and without a reference is unknown (nil). Stock 2.x has no guest agent, so a
    /// known-good picture is its evidence; a lit Connect-to-iTunes screen alone never qualifies as home.
    public static func home(lock: [String: Any], events: Events, entryID: String, references: URL) -> (
        ok: Bool?, detail: String
    ) {
        let package = lock["guest_package"] as? [String: Any] ?? [:]
        let derived = lock["derived"] as? [String: Any] ?? [:]
        let hasAgent =
            (package["jobs"] as? [String] ?? []).contains("com.qemu.it-agent.plist")
            || (derived.string("guest_tools") ?? "").hasPrefix("installed")
        var shots: [String: Event] = [:]
        for e in events.find("screenshot") {
            if let path = e.string("path") {
                shots[URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent] = e
            }
        }
        let homes = events.find("home")
        let names = ["home", "home2", "installed"].filter { shots[$0] != nil }
        guard !names.isEmpty else { return (nil, "no home screenshot taken") }
        let dark = names.filter { (shots[$0]?.double("brightness") ?? 0) < 0.05 }
        let wrong = homes.compactMap { h -> String? in
            guard let front = h.string("frontmost"), !front.isEmpty, front != "com.apple.springboard" else {
                return nil
            }
            return front
        }
        let locked = homes.filter {
            $0.string("frontmost") == "com.apple.springboard" && $0.string("screen") != "Home Screen"
        }
        .map { $0.int("generation") ?? 1 }
        let unanswered = homes.filter { hasAgent && ($0.string("frontmost") ?? "").isEmpty }.map {
            $0.int("generation") ?? 1
        }
        // The references are English Home screens: a base prepared in another language (create --language) has its
        // own labels, so only the agent judges it.
        let language = derived.string("language").map { String($0.prefix { $0 != "," }) } ?? "en"
        var frames: [String: FrameCheck.Verdict] = [:]
        for name in names where language == "en" {
            let ref = references.appendingPathComponent("\(entryID)-\(name).png")
            if FileManager.default.fileExists(atPath: ref.path), let path = shots[name]?.string("path") {
                frames[name] = FrameCheck.verdict(capture: URL(fileURLWithPath: path), reference: ref)
            }
        }
        let badFrames = frames.filter { !$0.value.ok }.keys.sorted()
        let observed = Set(
            homes.filter { !($0.string("frontmost") ?? "").isEmpty }.map { h -> String in
                let g = h.int("generation") ?? 1
                return g == 1 ? "home" : "home\(g)"
            }
        )
        let unknown = names.filter { $0.hasPrefix("home") && !hasAgent && !observed.contains($0) && frames[$0] == nil }
        let ok: Bool? =
            !dark.isEmpty || !wrong.isEmpty || !locked.isEmpty || !unanswered.isEmpty || !badFrames.isEmpty
            ? false
            : unknown.isEmpty ? true : nil
        var parts: [String] = []
        parts.append(
            "brightness "
                + names.map { "\($0) " + String(format: "%.3f", shots[$0]?.double("brightness") ?? -1) }.joined(
                    separator: ", "
                )
        )
        if !homes.isEmpty {
            parts.append(
                "frontmost "
                    + (hasAgent
                        ? homes.map { h in
                            [h.string("frontmost"), h.string("screen")].compactMap { $0?.isEmpty == false ? $0 : nil }
                                .joined(separator: " / ")
                        }.map { $0.isEmpty ? "no answer" : $0 }.joined(separator: ", ")
                        : "unknown (no guest agent on this build)")
            )
        }
        if !dark.isEmpty { parts.append("dark \(dark)") }
        if !wrong.isEmpty { parts.append("wrong app \(wrong)") }
        if !locked.isEmpty { parts.append("still locked on boot \(locked)") }
        if !unanswered.isEmpty { parts.append("agent unanswered on boot \(unanswered)") }
        if !unknown.isEmpty { parts.append("unjudged \(unknown) (no agent, no reference)") }
        for (name, v) in frames.sorted(by: { $0.key < $1.key }) { parts.append("frame \(name): \(v.why)") }
        if language != "en" { parts.append("frame not compared (references are English, the base is \(language))") }
        return (ok, parts.joined(separator: "; "))
    }

    /// The backlight level the board's own firmware programs at Brightness 100% (qemu_ios_ui_backlight_level's code),
    /// or nil where the emulator does not decode the backlight.
    public static func backlightTop(board: String, base: URL, productVersion: String) -> Int? {
        switch board {
        case "n45ap", "m68ap": return 0x2e  // ApplePCF50635PMUBacklight's "raw" table tops out at LEDOUT 0x2e
        case "n72ap": return 0xf5  // AppleD1759PMUBacklight at Brightness 1.0
        case "k48ap", "n81ap", "n90ap":
            // 6.x+ kernels step through the device tree's backlight-table (u16 codes, 0x7b3 at the n90's top); earlier
            // ones run the SWI level up to its full 11 bits. An iBoot base (firmwarekit's iPad, up to 5.1.1) has no
            // kboot.bin to read the tree from; its version says which.
            let major = Int(productVersion.split(separator: ".").first ?? "") ?? 0
            guard let kboot = try? Data(contentsOf: base.appendingPathComponent("kboot.bin")) else {
                return major < 6 ? 0x7ff : nil
            }
            func le(_ offset: Int, _ count: Int) -> Int {
                (0..<count).reduce(0) { $0 | Int(kboot[kboot.startIndex + offset + $1]) << (8 * $1) }
            }
            func property(_ key: String) -> Int? {
                var name = Data(key.utf8)
                name.append(Data(count: 32 - name.count))
                return kboot.range(of: name).map { $0.lowerBound - kboot.startIndex }
            }
            guard let start = property("backlight-table") else {
                // backlight-id 5 (the iPhone 4's panel, as iBoot fills it) picks AppleARMBacklight's backlight-5
                // table, which tops out at 0x7b3 as the 6.x+ device tree's does; any other runs the full 11 bits.
                return property("backlight-id").map { le($0 + 36, 4) } == 5 ? 0x7b3 : 0x7ff
            }
            let size = le(start + 32, 4) & 0x7fff_ffff
            return le(start + 36 + size - 2, 2)
        default: return nil
        }
    }

    /// Every path under a directory with its size, mode and modification time: a prepared base must not change.
    /// Finder's .DS_Store is left out: a window open on the folder rewrites it while a run boots.
    public static func tree(_ root: URL) -> [String: [Int]] {
        var out: [String: [Int]] = [:]
        guard let walk = FileManager.default.enumerator(atPath: root.path) else { return out }
        while let rel = walk.nextObject() as? String {
            if (rel as NSString).lastPathComponent == ".DS_Store" { continue }
            var st = stat()
            guard lstat(root.appendingPathComponent(rel).path, &st) == 0 else { continue }
            out[rel] = [
                Int(st.st_size), Int(st.st_mode),
                Int(st.st_mtimespec.tv_sec) * 1_000_000_000 + Int(st.st_mtimespec.tv_nsec)
            ]
        }
        return out
    }

    /// What changed between two trees, one phrase per path (at most `limit`).
    public static func treeDiff(_ before: [String: [Int]], _ after: [String: [Int]], limit: Int = 20) -> String {
        var lines: [String] = []
        for path in Set(before.keys).union(after.keys).sorted() where before[path] != after[path] {
            switch (before[path], after[path]) {
            case (nil, let b?): lines.append("added \(path) (size \(b[0]), mode \(String(b[1], radix: 8)))")
            case (_?, nil): lines.append("removed \(path)")
            case (let a?, let b?):
                let moved = zip(["size", "mode", "mtime_ns"], zip(a, b)).filter { $1.0 != $1.1 }.map {
                    "\($0) \($1.0)->\($1.1)"
                }
                lines.append("changed \(path): " + moved.joined(separator: ", "))
            default: break
            }
        }
        return lines.prefix(limit).joined(separator: "; ")
            + (lines.count > limit ? "; … \(lines.count - limit) more" : "")
    }
}
