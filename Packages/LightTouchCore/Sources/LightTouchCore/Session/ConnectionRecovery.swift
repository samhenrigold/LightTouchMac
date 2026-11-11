// The device connection's health as the session sees it: the standing issue from failed service reads, the
// recovery of an unresponsive management service, and the once-per-boot activation verdict.

import DeviceRuntime
import Foundation
import HostRuntime
import HostServiceWire
import Observation

/// What connection recovery and the activation check read and change on the session.
public protocol ConnectionHost: AnyObject {
    var bootScope: BootSessionScope { get }
    var profile: Board { get }
    /// The last service round trip: nil = never checked. Setting it runs the session's reachability reactions.
    var deviceReachable: Bool? { get set }
    var isRunning: Bool { get }
    var preparingDevice: Bool { get }
    var isInstalling: Bool { get }
    var hasFileTransfer: Bool { get }
    /// An install (AppInstaller) holds this device.
    var installerUsesDevice: Bool { get }
    /// The guest agent, live: 0 absent or not running, 1 alive, 2 stale.
    var liveAgentStatus: Int { get }
    var guestAgentAlive: Bool { get }
    /// Restart lockdownd through the guest agent (independent of the transport that broke).
    func reconnectManagement() async throws
    /// The app list may have changed (.ltmAppsChanged).
    func appsMayHaveChanged()
}

/// A transient installd transition is not a dead device. If repeated reads fail, reopen the management service
/// through the independent guest agent. Never reboot the iPod or touch its applications to repair a connection.
@Observable public final class ConnectionRecovery {
    private unowned let host: ConnectionHost
    private let notices: DeviceNotices
    public init(host: ConnectionHost, notices: DeviceNotices) {
        self.host = host
        self.notices = notices
    }

    public internal(set) var issue: DeviceConnectionIssue?
    private var failures = 0
    var lastRecovery = Date.distantPast
    /// After lockdownd restarts, before the app list is read again.
    var settle: Duration = .seconds(2)
    public var isReconnecting = false
    private var task: Task<Void, Never>? {
        get { host.bootScope[.recovery] }
        set { host.bootScope[.recovery] = newValue }
    }

    public func reportFailure(_ error: Error, operation: String) {
        guard let issue = DeviceConnectionIssue(error: error, operation: operation, profile: host.profile) else {
            return
        }
        // An unactivated guest stays that way for the boot; a transient failure doesn't replace the message.
        if self.issue?.persistent == true, !issue.persistent { return }
        if self.issue != issue {
            logEvent("device connection: \(issue.detail); agent=\(host.liveAgentStatus)")
            AppReports.failed(
                "Services.connectionLost", error, ["issue": issue.summary, "board": host.profile.rawValue])
        }
        self.issue = issue
        if issue.blocksCommands {
            host.deviceReachable = false
        } else {
            // installd can be busy with a deletion made on the iPod itself.
            // Killing lockdownd during that transition only makes it worse.
            failures = 0
        }
    }

    /// A service answered: nothing blocks commands any more, not even a stale activation issue.
    public func servicesAnswered() {
        guard let issue else { return }
        if issue.persistent {
            logEvent("device connection: services answer; clearing \"\(issue.summary)\"")
            notices.resolve(.activation)
        }
        self.issue = nil
    }

    public func cancel() { task?.cancel() }

    /// A boot began or ended: its issue, its failure count and its reconnection are the last boot's.
    public func forget() {
        issue = nil
        failures = 0
        isReconnecting = false
    }

    /// Every reachability change: a second failed read in a row of the kind that a management restart fixes,
    /// with nothing using the device, an agent to do it, and none in the last minute.
    public func consider() {
        if host.deviceReachable == true {
            failures = 0
            return
        }
        guard host.deviceReachable == false, host.isRunning, !host.preparingDevice,
            issue?.reconnectManagement == true
        else { return }
        failures += 1
        guard failures >= 2, task == nil,
            !host.isInstalling, !host.hasFileTransfer, !host.installerUsesDevice, host.liveAgentStatus == 1,
            Date().timeIntervalSince(lastRecovery) >= 60
        else { return }
        lastRecovery = Date()
        failures = 0
        isReconnecting = true
        let generation = host.bootScope.generation
        let settle = settle
        task = Task { [weak self] in
            guard let self else { return }
            let host = host  // held for the attempt, as the session itself was
            defer {
                if generation == host.bootScope.generation {
                    task = nil
                    isReconnecting = false
                }
            }
            do {
                guard host.isRunning, !host.preparingDevice, !host.isInstalling, !host.hasFileTransfer,
                    !host.installerUsesDevice
                else { return }
                // Not through the management transport that broke: the agent
                // is independent of lockdown, and launchd relaunches lockdownd.
                if host.guestAgentAlive {
                    try await host.reconnectManagement()
                    logEvent("device: restarted unresponsive management service; reconnecting")
                    AppReports.failed("Services.restarted", nil, ["board": host.profile.rawValue])
                    try await Task.sleep(for: settle)
                    guard !Task.isCancelled, generation == host.bootScope.generation, host.isRunning else { return }
                    host.appsMayHaveChanged()
                }
            } catch {
                if !Task.isCancelled {
                    logEvent("device: connection recovery failed: \(error.localizedDescription)")
                    AppReports.failed("Services.recoveryFailed", error, ["board": host.profile.rawValue])
                }
            }
        }
    }
}

/// Lockdown's activation answers, for the activation check.
public protocol ActivationServices: AnyObject {
    /// ActivationState, or nil when lockdown couldn't be asked.
    func activationState() async -> String?
    func finishActivation() async throws
    /// installation_proxy answers: a lockdown that serves is activated enough.
    func installProxyReady() async -> Bool
}

/// On the first lockdown answer of a boot, ask ActivationState: up to three times over 20 s, so a failed or
/// transient answer never decides. Anything but an activated state is a persistent issue when lockdown's services
/// refuse too: commands stay blocked, the notice offers Erase. Services that answer win over the string (the
/// built-in iPod reports Unactivated and works), and a service answering later clears a standing issue
/// (ConnectionRecovery.servicesAnswered).
public final class ActivationCheck {
    private unowned let host: ConnectionHost
    private unowned let services: ActivationServices
    private let recovery: ConnectionRecovery
    private let readiness: ReadinessWatch
    private let notices: DeviceNotices
    public init(
        host: ConnectionHost,
        services: ActivationServices,
        recovery: ConnectionRecovery,
        readiness: ReadinessWatch,
        notices: DeviceNotices
    ) {
        self.host = host
        self.services = services
        self.recovery = recovery
        self.readiness = readiness
        self.notices = notices
    }

    private var checkedGeneration: Int?
    /// Between the three answers a verdict needs.
    var retryDelay: Duration = .seconds(10)
    private var task: Task<Void, Never>? {
        get { host.bootScope[.activation] }
        set { host.bootScope[.activation] = newValue }
    }
    private var generation: Int { host.bootScope.generation }

    public func checkIfNeeded() {
        guard host.deviceReachable == true, task == nil, checkedGeneration != generation else { return }
        checkedGeneration = generation
        let generation = generation
        let retryDelay = retryDelay
        task = Task { [weak self] in
            defer { if generation == self?.generation { self?.task = nil } }
            var state: String?
            for attempt in 0..<3 {
                if attempt > 0 { try? await Task.sleep(for: retryDelay) }
                guard let self, generation == self.generation else { return }
                let host = host
                let services = services  // held for this attempt, as the session itself was
                if let answer = await services.activationState() {
                    state = answer
                    if DeviceConnectionIssue.activation(state: answer, profile: host.profile) == nil {
                        do {
                            try await services.finishActivation()
                            guard generation == self.generation else { return }
                            checkedGeneration = generation
                            break
                        } catch {
                            guard generation == self.generation else { return }
                            logEvent("activation completion: \(error)")
                            // Retry transient startup failures. Keep a later activation check
                            // eligible if the protocol did not acknowledge completion.
                            checkedGeneration = nil
                        }
                    }
                }
            }
            guard let self, generation == self.generation else { return }
            let host = host
            let services = services
            guard let state else {
                checkedGeneration = nil
                return
            }  // couldn't ask: again on the next answer
            logEvent("activation: lockdown reports \(state)")
            guard let issue = DeviceConnectionIssue.activation(state: state, profile: host.profile) else {
                notices.resolve(.activation)
                return
            }
            if await services.installProxyReady() {
                guard generation == self.generation else { return }
                logEvent("activation: services answer; not blocking on \(state)")
                notices.resolve(.activation)
                return
            }
            guard generation == self.generation else { return }
            recovery.issue = issue
            host.deviceReachable = false
            readiness.cancel()
            readiness.preparingDevice = false
            notices.report(issue.summary, for: .activation)
        }
    }
}
