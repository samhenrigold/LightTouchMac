import Foundation

@main struct Check {
    @MainActor static func main() async throws {
        let queue = InstallationQueue()
        var order: [String] = []
        var concurrent = 0
        func job(_ name: String, download: Int) -> Task<Void, Error> {
            Task { @MainActor in
                try await Task.sleep(for: .milliseconds(download))
                try await queue.acquire()
                defer { queue.release() }
                try Task.checkCancellation()
                concurrent += 1
                precondition(concurrent == 1)
                defer { concurrent -= 1 }
                order.append(name)
                try await Task.sleep(for: .milliseconds(20))
            }
        }
        let large = job("large", download: 150)
        let small = job("small", download: 10)
        let second = job("second", download: 15)
        try await large.value; try await small.value; try await second.value
        precondition(order == ["small", "second", "large"])
        precondition(!queue.isBusy)
        try await queue.acquire()
        let cancelled = job("cancelled", download: 0)
        try await Task.sleep(for: .milliseconds(20))
        cancelled.cancel()
        do { try await cancelled.value; fatalError("cancelled waiter ran") }
        catch is CancellationError {}
        queue.release()
        let next = job("next", download: 0)
        try await next.value
        precondition(order.last == "next" && !order.contains("cancelled") && !queue.isBusy)
        try await queue.acquire()
        queue.pause()
        let paused = job("paused", download: 0)
        try await Task.sleep(for: .milliseconds(20))
        queue.release()
        try await Task.sleep(for: .milliseconds(20))
        precondition(!queue.isBusy && queue.isPaused && !order.contains("paused"))
        let cancelledWhilePaused = job("cancelled paused", download: 0)
        try await Task.sleep(for: .milliseconds(20))
        cancelledWhilePaused.cancel()
        do { try await cancelledWhilePaused.value; fatalError("cancelled paused waiter ran") }
        catch is CancellationError {}
        queue.resume()
        try await paused.value
        precondition(order.last == "paused" && !queue.isBusy && !queue.isPaused)
        print("PASS: small ready downloads bypass large transfers, one install at a time, queued cancellation drains")
    }
}
