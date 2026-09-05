import Foundation

/// Only ready IPAs enter this queue. Network transfers never reserve the device.
@MainActor final class InstallationQueue {
    private(set) var isBusy = false
    private(set) var isPaused = false
    private var waiters: [(UUID, CheckedContinuation<Void, Error>)] = []

    func acquire() async throws {
        try Task.checkCancellation()
        if !isBusy && !isPaused { isBusy = true; return }
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                waiters.append((id, continuation))
            }
        } onCancel: {
            Task { @MainActor in
                guard let index = self.waiters.firstIndex(where: { $0.0 == id }) else { return }
                self.waiters.remove(at: index).1.resume(throwing: CancellationError())
            }
        }
    }

    func pause() { isPaused = true }

    func resume() {
        isPaused = false
        if !isBusy, !waiters.isEmpty {
            isBusy = true
            waiters.removeFirst().1.resume()
        }
    }

    func release() {
        if waiters.isEmpty || isPaused { isBusy = false }
        else { waiters.removeFirst().1.resume() }
    }
}
