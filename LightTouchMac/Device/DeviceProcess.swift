import DeviceRuntime
import HostRuntime
import Foundation
import CoreGraphics

/// GUI presentation and native-log capture around the shared session owner.
/// Spawn, boot, cancellation, death ordering and exclusive reaping live in DeviceRuntime.
@MainActor final class DeviceProcess {
    let profile: DeviceProfile
    private let process: DeviceSessionProcess
    private let log: ProcessLogCapture?
    private(set) var deathReason: String?
    var link: DeviceLink { process.link }
    var info: HelperInfo? { process.info }
    var status: SharedStatus? { process.status }
    var isDead: Bool { process.isDead }
    var onAudio: ((LinkEvent) -> Void)? {
        get { process.onAudio }
        set { process.onAudio = newValue }
    }
    var onDeath: ((String) -> Void)?

    init(instance: UUID, profile: DeviceProfile, log url: URL, lease: URL? = nil,
         helper: URL? = nil, requirement: String? = nil) {
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

    func start(_ configure: @escaping (HelperInfo) -> BootConfig?,
               preparation: (@MainActor () async throws -> Void)? = nil,
               completion: @escaping (Result<HelperInfo, DeviceLinkError>) -> Void) {
        process.start({ [weak self] info in
            self?.checkBoard(info)
            return configure(info)
        }, preparation: preparation) { result in
            if case let .failure(error) = result { logEvent("device helper: didn’t start: \(error)") }
            completion(result)
        }
    }

    func terminate() { process.terminate() }
    func kill() { process.kill() }
    func waitForExit(timeout: TimeInterval) async -> Bool { await process.waitForExit(timeout: timeout) }

    static func reason(_ death: DeviceProcessDeath, profile: DeviceProfile) -> String {
        switch death {
        case .startFailed(.helperFailure(DeviceLinkWire.leaseRefusal)): DeviceLinkWire.leaseRefusal
        case .startFailed: "The \(profile.shortName) didn’t start."
        case .stopped: profile.stoppedReason
        case .unexpected: "The \(profile.shortName) stopped unexpectedly."
        }
    }

    /// Profile geometry drives presentation; the dylib only confirms it.
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
}
