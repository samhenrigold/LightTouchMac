// Installing one decrypted .ipa on one running device: MinimumOSVersion
// against the device's iOS, the archive preflight, the home-screen
// placeholder, the exec-bit repair, the AFC free-space check and upload, then
// installation_proxy with its transient-connect retry. The steps are the
// services' (InstallationProxy, AFC) and the agent's (dlicon); the order and
// the policy between them live here.

import Foundation
import HostRuntime
import HostServiceClient
import HostServiceWire
import Subprocess
import System

/// The device services an install uses (DeviceServices'), so the pipeline's policy can be exercised alone.
public protocol AppInstallServices: Sendable {
    func freeSpaceBytes() async throws -> Int64
    func stage(_ ipa: URL, progress: @escaping @Sendable (Double) -> Void) async throws -> String
    func removeStaged(_ path: String) async
    func install(_ ipa: URL, staged: String, bundleID: String, progress: @escaping @Sendable (Int, String) -> Void)
        async throws
}
extension DeviceServices: AppInstallServices {}

/// The guest agent's home-screen placeholder (GuestAgent's dlicon).
public protocol InstallPlaceholderAgent: Sendable {
    var isAlive: Bool { get }
    @discardableResult func placeholder(_ action: String, id: String, bundleID: String?) async throws -> Bool
}
extension GuestAgent: InstallPlaceholderAgent {}

public struct AppInstallPipeline: Sendable {
    public init(
        services: any AppInstallServices,
        agent: any InstallPlaceholderAgent,
        deviceOS: String = "3.1.3",
        soc: Board.SoC,
        afcReadyTimeout: Duration = .seconds(300)
    ) {
        self.services = services
        self.agent = agent
        self.deviceOS = deviceOS
        self.soc = soc
        self.afcReadyTimeout = afcReadyTimeout
    }
    public let services: any AppInstallServices
    public let agent: any InstallPlaceholderAgent
    /// The device's iOS version (its catalog entry), which MinimumOSVersion is checked against.
    public var deviceOS = "3.1.3"
    /// The device's processor, which the app's binary is checked against (AppBinary).
    public let soc: Board.SoC
    /// iOS 7 only: how long the first AFC request may keep timing out before the install gives up. 7.x
    /// starts afcd in launchd's throttled band, and early in a boot it can sit unscheduled behind ~100
    /// runnable daemon threads for minutes (qemu-ios docs/n90 debt 6); a request sent then goes unanswered.
    public var afcReadyTimeout: Duration = .seconds(300)

    /// Install a decrypted .ipa: AFC stage + instproxy, in-process, no shell.
    /// Every supported image carries its GL engine shim. `progress` gets
    /// short, human phase strings for the sidebar row. The return string is
    /// non-empty only to carry the "SDK too new" marker the caller warns on.
    @discardableResult
    public func install(
        _ ipa: URL,
        placeholderRaised: Bool = false,
        progress: @escaping @Sendable (String) -> Void = { _ in }
    ) async throws -> String {
        // MinimumOSVersion, NOT DTSDKName. The SDK an app was BUILT with says
        // nothing about whether it runs: Temple Run 1.0 is DTSDKName
        // iphoneos4.2 with MinimumOSVersion 3.0 and runs fine on 3.1.3 (the
        // device's own version is what it is compared with). Gating
        // on the build SDK cried wolf on most of the library, which trains
        // people to click through the one warning that is real. iPhone OS
        // enforces MinimumOSVersion, so that is what we check.
        let minOS = await AppMetadataCache.minimumOS(from: ipa)
        let sdkMarker = Self.sdkTooNew(minOS, deviceOS: deviceOS) ? "\nnewer than the device's SDK" : ""

        // Cheapest possible pre-flight, and the app had none: without a
        // Payload/<name>.app/Info.plist this is not an iPhone app archive at
        // all — a renamed zip, a truncated download, a .ipa of something else.
        // installd's answer to that is PackageExtractionFailed, which the app
        // renders as "package extraction failed (device may be full)": the user
        // is told to uninstall things to make room, after waiting out a
        // multi-minute upload, for a file that was never installable.
        guard await AppMetadataCache.bundleID(of: ipa) != nil else {
            throw DeviceError.preflight(
                "“\(ipa.lastPathComponent)” isn’t an app archive (IPA)."
            )
        }
        // The binary itself, before the minutes of upload: an encrypted copy or one for another processor installs
        // (AppSync answers for its signature) and then dies at launch with nothing said.
        if let member = await AppMetadataCache.executableMember(of: ipa),
            let problem = await AppBinary.problem(in: ipa, member: member, soc: soc)
        {
            throw DeviceError.preflight(problem)
        }

        do {
            // Placeholder first, before anything slow: the exec-bit repair
            // repacks the whole archive and the free-space check is a round
            // trip, and until now this path put nothing on the home screen for
            // any of it.
            //
            // Keyed on the bundle id, falling back to the filename. Info.plist
            // is already unzipped just above for minimumOS, so this is free —
            // and keying on the filename alone meant the same app dropped from
            // two differently named files raised two placeholders. The filter
            // is also what makes the value safe inside the single quotes it is
            // interpolated into below.
            let key =
                await AppMetadataCache.bundleID(of: ipa)
                ?? ipa.deletingPathExtension().lastPathComponent
            let placeholder = Self.placeholderID(for: key)
            // The add and the cancel are two independent fire-and-forget agent
            // requests, so a fast failure below (disk full answers in about a
            // second) could run the cancel FIRST and
            // strand a "downloading" placeholder on the home screen with nothing
            // ever coming to replace it. Chaining the cancel behind the add's
            // own task is what orders them.
            //
            // placeholderRaised: a catalog install already put this exact icon
            // up at download start (installPlaceholder derives the same id from
            // the same bundle id). Adding it again drew a SECOND placeholder —
            // so adopt the existing one and only own the cancel.
            // The placeholder is the agent's dlicon; without it (the iPad, a
            // v1 agent) installd shows no icon and nothing is lost.
            let raised = placeholderRaised ? nil : placeholderIcon("add", placeholder, bundleID: key)
            defer { placeholderIcon("cancel", placeholder, after: raised) }

            // An .ipa whose binary is archived 0644 installs fine and then never
            // launches: posix_spawn fails EACCES, SpringBoard logs only "exited
            // abnormally", the icon bounces once and NO crash report is written
            // — it reads as an emulator bug. install-ipa.sh repacks it 0755;
            // the in-process path skipped that, so every 2009-era .ipa of this
            // shape (Cube Runner among them) regressed on the default image.
            let repaired = try await Self.execBitRepaired(ipa)
            defer { if let repaired { try? FileManager.default.removeItem(at: repaired) } }
            let ipa = repaired ?? ipa
            try Task.checkCancellation()
            let bytes = (try? FileManager.default.attributesOfItem(atPath: ipa.path)[.size] as? Int) ?? 0
            let free = try await freeSpaceOnceAFCAnswers(progress)
            let needed = Int64(bytes) * 2 + (16 << 20)
            guard free >= needed else { throw DeviceError.diskFull(free: free, needed: needed) }

            progress("Sending to device…")
            let staged = try await services.stage(ipa) { frac in
                progress("Sending to device… \(Int(frac * 100))%")
            }
            defer { Task { await services.removeStaged(staged) } }

            // Cancelling during the upload is honored here, at the last point
            // where it can be: instproxy_install runs on a detached thread that
            // ignores cancellation, so once it starts, the install finishes.
            try Task.checkCancellation()

            // attempts: 1. An install that hit its watchdog leaves a live
            // libimobiledevice thread and an open lockdown service behind
            // (deliberately — freeing them under the library is worse), so
            // retrying a TIMEOUT meant three of those against a guest that
            // serves about one, which is how a wedged install took the rest of
            // the session's app management down with it. Transient CONNECT
            // failures still retry; see DeviceError.isTransient.
            try await withTransientRetry(attempts: 3) {
                try await services.install(ipa, staged: staged, bundleID: key) { pct, _ in
                    progress(pct >= 0 ? "Installing… \(pct)%" : "Installing…")
                }
            }
            return "installed" + sdkMarker
        }
    }

    /// The free-space query is the install's first AFC request, so it doubles as the readiness probe: on
    /// iOS 7 a timeout is retried (each try has Timeouts.query) until afcd answers, at most afcReadyTimeout,
    /// before anything is sent. Other errors, and every error on other versions, fail as before.
    private func freeSpaceOnceAFCAnswers(_ progress: @Sendable (String) -> Void) async throws -> Int64 {
        guard (Int(deviceOS.prefix { $0.isNumber }) ?? 0) >= 7 else { return try await services.freeSpaceBytes() }
        let deadline = ContinuousClock.now + afcReadyTimeout
        while true {
            do { return try await services.freeSpaceBytes() } catch DeviceError.timedOut {
                guard ContinuousClock.now < deadline else {
                    throw DeviceError.failed(
                        "The device’s file service didn’t answer while iOS was starting, so the app wasn’t sent. Try again in a minute."
                    )
                }
                progress("Waiting for iOS to finish starting…")
                try await Task.sleep(for: .seconds(1))
            }
        }
    }

    /// If the .ipa stores its main binary without the exec bit, a copy repacked
    /// 0755 (via the bundled ipod-helper);
    /// nil if no repair is needed or anything is unreadable — callers fall back
    /// to the original, which is exactly today's behavior.
    private static func execBitRepaired(_ ipa: URL) async throws -> URL? {
        guard let member = await AppMetadataCache.executableMember(of: ipa),
            let helper = Bundled.tool("ipod-helper")
        else { return nil }
        guard let mode = ZipMembers.permissions(ipa, member), mode & 0o111 == 0 else { return nil }

        let out = FileManager.default.temporaryDirectory
            .appendingPathComponent("ltm-fixed-\(UUID().uuidString)")
            .appendingPathExtension("ipa")
        var succeeded = false
        defer { if !succeeded { try? FileManager.default.removeItem(at: out) } }
        let result = try await run(
            .path(FilePath(helper)),
            arguments: ["ipa-chmod", ipa.path, out.path, member],
            output: .discarded,
            error: .string(limit: 1 << 16)
        )
        guard result.terminationStatus.isSuccess, FileManager.default.fileExists(atPath: out.path) else {
            logEvent("install: executable repair failed: \(result.standardError)")
            throw DeviceError.preflight("Couldn’t prepare the app’s files for install.")
        }
        succeeded = true
        logEvent("install: \(member) archived non-executable — repacked 0755")
        return out
    }

    /// Whether a declared MinimumOSVersion ("4.0", "6.1") is newer than the
    /// device's OS — the version iPhone OS itself refuses to launch past.
    /// Tolerates a leading "iphoneos" so an accidental DTSDKName still parses.
    public static func sdkTooNew(_ sdkName: String?, deviceOS: String = "3.1.3") -> Bool {
        guard let sdkName else { return false }
        let digits = sdkName.drop { !$0.isNumber }
        let parts = digits.split(separator: ".").compactMap { Int($0) }
        let device = deviceOS.split(separator: ".").compactMap { Int($0) }
        for (a, b) in zip(parts, device) where a != b { return a > b }
        return parts.count > device.count && parts[device.count] > 0
    }

    /// Retry only genuinely transient device errors (a service refusing
    /// connections right after boot or an uninstall); a rejected package or a
    /// full disk fails immediately.
    private func withTransientRetry(attempts: Int, _ body: () async throws -> Void) async throws {
        var lastError: Error = DeviceError.failed("no attempt made")
        for i in 0..<attempts {
            do { return try await body() } catch let error as DeviceError where error.isTransient {
                lastError = error
                try await Task.sleep(for: .seconds(Double(min(i + 1, 5)) * 2))
            }
        }
        throw lastError
    }

    /// The one id both phases share for a given app, so a placeholder raised
    /// at download start is the SAME icon the install phase adopts and
    /// cancels — never two. (Two ids was tried: the download's icon and the
    /// install's coexisted on the home screen through the whole install.)
    public static func placeholderID(for key: String) -> String {
        "qemu-install-"
            + key
            .filter { $0.isLetter || $0.isNumber || $0 == "." || $0 == "-" || $0 == "_" }
    }

    /// Raise or drop the placeholder from outside the install path (the
    /// catalog's download phase). Cancel of an id that is already gone is a
    /// no-op on SpringBoard, so belt-and-suspenders cancels are safe.
    @discardableResult
    public func installPlaceholder(
        _ action: String,
        bundleID: String,
        after previous: Task<Void, Never>? = nil
    ) -> Task<Void, Never>? {
        guard agent.isAlive else { return nil }
        return placeholderIcon(action, Self.placeholderID(for: bundleID), bundleID: bundleID, after: previous)
    }

    /// Deliberately fire-and-forget and cosmetic: a slow or absent agent costs
    /// the install nothing. An unstructured Task does not inherit cancellation,
    /// which lets the `cancel` in a defer still run when the install was
    /// cancelled; if even that is lost, the icon dies with the running SpringBoard.
    @discardableResult
    private func placeholderIcon(
        _ action: String,
        _ id: String,
        bundleID: String? = nil,
        after previous: Task<Void, Never>? = nil
    ) -> Task<Void, Never> {
        let agent = self.agent
        return Task {
            await previous?.value
            guard agent.isAlive else { return }
            do { try await agent.placeholder(action, id: id, bundleID: bundleID) } catch {
                logEvent("install placeholder \(action): \(error.localizedDescription)")
            }
        }
    }
}
