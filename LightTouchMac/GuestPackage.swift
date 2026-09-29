// Guest packages (docs/guest-package-bootstrap.md, P5): the app's side.
//
// Each boot, the app composes Devices/<uuid>/work/guest-offer/ from the
// bundled Resources/guest/<arch>.itpack (qemu-ios contrib/guest-package/
// mkpkg.py `offer` is the reference) and passes it as the machine's
// guest-package= property. The baked loader it_boot pulls the offer over
// QC_PKG_*, installs or reverts, and REPORTs the serial now current; the
// helper publishes that in the status block. The app judges the session
// (good/bad) and records it in device.json `guest`, and the next offer
// carries those verdicts. No report: the image has no loader (legacy baked
// tools), and the app keeps them current itself (GuestServices).
//
// Foundation only, so tests compile it as the app does.

import CryptoKit
import Foundation

nonisolated enum GuestPackage {
    /// One package's manifest.json.
    struct Manifest: Codable, Sendable {
        struct Requires: Codable, Sendable {
            var boards: [String]
            var builds: [String]
            var host: [String: [Int]]?
        }
        struct File: Codable, Sendable {
            var name: String
            var mode: String
            var size: Int
            var sha256: String
        }
        struct Hook: Codable, Sendable {
            var file: String
            var target: String
            var gli: String?
            var respring: Bool
        }
        var serial: Int64
        var version: String
        var family: String
        var arch: String
        var stub: Bool?
        var requires: Requires
        var files: [File]
        var jobs: [String]
        var hooks: [Hook]
    }

    /// What was offered this boot.
    struct Offer: Sendable, Equatable {
        /// The bundled package's serial.
        var bundled: Int64
        var version: String
        /// 0 when the offer asks for the built-in (seed) package.
        var serial: Int64
        var glHook: Bool
    }

    /// The offer wire this app writes (it_boot's `ltpkg 1`), and the GL wire
    /// range the host serves (QC_GLES_HELLO; 0 is a shim without a hello).
    static let packageProtocol = 1
    static let glesProtocols = 0...0

    static let magic = Data("ITPACK01".utf8)

    /// it_boot's R_* report codes.
    enum ReportCode: Int32 {
        case unchanged = 0, installed, switched, revertedBad, revertedTries, refused
    }

    static func arch(board: String) -> String? { ["n72ap": "armv6", "k48ap": "armv7"][board] }

    /// The bundled itpack for an arch: the app's flat Resources/guest-tools (which
    /// firmwarekit also seeds from), else (development) LTM_GUEST_PACKAGE or a
    /// qemu-ios checkout's build/guest-package.
    static func bundledPack(arch: String, filesRoot: String, resources: URL? = Bundle.main.resourceURL) -> URL? {
        var candidates = [resources?.appendingPathComponent("guest-tools/\(arch).itpack")].compactMap { $0 }
        if let dir = ProcessInfo.processInfo.environment["LTM_GUEST_PACKAGE"] {
            candidates.append(URL(fileURLWithPath: dir).appendingPathComponent("\(arch).itpack"))
        }
        for checkout in ["qemu-ios-ipad1", "qemu-ios"] {
            candidates.append(URL(fileURLWithPath: filesRoot).deletingLastPathComponent()
                .appendingPathComponent("\(checkout)/build/guest-package/\(arch).itpack"))
        }
        return candidates.first { FileManager.default.isReadableFile(atPath: $0.path) }
    }

    // MARK: - itpack

    /// "ITPACK01", a little-endian u32 index length, the JSON index, then one zlib stream.
    static func read(_ url: URL) throws -> [(name: String, data: Data)] {
        func invalid(_ why: String) -> Error { DeviceToolsError.failed("\(url.lastPathComponent): \(why)") }
        let blob = try Data(contentsOf: url)
        guard blob.count >= 12, blob.prefix(8) == magic else { throw invalid("not an .itpack") }
        let n = Int(blob[blob.startIndex + 8]) | Int(blob[blob.startIndex + 9]) << 8
            | Int(blob[blob.startIndex + 10]) << 16 | Int(blob[blob.startIndex + 11]) << 24
        guard blob.count >= 12 + n + 2 else { throw invalid("truncated") }
        struct Index: Decodable { struct Entry: Decodable { var name: String; var size: Int }; var entries: [Entry] }
        let index = try JSONDecoder().decode(Index.self, from: blob.subdata(in: 12..<12 + n))
        // zlib's 2-byte header off: Compression's zlib is raw deflate (the adler trailer is ignored).
        let stream = try (blob.subdata(in: 12 + n + 2..<blob.count) as NSData).decompressed(using: .zlib) as Data
        var entries: [(String, Data)] = [], offset = 0
        for e in index.entries {
            guard !e.name.hasPrefix("/"), !e.name.split(separator: "/").contains(".."), e.size >= 0,
                  offset + e.size <= stream.count else { throw invalid("bad entry \(e.name)") }
            entries.append((e.name, stream.subdata(in: offset..<offset + e.size)))
            offset += e.size
        }
        guard offset == stream.count else { throw invalid("the index does not cover the stream") }
        return entries
    }

    /// mkpkg's requires.builds: an exact build id, or "<major>*" for every build of that iOS major (2.x = 5*,
    /// 3.x = 7*, 4.x = 8*), as FirmwareKit's GuestPackage.buildMatches.
    static func buildMatches(_ builds: [String], _ build: String) -> Bool {
        let major = build.prefix { $0.isNumber }
        return builds.contains { $0 == build || ($0.hasSuffix("*") && $0.dropLast() == major) }
    }

    /// The package in an itpack for this board and build, with its payloads by
    /// package path; nil when there is none (or only a stub).
    static func package(in itpack: URL, board: String, build: String) throws -> (Manifest, [String: Data])? {
        let entries = try read(itpack)
        for (name, data) in entries where name.hasSuffix("/manifest.json") {
            let manifest = try JSONDecoder().decode(Manifest.self, from: data)
            guard manifest.requires.boards.contains(board), buildMatches(manifest.requires.builds, build),
                  manifest.stub != true else { continue }
            let prefix = String(name.dropLast("manifest.json".count))
            var payloads: [String: Data] = [:]
            for (entry, bytes) in entries where entry.hasPrefix(prefix) && entry != name {
                payloads[String(entry.dropFirst(prefix.count))] = bytes
            }
            return (manifest, payloads)
        }
        return nil
    }

    // MARK: - Offer

    /// mkpkg.py offer_text: payload lines are indexed in manifest order.
    static func offerText(_ m: Manifest, build: String, serial: Int64? = nil, good: [Int64] = [], bad: [Int64] = []) -> String {
        var lines = ["ltpkg \(packageProtocol)", "build \(build)", "serial \(serial ?? m.serial) \(m.version)"]
        lines += good.map { "verdict good \($0)" } + bad.map { "verdict bad \($0)" }
        if serial == nil || serial == m.serial {
            let hooks = Dictionary(m.hooks.map { ($0.file, $0) }, uniquingKeysWith: { a, _ in a })
            for (i, f) in m.files.enumerated() {
                let kind = hooks[f.name] != nil ? "hook" : m.jobs.contains(f.name) ? "job" : "file"
                var line = "\(kind) \(i) \(f.name) \(f.mode) \(f.size) \(f.sha256)"
                if let hook = hooks[f.name] { line += " \(hook.target)" + (hook.respring ? " respring" : "") }
                lines.append(line)
            }
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// Write this boot's offer into `dir` (replacing it). `lock` is the
    /// preparer's record, when there is one: as its seed did, hooks for another
    /// GL dispatch table than the shim it installed, and hooks whose targets the
    /// device lacks (libappsync without AppSync), are dropped.
    /// Nil (and no directory) when the itpack has nothing for this device.
    static func compose(itpack: URL, board: String, build: String, lock: LockRecord?, guest: DeviceInstance.Guest?,
                        into dir: URL) throws -> Offer? {
        let fm = FileManager.default
        try? fm.removeItem(at: dir)
        guard let found = try package(in: itpack, board: board, build: build) else { return nil }
        var (manifest, payloads) = found
        if let range = manifest.requires.host?["guest-package"], range.count == 2,
           !(range[0]...range[1]).contains(packageProtocol) { return nil }
        if let lock {
            let dropped = Set(manifest.hooks.filter { hook in
                (hook.gli != nil && hook.gli != lock.gli) || (lock.hooks.map { !$0.contains(hook.target) } ?? false)
            }.map(\.file))
            manifest.hooks.removeAll { dropped.contains($0.file) }
            manifest.files.removeAll { dropped.contains($0.name) }
        }
        let builtIn = guest?.builtIn == manifest.serial
        let staging = dir.deletingLastPathComponent().appendingPathComponent(".\(dir.lastPathComponent)-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: staging) }
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        if !builtIn {
            for f in manifest.files {
                guard let data = payloads[f.name], data.count == f.size,
                      SHA256.hash(data: data).map({ String(format: "%02x", $0) }).joined() == f.sha256 else {
                    throw DeviceToolsError.failed("\(itpack.lastPathComponent): \(manifest.family)/\(f.name) does not match its manifest")
                }
                let url = staging.appendingPathComponent(f.name)
                try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try data.write(to: url)
            }
        }
        let text = offerText(manifest, build: build, serial: builtIn ? 0 : nil,
                             good: guest?.lastGood.map { [$0] } ?? [], bad: guest?.bad ?? [])
        try Data(text.utf8).write(to: staging.appendingPathComponent("offer"))
        try fm.moveItem(at: staging, to: dir)
        return Offer(bundled: manifest.serial, version: manifest.version, serial: builtIn ? 0 : manifest.serial,
                     glHook: !builtIn && manifest.hooks.contains { $0.gli != nil })
    }

    /// The preparer's record (device.lock.json `guest_package`).
    struct LockRecord: Equatable, Sendable {
        var seed: Int64?
        /// The GL dispatch id it installed a shim for; nil: none.
        var gli: String?
        /// The hook targets it kept (present on the volume); nil: not recorded.
        var hooks: [String]?
    }

    static func lockRecord(_ lock: URL) -> LockRecord? {
        guard let data = try? Data(contentsOf: lock),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let record = json["guest_package"] as? [String: Any] else { return nil }
        return LockRecord(seed: (record["seed"] as? NSNumber)?.int64Value, gli: record["gli"] as? String,
                          hooks: record["hooks"] as? [String])
    }

    // MARK: - Verdicts

    enum Verdict: Equatable, Sendable {
        case good(Int64)
        case bad(Int64)
        /// No report once healthy: the image has no loader.
        case legacy
        /// Stop judging this boot without a verdict.
        case undecided
    }

    /// Healthy for this long (UI up, the agent or lockdown answering) makes the
    /// reported package good; no report by then means no loader.
    static let goodAfter: Duration = .seconds(10), legacyAfter: Duration = .seconds(30)
    /// A package that isn't healthy this long after boot is bad.
    static let badAfter: Duration = .seconds(300)

    /// This boot's verdict so far; nil: keep watching. A restored session never
    /// re-runs the loader, so it has no report and says nothing about tools. Only
    /// a package that isn't the seed or the last good one can be judged bad.
    static func verdict(report: GuestPackageReport?, healthyFor: Duration, elapsed: Duration,
                        record: DeviceInstance.Guest?, restored: Bool) -> Verdict? {
        if let report, healthyFor >= goodAfter { return .good(report.serial) }
        if report == nil, healthyFor >= legacyAfter { return restored ? .undecided : .legacy }
        guard elapsed >= badAfter else { return nil }
        if let report, report.serial != record?.lastGood, report.serial != record?.seed { return .bad(report.serial) }
        return .undecided
    }

    // MARK: - State

    /// What the UI says about a device's guest tools: the "Guest tools" status line.
    enum Status: Equatable, Sendable {
        /// No offer (no itpack, an older dylib) or no report yet.
        case unknown
        /// No report after a healthy start: the image has no loader.
        case legacy
        case current(serial: Int64)
        /// The built-in (seed) package, on request.
        case builtIn(serial: Int64)
        /// The loader went back to an earlier package: `why` is its report code.
        case reverted(serial: Int64, why: ReportCode)
        /// Older than the bundled package, or a GL protocol the host doesn't serve.
        case outOfDate
        /// The agent went stale for over a minute, or the iPad's it_ethlink never came up.
        case notResponding
        /// iBoot entered recovery mode.
        case recovery
        /// lockdown hasn't answered yet.
        case notBooted

        var text: String {
            switch self {
            case .unknown: "Unknown"
            case .legacy: "Won’t update — erase and prepare again to get updates"
            case .current: "Up to date"
            case .builtIn: "Built in"
            case let .reverted(_, why):
                "Using an earlier version — " + (why == .revertedBad ? "the update didn’t work"
                                                  : why == .revertedTries ? "the update kept failing" : "the update was refused")
            case .outOfDate: "Out of date — restart to update"
            case .notResponding: "Not responding"
            case .recovery: "Unavailable in recovery mode"
            case .notBooted: "Waiting for iOS"
            }
        }
    }

    /// The UI state for a report (nil: none this boot) against the offer.
    static func status(report: GuestPackageReport?, offer: Offer?, record: DeviceInstance.Guest?,
                       glesProtocol: Int32) -> Status {
        guard let offer else { return report.map { .current(serial: $0.serial) } ?? .unknown }
        guard let report else {
            // A restored snapshot keeps running what the last cold boot installed.
            if let active = record?.active, active < offer.bundled, record?.bad.contains(offer.bundled) != true,
               record?.builtIn != offer.bundled { return .outOfDate }
            return .unknown
        }
        if !glesProtocols.contains(Int(glesProtocol)) { return .outOfDate }
        switch ReportCode(rawValue: report.result) {
        case let code? where [.revertedBad, .revertedTries, .refused].contains(code): return .reverted(serial: report.serial, why: code)
        default: break
        }
        if offer.serial == 0 { return .builtIn(serial: report.serial) }
        if report.result < 0 || report.serial < offer.bundled { return .outOfDate }
        return .current(serial: report.serial)
    }
}
