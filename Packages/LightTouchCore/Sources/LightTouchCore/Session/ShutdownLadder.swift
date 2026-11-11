// Stop, Force Stop and Shut Down.
//
// Stop is a hard halt (Sam, 2026-09-28), never a guest shutdown: a booting or wedged guest ignores those and left
// the window on "Powering off…". SIGTERM makes the helper pause the VM, which flushes storage, and quit QEMU
// (DeviceHost.halt); a helper still alive after the halt budget is killed. The guest's filesystems replay their
// journals on the next boot. The helper's exit is Stopped (BootWatch.helperDied).
//
// Shut Down: the guest powers itself off, as the slider does (qemu_ios_ui_shutdown: the guest agent's halt, or
// 1.x's power-off gesture), so its storage is left clean; the helper stays, powered off, as after the slider. A
// guest still starting up can't power itself off (no SpringBoard, no agent yet): Shut Down then is Stop, and the boot
// ends at once instead of carrying on under "Stopping…" until the shutdown budget forced it.

import DeviceRuntime
import Foundation
import HostRuntime
import Observation

/// What Stop and Shut Down read and do on the session.
public protocol ShutdownHost: AnyObject {
    var state: VMState { get }
    var isErasing: Bool { get }
    var storageFailed: Bool { get }
    /// Something changed the files the helper has open: a flush would write into dead inodes.
    var filesMeddled: Bool { get }
    var helper: DeviceHelper? { get }
    var helperLink: HelperLink? { get }
    /// The boot hasn't reached the Home screen yet (ReadinessWatch.preparingDevice).
    var preparingDevice: Bool { get }
    var workers: WorkerRetirement { get }
    func retireBoot()
    /// Before the guest goes: queued installs are dropped and the clock sync ends.
    func willStop()
}

/// How a Shut Down ended. Only `poweredOff` left the guest's storage clean: what waits for a shut-down device (Show
/// File System's Shut Down First) goes on from that alone (state audit A-15).
public enum ShutdownOutcome: Equatable {
    /// The guest powered itself off.
    case poweredOff
    /// It was stopped instead: a Force Stop took over, or the helper died.
    case forced
    /// The guest didn't power off within the budget (or Shut Down couldn't be asked); it keeps running.
    case timedOut
}

@Observable public final class ShutdownLadder {
    public struct Budgets {
        public init() {}
        /// SIGTERM to the kill.
        public var halt: TimeInterval = 10
        /// The kill to giving up on the exit.
        public var kill: TimeInterval = 5
        /// How long Stop waits for the services worker's teardown after the helper is gone. Retirement already
        /// cancelled the worker (its subprocess is torn down); a teardown that never finishes keeps reaping in
        /// the background, never holding Stop.
        public var serviceTeardown: TimeInterval = 2
        /// Shut Down's wait for the guest to power off.
        public var shutdown: TimeInterval = 90 * Board.hostSlowdown
        /// The quit backstop: the halt, then the kill, then the services worker.
        public var stop: TimeInterval { halt + kill + serviceTeardown }
    }

    private unowned let host: ShutdownHost
    public var budgets = Budgets()
    public init(host: ShutdownHost) { self.host = host }

    /// Where the ladder is: idle, waiting for the guest to power off, or halting the helper (a Force Stop can take
    /// over a Shut Down). Each step holds its task, so a second request joins it; a halt ends back at idle however
    /// it ends, so a helper that outlived it can still be stopped, aborted and seen to crash (state audit A-10).
    public enum Step {
        case idle
        case shuttingDown(Task<ShutdownOutcome, Never>)
        case halting(Task<Bool, Never>)
    }
    public private(set) var step = Step.idle

    public var shuttingDown: Bool { if case .idle = step { false } else { true } }
    /// Stop asked the helper to halt: its exit is Stopped, not a crash.
    public var halting: Bool { haltTask != nil }
    private var haltTask: Task<Bool, Never>? { if case .halting(let task) = step { task } else { nil } }

    private var isPoweredOff: Bool { host.state == .poweredOff }
    private var isDead: Bool { host.state.isDead }

    /// A live helper whose VM can be stopped, including mid-boot.
    public var canStop: Bool {
        !isDead && !isPoweredOff && !shuttingDown && !host.isErasing && host.state != .notStarted
    }
    /// Force Stop: Stop's hard halt, also while a Shut Down is under way (one the guest never finishes).
    public var canForceStop: Bool { canStop || (isShuttingDownCleanly && !isPoweredOff && !isDead) }
    public var canShutDown: Bool {
        (host.state == .running || host.state == .booting) && !shuttingDown && !host.isErasing && !host.storageFailed
            && host.helper?.isDead == false
    }
    public var isShuttingDownCleanly: Bool { if case .shuttingDown = step { true } else { false } }
    /// The guest can't take a shutdown request yet (still starting up): Shut Down halts it, as Stop does.
    public var shutDownHalts: Bool { host.state == .booting || host.preparingDevice }

    /// Asks the guest to power off, now; one still starting up is halted instead (`.forced`). The task's value: how
    /// it ended.
    @discardableResult public func shutDown() -> Task<ShutdownOutcome, Never> {
        guard canShutDown else { return Task { .timedOut } }
        host.willStop()
        if shutDownHalts {
            logEvent("shut down: the guest is still starting; stopping it")
            let halt = halt()
            return Task { await halt.value ? .forced : .timedOut }
        }
        logEvent("shut down: asking the guest")
        host.helperLink?.send(.machine(.shutdown))
        let budget = budgets.shutdown
        let task = Task { [weak self] () -> ShutdownOutcome in
            // The Mac's sleep doesn't count against the guest.
            let deadline = SuspendingClock.now + .seconds(budget)
            while let self, SuspendingClock.now < deadline, !self.isPoweredOff, !self.isDead, self.haltTask == nil {
                try? await Task.sleep(for: .milliseconds(200))
            }
            guard let self else { return .timedOut }
            // A Force Stop that took over owns the step until its halt ends.
            let outcome: ShutdownOutcome =
                haltTask != nil || isDead ? .forced : isPoweredOff ? .poweredOff : .timedOut
            if haltTask == nil { step = .idle }
            let said =
                switch outcome {
                case .poweredOff: "the guest powered off"
                case .forced: "force stopped"
                case .timedOut: "the guest didn't power off"
                }
            logEvent("shut down: \(said)")
            return outcome
        }
        step = .shuttingDown(task)
        return task
    }

    /// Force Stop (and the guest's power-off from the menu): the halt, once queued installs are dropped. The task's
    /// value is the halt's; false when there is nothing to stop.
    @discardableResult public func forceStop() -> Task<Bool, Never> {
        guard canForceStop else { return Task { false } }
        host.willStop()
        return halt()
    }

    /// Starts the halt now, or joins the one under way. The task's value: true iff the helper is gone.
    @discardableResult public func halt() -> Task<Bool, Never> {
        if host.helper?.isDead != false { return Task { true } }
        if let haltTask { return haltTask }
        let process = host.helper
        let budgets = budgets
        // Runs once this call returns: the step is .halting before the helper is told, so its exit reads as Stopped.
        let task = Task { [weak self] in
            var exited = await process?.waitForExit(timeout: budgets.halt) ?? true
            if !exited {
                logEvent("stop: the device helper did not exit in \(Int(budgets.halt)) s; killing it")
                AppReports.failed("Device.haltTimedOut")
                process?.kill()
                exited = await process?.waitForExit(timeout: budgets.kill) ?? true
            }
            guard let self else { return exited }
            let host = host
            await host.workers.awaitTeardown(budget: budgets.serviceTeardown)
            if exited { logEvent("stop: device halted") }
            step = .idle
            return exited
        }
        step = .halting(task)
        host.retireBoot()
        if host.filesMeddled {
            // The overlay or NOR the helper has open is gone from disk: a flush would
            // write into dead inodes, so quit QEMU outright (no pause first).
            logEvent("stop: files were changed under the device; quitting without a flush")
            host.helperLink?.send(.machine(.quit))
        } else if isPoweredOff {
            // The guest powered itself off (its storage is clean) and the machine is stopped: quit QEMU.
            host.helperLink?.send(.machine(.quit))
        } else {
            process?.terminate()
        }
        return task
    }
}
