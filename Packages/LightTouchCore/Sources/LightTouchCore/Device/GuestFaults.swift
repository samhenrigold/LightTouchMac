// What a boot's serial log shows went wrong inside iOS while the device still came up: the data volume left
// unmounted (so /private/var, and everything the device writes, stays on the system volume), a file system check
// that failed, a system process that crashed, a kernel panic. Each of these left devices looking fine for months
// (issue 97's iPhone 3GS 3.1.x data volumes never mounted). The app watches for them as the guest prints them
// (EmulatorController.openSerialLog) and logs each as an error; sessions single fails a run whose log shows one.
// Pure Foundation; LightTouchCoreTests' GuestFaultsTests.

import Foundation

public nonisolated enum GuestFaults {
    /// Phrases that are a fault wherever they appear, and what each means.
    public static let phrases: [String: String] = [
        "panic(cpu ": "the iOS kernel panicked",
        "Exited abnormally": "a system process crashed",
        "fwexec(mount_tool": "launchd couldn't mount the device's volumes",
        "Invalid content in Journal": "a volume's journal is unreadable"
    ].merging((1...9).map { ("fsck exited with status: \($0)", "the file system check failed") }) { a, _ in a }

    /// The lines launchd prints as it mounts the fstab (mount -v): the system volume, then the data volume.
    public static let systemMounted = " on / (", dataMounted = " on /private/var ("

    /// Everything the serial watch looks for.
    public static var watched: [String] { Array(phrases.keys) + [systemMounted, dataMounted] }

    /// The data volume fault: launchd printed the system volume's mount and, by the time iOS answered, never the data
    /// volume's. `dataVolume`: the device has a data partition (the recipe's data_size "partition"). A board whose
    /// kernel console is off prints neither line, so nothing is judged there.
    public static func dataVolumeFault(seen: Set<String>, dataVolume: Bool) -> String? {
        dataVolume && seen.contains(systemMounted) && !seen.contains(dataMounted) ? unmounted : nil
    }
    static let unmounted =
        "the data volume didn't mount: /private/var, and everything the device writes, is on the system volume"

    /// Every fault in a whole serial log (all the boots in it), one line each with what the log said.
    public static func faults(log: String, dataVolume: Bool) -> [String] {
        let lines = log.split(whereSeparator: \.isNewline)
        var out: [String] = []
        for (phrase, meaning) in phrases.sorted(by: { $0.key < $1.key }) {
            let hits = lines.filter { $0.contains(phrase) }
            guard let first = hits.first else { continue }
            out.append("\(meaning) (\(hits.count)×): \(first.trimmingCharacters(in: .whitespaces).prefix(160))")
        }
        let boots = lines.filter { $0.contains(systemMounted) }.count
        let data = lines.filter { $0.contains(dataMounted) }.count
        if dataVolume, data < boots {
            out.append(unmounted + " (on \(boots - data) of \(boots) boots)")
        }
        return out
    }

    /// The last line of `log` that shows `phrase`, as faults(log:) quotes it: what a fault said, for its report (a
    /// panic's string, the process that exited).
    public static func line(_ phrase: String, in log: String) -> String? {
        log.split(whereSeparator: \.isNewline).last { $0.contains(phrase) }
            .map { String($0.trimmingCharacters(in: .whitespaces).prefix(160)) }
    }

    // MARK: - Crash reports

    /// The processes the guest wrote a crash report for during this boot, each once, sorted: `ages` are the reports'
    /// paths and how many seconds before the device's clock now each was written (DeviceServices.crashReports),
    /// `uptime` the seconds since power-on. Most boards' serial never shows launchd's job lines, so a crash-looping
    /// daemon is seen only here. A report counts if it is no older than the boot, give or take `slack` (the guest's
    /// clock against the Mac's over a boot).
    public static func crashedProcesses(ages: [String: Double], uptime: Double, slack: Double = 120) -> [String] {
        Set(ages.compactMap { path, age in age <= uptime + slack ? process(report: path) : nil }).sorted()
    }

    /// The processes a run from a prepared base crashed: every report `listed` (paths as the crash report service
    /// names them) that wasn't already on the base, whatever its age. `base` is every path on the base's data volume
    /// (or its one volume). Ages can't tell a run's reports from the base's: a dated beta's clock starts at its pinned
    /// date every boot. A report is matched by file name, from any CrashReporter folder: at boot crash_mover moves
    /// /var/logs/CrashReporter's (stackshots, panics) and /var/wireless's into mobile's, where the service lists them.
    /// ponytail: by name; a run's report under a base report's name (the same second of a pinned clock) is missed.
    public static func crashedProcesses(listed: some Sequence<String>, base: some Sequence<String>) -> [String] {
        let name = { (path: String) in (path as NSString).lastPathComponent }
        let inBase = Set(base.filter { $0.contains("CrashReporter/") }.map(name))
        return Set(listed.filter { !inBase.contains(name($0)) }.compactMap(process(report:))).sorted()
    }

    /// iOS serves its crash reports over AFC (com.apple.crashreportcopymobile) from 3.0; 1.x and 2.x lockdownd refuse
    /// that service (2.2's says InvalidService) and have CrashReportCopyAgent (com.apple.crashreportcopy), a DeviceLink
    /// protocol, instead, which the services worker speaks for 2.x. 1.x's two boards, the iPhone 2G and iPod touch 1G,
    /// print launchd's "Exited abnormally" on the serial log, which faults(log:) judges.
    public static func listsCrashReports(version: String) -> Bool {
        version.compare("2.0", options: .numeric) != .orderedAscending
    }

    /// The process a crash report is about, from ReportCrash's name for it: "SpringBoard_2011-03-01-120102_iPad.plist"
    /// (.ips from 7.0), "LowMemory-2011-03-01-120102.plist" (jetsam's: a clean boot that runs out of memory is a
    /// fault too), "stacks+MobileMail-…" (a hang's stackshot), "panic-full-2011-…" (a kernel panic). nil for what
    /// isn't one: LatestCrash-*.plist (links to the newest report of a process), 7.x's Sandbox-<process>-… (a sandbox
    /// violation the process survived), SystemLog_… (bug_type 116: a copy of the system log CrashReporter takes beside
    /// another report, no process of its own), the logs beside them (DiagnosticLogs/*.log, MobileBackup.log) and
    /// anything without ReportCrash's date.
    public static func process(report path: String) -> String? {
        let name = (path as NSString).lastPathComponent
        guard ["plist", "ips", "crash"].contains((name as NSString).pathExtension),
            !name.hasPrefix("LatestCrash"), !name.hasPrefix("Sandbox-"), !name.hasPrefix("SystemLog_"),
            let match = name.firstMatch(of: /^(.+?)[_-]\d{4}-\d{2}-\d{2}-\d{6}/)
        else { return nil }
        return String(match.1)
    }
}
