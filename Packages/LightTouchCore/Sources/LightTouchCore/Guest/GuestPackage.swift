import Crypto
import DeviceRuntime
import Foundation
import HostRuntime
import HostServiceWire

// Guest packages: the app's side.
//
// Each boot, the app composes Devices/<uuid>/work/guest-offer/ from the
// bundled Resources/guest/<arch>.itpack (qemu-ios contrib/guest-package/
// mkpkg.py `offer` is the reference) and passes it as the machine's
// guest-package= property. The baked loader it_boot pulls the offer over
// QC_PKG_*, installs or reverts, and REPORTs the serial now current; the
// helper publishes that in the status block. The app judges the session
// (good/bad) and records it in device.plist `guest`, and the next offer
// carries those verdicts. No report: the image has no loader (legacy baked
// tools), and the app keeps them current itself (GuestServices). The .itpack and offer formats are
// HostRuntime's GuestPack, which FirmwareKit's seed writes too.

public nonisolated enum GuestPackage {
    public typealias Manifest = GuestPack.Manifest

    /// What was offered this boot.
    public struct Offer: Sendable, Equatable {
        /// The bundled package's serial.
        public var bundled: Int64
        public var version: String
        /// 0 when the offer asks for the built-in (seed) package.
        public var serial: Int64
        public var glHook: Bool
    }

    /// The GL wire range the host serves (QC_GLES_HELLO; 0 is no hello yet or no shim, 1 the name-keyed wire).
    public static let glesProtocols = 0...1

    /// it_boot's R_* report codes.
    public enum ReportCode: Int32, Sendable {
        case unchanged = 0
        case installed
        case switched
        case revertedBad
        case revertedTries
        case refused
    }

    /// The bundled itpack for an arch: the app's guest-tools (Bundled.guestRoot, which
    /// firmwarekit also seeds from), else (development) LTM_GUEST_PACKAGE or a
    /// qemu-ios checkout's build/guest-package (Debug only).
    public static func bundledPack(arch: String, filesRoot: String, guestRoot: URL?) -> URL? {
        var candidates = [guestRoot?.appendingPathComponent("guest-tools/\(arch).itpack")].compactMap { $0 }
        #if DEBUG
            if let dir = ProcessInfo.processInfo.environment["LTM_GUEST_PACKAGE"] {
                candidates.append(URL(fileURLWithPath: dir).appendingPathComponent("\(arch).itpack"))
            }
            candidates.append(
                URL(fileURLWithPath: filesRoot).deletingLastPathComponent()
                    .appendingPathComponent("qemu-ios/build/guest-package/\(arch).itpack")
            )
        #endif
        return candidates.first { FileManager.default.isReadableFile(atPath: $0.path) }
    }

    /// The package in an itpack for this board and build, with its payloads by package path; nil when there is
    /// none (or only a stub).
    static func package(in itpack: URL, board: String, build: String) throws -> (Manifest, [String: Data])? {
        try GuestPack.packages(GuestPack.read(itpack), board: board, build: build).first.map {
            ($0.manifest, $0.payloads)
        }
    }

    // MARK: - Offer

    /// Write this boot's offer into `dir` (replacing it). `lock` is the
    /// preparer's record, when there is one: as its seed did, the GL engines'
    /// hooks when it installed no shim, and hooks whose targets the
    /// device lacks (libappsync without AppSync), are dropped.
    /// Nil (and no directory) when the itpack has nothing for this device.
    public static func compose(
        itpack: URL,
        board: String,
        build: String,
        lock: LockRecord?,
        guest: DeviceInstance.Guest?,
        into dir: URL,
        augment: ((URL, Int64) throws -> (serial: Int64, version: String))? = nil
    ) throws -> Offer? {
        let fm = FileManager.default
        try? fm.removeItem(at: dir)
        guard let found = try package(in: itpack, board: board, build: build) else { return nil }
        var (manifest, payloads) = found
        if let range = manifest.requires.host?["guest-package"], range.count == 2,
            !(range[0]...range[1]).contains(GuestPack.packageProtocol)
        {
            return nil
        }
        if let lock {
            let dropped = Set(
                manifest.hooks.filter { hook in
                    (!lock.gles && Manifest.glTargets.contains(hook.target))
                        || (lock.hooks.map { !$0.contains(hook.target) } ?? false)
                }.map(\.file)
            )
            manifest.dropHooks(dropped)
        }
        let builtIn = guest?.builtIn == manifest.serial
        let staging = dir.deletingLastPathComponent().appendingPathComponent(
            ".\(dir.lastPathComponent)-\(UUID().uuidString)"
        )
        defer { try? fm.removeItem(at: staging) }
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        if !builtIn {
            for f in manifest.files {
                guard let data = payloads[f.name], data.count == f.size,
                    SHA256.hash(data: data).map({ String(format: "%02x", $0) }).joined() == f.sha256
                else {
                    throw DeviceToolsError.failed(
                        "\(itpack.lastPathComponent): \(manifest.family)/\(f.name) does not match its manifest"
                    )
                }
                let url = staging.appendingPathComponent(f.name)
                try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try data.write(to: url)
            }
        }
        let text = GuestPack.offerText(
            manifest,
            build: build,
            serial: builtIn ? 0 : nil,
            good: guest?.lastGood.map { [$0] } ?? [],
            bad: guest?.bad ?? []
        )
        try Data(text.utf8).write(to: staging.appendingPathComponent("offer"))
        var offeredSerial = builtIn ? 0 : manifest.serial
        var offeredVersion = manifest.version
        if !builtIn, let augment {
            let developer = try augment(staging, manifest.serial)
            offeredSerial = developer.serial
            offeredVersion = developer.version
        }
        try fm.moveItem(at: staging, to: dir)
        return Offer(
            bundled: manifest.serial,
            version: offeredVersion,
            serial: offeredSerial,
            glHook: !builtIn && manifest.hooks.contains { Manifest.glTargets.contains($0.target) }
        )
    }

    /// The preparer's record (device.lock.json `guest_package`).
    public struct LockRecord: Equatable, Sendable {
        public var seed: Int64?
        /// Whether it installed the GL shim.
        public var gles: Bool
        /// The hook targets it kept (present on the volume); nil: not recorded.
        public var hooks: [String]?
    }

    public static func lockRecord(_ lock: DeviceLock?) -> LockRecord? {
        guard let record = lock?.guestPackage?.object else { return nil }
        return LockRecord(
            seed: record["seed"]?.int.map(Int64.init),
            gles: record["gles"]?.bool ?? (record["gli"]?.string != nil),  // locks before gl-runtime: a gli id
            hooks: record["hooks"]?.strings
        )
    }

    // MARK: - Verdicts

    public enum Verdict: Equatable, Sendable {
        case good(Int64)
        case bad(Int64)
        /// No report once healthy: the image has no loader.
        case legacy
        /// Stop judging this boot without a verdict.
        case undecided
    }

    /// Healthy for this long (UI up, the agent or lockdown answering) makes the
    /// reported package good; no report by then means no loader.
    public static let goodAfter: Duration = .seconds(10), legacyAfter: Duration = .seconds(30)
    /// A package that isn't healthy this long after boot is bad.
    public static let badAfter: Duration = .seconds(300)

    /// This boot's verdict so far; nil: keep watching. A restored session never
    /// re-runs the loader, so it has no report and says nothing about tools. Only
    /// a package that isn't the seed or the last good one can be judged bad.
    public static func verdict(
        report: GuestPackageReport?,
        healthyFor: Duration,
        elapsed: Duration,
        record: DeviceInstance.Guest?,
        restored: Bool
    ) -> Verdict? {
        if let report, healthyFor >= goodAfter { return .good(report.serial) }
        if report == nil, healthyFor >= legacyAfter { return restored ? .undecided : .legacy }
        guard elapsed >= badAfter else { return nil }
        if let report, report.serial != record?.lastGood, report.serial != record?.seed { return .bad(report.serial) }
        return .undecided
    }

    // MARK: - State

    /// What the UI says about a device's guest tools: the "Guest tools" status line.
    public enum Status: Equatable, Sendable {
        /// No offer (no itpack, an older dylib) or no report yet.
        case unknown
        /// No report after a healthy start: the image has no loader.
        case legacy
        case current(serial: Int64)
        /// The built-in (seed) package, on request.
        case builtIn(serial: Int64)
        /// The loader went back to an earlier package: `why` is its report code.
        case reverted(serial: Int64, why: ReportCode)
        /// Older than the bundled package, or a GL protocol the host doesn't serve.
        case outOfDate
        /// The agent went stale for over a minute.
        case notResponding
        /// iBoot entered recovery mode.
        case recovery
        /// lockdown hasn't answered yet.
        case notBooted

        /// Worth a word in the status line: the user can act on it (restart, or notice the tools have stopped).
        /// Up to date, built in, legacy, waiting and unknown are the quiet default.
        public var needsAttention: Bool {
            switch self {
            case .outOfDate, .reverted, .notResponding: true
            default: false
            }
        }

        public var text: String {
            switch self {
            case .unknown: "Unknown"
            case .legacy: "Won’t update — erase and prepare again to get updates"
            case .current: "Up to date"
            case .builtIn: "Built in"
            case .reverted(_, let why):
                "Using an earlier version — "
                    + (why == .revertedBad
                        ? "the update didn’t work"
                        : why == .revertedTries ? "the update kept failing" : "the update was refused")
            case .outOfDate: "Out of date — restart to update"
            case .notResponding: "Not responding"
            case .recovery: "Unavailable in recovery mode"
            case .notBooted: "Waiting for iOS"
            }
        }
    }

    /// The UI state for a report (nil: none this boot) against the offer.
    public static func status(
        report: GuestPackageReport?,
        offer: Offer?,
        record: DeviceInstance.Guest?,
        glesProtocol: Int32
    ) -> Status {
        guard let offer else { return report.map { .current(serial: $0.serial) } ?? .unknown }
        guard let report else {
            // A restored snapshot keeps running what the last cold boot installed.
            if let active = record?.active, active < offer.bundled, record?.bad.contains(offer.bundled) != true,
                record?.builtIn != offer.bundled
            {
                return .outOfDate
            }
            return .unknown
        }
        if !glesProtocols.contains(Int(glesProtocol)) { return .outOfDate }
        switch ReportCode(rawValue: report.result) {
        case let code? where [.revertedBad, .revertedTries, .refused].contains(code):
            return .reverted(serial: report.serial, why: code)
        default: break
        }
        if offer.serial == 0 { return .builtIn(serial: report.serial) }
        if report.result < 0 || report.serial < offer.bundled { return .outOfDate }
        return .current(serial: report.serial)
    }
}

/// Qualifies one cold boot's automatic additions without owning a window or
/// emulator. The caller owns the task (BootSessionScope in the GUI), supplies
/// fresh device observations, and persists emitted record changes.
@MainActor
public struct GuestPackageSession {
    public struct Observation {
        public init(
            report: GuestPackageReport? = nil,
            record: DeviceInstance.Guest? = nil,
            glesProtocol: Int32,
            healthy: Bool
        ) {
            self.report = report
            self.record = record
            self.glesProtocol = glesProtocol
            self.healthy = healthy
        }
        public var report: GuestPackageReport?
        public var record: DeviceInstance.Guest?
        public var glesProtocol: Int32
        public var healthy: Bool
    }
    public struct Update {
        public var status: GuestPackage.Status
        public var changedReport: GuestPackageReport?
        public var verdict: GuestPackage.Verdict?

        public var changesRecord: Bool {
            if changedReport != nil { return true }
            switch verdict {
            case .good?, .bad?: return true
            default: return false
            }
        }

        public func apply(to record: inout DeviceInstance.Guest) {
            if let changedReport { record.active = changedReport.serial }
            switch verdict {
            case .good(let serial)?:
                record.lastGood = serial
                record.bad.removeAll { $0 == serial }
            case .bad(let serial)?:
                if !record.bad.contains(serial) { record.bad.append(serial) }
            default: break
            }
        }
    }

    private let offer: GuestPackage.Offer
    private var healthySince: Duration?
    private var seen: GuestPackageReport?
    private var finished = false

    public init(offer: GuestPackage.Offer) { self.offer = offer }

    /// Elapsed time is measured by the owner's monotonic clock, never the RTC
    /// or wall clock (which can change during timezone synchronization).
    public mutating func observe(_ observation: Observation, elapsed: Duration) -> Update? {
        guard !finished else { return nil }
        let report = observation.report
        let changedReport = report != seen ? report : nil
        if let changedReport { seen = changedReport }
        if observation.healthy { healthySince = healthySince ?? elapsed } else { healthySince = nil }
        let steady = healthySince.map { elapsed - $0 } ?? .zero
        let verdict = GuestPackage.verdict(
            report: report,
            healthyFor: steady,
            elapsed: elapsed,
            record: observation.record,
            restored: false
        )
        finished = verdict != nil
        let status =
            verdict == .legacy
            ? GuestPackage.Status.legacy
            : GuestPackage.status(
                report: report,
                offer: offer,
                record: observation.record,
                glesProtocol: observation.glesProtocol
            )
        return Update(status: status, changedReport: changedReport, verdict: verdict)
    }

    /// Nil observation retires this watch. Cancellation is checked after every
    /// suspension before sampling or publishing, so an old boot cannot write
    /// a verdict even if the caller still has a valid status block.
    public static func watch(
        offer: GuestPackage.Offer,
        interval: Duration = .seconds(1),
        sample: () -> Observation?,
        publish: (Update) -> Void
    ) async {
        let started = ContinuousClock.now
        var session = Self(offer: offer)
        while !Task.isCancelled {
            do { try await Task.sleep(for: interval) } catch { return }
            guard !Task.isCancelled, let observation = sample(),
                let update = session.observe(observation, elapsed: ContinuousClock.now - started)
            else { return }
            guard !Task.isCancelled else { return }
            publish(update)
            if update.verdict != nil { return }
        }
    }
}
