// What a device session drives: its helper process and that helper's link. DeviceProcess and DeviceLink in the
// app; recorders in LightTouchCoreTests, so the session's state machines run without a helper.

import DeviceRuntime
import Foundation
import HostRuntime

/// The helper's link as the session uses it: ordered commands, and requests whose reply runs on the main queue.
nonisolated public protocol HelperLink: AnyObject {
    func send(_ command: LinkCommand)
    func request(_ request: LinkRequest, timeout: TimeInterval, reply: @escaping DeviceLink.Reply)
}

extension DeviceLink: HelperLink {}

/// The helper process: Stop's SIGTERM, the kill after it, and the wait for its exit.
public protocol DeviceHelper: AnyObject {
    var isDead: Bool { get }
    func terminate()
    func kill()
    func waitForExit(timeout: TimeInterval) async -> Bool
}

extension DeviceProcess: DeviceHelper {}

extension BootSessionScope {
    /// A control request for this boot; `done(true)` when the machine applied it (false on a machine without the
    /// control, the iPod, or from a helper that's gone). A reply that lands after this boot retired, or in a later
    /// boot, is dropped: it must not change the next boot.
    public func control(
        _ request: LinkRequest,
        on link: HelperLink?,
        _ done: @escaping @MainActor (Bool) -> Void = { _ in }
    ) {
        guard let link, !retired else { return done(false) }
        let session = id
        link.request(request, timeout: 10) { [weak self] reply in
            MainActor.assumeIsolated {
                guard let self, !self.retired, session == self.id else { return }
                if case .success(.ok(true)) = reply { done(true) } else { done(false) }
            }
        }
    }
}

/// Retired boots' services workers, stopped one after another; Stop waits for them only so long.
public final class WorkerRetirement {
    public init() {}
    public private(set) var task: Task<Void, Never>?

    /// After every earlier retirement, `stop` (the retired boot's services worker teardown).
    public func chain(_ stop: @escaping () async -> Void) {
        let previous = task
        task = Task {
            await previous?.value
            await stop()
        }
    }

    /// Waits for the retired boots' workers, at most `budget` seconds; one that never finishes keeps reaping in
    /// the background. False when the budget ran out.
    @discardableResult
    public func awaitTeardown(budget: TimeInterval) async -> Bool {
        guard let retirement = task else { return true }
        let (done, signal) = AsyncStream<Bool>.makeStream()
        Task {
            await retirement.value
            signal.yield(true)
        }
        let timer = Task {
            try? await Task.sleep(for: .seconds(budget))
            signal.yield(false)
        }
        var first = done.makeAsyncIterator()
        let finished = await first.next() ?? false
        timer.cancel()
        signal.finish()
        if !finished {
            logEvent("stop: the services worker did not finish in \(Int(budget)) s; it is reaped in the background")
            AppReports.failed("Services.workerStuck")
        }
        return finished
    }
}
