import Foundation
import FirmwareKit
import HostRuntime

@MainActor final class CommandLifetime {
    private let operation: Task<Int32, Never>
    private var cancellation: Task<Void, Never>?
    private var signals: [DispatchSourceSignal] = []
    private var parentWatch: DispatchSourceProcess?
    private let output: PipeOutput
    private let cleanup: (@Sendable () async throws -> Void)?

    init(output: PipeOutput, cleanup: (@Sendable () async throws -> Void)? = nil,
         operation: @escaping @Sendable () async -> Int32) {
        self.output = output; self.cleanup = cleanup
        self.operation = Task { await operation() }
        signals = [SIGTERM, SIGINT].map { sig in
            signal(sig, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            source.setEventHandler { [weak self] in
                Task { @MainActor in self?.cancel(sig == SIGTERM ? "SIGTERM" : "SIGINT") }
            }
            source.resume(); return source
        }
        let parent = getppid()
        let source = DispatchSource.makeProcessSource(identifier: parent, eventMask: .exit, queue: .main)
        source.setEventHandler { [weak self] in Task { @MainActor in self?.cancel("parent exited") } }
        source.resume(); parentWatch = source
        if parent == 1 || getppid() != parent { cancel("no parent") }
    }
    private func cancel(_ reason: String) {
        guard cancellation == nil else { return }
        output.stop()
        FirmwareDiagnostics.write(Data("firmwarekit: cancelled (\(reason))\n".utf8))
        FirmwareDiagnostics.stop()
        let children = Preparer.childrenForCancellation()
        operation.cancel()
        cancellation = Task { await Preparer.stopChildren(children) }
    }
    func wait() async -> Int32 {
        let status = await operation.value
        let outputSucceeded = await output.finish()
        let diagnosticsSucceeded = await FirmwareDiagnostics.finish()
        if let cancellation {
            await cancellation.value
            do { try await cleanup?() }
            catch {
                // Output was stopped so cancellation cannot wait on a lost
                // consumer. Failure is observable as exit 1; staging is retained.
                return 1
            }
            return 143
        }
        guard outputSucceeded && diagnosticsSucceeded else {
            // Delivery failure is reflected in status, not another unjoined
            // write to a stream that may already have lost its consumer.
            return 1
        }
        return status
    }
}
