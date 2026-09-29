// Created by Sam on 2026-08-05.
//
// Host-side app management over USB. Installs, listing, uninstalls and media
// staging are stock lockdown services in-process (DeviceServices); guest
// commands are the agent's typed ops (GuestServices). No SSH, no guest shell.
// External host tools run via swift-subprocess.

import Foundation
import Subprocess
import System

struct InstalledApp: Identifiable, Sendable {
    /// The `CFBundleIdentifier`
    let id: String
    let name: String
    let version: String
}

/// Talks to one running device, identified by its usbmuxd client socket. The
/// facade the UI calls.
struct DeviceTools: Sendable {
    let clientSocket: String
    /// This device's web-proxy files (WebProxyConfiguration.directory).
    let proxyDirectory: URL
    /// The device's helper, for the guest agent (DeviceLink `.agent` requests).
    var agent: DeviceLink?
    /// The agent's capabilities, per device (EmulatorController's).
    var agentCache = GuestAgentCache()
    /// A guest-package report arrived: the guest runs a loader package.
    var packaged = false
    /// The device's iOS version (its catalog entry), which MinimumOSVersion is checked against.
    var deviceOS = "3.1.3"

    private var proxyFile: String { WebProxyConfiguration.file(in: proxyDirectory).path }
    private var guestAgent: GuestAgent { GuestAgent(link: agent, cache: agentCache) }
    private var guest: GuestServices { GuestServices(agent: guestAgent, packaged: packaged) }

    private var services: DeviceServices { DeviceServices(clientSocket: clientSocket) }

    // The app's own tools first, then Homebrew's — without assuming any PATH.
    private static let searchPaths = Bundled.binarySearchPaths

    /// The raw libimobiledevice tools (lockdown-mcinstall) find this device here.
    private var toolEnvironment: Environment {
        .inherit.updating(["USBMUXD_SOCKET_ADDRESS": clientSocket])
    }
    
    // MARK: - List (in-process)

    func installedApps() async throws -> [InstalledApp] {
        try await services.installedApps()
    }

    // MARK: - Music import

    func stageSong(_ song: MediaSong, progress: @escaping @Sendable (Double) -> Void) async throws {
        try await services.stageSong(song, progress: progress)
    }

    /// Once this starts, keep the staged audio even on an uncertain outcome.
    /// The guest service owns database mutations and reconciles the same path.
    func commitSong(_ song: MediaSong) async throws {
        try await commitLibraryMedia(id: song.id, metadata: song.metadata, destination: "Music")
    }

    private func commitLibraryMedia(id: String, metadata: URL, destination: String) async throws {
        guard try await guest.commitMedia(id: id, helper: "itmedia", localHelper: { try Self.guestTool("itmedia") },
                                          metadata: metadata) else {
            throw DeviceToolsError.failed("\(destination) did not confirm the import. The copied media has been retained.")
        }
    }

    /// The app's copy of a guest helper for images whose loader package lacks it.
    private static func guestTool(_ name: String) throws -> URL {
        guard let path = Bundled.resolve(name, fallbacks: ["\(Bundled.filesRoot)/../qemu-ios/contrib/it-media/\(name)"]) else {
            throw DeviceToolsError.toolMissing(name)
        }
        return URL(fileURLWithPath: path)
    }

    // MARK: - Photo import

    func stageMedia(_ media: PreparedMedia, progress: @escaping @Sendable (Double) -> Void) async throws {
        switch media {
        case .song(let song): try await stageSong(song, progress: progress)
        case .photo(let photo): try await services.stagePhoto(photo, progress: progress)
        case .video(let video): try await services.stageVideo(video, progress: progress)
        }
    }

    func commitMedia(_ media: PreparedMedia) async throws {
        switch media {
        case .song(let song): try await commitSong(song)
        case .photo(let photo): try await commitPhoto(photo)
        case .video(let video): try await commitLibraryMedia(id: video.id, metadata: video.metadata, destination: "Videos")
        }
    }

    func commitPhoto(_ photo: MediaPhoto) async throws {
        guard try await guest.commitMedia(id: photo.id, helper: "itphoto", localHelper: { try Self.guestTool("itphoto") },
                                          metadata: nil) else {
            throw DeviceToolsError.failed("Photos did not confirm the import. Check Saved Photos before importing it again.")
        }
    }

    // MARK: - Install

    /// Install a decrypted .ipa: AFC stage + instproxy, in-process, no shell.
    /// Every supported image carries its GL engine shim. `progress` gets
    /// short, human phase strings for the sidebar row. The return string is
    /// non-empty only to carry the "SDK too new" marker the caller warns on.
    @discardableResult
    func install(_ ipa: URL, placeholderRaised: Bool = false,
                 progress: @escaping @Sendable (String) -> Void = { _ in }) async throws -> String {
        // MinimumOSVersion, NOT DTSDKName. The SDK an app was BUILT with says
        // nothing about whether it runs: Temple Run 1.0 is DTSDKName
        // iphoneos4.2 with MinimumOSVersion 3.0 and runs fine on 3.1.3 (the
        // device's own version is what it is compared with). Gating
        // on the build SDK cried wolf on most of the library, which trains
        // people to click through the one warning that is real. iPhone OS
        // enforces MinimumOSVersion, so that is what we check.
        let minOS = await AppMetadataCache.shared.minimumOS(from: ipa)
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
                "“\(ipa.lastPathComponent)” doesn't look like an iPhone app archive — "
                + "it has no Payload/…app/Info.plist inside.")
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
            let key = await AppMetadataCache.bundleID(of: ipa)
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
            let free = try await services.freeSpaceBytes()
            let needed = Int64(bytes) * 2 + (16 << 20)
            guard free >= needed else { throw DeviceError.diskFull(free: free, needed: needed) }

            progress("Sending to device…")
            let staged = try await services.stage(ipa) { frac in
                progress("Sending to device… \(Int(frac * 100))%")
            }
            defer { Task { await services.removeStaged(staged) } }

            // Cancelling during the upload is honoured here, at the last point
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
                try await services.install(stagedPath: staged) { pct, _ in
                    progress(pct >= 0 ? "Installing… \(pct)%" : "Installing…")
                }
            }
            return "installed" + sdkMarker
        }
    }

    /// If the .ipa stores its main binary without the exec bit, a copy repacked
    /// 0755 (via the bundled ipod-helper, the same tool install-ipa.sh uses);
    /// nil if no repair is needed or anything is unreadable — callers fall back
    /// to the original, which is exactly today's behaviour.
    /// A development build has no bundled lockdown helpers (package.sh builds
    /// them), so the time zone was never synced when running from Xcode.
    /// Debug builds compile scripts/<name>.c against Homebrew's
    /// libimobiledevice into the work directory, once per source change.
    static func developmentHelper(_ name: String) -> String? {
        #if DEBUG
        let source = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("scripts/\(name).c")
        let binary = Bundled.workDirectory.appendingPathComponent("dev-tools/\(name)")
        let fm = FileManager.default
        guard let sourceDate = (try? fm.attributesOfItem(atPath: source.path))?[.modificationDate] as? Date else { return nil }
        if let built = (try? fm.attributesOfItem(atPath: binary.path))?[.modificationDate] as? Date,
           built >= sourceDate, fm.isExecutableFile(atPath: binary.path) { return binary.path }
        try? fm.createDirectory(at: binary.deletingLastPathComponent(), withIntermediateDirectories: true)
        let build = Process()
        build.executableURL = URL(fileURLWithPath: "/bin/sh")
        build.arguments = ["-c", "PATH=/opt/homebrew/bin:/usr/local/bin:$PATH; "
            + "cc -O2 -o \"$1\" \"$2\" $(pkg-config --cflags --libs libimobiledevice-1.0 libplist-2.0)",
            "sh", binary.path, source.path]
        do { try build.run() } catch { return nil }
        build.waitUntilExit()
        guard build.terminationStatus == 0 else {
            logEvent("\(name): could not build the development helper")
            return nil
        }
        return binary.path
        #else
        return nil
        #endif
    }

    private static func execBitRepaired(_ ipa: URL) async throws -> URL? {
        guard let member = await AppMetadataCache.executableMember(of: ipa),
              let helper = Bundled.tool("ipod-helper") else { return nil }
        // `unzip -Z` long listing: the mode string is the first field and the
        // member the last, e.g. "-rw-r--r--  2.0 unx  … Payload/X.app/X".
        guard let listing = try? await run(
            .path(FilePath("/usr/bin/unzip")), arguments: ["-Z", ipa.path],
            output: .string(limit: 1 << 22), error: .discarded).standardOutput,
              let line = listing.split(separator: "\n").first(where: {
                  $0.hasSuffix(" " + member)
              }),
              let mode = line.split(separator: " ").first,
              mode.count >= 4, !mode.contains("x")
        else { return nil }

        let out = FileManager.default.temporaryDirectory
            .appendingPathComponent("ltm-fixed-\(UUID().uuidString)")
            .appendingPathExtension("ipa")
        var succeeded = false
        defer { if !succeeded { try? FileManager.default.removeItem(at: out) } }
        let result = try await run(
            .path(FilePath(helper)),
            arguments: ["ipa-chmod", ipa.path, out.path, member],
            output: .discarded, error: .string(limit: 1 << 16))
        guard result.terminationStatus.isSuccess, FileManager.default.fileExists(atPath: out.path) else {
            logEvent("install: executable repair failed: \(result.standardError)")
            throw DeviceError.preflight("Could not repair the IPA's executable permissions.")
        }
        succeeded = true
        logEvent("install: \(member) archived non-executable — repacked 0755")
        return out
    }

    /// Whether a declared MinimumOSVersion ("4.0", "6.1") is newer than the
    /// device's OS — the version iPhone OS itself refuses to launch past.
    /// Tolerates a leading "iphoneos" so an accidental DTSDKName still parses.
    static func sdkTooNew(_ sdkName: String?, deviceOS: String = "3.1.3") -> Bool {
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
            do { return try await body() }
            catch let error as DeviceError where error.isTransient {
                lastError = error
                try await Task.sleep(for: .seconds(Double(min(i + 1, 5)) * 2))
            }
        }
        throw lastError
    }

    // MARK: - Uninstall (in-process)

    func uninstall(_ bundleID: String) async throws {
        try await services.uninstall(bundleID)
    }

    // MARK: - Free space (in-process)

    func freeSpaceBytes() async throws -> Int64 { try await services.freeSpaceBytes() }

    /// Respring: launchd stops SpringBoard and KeepAlive brings it straight back.
    ///
    /// This is the cheap fix for the "a freshly sideloaded app crashes until I
    /// restart the iPod" problem — SpringBoard caches what it knows about
    /// installed apps, and a respring rebuilds that in a few seconds where a
    /// full boot costs ~40. A deliberate, user-invoked action, never something
    /// the install path does behind your back.
    func restartSpringBoard() async throws { try await guest.respring() }

    /// Nil means this image has no agent; failures must not start a second transport.
    func guestOrientation() async throws -> Int? {
        guard guestAgent.status != 0 else { return nil }
        return try await guestAgent.orientation()
    }

    /// SpringBoard's foreground app name (the agent's frontmost); nil without an agent.
    func foregroundAppName() async throws -> String? {
        guard guestAgent.isAlive else { return nil }
        return try await guest.foregroundAppName()
    }

    /// Both boards, no guest helper: routing is the image's PAC (always the proxy, DIRECT as fallback) and
    /// the host's itwebproxy mode, so only trust needs the device. Turning the proxy on offers a
    /// configuration profile with this device's CA through lockdown's stock MCInstall service
    /// (lockdown-mcinstall, a child process like lockdown-tz); the user taps Install once in Settings.
    /// ponytail: turning it off leaves the profile installed (the CA is this device's own and its key
    /// never leaves the Mac); remove it in Settings > General > Profiles, or add RemoveProfile if asked.
    func configureWebProxy(enabled: Bool) async throws {
        guard enabled else { return }
        guard let host = Bundled.resolve("itwebproxy", fallbacks: [
            "\(Bundled.filesRoot)/../qemu-ios/contrib/it-webproxy/itwebproxy"
        ]) else { throw DeviceToolsError.toolMissing("itwebproxy") }
        // Packaged apps bundle it (package.sh); dev builds find it on the usual PATH directories.
        guard let tool = Bundled.resolve("lockdown-mcinstall", fallbacks: Bundled.binarySearchPaths.map { "\($0)/lockdown-mcinstall" })
        else { throw DeviceToolsError.toolMissing("lockdown-mcinstall") }
        let prepared = try await run(.path(FilePath(host)), arguments: ["--init-ca", proxyFile],
                                     output: .discarded, error: .string(limit: 1 << 16))
        guard prepared.terminationStatus.isSuccess else {
            logEvent("proxy: certificate preparation failed: \(prepared.standardError)")
            throw DeviceToolsError.failed("Could not prepare this device’s HTTP proxy certificate.")
        }
        let offered = try await run(.path(FilePath(tool)), arguments: [proxyFile + ".ca.der"],
                                    environment: toolEnvironment,
                                    output: .string(limit: 1 << 10), error: .string(limit: 1 << 10))
        guard offered.terminationStatus.isSuccess else {
            throw DeviceToolsError.failed("Could not offer the proxy certificate to the device. \(offered.standardError)")
        }
        logEvent("proxy: certificate profile offered; confirm Install in the device's Settings")
    }

    /// Push the guest's dirty buffers to flash.
    func syncFilesystem() async throws { try await guestAgent.sync() }

    /// Ask SpringBoard to launch an installed app — the same path a tap on
    /// its icon takes (the agent's SBSLaunchApplicationWithIdentifier).
    /// SpringBoard refuses the request on a locked device.
    func launchApp(_ bundleID: String) async throws {
        guard guestAgent.isAlive else {
            throw DeviceToolsError.failed("Open the app on the device’s Home screen; launching from the sidebar isn’t available for this device yet.")
        }
        try await guest.launch(bundleID)
    }

    static func reconnectManagementService(agent: DeviceLink?, cache: GuestAgentCache) async throws -> Bool {
        // Recovery must not queue on the broken management transport: the agent
        // is independent of lockdown. launchd owns and relaunches lockdownd.
        let guest = GuestServices(agent: GuestAgent(link: agent, cache: cache))
        guard guest.agent.isAlive else { return false }
        try await guest.reconnectManagement()
        return true
    }

    /// The one id both phases share for a given app, so a placeholder raised
    /// at download start is the SAME icon the install phase adopts and
    /// cancels — never two. (Two ids was tried: the download's icon and the
    /// install's coexisted on the home screen through the whole install.)
    static func placeholderID(for key: String) -> String {
        "qemu-install-" + key
            .filter { $0.isLetter || $0.isNumber || $0 == "." || $0 == "-" || $0 == "_" }
    }

    /// Raise or drop the placeholder from outside the install path (the
    /// catalog's download phase). Cancel of an id that is already gone is a
    /// no-op on SpringBoard, so belt-and-suspenders cancels are safe.
    @discardableResult
    func installPlaceholder(_ action: String, bundleID: String,
                            after previous: Task<Void, Never>? = nil) -> Task<Void, Never>? {
        guard guestAgent.isAlive else { return nil }
        return placeholderIcon(action, Self.placeholderID(for: bundleID), bundleID: bundleID, after: previous)
    }

    /// Deliberately fire-and-forget and cosmetic: a slow or absent agent costs
    /// the install nothing. An unstructured Task does not inherit cancellation,
    /// which lets the `cancel` in a defer still run when the install was
    /// cancelled; if even that is lost, the icon dies with the running SpringBoard.
    @discardableResult
    private func placeholderIcon(_ action: String, _ id: String, bundleID: String? = nil,
                                 after previous: Task<Void, Never>? = nil) -> Task<Void, Never> {
        let agent = guestAgent
        return Task {
            await previous?.value
            guard agent.isAlive else { return }
            do { try await agent.placeholder(action, id: id, bundleID: bundleID) }
            catch { logEvent("install placeholder \(action): \(error.localizedDescription)") }
        }
    }

    // MARK: - Timezone

    /// Sync the guest's timezone through the bundled lockdown-tz helper — a
    /// child process ON PURPOSE. lockdownd_set_value called in-process against
    /// 3.1.3's lockdownd corrupts the heap: the app died ~20 s later in
    /// unrelated Swift runtime code, reproducibly, while the identical call
    /// from a child process is clean (scripts/lockdown-tz.c). The tool reads
    /// first, sets only on mismatch, and prints the zone in effect. Dev builds
    /// without the bundled tool skip quietly — the zone is cosmetic.
    func setTimeZone(_ identifier: String) async throws {
        guard let tool = Bundled.tool("lockdown-tz") ?? Self.developmentHelper("lockdown-tz") else {
            logEvent("timezone: no bundled lockdown-tz (dev build) — leaving the guest's zone alone")
            return
        }
        let zone = try await GuestServices.setTimeZone(identifier, tool: tool, socket: clientSocket)
        logEvent("timezone: guest zone now \(zone)")
    }
}
