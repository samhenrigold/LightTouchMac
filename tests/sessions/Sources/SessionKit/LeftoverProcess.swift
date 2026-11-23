// Whether a process id a run recorded still names a process that run started, before the run's end kills it: a
// recorded process that exited leaves its id free for any other (another agent's helper, on a busy Mac), so the
// process must be one of the executables a run starts and must have started no earlier than the run.

import Darwin
import Foundation

public enum LeftoverProcess {
    /// What a run starts: device helpers, usbmuxds (directly, or through the services worker that becomes one), the
    /// services worker and the drivers.
    public static let executables: Set<String> = [
        "LightTouchDevice", "usbmuxd", "LightTouchServices", "session-driver", "helper-driver"
    ]

    /// Whether `pid` is alive, runs one of `executables` and started at or after `since`.
    public static func isOurs(_ pid: pid_t, since: Date, executables: Set<String> = executables) -> Bool {
        guard pid > 0, let name = executableName(pid), executables.contains(name), let started = startTime(pid) else {
            return false
        }
        // proc_bsdinfo keeps microseconds; a second of slack covers a clock read just before the spawn.
        return started >= since.addingTimeInterval(-1)
    }

    private static func executableName(_ pid: pid_t) -> String? {
        var path = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))  // PROC_PIDPATHINFO_MAXSIZE
        guard proc_pidpath(pid, &path, UInt32(path.count)) > 0 else { return nil }
        return URL(fileURLWithPath: String(cString: path)).lastPathComponent
    }

    private static func startTime(_ pid: pid_t) -> Date? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
        return Date(
            timeIntervalSince1970: TimeInterval(info.pbi_start_tvsec) + TimeInterval(info.pbi_start_tvusec) / 1e6)
    }
}
