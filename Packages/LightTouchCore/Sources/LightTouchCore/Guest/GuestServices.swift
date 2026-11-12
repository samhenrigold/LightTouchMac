// Guest services without a shell (qemu-ios docs/archive/guest-services-plan.md, P2).
//
// Everything the app asks of a running iPod goes through the guest agent's
// typed v2 ops (contrib/it-agent/README.md): spawn with no shell, put/get,
// chown/unlink, sync, launch, frontmost, lockstatus, orientation, dlicon,
// halt. Stock lockdown services (installs, AFC, the time zone through the
// lockdown-tz child process) are DeviceServices (Services/).
//
// Capabilities come from the agent's ping: a v2 agent lists its ops; a v1
// agent (older images, which still carry freeze's /bin/sh) answers only its
// version, and each op it lacks falls back here to its `exec` with the same
// command a shell would have run. No SSH anywhere.
//
// Foundation only, so tests/drivers/session-driver compiles it as the app does.

import Foundation
import HostRuntime
import HostServiceWire

public enum AppLaunchError: Error {
    case locked, unavailable, failed

    public func message(for profile: Board) -> String {
        switch self {
        case .locked: "Unlock the \(profile.shortName), then try again."
        case .unavailable: "Wait for the \(profile.shortName) to finish starting, then try again."
        case .failed: "Try opening the app on the \(profile.shortName)."
        }
    }
}

/// The app's guest operations, over the agent.
public nonisolated struct GuestServices: Sendable {
    public init(agent: GuestAgent, packaged: Bool = false) {
        self.agent = agent
        self.packaged = packaged
    }
    public let agent: GuestAgent
    /// True when the guest runs a package from the loader (a guest-package
    /// report arrived): its binaries are under `packageBin`.
    public var packaged = false

    public static let packageBin = "/usr/local/lighttouch/current/bin"
    public static let launchctl = "/bin/launchctl"

    // MARK: Media

    /// Commit staged media into the library with itmedia (Music, Videos: a
    /// metadata plist) or itphoto (Saved Photos). Always use the app's helper:
    /// older installed packages may silently ignore new metadata fields.
    public func commitMedia(id: String, helper: String, localHelper: () throws -> URL, metadata: URL?) async throws
        -> Bool
    {
        guard UUID(uuidString: id) != nil else { throw DeviceToolsError.failed("Invalid media staging identifier.") }
        try await agent.chown(501, 501, "/var/mobile/Media/LightTouch")
        try await agent.chown(501, 501, "/var/mobile/Media/LightTouch/\(id)")
        var temporary: [String] = []
        var arguments = [id]
        if let metadata {
            let remote = "/tmp/ltm-media-\(id).plist"
            try await agent.put(remote, mode: 0o644, try Data(contentsOf: metadata))
            temporary.append(remote)
            arguments.insert(remote, at: 0)
        }
        do {
            let executable = "/tmp/ltm-\(helper)-\(id)"
            try await agent.put(executable, mode: 0o755, try Data(contentsOf: localHelper()))
            temporary.append(executable)
            let output = try await agent.spawn([executable] + arguments)
            for path in temporary { try? await agent.unlink(path) }
            return String(decoding: output, as: UTF8.self).hasSuffix("imported\n")
        } catch {
            for path in temporary { try? await agent.unlink(path) }
            throw error
        }
    }

    // MARK: Trust

    /// Trust a CA in the guest's own trust store the way a profile install
    /// does, through securityd's API (ittrust: SecTrustStoreSetTrustSettings
    /// in the user domain), with no screen on the device. The package's copy,
    /// or the app's uploaded to /tmp for the one run. Idempotent; the store
    /// keeps it across boots, so nothing asks twice. ittrust adapts at runtime
    /// (dlopen), one source for both arches.
    public func trustCertificate(_ der: Data, localTool: (String) throws -> Data) async throws {
        let cert = "/tmp/ltm-ca-\(UUID().uuidString).der"
        try await agent.put(cert, mode: 0o644, der)
        let output: String
        do { output = try await runTool("ittrust", ["add", cert], localTool: localTool) } catch {
            try? await agent.unlink(cert)
            throw error
        }
        try? await agent.unlink(cert)
        guard output.contains("Guest trust add: 0") else {
            throw DeviceToolsError.failed("The device didn’t accept the certificate: \(output)")
        }
    }

    /// The image's baked PAC (/usr/share/ltm/proxy.pac, /usr/local/share/ltm/ before 09-30: every request to the
    /// web proxy guestfwd, DIRECT as fallback) routes the guest through the proxy. An image without it (the legacy iPod
    /// image) goes straight out through slirp, so the trusted CA never sees a request: itproxy points
    /// the Wi-Fi service's HTTP and HTTPS proxies at the guestfwd through configd (idempotent; it keeps
    /// a backup of the keys it owns). The host's "off" mode passes those connections straight through.
    public func routeThroughProxy(localTool: (String) throws -> Data) async throws {
        for pac in [Self.proxyPAC, Self.legacyProxyPAC] where try await agent.get(pac, limit: 1 << 20) != nil { return }
        let output = try await runTool("itproxy", ["on"], localTool: localTool)
        guard output.contains("Proxy enabled") else {
            throw DeviceToolsError.failed("The device didn’t accept the proxy setting: \(output)")
        }
    }

    public static let proxyPAC = "/usr/share/ltm/proxy.pac"
    /// Where earlier preparations baked it; 4.x's Safari sandbox can't read it there (re-prepare to fix Safari).
    public static let legacyProxyPAC = "/usr/local/share/ltm/proxy.pac"

    /// A guest tool's output: the package's copy, or the app's uploaded to /tmp for the one run.
    private func runTool(_ name: String, _ arguments: [String], localTool: (String) throws -> Data) async throws
        -> String
    {
        if packaged {
            do {
                return String(
                    decoding: try await agent.spawn(["\(Self.packageBin)/\(name)"] + arguments),
                    as: UTF8.self
                )
            } catch let error as GuestAgentError where error.status == GuestAgentError.notFound {}
        }
        let executable = "/tmp/ltm-\(name)-\(UUID().uuidString)"
        try await agent.put(executable, mode: 0o755, try localTool(name))
        let output: Data
        do { output = try await agent.spawn([executable] + arguments) } catch {
            try? await agent.unlink(executable)
            throw error
        }
        try? await agent.unlink(executable)
        return String(decoding: output, as: UTF8.self)
    }

    // MARK: Time zone

    /// 4.x's locationd applies an external zone (lockdown's TimeZone, as iTunes
    /// wrote it) only while it has applied none: the first one is kept as
    /// PreviousTimeZone in its cache and every later external zone is dropped
    /// (CLTimeZoneManager::handleExternalTimeZoneUpdate, 4.2.1 locationd
    /// 0x910e0), so the Mac's zone reached a device once and never followed the
    /// Mac again. Clears that record with locationd unloaded (it writes the cache
    /// as it exits), so its next external zone applies as on a fresh device.
    /// False, touching nothing, when the cache holds no such record.
    public func forgetExternalTimeZone() async throws -> Bool {
        let cache = "/var/root/Library/Caches/locationd/cache.plist"
        let job = "/System/Library/LaunchDaemons/com.apple.locationd.plist"
        func withoutRecord() async throws -> Data? {
            guard let data = try await agent.get(cache, limit: 16 << 20),
                var plist = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
                plist.removeValue(forKey: "PreviousTimeZone") != nil
            else { return nil }
            return try PropertyListSerialization.data(fromPropertyList: plist, format: .binary, options: 0)
        }
        guard try await withoutRecord() != nil else { return false }
        try await agent.spawn([Self.launchctl, "unload", job])
        do {
            if let edited = try await withoutRecord() { try await agent.put(cache, mode: 0o644, edited) }
        } catch {
            _ = try? await agent.spawn([Self.launchctl, "load", job])
            throw error
        }
        try await agent.spawn([Self.launchctl, "load", job])
        return true
    }

    // MARK: SpringBoard and launchd

    /// What the era's jailbreak respring restarted: from iOS 6, where backboardd is the window server and owns HID,
    /// backboardd (sbreload, `killall backboardd`), and SpringBoard and every app go with it; before that, SpringBoard
    /// (and its apps). launchd's KeepAlive brings them straight back. Which one is the guest's own answer: the
    /// firmware has a backboardd job or not. Where the agent tells which SpringBoard answers it, this returns when
    /// another one does (a minute at most): the one being stopped still answers for a moment, as if nothing happened.
    public func respring() async throws {
        let job =
            try await agent.get(Self.backboarddJob, limit: 1 << 20) != nil
            ? "com.apple.backboardd" : "com.apple.SpringBoard"
        let stopped = agent.report?.springBoard
        try await agent.spawn([Self.launchctl, "stop", job])
        if let stopped, stopped > 1 {
            _ = await agent.waitForReport(seconds: 60) { $0.isAnswering && $0.springBoard != stopped }
            try Task.checkCancellation()
        }
    }

    static let backboarddJob = "/System/Library/LaunchDaemons/com.apple.backboardd.plist"
    /// A launch SpringBoard refuses while it is busy is asked this many times, this far apart (shorter in tests).
    static let launchTries = 3
    nonisolated(unsafe) static var launchRetryPause: Duration = .seconds(1)

    /// launchd owns and relaunches lockdownd.
    public func reconnectManagement() async throws {
        try await agent.spawn([Self.launchctl, "stop", "com.apple.mobile.lockdown"])
    }

    /// SpringBoardServices' launch, the same path a tap on the icon takes. It
    /// refuses a locked device, which lockstatus then tells apart. It also refuses while another app is still
    /// closing (3.1.3 answers an error a third of a second after Home, and takes the same launch a moment later),
    /// so a refusal that isn't the lock is asked again, `launchTries` times in all. Only a refusal: a request whose
    /// answer was lost is never repeated (GuestAgent).
    public func launch(_ bundleID: String) async throws {
        for attempt in 1...Self.launchTries {
            do {
                try await agent.launch(bundleID)
                return
            } catch is CancellationError { throw CancellationError() } catch {
                logEvent("launch \(bundleID): \(error.localizedDescription)")
                if (try? await agent.isLocked()) == true { throw AppLaunchError.locked }
                guard error is GuestAgentError, attempt < Self.launchTries else { throw AppLaunchError.failed }
                try await Task.sleep(for: Self.launchRetryPause)
            }
        }
    }

    /// Text into the focused field through the agent's `type` (it_typein in the frontmost app). False when the agent
    /// said it didn't type it (no such op, no it_typein polling in this guest, no field, a locked device): the
    /// caller's keys do then. True when it did, and also when it never answered: the text may be in the field, and
    /// typing it again would double it.
    public func type(_ text: String) async -> Bool {
        guard (try? await agent.capabilities().has("type")) == true else { return false }
        do {
            // The emulator gives a routed request 5 s (qemu-ios hw/arm/ipod-agent.c); past that the agent is gone.
            return try await agent.raw("type", body: Data(text.utf8), deadline: 10).status == 0
        } catch {
            logEvent("typing: no answer from the guest agent; \(text.count) characters not typed again")
            return true
        }
    }

    public func foregroundAppName() async throws -> String? {
        let name = try await agent.frontmost().name.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? nil : String(name.prefix(200))
    }

    /// Foreground bundle id and display name in one round-trip. The bundle id
    /// tells Setup (com.apple.purplebuddy) from the home screen/lock screen
    /// (com.apple.springboard); the name is the trimmed display name (nil when empty).
    public func foreground() async throws -> (bundleID: String, name: String?) {
        let f = try await agent.frontmost()
        let name = f.name.trimmingCharacters(in: .whitespacesAndNewlines)
        return (f.bundleID, name.isEmpty ? nil : String(name.prefix(200)))
    }
}
