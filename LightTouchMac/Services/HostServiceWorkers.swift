import Foundation
import Subprocess
import System

/// One command owner per endpoint. Blocking library calls never enter the GUI.
/// A deadline kills and reaps its process before a replacement accepts work.
actor HostServiceWorkers {
    static let shared = HostServiceWorkers()
    private var workers: [HostServiceEndpoint: HostServiceWorker] = [:]
    private var retired: Set<HostServiceEndpoint> = []
    private var subscriptions: [HostServiceEndpoint: [UUID: Task<Bool, Never>]] = [:]
    func worker(for endpoint: HostServiceEndpoint) throws -> HostServiceWorker {
        guard !retired.contains(endpoint) else { throw CancellationError() }
        if let worker = workers[endpoint] { return worker }
        let worker = HostServiceWorker(endpoint: endpoint)
        workers[endpoint] = worker
        return worker
    }
    func stop(endpoint: HostServiceEndpoint) async {
        retired.insert(endpoint)
        let observers = subscriptions.removeValue(forKey: endpoint) ?? [:]
        for observer in observers.values { observer.cancel() }
        if let worker = workers.removeValue(forKey: endpoint) { await worker.stop() }
        for observer in observers.values { _ = await observer.value }
    }
    func observe(endpoint: HostServiceEndpoint, onChange: @escaping @Sendable () -> Void) async -> Bool {
        guard !retired.contains(endpoint), let executable = HostServiceResources.executable else { return false }
        let id = UUID(), request = HostServiceRequest(id: UUID(), session: endpoint.session, operation: .observe)
        let task = Task {
            do {
                let bytes = try JSONEncoder().encode(request) + Data([10])
                let result = try await Subprocess.run(.path(FilePath(executable)),
                    arguments: Arguments(["--socket", endpoint.socket, "--udid", endpoint.udid ?? "", "--session", endpoint.session.uuidString]),
                    environment: .inherit.updating(["USBMUXD_SOCKET_ADDRESS": endpoint.socket,
                        "LTM_SERVICE_UDID": endpoint.udid, "LTM_SERVICE_FRAMEWORKS": HostServiceResources.frameworksDirectory]),
                    input: .inputWriter, output: .sequence, error: .discarded) { execution in
                    _ = try await execution.standardInputWriter.write(bytes)
                    try await execution.standardInputWriter.finish()
                    for try await line in execution.standardOutput.strings(bufferingPolicy: .maxLineLength(16 * 1024 * 1024)) {
                        let event = try JSONDecoder().decode(HostServiceEvent.self, from: Data(line.utf8))
                        guard event.id == request.id, event.session == endpoint.session else { throw DeviceError.notAttached }
                        if case .progress(.notification) = event.payload { onChange() }
                    }
                }
                return result.terminationStatus == .exited(0)
            } catch { return false }
        }
        subscriptions[endpoint, default: [:]][id] = task
        let result = await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() }
        subscriptions[endpoint]?[id] = nil
        return result
    }

}

actor HostServiceWorker {
    private struct Pending {
        let request: HostServiceRequest
        let continuation: CheckedContinuation<HostServiceValue, Error>
        let progress: @Sendable (HostServiceProgress) -> Void
        let timeout: Task<Void, Never>
    }
    let endpoint: HostServiceEndpoint
    private var queued: [UUID] = []
    private var pending: [UUID: Pending] = [:]
    private var active: UUID?
    private var process: Task<Void, Never>?
    private var channel: AsyncStream<Data>.Continuation?
    private var generation = UUID()
    private var closing = false
    private var deferred: (Pending, Error)?
    private var stopped = false

    init(endpoint: HostServiceEndpoint) { self.endpoint = endpoint }

    func request(_ operation: HostServiceOperation, seconds: Double,
                 progress: @escaping @Sendable (HostServiceProgress) -> Void = { _ in }) async throws -> HostServiceValue {
        try Task.checkCancellation()
        let id = UUID()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                guard !stopped else { continuation.resume(throwing: CancellationError()); return }
                let timer = Task { [weak self] in
                    do { try await Task.sleep(for: .seconds(seconds)) } catch { return }
                    await self?.cancel(id, error: DeviceError.timedOut(operation: "host service"))
                }
                pending[id] = Pending(request: HostServiceRequest(id: id, session: endpoint.session, operation: operation),
                    continuation: continuation, progress: progress, timeout: timer)
                queued.append(id)
                dispatch()
            }
        } onCancel: { Task { await self.cancel(id, error: CancellationError()) } }
    }

    private func dispatch() {
        guard !stopped, !closing, active == nil else { return }
        while let first = queued.first, pending[first] == nil { queued.removeFirst() }
        guard let id = queued.first, let next = pending[id] else { return }
        if process == nil { launch() }
        guard !closing, pending[id] != nil else { return }
        queued.removeFirst(); active = id
        do { channel?.yield(try JSONEncoder().encode(next.request) + Data([10])) }
        catch { finish(id, .failure(error)) }
    }

    private func launch() {
        guard let executable = HostServiceResources.executable else {
            closing = true
            let failures = pending.values
            pending.removeAll(); queued.removeAll()
            for value in failures {
                value.timeout.cancel(); value.continuation.resume(throwing: DeviceToolsError.toolMissing("LightTouchServices"))
            }
            closing = false
            return
        }
        let (stream, continuation) = AsyncStream<Data>.makeStream()
        channel = continuation
        let token = UUID(); generation = token
        let endpoint = endpoint
        let framework = HostServiceResources.frameworksDirectory
        let staging = HostServiceResources.stagingSession
        process = Task { [weak self] in
            var failure: Error = DeviceError.notAttached
            do {
                _ = try await Subprocess.run(.path(FilePath(executable)),
                    arguments: Arguments(["--socket", endpoint.socket, "--udid", endpoint.udid ?? "", "--session", endpoint.session.uuidString]),
                    environment: .inherit.updating(["USBMUXD_SOCKET_ADDRESS": endpoint.socket,
                        "LTM_SERVICE_FRAMEWORKS": framework, "LTM_SERVICE_UDID": endpoint.udid, "LTM_SERVICE_STAGING_SESSION": staging]),
                    input: .inputWriter, output: .sequence, error: .discarded) { execution in
                    try await withThrowingTaskGroup(of: Void.self) { group in
                        group.addTask {
                            for await bytes in stream { _ = try await execution.standardInputWriter.write(bytes) }
                            try await execution.standardInputWriter.finish()
                        }
                        group.addTask {
                            for try await line in execution.standardOutput.strings(bufferingPolicy: .maxLineLength(16 * 1024 * 1024)) {
                                let event = try JSONDecoder().decode(HostServiceEvent.self, from: Data(line.utf8))
                                await self?.receive(event, generation: token)
                            }
                            throw DeviceError.notAttached
                        }
                        defer { group.cancelAll() }
                        try await group.next()
                    }
                }
            } catch { failure = error }
            await self?.ended(generation: token, error: failure)
        }
    }

    private func receive(_ event: HostServiceEvent, generation token: UUID) {
        guard token == generation, !closing, event.session == endpoint.session,
              event.id == active, let value = pending[event.id] else { return }
        switch event.payload {
        case .result(let result): finish(event.id, .success(result))
        case .failure(let failure):
            // Old in-worker deadlines can abandon C threads. End that entire
            // process, and report only after it has been reaped.
            if case .device(.timedOut) = failure { cancel(event.id, error: failure.error) }
            else { finish(event.id, .failure(failure.error)) }
        case .progress(let progress): value.progress(progress)
        }
    }

    private func finish(_ id: UUID, _ result: Result<HostServiceValue, Error>) {
        guard let value = pending.removeValue(forKey: id) else { return }
        value.timeout.cancel(); value.continuation.resume(with: result)
        if active == id { active = nil }
        dispatch()
    }

    private func cancel(_ id: UUID, error: Error) {
        guard let value = pending.removeValue(forKey: id) else { return }
        value.timeout.cancel()
        if active == id, let process {
            deferred = (value, error)
            closing = true; channel?.finish(); process.cancel()
        } else { value.continuation.resume(throwing: error) }
    }

    private func ended(generation token: UUID, error: Error) {
        guard token == generation else { return }
        process = nil; channel = nil; closing = false
        if let (value, failure) = deferred {
            deferred = nil; value.continuation.resume(throwing: failure)
        } else if let id = active, let value = pending.removeValue(forKey: id) {
            value.timeout.cancel(); value.continuation.resume(throwing: error)
        }
        active = nil
        dispatch()
    }

    func stop() async {
        stopped = true
        let running = process
        for value in pending.values {
            value.timeout.cancel()
            if value.request.id == active, running != nil { deferred = (value, CancellationError()) }
            else { value.continuation.resume(throwing: CancellationError()) }
        }
        pending.removeAll(); queued.removeAll()
        closing = true; channel?.finish(); running?.cancel()
        await running?.value
    }
}

extension DeviceServices {
    func remote(_ operation: HostServiceOperation, seconds: Double,
                progress: @escaping @Sendable (HostServiceProgress) -> Void = { _ in }) async throws -> HostServiceValue {
        let worker = try await HostServiceWorkers.shared.worker(for: endpoint)
        return try await worker.request(operation, seconds: seconds, progress: progress)
    }
    func stopWorker() async { await HostServiceWorkers.shared.stop(endpoint: endpoint) }
}
