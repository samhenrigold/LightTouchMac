import Foundation
import HostRuntime

/// A helper's lifecycle outcome. Labels and display geometry belong to clients.
public enum DeviceProcessDeath: Equatable {
    case startFailed(DeviceLinkError)
    case stopped
    case unexpected

    public static func classify(startFailure: DeviceLinkError?, qemuExitCode: Int32?,
                                stopRequested: Bool, termination: DeviceTermination) -> Self {
        if let startFailure { return .startFailed(startFailure) }
        if qemuExitCode == 0 || (qemuExitCode == nil && stopRequested && termination == .exited(0)) {
            return .stopped
        }
        return .unexpected
    }
}

/// The single session owner used by the GUI and command-line clients. DeviceLink
/// exclusively spawns/reaps; this owner orders boot, stop and exactly-once death.
/// Inputs contain helper/board/storage identifiers, never GUI profiles or labels.
@MainActor public final class DeviceSessionProcess {
    public let link: DeviceLink
    public var onAudio: ((LinkEvent) -> Void)?
    public var onDeath: ((DeviceProcessDeath) -> Void)?
    public var onTermination: ((pid_t, DeviceTermination, Int32?) -> Void)?
    public private(set) var death: DeviceProcessDeath?
    public var isDead: Bool { death != nil }
    public var info: HelperInfo? { link.info }
    public var status: SharedStatus? { link.status }
    private var qemuExitCode: Int32?
    private var startFailure: DeviceLinkError?
    private var stopRequested = false
    private var helperPID: pid_t = 0
    private var startRequested = false
    private var preparationTask: Task<Void, Never>?
    private var bootRequested = false
    private var cancelledBeforeBoot = false

    public init(configuration: DeviceLink.Configuration) {
        link = DeviceLink(configuration: configuration)
        link.onEvent = { [weak self] event in MainActor.assumeIsolated { self?.received(event) } }
        link.onTerminated = { [weak self] termination in MainActor.assumeIsolated { self?.terminated(termination) } }
    }

    /// Optional stopped-storage preparation precedes spawn/hello. A nil boot
    /// configuration deliberately fails before a boot request.
    public func start(_ configure: @escaping (HelperInfo) -> BootConfig?,
                      preparation: (@MainActor () async throws -> Void)? = nil,
                      completion: @escaping (Result<HelperInfo, DeviceLinkError>) -> Void) {
        guard !startRequested, !isDead, !stopRequested else {
            completion(.failure(.closed("this device session has already started")))
            return
        }
        startRequested = true
        guard let preparation else { return spawn(configure, completion: completion) }
        // Stopped-storage maintenance finishes and refreshes the caller's paths
        // before the helper can acquire its lease. DeviceRuntime owns ordering;
        // firmware conversion remains in the maintenance worker.
        preparationTask = Task { [weak self] in
            guard let self else { return }
            do {
                try Task.checkCancellation()
                try await preparation()
                try Task.checkCancellation()
                self.preparationTask = nil
                guard !self.stopRequested, !self.isDead else { throw CancellationError() }
                self.spawn(configure, completion: completion)
            } catch {
                self.preparationTask = nil
                if self.stopRequested {
                    completion(.failure(.closed("device start cancelled before helper launch")))
                    self.died(.stopped)
                } else {
                    self.failStart(.helperFailure("device preparation failed: \(error)"), completion)
                }
            }
        }
    }

    private func spawn(_ configure: @escaping (HelperInfo) -> BootConfig?,
                       completion: @escaping (Result<HelperInfo, DeviceLinkError>) -> Void) {
        link.start { [weak self] result in
            MainActor.assumeIsolated { self?.started(result, configure, completion) }
        }
        helperPID = link.pid
    }

    private func started(_ result: Result<HelperInfo, DeviceLinkError>, _ configure: (HelperInfo) -> BootConfig?,
                         _ completion: @escaping (Result<HelperInfo, DeviceLinkError>) -> Void) {
        guard !stopRequested, !isDead else {
            cancelledBeforeBoot = true
            completion(.failure(.closed("device start cancelled before boot")))
            if link.pid > 0 { link.terminate() } else { died(.stopped) }
            return
        }
        switch result {
        case let .failure(error): failStart(error, completion)
        case let .success(info):
            guard let config = configure(info) else { return failStart(.helperFailure("not booted"), completion) }
            guard config.storageProof == nil || info.storageProofValidation == true else {
                return failStart(.helperFailure("The device helper cannot validate admitted storage."), completion)
            }
            bootRequested = true
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

    /// Bounded host halt; no claim of a guest filesystem shutdown.
    public func terminate() {
        if !isDead {
            stopRequested = true
            if startRequested && !bootRequested { cancelledBeforeBoot = true }
            if let preparationTask { preparationTask.cancel() }
            else { link.terminate() }
        }
    }
    public func kill() {
        if !isDead {
            if startRequested && !bootRequested {
                stopRequested = true
                cancelledBeforeBoot = true
            }
            if let preparationTask { stopRequested = true; preparationTask.cancel() }
            else { link.kill() }
        }
    }

    /// Cancellation cannot abandon bounded cleanup. The link retains exclusive
    /// reaping ownership even after this finite wait times out.
    public func waitForExit(timeout: TimeInterval) async -> Bool {
        let wait = Task { @MainActor in
            let clock = ContinuousClock()
            let deadline = clock.now.advanced(by: .seconds(timeout))
            while !isDead, clock.now < deadline {
                try? await clock.sleep(until: min(deadline, clock.now.advanced(by: .milliseconds(50))))
            }
            return isDead
        }
        return await wait.value
    }

    private func received(_ event: LinkEvent) {
        switch event {
        case let .qemuExited(code): qemuExitCode = code
        case .audio, .audioEnded: onAudio?(event)
        }
    }

    private func failStart(_ error: DeviceLinkError, _ completion: (Result<HelperInfo, DeviceLinkError>) -> Void) {
        if startFailure == nil { startFailure = error }
        completion(.failure(error))
        if link.pid > 0 { link.kill() } else { died(.startFailed(error)) }
    }

    private func terminated(_ termination: DeviceTermination) {
        onTermination?(helperPID, termination, qemuExitCode)
        died(cancelledBeforeBoot ? .stopped : .classify(startFailure: startFailure, qemuExitCode: qemuExitCode,
                       stopRequested: stopRequested, termination: termination))
    }

    private func died(_ reason: DeviceProcessDeath) {
        guard death == nil else { return }
        death = reason
        onDeath?(reason)
    }
}
