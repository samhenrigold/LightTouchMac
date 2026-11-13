import Foundation
import LightTouchCore
import Metal
import MetricKit
import Sparkle
import TelemetryDeck

/// Settings ▸ General ▸ Share anonymous usage and error reports, on unless turned off: TelemetryDeck signals for a
/// launch, a device's start, the apps opened in it and what failed, with no names, paths or messages (an error goes as
/// its domain and code, a crash as image+offset, a guest fault as the iOS line that showed it). Every signal carries the
/// Mac's graphics and the display settings, which the bug reports kept turning on (issues 26, 99, 122), and every
/// failure the steps that led to it, a trail kept on this Mac. Every signal goes through here, as the SDK starts only while sharing is on (a signal before it
/// starts would go with no app ID); turning sharing off stops new signals at once, and the next launch doesn't start
/// the SDK. What it already queued still goes: within 10 s, or, saved at a quit, once sharing is next on.
enum Analytics {
    static let key = "shareUsageReports"
    private static let appID = "F768F1A3-426B-4D24-AFF6-C258D0D2265E"
    private static var started = false
    private static let diagnostics = Diagnostics()
    /// Sparkle's delegate, for an update that fails (issue 95).
    static let updates = UpdateReports()

    static var isOn: Bool { UserDefaults.standard.object(forKey: key) as? Bool ?? true }

    /// Once, first thing at launch: the SDK (and its session start) when sharing is on, and the reports that come
    /// later: the packages' (AppReports), crash reports, MetricKit's hangs.
    static func launch() {
        lastRun = trail(UserDefaults.standard.stringArray(forKey: trailKey) ?? [])
        UserDefaults.standard.removeObject(forKey: trailKey)
        AppReports.sink = { kind, id, error, parameters, value in
            Task { @MainActor in
                switch kind {
                case .failure: failure(id, error, parameters, value: value)
                case .use: signal(id, parameters, value: value)
                }
            }
        }
        _ = startIfOn()
        MXMetricManager.shared.add(diagnostics)
        sendCrashReports()
    }

    /// Once the library is open: how Light Touch is set up, for what most people use (App.launched).
    static func libraryOpened(_ instances: [DeviceInstance]) {
        let defaults = UserDefaults.standard
        let internet = defaults.object(forKey: NetworkAccessPreference.key) as? Bool
        signal(
            "App.launched",
            [
                "devices": "\(instances.count)", "boards": Set(instances.map(\.board)).sorted().joined(separator: " "),
                "internet": internet.map { $0 ? "always" : "never" } ?? "ask",
                "shareClipboard": "\(ClipboardSync.enabled)",
                "withoutMounting": "\(defaults.bool(forKey: FirmwareJobs.withoutMountingKey))"
            ]
        )
    }

    /// Sharing turned on after launch starts the SDK with the next signal.
    private static func startIfOn() -> Bool {
        guard isOn else { return false }
        if !started {
            TelemetryDeck.initialize(config: .init(appID: appID))
            started = true
        }
        return true
    }

    // MARK: - Signals

    private static let gpu = MTLCreateSystemDefaultDevice()?.name ?? "none"
    /// What every signal carries: the GPU and whether its driver is Apple's (a third-party one crashed RealityKit,
    /// issue 99), the bezel, the renderer and the refresh rate.
    private static var context: [String: String] {
        [
            "gpu": gpu, "appleGPU": "\(DisplayView.rendersModel)", "bezel": "\(DisplayView.bezel)",
            "renderer": ANGLERenderer.isOn ? "ANGLE" : "OpenGL", "refresh": "\(DisplayRefresh.hz)"
        ]
    }

    /// `name` as TelemetryDeck's naming asks (Device.started); parameter values carry nothing about the user.
    static func signal(_ name: String, _ parameters: [String: String] = [:], value: Double? = nil) {
        guard startIfOn() else { return }
        breadcrumb([name, parameters["board"]].compactMap { $0 }.joined(separator: " "))
        TelemetryDeck.signal(name, parameters: context.merging(parameters) { $1 }, floatValue: value)
    }

    /// TelemetryDeck's error signal, `id` naming what failed, with the trail that led to it (`lastRun`: the last
    /// run's, for what ended it); `error` goes as its domain and code alone (a Swift error's type and case number), as
    /// its description can hold paths and names.
    static func failure(
        _ id: String,
        _ error: Error? = nil,
        category: ErrorCategory = .thrownException,
        _ parameters: [String: String] = [:],
        value: Double? = nil,
        lastRun: Bool = false
    ) {
        guard startIfOn() else { return }
        var parameters = context.merging(parameters) { $1 }
        if let error = error as NSError? {
            parameters["errorDomain"] = error.domain
            parameters["errorCode"] = String(error.code)
            // what a wrapping error (Sparkle's download error) wraps: the network's, the disk's
            if let underlying = error.userInfo[NSUnderlyingErrorKey] as? NSError {
                parameters["underlyingDomain"] = underlying.domain
                parameters["underlyingCode"] = String(underlying.code)
            }
        }
        parameters["breadcrumbs"] = lastRun ? self.lastRun : trail(steps)
        breadcrumb([id, parameters["board"]].compactMap { $0 }.joined(separator: " "))
        TelemetryDeck.errorOccurred(id: id, category: category, parameters: parameters, floatValue: value)
        // a failure can be a process's crash (the helper's, the services worker's, usbmuxd's): its report, once
        // ReportCrash has written it
        if id != "App.crashed", !crashLookScheduled {
            crashLookScheduled = true
            Task {
                try? await Task.sleep(for: .seconds(20))
                crashLookScheduled = false
                sendCrashReports()
            }
        }
    }

    private static var crashLookScheduled = false

    /// The library volume's free space, roughly, for a storage failure.
    static var freeSpace: String {
        let bytes =
            (try? Bundled.stateDirectory.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?
            .volumeAvailableCapacityForImportantUsage ?? 0
        let gigabytes = bytes / 1_000_000_000
        return [1, 5, 20, 100].first { gigabytes < $0 }.map { "<\($0) GB" } ?? "100+ GB"
    }

    /// Something in a device went wrong that no error was thrown for (a guest fault, a guest app's crash).
    static func fault(_ id: String, _ parameters: [String: String]) { failure(id, category: .appState, parameters) }

    /// CrashGuard found the last run died in `step`.
    static func lastRunDied(in step: CrashGuard.Step) {
        failure("CrashGuard.\(step.rawValue)", category: .appState, lastRun: true)
    }

    private static var opened: Set<String> = []
    /// A device's front app changed: Guest.appOpened once a launch for each app on each firmware, which apps people
    /// run where (the games behind issues 8, 12, 15, 23, 96), else a breadcrumb.
    static func frontApp(_ bundleID: String, _ parameters: [String: String]) {
        guard !bundleID.isEmpty else { return }
        if opened.insert("\(bundleID) \(parameters["firmware"] ?? "")").inserted {
            signal("Guest.appOpened", parameters.merging(["bundleID": bundleID]) { $1 })
        } else {
            breadcrumb("\(parameters["board"] ?? "") \(bundleID)")
        }
    }

    // MARK: - Breadcrumbs

    private static let trailKey = "analyticsTrail"
    private static let launched = Date()
    /// This run's last steps, oldest first, in the defaults too, so the next launch has them for what ended this run.
    private static var steps: [String] = []
    /// The last run's steps, read at launch.
    private static var lastRun = ""

    /// A step on the way to whatever fails next ("412s Device.started n72ap"), kept on this Mac and sent only with a
    /// failure: each signal is one, and so are a device's state changes and front apps.
    static func breadcrumb(_ step: String) {
        guard isOn else { return }
        steps = Array((steps + ["\(Int(Date().timeIntervalSince(launched)))s \(step)"]).suffix(20))
        UserDefaults.standard.set(steps, forKey: trailKey)
    }

    private static func trail(_ steps: [String]) -> String { String(steps.joined(separator: " > ").suffix(1000)) }

    // MARK: - Crash reports

    private static let reportsKey = "analyticsCrashReportsSince"

    /// macOS's crash reports for Light Touch's own processes written since the last look, each as App.crashed: the app,
    /// the device helper (QEMU runs in it), the services worker, firmwarekit, usbmuxd and the rest of Contents/MacOS,
    /// sandboxed or not, which MetricKit (the app's own process only) never sees. A launch looks, and so does a
    /// helper's death, once ReportCrash has had time to write. The first launch only marks where to begin.
    static func sendCrashReports() {
        guard let since = UserDefaults.standard.object(forKey: reportsKey) as? Date else {
            return UserDefaults.standard.set(Date(), forKey: reportsKey)
        }
        let contents = Bundle.main.bundleURL.appendingPathComponent("Contents")
        let ours = Set(
            ["MacOS", "Frameworks"].flatMap {
                (try? FileManager.default.contentsOfDirectory(atPath: contents.appendingPathComponent($0).path)) ?? []
            }.map { $0.replacingOccurrences(of: ".framework", with: "") }
        )
        Task {
            let found = await crashReports(since: since, ours: ours)
            for report in found {
                failure("App.crashed", category: .appState, report.summary, lastRun: report.written < launched)
            }
            if let newest = found.map(\.written).max() { UserDefaults.standard.set(newest, forKey: reportsKey) }
        }
    }

    /// Every report newer than `since` whose process is one of `ours`; other apps' are read no further than that.
    @concurrent private nonisolated static func crashReports(since: Date, ours: Set<String>) async -> [(
        written: Date, summary: [String: String]
    )] {
        let folder = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(
            "Library/Logs/DiagnosticReports")
        let files =
            (try? FileManager.default.contentsOfDirectory(
                at: folder,
                includingPropertiesForKeys: [.contentModificationDateKey]
            )) ?? []
        return files.compactMap { url in
            guard url.pathExtension == "ips",
                let written = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
                written > since, let data = try? Data(contentsOf: url)
            else { return nil }
            let summary = CrashSummary.report(ips: data, ours: ours)
            guard let process = summary["process"], ours.contains(process) else { return nil }
            return (written, summary)
        }
    }
}

/// MetricKit's diagnostics of the app's own process: a hang of its main thread (issues 26, 107: the window stalling)
/// as App.hang and a CPU spike as App.cpuException, each with its seconds and where it was.
private final class Diagnostics: NSObject, MXMetricManagerSubscriber {
    nonisolated func didReceive(_ payloads: [MXDiagnosticPayload]) {
        let binary = Bundle.main.executableURL?.lastPathComponent ?? "LightTouch"
        func summary(_ diagnostic: MXDiagnostic, _ tree: MXCallStackTree) -> [String: String] {
            var parameters = CrashSummary.frames(callStackTree: tree.jsonRepresentation(), binary: binary)
            parameters["build"] = diagnostic.metaData.applicationBuildVersion
            return parameters
        }
        var found: [(id: String, parameters: [String: String], seconds: Double)] = []
        for payload in payloads {
            for hang in payload.hangDiagnostics ?? [] {
                found.append(
                    ("App.hang", summary(hang, hang.callStackTree), hang.hangDuration.converted(to: .seconds).value))
            }
            for spike in payload.cpuExceptionDiagnostics ?? [] {
                found.append(
                    (
                        "App.cpuException", summary(spike, spike.callStackTree),
                        spike.totalCPUTime.converted(to: .seconds).value
                    )
                )
            }
        }
        Task { @MainActor in
            for report in found {
                Analytics.failure(report.id, category: .appState, report.parameters, value: report.seconds)
            }
        }
    }
}

/// Sparkle's update cycle ending in an error, but for no update found and the user's own Cancel or Later.
final class UpdateReports: NSObject, SPUUpdaterDelegate {
    func updater(_ updater: SPUUpdater, didAbortWithError error: Error) {
        // SUNoUpdateError, SUInstallationCanceledError, SUInstallationAuthorizeLaterError
        guard ![1001, 4007, 4008].contains((error as NSError).code) else { return }
        Analytics.failure("App.updateFailed", error)
    }
}
