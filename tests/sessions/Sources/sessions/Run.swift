import Foundation
import LightTouchCore
import SessionKit

/// The drivers built beside this executable.
let binDirectory = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath().deletingLastPathComponent()

/// Every pid the drivers report starting (helpers, usbmuxds), killed if still alive when a run ends; never a lookup by name.
func killLeftovers(_ events: Events, pidFile: URL? = nil) {
    var pids = Set(
        events.all.filter { ["hello", "booted", "usbmuxd", "connected", "hold"].contains($0.string("event") ?? "") }
            .compactMap { $0.int("pid") ?? $0.int("helperPid") }
    )
    if let pidFile, let text = try? String(contentsOf: pidFile, encoding: .utf8) {
        pids.formUnion(text.split(whereSeparator: \.isNewline).compactMap { Int($0) })
    }
    for pid in pids where pid > 0 && kill(pid_t(pid), 0) == 0 {
        kill(pid_t(pid), SIGKILL)
        print("  (killed leftover \(pid))")
    }
}

/// A started driver process writing JSON lines to `out`.
/// The drivers this process has brought up to date.
nonisolated(unsafe) private var builtDrivers: Set<String> = []

/// `tool` built from the current sources (DriverBuild) once per run before it first starts; a build that fails stops
/// the run rather than start a driver that may be old.
func upToDate(_ tool: String) {
    guard !builtDrivers.contains(tool),
        let arguments = DriverBuild.arguments(
            product: tool,
            bin: binDirectory,
            package: repository.appendingPathComponent("tests/sessions")
        )
    else { return }
    let log = FileManager.default.temporaryDirectory.appendingPathComponent("ltm-sessions-build-\(tool).log")
    try? FileManager.default.removeItem(at: log)
    guard run("/usr/bin/xcrun", ["swift"] + arguments, log: log) == 0 else {
        die(
            "\(tool) may be older than these sources and building it failed (see \(log.path)): swift "
                + arguments.joined(separator: " "),
            code: 3
        )
    }
    builtDrivers.insert(tool)
}

/// The vendor directory's libimobiledevice tools (idevicesyslog, idevicecrashreport), which the driver runs by name.
let vendorTools: URL? = vendorDirectory().flatMap { vendor in
    let work = vendor.appendingPathComponent("work")
    return ((try? FileManager.default.contentsOfDirectory(atPath: work.path)) ?? []).sorted().lazy
        .map { work.appendingPathComponent("\($0)/prefix/bin") }
        .first { FileManager.default.isExecutableFile(atPath: $0.appendingPathComponent("idevicesyslog").path) }
}

final class DriverProcess {
    let process = Process()
    let out: URL

    init(_ tool: String, _ arguments: [String], out: URL, environment: [String: String] = [:]) {
        self.out = out
        FileManager.default.createFile(atPath: out.path, contents: nil)
        upToDate(tool)
        process.executableURL = binDirectory.appendingPathComponent(tool)
        process.arguments = arguments
        var merged = ProcessInfo.processInfo.environment.merging(environment) { $1 }
        if let tools = vendorTools { merged["PATH"] = tools.path + ":" + (merged["PATH"] ?? "/usr/bin:/bin") }
        process.environment = merged
        let h = FileHandle(forWritingAtPath: out.path)
        process.standardOutput = h
        process.standardError = h
        process.standardInput = FileHandle.nullDevice
        do { try process.run() } catch { die("could not start \(tool): \(error)", code: 3) }
    }

    var pid: pid_t { process.processIdentifier }
    var events: Events { Events(jsonLines: (try? String(contentsOf: out, encoding: .utf8)) ?? "") }

    /// Its exit status, or nil once `seconds` pass (then it is killed).
    @discardableResult
    func wait(_ seconds: Double) -> Int32? {
        let deadline = Date().addingTimeInterval(seconds)
        while process.isRunning, Date() < deadline { usleep(100_000) }
        if process.isRunning {
            kill(pid, SIGKILL)
            process.waitUntilExit()
            return nil
        }
        return process.terminationStatus
    }

    /// The first event named `name`, waiting up to `seconds` while the driver runs.
    func waitFor(_ name: String, _ seconds: Double) -> Event? {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if let e = events.find(name).first { return e }
            if !process.isRunning { break }
            usleep(200_000)
        }
        return events.find(name).first
    }
}

/// session-driver with `config` (written to work/config.json): its events and exit status. Leftover processes it
/// started are killed.
func sessionDriver(_ config: [String: Any], work: URL, timeout: Double, environment: [String: String] = [:]) -> (
    Events, Int32?
) {
    let file = work.appendingPathComponent("config.json")
    do {
        try JSONSerialization.data(withJSONObject: config, options: [.prettyPrinted, .sortedKeys]).write(to: file)
    } catch { die("config: \(error)", code: 3) }
    let d = DriverProcess(
        "session-driver",
        [file.path],
        out: work.appendingPathComponent("driver.jsonl"),
        environment: environment
    )
    let status = d.wait(timeout + 10)
    let events = d.events
    killLeftovers(events, pidFile: work.appendingPathComponent("pids"))
    for fail in events.find("fail") { print("  driver: \(fail.string("why") ?? "")") }
    return (events, status)
}

func alive(_ pid: Int) -> Bool { pid > 0 && kill(pid_t(pid), 0) == 0 }

/// Seconds until `pid` is gone, or nil if it outlives `seconds`.
func waitGone(_ pid: Int, _ seconds: Double) -> Double? {
    let t0 = Date()
    while Date().timeIntervalSince(t0) < seconds {
        if !alive(pid) { return Date().timeIntervalSince(t0) }
        usleep(100_000)
    }
    return nil
}

/// The work directory `finish` prunes to its logs when the run passes (WorkPrune): none with --keep-work.
nonisolated(unsafe) private var prunedWork: URL?
/// A temporary work directory (no --work, no --keep-work), which a run that stops before it boots removes whole.
nonisolated(unsafe) var disposableWork: URL?

/// A fresh work directory: `--work`, or a temporary one.
func workDirectory(_ args: Inputs, _ name: String) -> URL {
    let work =
        args.work
        ?? FileManager.default.temporaryDirectory
        .appendingPathComponent("ltm-\(name)-\(UUID().uuidString.prefix(8))")
    if !args.keepWork { prunedWork = work }
    if args.work == nil, !args.keepWork { disposableWork = work }
    try? FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
    print("work: \(work.path)")
    return work
}

/// The user's real app.log, which no run may write (the drivers' app code logs under LTM_STATE_DIR, the run's own).
let realAppLog = URL(fileURLWithPath: getpwuid(getuid()).map { String(cString: $0.pointee.pw_dir) } ?? "/Users")
    .appendingPathComponent("Library/Logs/gold.samhenri.LightTouchMac/app.log")

func finish(_ report: Report, work: URL) -> Never {
    let real = (try? String(contentsOf: realAppLog, encoding: .utf8)) ?? ""
    report.check(!real.contains(work.path), "the run left the real \(realAppLog.path) alone")
    let verdict = "\(report.allPassed ? "PASS" : "FAIL"): \(report.summary)"
    try? (report.lines + ["", verdict, ""]).joined(separator: "\n")
        .write(to: work.appendingPathComponent("summary.txt"), atomically: true, encoding: .utf8)
    let pruned = report.allPassed && work == prunedWork && prune(work)
    print("\n\(pruned ? "logs" : "everything") kept in \(work.path)")
    print(report.verdict(log: work.path))
    exit(report.allPassed ? 0 : 1)
}

/// `work` down to what WorkPrune keeps: those files are set aside, the directory removed (a base the drivers
/// published under it is locked, uchg, and its NAND read only: removeTree unlocks first), and they are put back.
func prune(_ work: URL) -> Bool {
    let fm = FileManager.default
    let kept = WorkPrune.kept(under: work)
    let aside = work.deletingLastPathComponent().appendingPathComponent(".\(work.lastPathComponent).kept")
    do {
        try? fm.removeItem(at: aside)
        for path in kept {
            let to = aside.appendingPathComponent(path)
            try fm.createDirectory(at: to.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fm.copyItem(at: work.appendingPathComponent(path), to: to)
        }
        try DeviceStateStorage.removeTree(work)
        if fm.fileExists(atPath: aside.path) {
            try fm.moveItem(at: aside, to: work)
        } else {
            try fm.createDirectory(at: work, withIntermediateDirectories: true)
        }
        return true
    } catch {
        print("could not prune \(work.path): \(error)")
        return false
    }
}

/// The base fields every session-driver config carries.
func driverConfig(_ tools: Tools, work: URL, ipa: URL? = nil) -> [String: Any] {
    var config: [String: Any] = [
        "helper": tools.helper.path, "firmwarekit": tools.firmwarekit.path, "usbmuxd": tools.usbmuxd.path,
        "ipa": ipa?.path ?? "", "bundleID": ipa.flatMap(ipaBundleID) ?? "com.qemuios.harness", "work": work.path,
        "files": tools.files.path, "ipodBase": "", "ipadBase": ""
    ]
    if let requirement = tools.requirement, !requirement.isEmpty { config["requirement"] = requirement }
    return config
}

/// The IPA's CFBundleIdentifier, from its root app's Info.plist (the app's own archive readers).
func ipaBundleID(_ ipa: URL) -> String? {
    guard let root = IPAMembers.appRoot(ZipMembers.paths(ipa)),
        let data = ZipMembers.data(ipa, root + "Info.plist"),
        let info = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
    else { return nil }
    return info["CFBundleIdentifier"] as? String
}

/// What the drivers' children read: the dylib the helper loads and the services worker DeviceServices spawns.
func driverEnvironment(_ tools: Tools) -> [String: String] {
    [
        "LTM_QEMU_DYLIB": tools.dylib.path, "LTM_HOST_SERVICE_WORKER": tools.services.path,
        "LTM_STATE_DIR": FileManager.default.temporaryDirectory.appendingPathComponent("ltm-sessions-state").path
    ]
}

func format(_ value: Double?, _ digits: Int = 1) -> String { String(format: "%.\(digits)f", value ?? -1) }

/// This executable again with `arguments` and the run's --app, --dylib, --usbmuxd and --allow-stale, its output
/// inherited; its exit status.
func sessions(_ arguments: [String], _ inputs: Inputs) -> Int32 {
    var arguments = arguments
    if let app = inputs.app { arguments += ["--app", app.path] }
    if let dylib = inputs.dylib { arguments += ["--dylib", dylib.path] }
    if let usbmuxd = inputs.usbmuxd { arguments += ["--usbmuxd", usbmuxd.path] }
    if inputs.allowStale { arguments.append("--allow-stale") }
    fflush(stdout)
    let p = Process()
    p.executableURL = Bundle.main.executableURL
    p.arguments = arguments
    guard (try? p.run()) != nil else { return -1 }
    p.waitUntilExit()
    return p.terminationStatus
}
