// The guest package per boot: the offer composed from the bundled itpack for the guest's loader, and the watch
// that judges it (GuestPackageSession) and keeps the device record's `guest` serials and verdicts.

import DeviceRuntime
import Foundation
import HostRuntime
import Observation

/// What the guest-package watch reads of the session.
public protocol GuestPackageHost: AnyObject {
    var instance: DeviceInstance { get }
    var bootScope: BootSessionScope { get }
    var status: SharedStatus? { get }
    var guestArch: String { get }
    var state: VMState { get }
    var isDead: Bool { get }
    var shuttingDown: Bool { get }
    var hasGuestTools: Bool { get }
    var deviceReachable: Bool? { get }
}

@Observable public final class GuestPackageWatch {
    @ObservationIgnored private unowned let host: GuestPackageHost
    @ObservationIgnored private let stateDirectory: URL
    /// The bundled itpack for an arch (GuestPackage.bundledPack).
    @ObservationIgnored private let pack: (String) -> URL?

    public init(
        host: GuestPackageHost,
        stateDirectory: URL = Bundled.stateDirectory,
        pack: @escaping (String) -> URL? = {
            GuestPackage.bundledPack(arch: $0, filesRoot: Bundled.filesRoot, guestRoot: Bundled.guestRoot)
        }
    ) {
        self.host = host
        self.stateDirectory = stateDirectory
        self.pack = pack
    }

    /// What this boot offered the guest's loader; nil: no offer.
    public internal(set) var offer: GuestPackage.Offer?
    /// The loader's report as the watch judged it: the "Guest tools" line.
    public private(set) var status: GuestPackage.Status = .unknown
    /// The watch's sampling interval (shorter in tests).
    @ObservationIgnored var interval: Duration = .seconds(1)

    private var task: Task<Void, Never>? {
        get { host.bootScope[.guestPackage] }
        set { host.bootScope[.guestPackage] = newValue }
    }
    private var instance: DeviceInstance { host.instance }
    private var offerDirectory: URL { instance.paths.work.appendingPathComponent("guest-offer", isDirectory: true) }
    public var recordURL: URL {
        DeviceInstance.directory(instance.id, state: stateDirectory).appendingPathComponent(DeviceInstance.recordName)
    }
    /// The base's device.lock.json (decoded once while it is unchanged; nil for none or an unreadable one).
    public var lock: DeviceLock? { (try? DeviceLock.read(base: instance.paths.base)) ?? nil }
    /// The preparer's device.lock.json record.
    private var lockRecord: GuestPackage.LockRecord? { GuestPackage.lockRecord(lock) }
    var guestRecord: DeviceInstance.Guest? { (try? DeviceInstance.read(recordURL))?.guest }

    /// The record's `guest`, read fresh and written back (never the whole cached record).
    func updateGuestRecord(_ change: (inout DeviceInstance.Guest) -> Void) {
        guard var record = try? DeviceInstance.read(recordURL) else { return }
        var guest = record.guest ?? DeviceInstance.Guest()
        if guest.seed == nil { guest.seed = lockRecord?.seed }
        change(&guest)
        guard guest != record.guest else { return }
        record.guest = guest
        do {
            try record.write(state: stateDirectory)
            DeviceLibrary.shared.reload()
        } catch { logEvent("guest package: could not record \(guest): \(error.localizedDescription)") }
    }

    /// Compose this boot's offer from the bundled itpack; the machine's
    /// guest-package= directory, or nil (no property: an older dylib, no
    /// itpack, or nothing for this build) and the device keeps what it runs.
    public func compose() -> String? {
        offer = nil
        guard host.status?.guestPackageSupported == true, let pack = pack(host.guestArch) else {
            try? FileManager.default.removeItem(at: offerDirectory)
            return nil
        }
        let build = instance.firmware.split(separator: "-").last.map(String.init) ?? ""
        do {
            try FileManager.default.createDirectory(at: instance.paths.work, withIntermediateDirectories: true)
            offer = GuestOfferComposition.offer(
                augmentation: GuestDeveloperTools.augmentation(instance: instance, build: build)
            ) { augment in
                try GuestPackage.compose(
                    itpack: pack,
                    board: instance.board,
                    build: build,
                    lock: lockRecord,
                    guest: guestRecord,
                    into: offerDirectory,
                    augment: augment
                )
            }
        } catch {
            logEvent("guest package: no offer: \(error.localizedDescription)")
        }
        if let offer {
            logEvent(
                "guest package: offering \(offer.serial == 0 ? "the built-in package" : "serial \(offer.serial) (\(offer.version))")"
            )
        }
        return offer == nil ? nil : offerDirectory.path
    }

    /// One sample for this boot's watch; nil ends it (a later boot, a dead or stopping device, no helper).
    func sample(generation: Int) -> GuestPackageSession.Observation? {
        guard generation == host.bootScope.generation, !host.isDead, !host.shuttingDown,
            let status = host.status
        else { return nil }
        // iPods report their agent channel; iPads use a real lockdown
        // round trip because the helper has no pasteboard-agent status.
        let healthy =
            host.state == .running && status.uiReady
            && (host.hasGuestTools ? status.agentStatus == 1 : host.deviceReachable == true)
        return .init(
            report: status.guestPackage,
            record: guestRecord,
            glesProtocol: status.glesProtocol,
            healthy: healthy
        )
    }

    /// Judge this boot: a report and a healthy session (UI up, the agent or
    /// lockdown answering) is `good`; a new package with no healthy session
    /// within the budget is `bad`. No report once healthy: legacy baked tools.
    public func start() {
        task?.cancel()
        status = .unknown
        guard let offer else { return }
        let generation = host.bootScope.generation
        let interval = interval
        task = Task { [weak self] in
            await GuestPackageSession.watch(
                offer: offer,
                interval: interval,
                sample: { [weak self] in
                    self?.sample(generation: generation)
                },
                publish: { [weak self] update in
                    guard let self, generation == host.bootScope.generation, !host.isDead, !host.shuttingDown else {
                        return
                    }
                    if let report = update.changedReport {
                        logEvent("guest package: loader reports serial \(report.serial), result \(report.result)")
                    }
                    if update.changesRecord {
                        updateGuestRecord { update.apply(to: &$0) }
                    }
                    status = update.status
                    switch update.verdict {
                    case .good(let serial)?: logEvent("guest package: serial \(serial) judged good")
                    case .bad(let serial)?:
                        logEvent(
                            "guest package: serial \(serial) judged bad (no healthy session in \(GuestPackage.badAfter))"
                        )
                        AppReports.failed("Guest.packageBad", nil, ["serial": "\(serial)"])
                    case .legacy?: logEvent("guest package: no report; legacy baked guest tools")
                    default: break
                    }
                }
            )
        }
    }
}
