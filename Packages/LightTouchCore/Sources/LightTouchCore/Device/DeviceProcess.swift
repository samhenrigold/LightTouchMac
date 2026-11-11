import CoreGraphics
import DeviceRuntime
import Foundation
import HostRuntime

/// GUI presentation and native-log capture around the shared session owner.
/// Spawn, boot, cancellation, death ordering and exclusive reaping live in DeviceRuntime.
@MainActor public final class DeviceProcess {
    public let profile: Board
    private let process: DeviceSessionProcess
    private let log: ProcessLogCapture?
    public private(set) var deathReason: String?
    public var link: DeviceLink { process.link }
    public var info: HelperInfo? { process.info }
    public var status: SharedStatus? { process.status }
    public var isDead: Bool { process.isDead }
    public var onAudio: ((LinkEvent) -> Void)? {
        get { process.onAudio }
        set { process.onAudio = newValue }
    }
    public var onGuestPasteboard: ((String) -> Void)? {
        get { process.onGuestPasteboard }
        set { process.onGuestPasteboard = newValue }
    }
    public var onAgentReport: ((String) -> Void)? {
        get { process.onAgentReport }
        set { process.onAgentReport = newValue }
    }
    public var onDeath: ((String) -> Void)?

    public init(
        instance: UUID,
        profile: Board,
        log url: URL,
        lease: URL? = nil,
        helper: URL? = nil,
        requirement: String? = nil
    ) {
        self.profile = profile
        do { log = try ProcessLogCapture(url: url) } catch {
            logEvent("device helper: native.log unavailable at \(url.path): \(error.localizedDescription)")
            log = nil
        }
        var configuration = DeviceLink.Configuration(instance: instance, outputDescriptor: log?.writeDescriptor ?? -1)
        if let helper { configuration.helper = helper }
        configuration.board = profile.rawValue
        configuration.requirement = requirement
        configuration.lease = lease
        process = DeviceSessionProcess(configuration: configuration)
        var terminationLog: String?
        process.onTermination = { pid, termination, code in
            terminationLog = "device helper \(pid): \(termination), QEMU exit \(code.map(String.init) ?? "none")"
        }
        process.onDeath = { [weak self] death in
            guard let self else { return }
            let reason = Self.reason(death, profile: self.profile)
            self.deathReason = reason
            if let terminationLog { logEvent("\(terminationLog) — \(reason)") }
            self.log?.flush()
            self.onDeath?(reason)
        }
    }

    public func start(
        _ configure: @escaping (HelperInfo) -> BootConfig?,
        preparation: (@MainActor () async throws -> Void)? = nil,
        completion: @escaping (Result<HelperInfo, DeviceLinkError>) -> Void
    ) {
        process.start(
            { [weak self] info in
                self?.checkBoard(info)
                return configure(info)
            },
            preparation: preparation,
            completion: { result in
                if case .failure(let error) = result { logEvent("device helper: didn’t start: \(error)") }
                completion(result)
            }
        )
    }

    public func terminate() { process.terminate() }
    public func kill() { process.kill() }
    public func waitForExit(timeout: TimeInterval) async -> Bool { await process.waitForExit(timeout: timeout) }

    public static func reason(_ death: DeviceProcessDeath, profile: Board) -> String {
        switch death {
        case .startFailed(.helperFailure(DeviceLinkWire.leaseRefusal)): DeviceLinkWire.leaseRefusal
        case .startFailed: "The \(profile.shortName) didn’t start."
        case .stopped: profile.stoppedReason
        case .unexpected: "The \(profile.shortName) stopped unexpectedly."
        }
    }

    private func checkBoard(_ info: HelperInfo) {
        logEvent(
            "emulator dylib: \(info.dylibPath) (built \(Date(timeIntervalSince1970: info.dylibModified)), build \(info.buildID ?? "unknown")) in helper \(info.pid)"
        )
        if info.deviceInfo == nil { logEvent("display: libqemu-arm.dylib has no machine for \(profile.rawValue)") }
    }
}
