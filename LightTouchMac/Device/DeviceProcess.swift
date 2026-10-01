import HostRuntime
import Foundation
import CoreGraphics
import IOSurface

/// One running device's LightTouchDevice (docs/multi-device-plan.md, A): spawned
/// with its own native.log, its hello checked against the board, booted once.
/// It dies once (`onDeath`, with the reason the row and the dead overlay show);
/// a restart is a new DeviceProcess. Session tests currently compile this app
/// adapter; the boot recipe and storage lease come from the real HostRuntime module.
@MainActor final class DeviceProcess {
    let link: DeviceLink
    let profile: DeviceProfile
    private let log: ProcessLogCapture?
    /// `.audio` and `.audioEnded`, for the recorder (GuestAudioCapture).
    var onAudio: ((LinkEvent) -> Void)?
    /// Fires once: the helper is gone, or never came up.
    var onDeath: ((String) -> Void)?
    private(set) var deathReason: String?
    var isDead: Bool { deathReason != nil }
    /// The hello reply (dylib path and mtime, build id, board), nil until it answered.
    var info: HelperInfo? { link.info }
    var status: SharedStatus? { link.status }
    private var qemuExitCode: Int32?
    private var startFailure: String?
    /// terminate() was asked: an exit 0 is the stop we requested, whether or not
    /// the qemuExited event made it out before the exit.
    private var stopRequested = false
    /// The spawned helper's pid, for the log: the link zeroes its own on reap.
    private var helperPID: pid_t = 0

    /// `helper` and `requirement` default to the bundled helper and the app's Team (tests pass their own).
    /// `lease` is the device's work/lease: the helper refuses to run beside another holder.
    init(instance: UUID, profile: DeviceProfile, log url: URL, lease: URL? = nil, helper: URL? = nil, requirement: String? = nil) {
        self.profile = profile
        do { log = try ProcessLogCapture(url: url) }
        catch {
            logEvent("device helper: native.log unavailable at \(url.path): \(error.localizedDescription)")
            log = nil
        }
        var configuration = DeviceLink.Configuration(instance: instance, outputDescriptor: log?.writeDescriptor ?? -1)
        if let helper { configuration.helper = helper }
        configuration.machine = profile.machineName
        configuration.requirement = requirement
        if let lease { configuration.arguments = ["--lease", lease.path] }
        link = DeviceLink(configuration: configuration)
        link.onEvent = { [weak self] event in MainActor.assumeIsolated { self?.received(event) } }
        link.onTerminated = { [weak self] termination in MainActor.assumeIsolated { self?.terminated(termination) } }
    }

    /// Spawn, rendezvous and hello, check the board, then boot what `configure`
    /// builds from the hello (nil: don't boot). `completion` runs once; a
    /// failure is also a death (onDeath follows).
    func start(_ configure: @escaping (HelperInfo) -> BootConfig?,
               completion: @escaping (Result<HelperInfo, DeviceLinkError>) -> Void) {
        link.start { [weak self] result in
            MainActor.assumeIsolated { self?.started(result, configure, completion) }
        }
        helperPID = link.pid   // the spawn is synchronous
    }

    private func started(_ result: Result<HelperInfo, DeviceLinkError>, _ configure: (HelperInfo) -> BootConfig?,
                         _ completion: @escaping (Result<HelperInfo, DeviceLinkError>) -> Void) {
        switch result {
        case let .failure(error): failStart(error, completion)
        case let .success(info):
            checkBoard(info)
            guard let config = configure(info) else { return failStart(.helperFailure("not booted"), completion) }
            link.request(.boot(config), timeout: 30) { [weak self] reply in
                MainActor.assumeIsolated { self?.booted(reply, info, completion) }
            }
        }
    }

    private func booted(_ reply: Result<LinkReply, DeviceLinkError>, _ info: HelperInfo,
                        _ completion: (Result<HelperInfo, DeviceLinkError>) -> Void) {
        switch reply {
        case .success(.ok(true)): completion(.success(info))
        case let .success(.failure(message)): failStart(.helperFailure(message), completion)
        case let .success(other): failStart(.helperFailure("unexpected boot reply \(other)"), completion)
        case let .failure(error): failStart(error, completion)
        }
    }

    /// SIGTERM: the helper pauses storage and halts QEMU within a bounded time.
    /// This does not request a guest filesystem shutdown.
    /// Never after its death (the link also zeroes its pid on reap).
    func terminate() { if !isDead { stopRequested = true; link.terminate() } }
    func kill() { if !isDead { link.kill() } }

    /// True once the helper is gone, false after `timeout`.
    func waitForExit(timeout: TimeInterval) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !isDead, Date() < deadline { try? await Task.sleep(for: .milliseconds(50)) }
        return isDead
    }

    private func received(_ event: LinkEvent) {
        switch event {
        case let .qemuExited(code): qemuExitCode = code
        case .audio, .audioEnded: onAudio?(event)
        }
    }

    /// Geometry is DeviceProfile's constants; the dylib only confirms them.
    private func checkBoard(_ info: HelperInfo) {
        logEvent("emulator dylib: \(info.dylibPath) (built \(Date(timeIntervalSince1970: info.dylibModified)), build \(info.buildID ?? "unknown")) in helper \(info.pid)")
        guard let device = info.deviceInfo else {
            return logEvent("display: libqemu-arm.dylib does not know machine \(profile.machineName)")
        }
        let reported = CGSize(width: device.screenWidth, height: device.screenHeight)
        if reported != profile.screenPixels {
            logEvent("display: \(profile.machineName) is \(profile.screenPixels) in DeviceProfile but \(reported) in the dylib")
        }
    }

    private func failStart(_ error: DeviceLinkError, _ completion: (Result<HelperInfo, DeviceLinkError>) -> Void) {
        let reason = if case .helperFailure(DeviceLinkWire.leaseRefusal) = error { DeviceLinkWire.leaseRefusal }
            else { "The \(profile.shortName) didn’t start." }
        logEvent("device helper: didn’t start: \(error)")
        if startFailure == nil { startFailure = reason }
        completion(.failure(error))
        // A spawned helper reports its own end; one that never ran can't.
        if link.pid > 0 { link.kill() } else { died(reason) }
    }

    private func terminated(_ termination: DeviceTermination) {
        let reason: String
        if let startFailure { reason = startFailure }
        // The user sees stopped or stopped unexpectedly; the exit code and signal go to the log.
        else if qemuExitCode == 0 || (qemuExitCode == nil && stopRequested && termination == .exited(0)) { reason = profile.stoppedReason }
        else { reason = "The \(profile.shortName) stopped unexpectedly." }
        logEvent("device helper \(helperPID): \(termination), QEMU exit \(qemuExitCode.map(String.init) ?? "none") — \(reason)")
        died(reason)
    }

    private func died(_ reason: String) {
        guard deathReason == nil else { return }
        deathReason = reason
        log?.flush()
        onDeath?(reason)
    }
}
