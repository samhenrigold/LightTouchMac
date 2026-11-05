// Erase All Content and Settings: stop the guest and its helper, erase this device, then start it fresh (a running
// device) or leave it ready (a stopped one). The app keeps running. No request is left behind for an unrelated
// future launch.

import DeviceRuntime
import Foundation
import HostRuntime

/// What the erase reads and does on the session.
public protocol EraseHost: AnyObject {
    var isErasing: Bool { get set }
    var state: VMState { get }
    /// start() ran: an erased device starts again.
    var started: Bool { get }
    var helper: DeviceHelper? { get }
    var helperLink: HelperLink? { get }
    var notices: DeviceNotices { get }
    var profile: Board { get }
    /// What the erase removes.
    var eraseTargets: DeviceErase.Targets { get }
    /// Nothing queued can land on an erased device: installs are dropped first.
    func discardInstalls()
    /// The foreground and orientation watches stop asking the guest.
    func stopGuestWatches()
    /// Stop's halt, started now (ShutdownLadder.halt).
    @discardableResult func halt() -> Task<Bool, Never>
    /// A fresh helper boots the erased device (DeviceSessionHost.restart).
    func restart()
}

public final class DeviceErase {
    /// iOS's own Erase All Content and Settings stopped short: mobile_obliterator leaves why in NVRAM with auto-boot
    /// off, and iBoot goes to recovery. A device with no data partition (the n72, n45 and m68 recipes) always ends
    /// here, since there is no /private/var to unmount. The person already confirmed the erase on the device.
    public nonisolated static func guestAsked(nor: URL?) -> Bool {
        guard let nor, let flash = try? Data(contentsOf: nor) else { return false }
        return flash.range(of: Data("obliteration=".utf8)) != nil
    }

    public nonisolated struct Targets: Sendable {
        public init(overlay: URL, snapshots: [URL], preparedNOR: URL?, state: URL, owner: UUID) {
            self.overlay = overlay
            self.snapshots = snapshots
            self.preparedNOR = preparedNOR
            self.state = state
            self.owner = owner
        }
        public var overlay: URL
        /// Saved-state files older builds wrote beside the overlay.
        public var snapshots: [URL]
        /// The device's private NOR copy, which pairs with its overlay; the next boot clones base/nor.bin again.
        public var preparedNOR: URL?
        public var state: URL
        public var owner: UUID

        /// What erasing this device removes, under the app's state.
        public init(_ instance: DeviceInstance) {
            let paths = instance.paths
            self.init(
                overlay: paths.overlay,
                snapshots: [paths.snapshot, paths.snapshotTmp, paths.snapshotBad],
                preparedNOR: paths.writableNOR,
                state: Bundled.stateDirectory,
                owner: instance.id
            )
        }

        /// Removes them, under the device's storage lease (DeviceStateStorage.erase).
        public func remove() throws {
            try DeviceStateStorage.erase(
                overlay: overlay,
                snapshots: snapshots,
                preparedNOR: preparedNOR,
                state: state,
                owner: owner
            )
        }
    }

    /// An erase clears the notices whose remedy it was.
    public static func erased(_ notices: DeviceNotices) {
        notices.resolve(.erase)
        notices.resolve(.activation)
    }

    private unowned let host: EraseHost
    public init(host: EraseHost) { self.host = host }
    /// How long a helper gets to exit (release every NAND/NOR writer) after its halt, and how often it's checked.
    var exitWait: Duration = .seconds(15)
    var exitPoll: Duration = .milliseconds(100)

    public func request() {
        guard !host.isErasing else { return }
        host.discardInstalls()
        host.isErasing = true
        host.stopGuestWatches()
        let exitWait = exitWait
        let exitPoll = exitPoll
        let host = host  // the session stays until its erase ends
        Task {
            if !host.state.isDead, host.state != .notStarted {
                _ = await host.halt().value
                // The helper must release every NAND/NOR writer (exit) before removal;
                // one whose guest powered itself off is still alive.
                host.helperLink?.send(.machine(.quit))
                let deadline = ContinuousClock.now + exitWait
                while host.helper?.isDead == false, ContinuousClock.now < deadline {
                    try? await Task.sleep(for: exitPoll)
                }
                guard host.helper?.isDead != false else {
                    host.isErasing = false
                    host.notices.report(
                        "Couldn’t stop the \(host.profile.shortName) to erase it. Try again.",
                        for: .erase
                    )
                    return
                }
            }
            let targets = host.eraseTargets
            do {
                try await Task.detached { try targets.remove() }.value
                Self.erased(host.notices)
                host.isErasing = false
                if host.started {
                    logEvent("reset: device erased; starting it fresh")
                    host.restart()
                } else {
                    logEvent("reset: device erased")
                }
            } catch {
                host.isErasing = false
                host.notices.report(
                    "Couldn’t finish erasing the \(host.profile.shortName): \(error.localizedDescription)",
                    for: .erase
                )
            }
        }
    }
}
