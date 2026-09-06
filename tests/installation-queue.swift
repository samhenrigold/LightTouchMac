import Foundation

@main struct Check {
    @MainActor static func main() async throws {
        let queue = InstallationQueue()
        var order: [String] = [], ready: [String] = []
        var concurrent = 0
        func until(_ condition: () -> Bool) async throws {
            let deadline = ContinuousClock.now + .seconds(5)
            while !condition() {
                precondition(ContinuousClock.now < deadline, "queue did not reach expected state")
                try await Task.sleep(for: .milliseconds(10))
            }
        }
        func job(_ name: String) -> (task: Task<Void, Error>, download: AsyncStream<Void>.Continuation, finish: AsyncStream<Void>.Continuation) {
            let download = AsyncStream<Void>.makeStream(), finish = AsyncStream<Void>.makeStream()
            let task = Task { @MainActor in
                for await _ in download.stream { break }
                try Task.checkCancellation()
                ready.append(name)
                try await queue.acquire()
                defer { queue.release() }
                try Task.checkCancellation()
                concurrent += 1
                precondition(concurrent == 1)
                defer { concurrent -= 1 }
                order.append(name)
                for await _ in finish.stream { break }
            }
            return (task, download.continuation, finish.continuation)
        }
        // Explicit download/completion gates: timer coalescing must not choose
        // readiness order for this test when the host is busy building QEMU.
        let large = job("large"), small = job("small"), second = job("second")
        small.download.yield()
        try await until { order == ["small"] }
        second.download.yield()
        try await until { ready.contains("second") }
        small.finish.yield()
        try await until { order == ["small", "second"] }
        large.download.yield(); large.finish.yield(); second.finish.yield()
        try await large.task.value; try await small.task.value; try await second.task.value
        precondition(order == ["small", "second", "large"] && !queue.isBusy)
        try await queue.acquire()
        let cancelled = job("cancelled"); cancelled.download.yield()
        try await until { ready.contains("cancelled") }
        cancelled.task.cancel()
        do { try await cancelled.task.value; fatalError("cancelled waiter ran") }
        catch is CancellationError {}
        queue.release()
        let next = job("next"); next.download.yield(); next.finish.yield()
        try await next.task.value
        precondition(order.last == "next" && !order.contains("cancelled") && !queue.isBusy)
        try await queue.acquire()
        queue.pause()
        let paused = job("paused"); paused.download.yield()
        try await until { ready.contains("paused") }
        queue.release()
        precondition(!queue.isBusy && queue.isPaused && !order.contains("paused"))
        let cancelledWhilePaused = job("cancelled paused"); cancelledWhilePaused.download.yield()
        try await until { ready.contains("cancelled paused") }
        cancelledWhilePaused.task.cancel()
        do { try await cancelledWhilePaused.task.value; fatalError("cancelled paused waiter ran") }
        catch is CancellationError {}
        queue.resume(); paused.finish.yield()
        try await paused.task.value
        precondition(order.last == "paused" && !queue.isBusy && !queue.isPaused)
        print("PASS: small ready downloads bypass large transfers, one install at a time, queued cancellation drains")
    }
}
