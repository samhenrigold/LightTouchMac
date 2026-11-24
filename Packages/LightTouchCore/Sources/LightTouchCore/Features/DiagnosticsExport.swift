// Help > Export Diagnostics: the app's logs, the selected device's (Device/: serial, usbmuxd, the helper's and QEMU's
// native.log, firmwarekit's boot admission and storage migration log, its preparation log), the app's crash reports
// and a summary with the Copy Bug Report Info block, each scrubbed of identity (scrub) and cut to its newest
// `logLimit` bytes, zipped atomically into a scratch directory.

import Foundation
import Subprocess
import System

// MARK: - Diagnostics storage

/// Each export owns its scratch and publishes one complete archive. Kept apart
/// from the window so the failure/cancellation paths can run without a device.
public nonisolated enum DiagnosticsExport {
    /// What a report needs before anything else: which build, on which macOS, on which Mac.
    public static func systemSummary(bundle: Bundle = .main) -> String {
        let info = bundle.infoDictionary ?? [:]
        let version = info["CFBundleShortVersionString"] as? String ?? "?"
        let build = info["CFBundleVersion"] as? String ?? "?"
        func sysctl(_ name: String) -> String? {
            var size = 0
            guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
            var value = [CChar](repeating: 0, count: size)
            guard sysctlbyname(name, &value, &size, nil, 0) == 0 else { return nil }
            return String(decoding: value.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
        }
        var translated: Int32 = 0
        var size = MemoryLayout<Int32>.size
        let rosetta = sysctlbyname("sysctl.proc_translated", &translated, &size, nil, 0) == 0 && translated == 1
        #if arch(arm64)
            let arch = "arm64"
        #else
            let arch = rosetta ? "x86_64 (Rosetta)" : "x86_64"
        #endif
        return """
            Light Touch \(version) (\(build))
            macOS \(ProcessInfo.processInfo.operatingSystemVersionString)
            \(arch) on \(sysctl("hw.model") ?? "?")\(sysctl("machdep.cpu.brand_string").map { ", \($0)" } ?? "")
            """
    }

    /// The newest crash reports (.ips) of the app's own executables (Contents/MacOS: the app, its helper,
    /// workers and tools), from the last 30 days, at most `limit`.
    public static func crashReports(
        executables: [String],
        in folder: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/DiagnosticReports"),
        limit: Int = 10,
        now: Date = Date()
    ) -> [URL] {
        let keys: Set<URLResourceKey> = [.contentModificationDateKey, .isRegularFileKey]
        let files =
            (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: Array(keys))) ?? []
        return files.compactMap { url -> (URL, Date)? in
            let name = url.lastPathComponent
            guard url.pathExtension == "ips", executables.contains(where: { name.hasPrefix($0 + "-") }),
                let values = try? url.resourceValues(forKeys: keys), values.isRegularFile == true,
                let date = values.contentModificationDate, now.timeIntervalSince(date) < 30 * 86_400
            else { return nil }
            return (url, date)
        }.sorted { $0.1 > $1.1 }.prefix(limit).map(\.0)
    }

    /// The most of one log the archive keeps: its newest bytes.
    public static let logLimit = 2_000_000

    /// The last `limit` bytes of `url` as text, and whether earlier ones were left out; empty when it can't be read.
    public static func tail(of url: URL, limit: Int) -> (text: String, cut: Bool) {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return ("", false) }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        let cut = size > UInt64(limit)
        try? handle.seek(toOffset: cut ? size - UInt64(limit) : 0)
        return (String(decoding: (try? handle.readToEnd()) ?? Data(), as: UTF8.self), cut)
    }

    /// `logs` go at the archive's top, `deviceLogs` (the selected device's) in Device/.
    @concurrent
    public static func write(
        to destination: URL,
        logs: [URL],
        deviceLogs: [URL] = [],
        info: String,
        crashReports: [URL] = [],
        secrets: [String] = [],
        identity: HostIdentity = .current,
        temporaryRoot: URL = FileManager.default.temporaryDirectory,
        archiver: URL = URL(fileURLWithPath: "/usr/bin/ditto")
    ) async throws {
        try Task.checkCancellation()
        let fm = FileManager.default
        let scratch = temporaryRoot.appendingPathComponent(
            "LightTouch-diagnostics-" + UUID().uuidString,
            isDirectory: true
        )
        try fm.createDirectory(
            at: scratch,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        defer { try? fm.removeItem(at: scratch) }
        let staging = scratch.appendingPathComponent("LightTouchMac-diagnostics", isDirectory: true)
        try fm.createDirectory(at: staging, withIntermediateDirectories: false)
        let device = staging.appendingPathComponent("Device", isDirectory: true)
        for (folder, sources) in [(staging, logs), (device, deviceLogs)] {
            for source in sources where fm.fileExists(atPath: source.path) {
                try Task.checkCancellation()
                let log = tail(of: source, limit: logLimit)
                try fm.createDirectory(at: folder, withIntermediateDirectories: true)
                try scrub((log.cut ? "(earlier lines cut)\n" : "") + log.text, secrets: secrets, identity: identity)
                    .write(
                        to: folder.appendingPathComponent(source.lastPathComponent), atomically: false, encoding: .utf8)
            }
        }
        try scrub(info, secrets: secrets, identity: identity)
            .write(to: staging.appendingPathComponent("info.txt"), atomically: true, encoding: .utf8)
        if !crashReports.isEmpty {
            let reports = staging.appendingPathComponent("CrashReports", isDirectory: true)
            try fm.createDirectory(at: reports, withIntermediateDirectories: false)
            for report in crashReports {
                guard let data = try? Data(contentsOf: report) else { continue }
                try scrubCrashReport(String(decoding: data, as: UTF8.self), identity: identity)
                    .write(
                        to: reports.appendingPathComponent(report.lastPathComponent), atomically: false, encoding: .utf8
                    )
            }
        }

        // Keep the final rename on the destination volume. Failure or cancellation
        // leaves an existing user-selected archive untouched.
        let archive = destination.deletingLastPathComponent()
            .appendingPathComponent(".LightTouch-diagnostics-" + UUID().uuidString + ".zip")
        defer { try? fm.removeItem(at: archive) }
        try await runArchiver(archiver, staging: staging, archive: archive)
        let attributes = try fm.attributesOfItem(atPath: archive.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular,
            (attributes[.size] as? NSNumber)?.uint64Value ?? 0 > 0
        else {
            throw CocoaError(.fileReadCorruptFile)
        }
        try Task.checkCancellation()
        guard rename(archive.path, destination.path) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }

    private static func runArchiver(_ executable: URL, staging: URL, archive: URL) async throws {
        // Cancelling the task stops ditto (Subprocess's teardown).
        let result = try await Subprocess.run(
            .path(FilePath(executable.path)),
            arguments: ["-c", "-k", "--sequesterRsrc", "--keepParent", staging.path, archive.path],
            output: .discarded,
            error: .discarded
        )
        try Task.checkCancellation()
        guard result.terminationStatus.isSuccess else {
            throw NSError(
                domain: "LightTouch.Diagnostics",
                code: 1,
                userInfo: [
                    NSLocalizedDescriptionKey: "Couldn’t create the diagnostics file."
                ]
            )
        }
    }
}

// MARK: - Identity scrubbing

nonisolated extension DiagnosticsExport {
    /// What names this Mac and its user, for scrubbing.
    public struct HostIdentity: Sendable {
        public var home: String
        public var names: [String]
        public init(home: String, names: [String]) {
            self.home = home
            self.names = names
        }
        public static var current: HostIdentity {
            // gethostname, not ProcessInfo.hostName: that one resolves the name (mDNS), which asks for Local Network
            var buffer = [CChar](repeating: 0, count: Int(MAXHOSTNAMELEN) + 1)
            let host = gethostname(&buffer, buffer.count) == 0 ? String(cString: buffer) : ""
            return HostIdentity(
                home: NSHomeDirectory(),
                names: [NSUserName(), NSFullUserName(), host, host.replacingOccurrences(of: ".local", with: "")]
            )
        }
    }

    /// Shapes of identity, each with its placeholder: email, MAC address, UUID, UDID (new and 40-hex), IMEI/ICCID,
    /// serial number. 32-hex build IDs don't match.
    private static let identityShapes: [(NSRegularExpression, String)] = [
        (#"[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}"#, "<email>"),
        (#"\b[0-9A-Fa-f]{2}(?:[:-][0-9A-Fa-f]{2}){5}\b"#, "<mac>"),
        (#"\b[0-9A-Fa-f]{8}-(?:[0-9A-Fa-f]{4}-){3}[0-9A-Fa-f]{12}\b"#, "<uuid>"),
        (#"\b[0-9A-Fa-f]{8}-[0-9A-Fa-f]{16}\b"#, "<udid>"),
        (#"\b[0-9A-Fa-f]{40}\b"#, "<udid>"),
        (#"\b\d{14,20}\b"#, "<number>"),
        (#"\b(?=[A-Z0-9]*[0-9])(?=[A-Z0-9]*[A-Z])[A-Z0-9]{11,12}\b"#, "<serial>")
    ].map { (try! NSRegularExpression(pattern: $0.0), $0.1) }

    /// A crash report's identifying members (its header's and its body's), whose values become <redacted>.
    private static let crashReportKeys = try! NSRegularExpression(
        pattern: #"("(?:crashReporterKey|bootSessionUUID|sleepWakeUUID|incident|incident_id|"#
            + #"Hardware UUID|Sleep/Wake UUID|hardwareUUID|serialNumber|Serial Number)"\s*:\s*)"[^"]*""#
    )

    private static func replace(_ regex: NSRegularExpression, in text: String, with template: String) -> String {
        regex.stringByReplacingMatches(
            in: text,
            range: NSRange(text.startIndex..., in: text),
            withTemplate: template
        )
    }

    /// The home folder becomes ~, and the user's and the Mac's names and `secrets` <redacted> (whole words).
    private static func scrubNames(_ text: String, secrets: [String], identity: HostIdentity) -> String {
        var out = text
        if identity.home.count > 1 { out = out.replacingOccurrences(of: identity.home, with: "~") }
        for secret in secrets where secret.count >= 4 {
            out = out.replacingOccurrences(of: secret, with: "<redacted>", options: .caseInsensitive)
        }
        for name in Set(identity.names) where name.count >= 3 {
            let pattern = "\\b" + NSRegularExpression.escapedPattern(for: name) + "\\b"
            guard let word = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else { continue }
            out = replace(word, in: out, with: "<redacted>")
        }
        return out
    }

    /// Text without identity: the home folder becomes ~, the user's and the Mac's names and `secrets` (a device's
    /// UDID, seed, ...) become <redacted>, and anything shaped like a UDID, UUID, MAC address, IMEI/ICCID, serial
    /// number or email address becomes a placeholder.
    public static func scrub(_ text: String, secrets: [String] = [], identity: HostIdentity = .current) -> String {
        identityShapes.reduce(scrubNames(text, secrets: secrets, identity: identity)) {
            replace($1.0, in: $0, with: $1.1)
        }
    }

    /// A crash report (.ips: a JSON header line, then the JSON report) without the home folder, the names, and the
    /// members that identify the Mac or the report (crashReporterKey, bootSessionUUID, incident, ...). Shapes are
    /// left alone: the stacks and the binary images' UUIDs are what symbolicate it.
    public static func scrubCrashReport(_ text: String, identity: HostIdentity = .current) -> String {
        replace(crashReportKeys, in: scrubNames(text, secrets: [], identity: identity), with: "$1\"<redacted>\"")
    }
}
