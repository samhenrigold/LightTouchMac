#!/usr/bin/env python3
"""Bound installation setup without abandoning a started guest mutation. Compiles Services/InstallationProxy.swift
and Transport/DeviceExecution.swift whole against a fake libimobiledevice, with two pause points patched in
(after openBeforeDeadline stores the connection for the deadline's loser, and after it is handed to the install) so the races
run deterministically; no production deadline, cancellation or cleanup is replaced."""
from pathlib import Path
from host_service_fixtures import leaves, local_engine_stub
import subprocess
import tempfile

root = Path(__file__).resolve().parents[2]
app = root / "LightTouchMac"


def patched(text, old, new):
    assert text.count(old) == 1, old
    return text.replace(old, new)


install = patched((app / "Services/InstallationProxy.swift").read_text(),
                  "let connection = try await Self.installConnection()",
                  "let connection = try await Self.installConnection()\n                await Fixture.shared.afterConnection()")
# openBeforeDeadline is the install connection's only user in this build.
execution = patched((app / "Transport/DeviceExecution.swift").read_text(),
                    "if let opened = try open() { late.store(opened) }",
                    "if let opened = try open() { late.store(opened); Fixture.shared.afterStore() }")
fixture = r'''
import Foundation
import Dispatch
nonisolated func logEvent(_ message: String) { }
nonisolated final class Fixture: @unchecked Sendable {
    static let shared = Fixture()
    let lock = NSLock()
    var blockDevice = false, blockService = false, blockStore = false, blockHandoff = false
    var deviceEntered = false, serviceEntered = false, storeEntered = false, handoffEntered = false
    var deviceFrees = 0, clientFrees = 0, installs = 0, progress = 0
    var readStarted = false
    var installResult: Int32 = 0
    var callback: IMobileDevice.InstproxyStatusCB?
    var context: UnsafeMutableRawPointer?
    var handoff: CheckedContinuation<Void, Never>?
    let deviceRelease = DispatchSemaphore(value: 0), serviceRelease = DispatchSemaphore(value: 0)
    let storeRelease = DispatchSemaphore(value: 0)

    func reset() {
        lock.withLock {
            precondition(handoff == nil)
            blockDevice = false; blockService = false; blockStore = false; blockHandoff = false
            deviceEntered = false; serviceEntered = false; storeEntered = false; handoffEntered = false
            deviceFrees = 0; clientFrees = 0; installs = 0; progress = 0; readStarted = false
            callback = nil; context = nil; installResult = 0
        }
    }
    func afterStore() {
        if lock.withLock({ storeEntered = blockStore; return blockStore }) { storeRelease.wait() }
    }
    func afterConnection() async {
        guard lock.withLock({ blockHandoff }) else { return }
        await withCheckedContinuation { continuation in
            lock.withLock { handoff = continuation; handoffEntered = true }
        }
    }
    func resumeHandoff() {
        let continuation = lock.withLock { let saved = handoff; handoff = nil; return saved }
        continuation?.resume()
    }
    func emit(_ status: Int) {
        let (callback, context) = lock.withLock { (callback, context) }
        callback?(nil, OpaquePointer(bitPattern: status), context)
    }
}
nonisolated enum IMobileDevice {
    static let success: Int32 = 0, isAvailable = true
    typealias InstproxyStatusCB = @convention(c) (OpaquePointer?, OpaquePointer?, UnsafeMutableRawPointer?) -> Void
    typealias NewDevice = @convention(c) (UnsafeMutablePointer<OpaquePointer?>, UnsafePointer<CChar>?) -> Int32
    typealias Free = @convention(c) (OpaquePointer?) -> Int32
    typealias Install = @convention(c) (OpaquePointer?, UnsafePointer<CChar>?, OpaquePointer?, InstproxyStatusCB?, UnsafeMutableRawPointer?) -> Int32
    typealias StatusError = @convention(c) (OpaquePointer?, UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?, UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?, UnsafeMutablePointer<UInt64>?) -> Int32
    typealias StatusName = @convention(c) (OpaquePointer?, UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>) -> Void
    typealias StatusPercent = @convention(c) (OpaquePointer?, UnsafeMutablePointer<Int32>) -> Void
    static let idevice_new: NewDevice? = { output, _ in
        precondition(String(cString: getenv("USBMUXD_SOCKET_ADDRESS")) == "127.0.0.1:1", "gate did not select the install endpoint before startup")
        let state = Fixture.shared
        let blocked = state.lock.withLock { state.deviceEntered = true; return state.blockDevice }
        if blocked { state.deviceRelease.wait() }
        output.pointee = OpaquePointer(bitPattern: 17)
        return 0
    }
    static func openDevice(_ output: inout OpaquePointer?) -> Int32 { idevice_new!(&output, nil) }
    static let idevice_free: Free? = { pointer in
        precondition(pointer == OpaquePointer(bitPattern: 17))
        Fixture.shared.lock.withLock { Fixture.shared.deviceFrees += 1; precondition(Fixture.shared.deviceFrees == 1) }
        return 0
    }
    static func startInstallationProxy(device: OpaquePointer) throws -> OpaquePointer {
        precondition(device == OpaquePointer(bitPattern: 17))
        let state = Fixture.shared
        let blocked = state.lock.withLock { state.serviceEntered = true; return state.blockService }
        if blocked { state.serviceRelease.wait() }
        return OpaquePointer(bitPattern: 18)!
    }
    static let instproxy_client_free: Free? = { pointer in
        precondition(pointer == OpaquePointer(bitPattern: 18))
        let state = Fixture.shared
        // Model a final reader callback during join. Its retained context must
        // survive until this C free has returned, including immediate failures.
        state.emit(1)
        state.lock.withLock { state.clientFrees += 1; precondition(state.clientFrees == 1) }
        return 0
    }
    static let instproxy_install: Install? = { client, path, _, callback, context in
        precondition(client == OpaquePointer(bitPattern: 18) && String(cString: path!) == "PublicStaging/test.ipa")
        let state = Fixture.shared
        return state.lock.withLock {
            state.installs += 1; state.callback = callback; state.context = context
            return state.installResult
        }
    }
    static let instproxy_status_get_error: StatusError? = { status, name, description, _ in
        guard status == OpaquePointer(bitPattern: 3) else { return 0 }
        name?.pointee = strdup("ApplicationVerificationFailed")
        description?.pointee = strdup("rejected fixture")
        return -5
    }
    static let instproxy_status_get_name: StatusName? = { status, output in
        output.pointee = strdup(status == OpaquePointer(bitPattern: 2) ? "Complete" : "Installing")
    }
    static let instproxy_status_get_percent_complete: StatusPercent? = { _, output in output.pointee = 50 }
    // The list and uninstall halves of the file, not exercised here.
    static let instproxy_uninstall: Install? = nil
    typealias Browse = @convention(c) (OpaquePointer?, OpaquePointer?, UnsafeMutablePointer<OpaquePointer?>) -> Int32
    typealias PlistFree = @convention(c) (OpaquePointer?) -> Void
    static let instproxy_browse: Browse? = nil
    static let plist_free: PlistFree? = nil
    static func encode(_ value: Any) -> OpaquePointer? { nil }
    static func decode(_ node: OpaquePointer) -> Any? { nil }
}
struct DeviceServices: Sendable {
    let clientSocket: String
    func run<T: Sendable>(_ seconds: Double, _ label: String,
                          _ body: @escaping @Sendable (IMobileDevice.Type, OpaquePointer) throws -> T) async throws -> T {
        fatalError("not exercised")
    }
}
'''
main = r'''
@main struct Check {
    @MainActor static func wait(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(2)
        while !condition(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(1)) }
        precondition(condition(), "condition did not complete")
    }
    @MainActor static func launch() -> Task<Void, Error> {
        Task {
            try await DeviceServices(clientSocket: "127.0.0.1:1").install(stagedPath: "PublicStaging/test.ipa") { _, _ in
                Fixture.shared.lock.withLock { Fixture.shared.progress += 1 }
            }
        }
    }
    @MainActor static func expectFailure(_ task: Task<Void, Error>, _ expected: DeviceError?) async throws {
        let result = await withSoftDeadline(0.5) {
            do { try await task.value; return false }
            catch is CancellationError { return expected == nil }
            catch let error as DeviceError { return expected.map { "\($0)" == "\(error)" } ?? false }   // DeviceError is not Equatable
            catch { return false }
        }
        precondition(result == true, "install did not fail promptly with expected error")
    }
    @MainActor static func gateAvailable() async {
        let answer = await withSoftDeadline(0.2) { try? await DeviceGate.shared.serialized { 7 } }
        precondition(answer == .some(.some(7)), "startup failure held DeviceGate")
    }
    @MainActor static func main() async throws {
        Timeouts.serviceProbe = 0.04; Timeouts.installIdle = 0.20; Timeouts.installAbsolute = 1.0
        let state = Fixture.shared
        // Block each startup boundary, then let it return AFTER timeout or
        // cancellation. Neither the early exit nor a late handle may install.
        for atDevice in [true, false] {
            for cancel in [false, true] {
                state.reset()
                state.lock.withLock { state.blockDevice = atDevice; state.blockService = !atDevice }
                let task = launch()
                try await wait { state.lock.withLock { atDevice ? state.deviceEntered : state.serviceEntered } }
                if cancel { task.cancel() }
                try await expectFailure(task, cancel ? nil : .timedOut(operation: "install connection"))
                precondition(AbandonedWork.count == 1, "startup was not counted exactly once")
                await gateAvailable()
                precondition(state.lock.withLock { state.installs == 0 && state.deviceFrees == 0 && state.clientFrees == 0 })
                if atDevice { state.deviceRelease.signal() } else { state.serviceRelease.signal() }
                try await wait { AbandonedWork.count == 0 }
                precondition(state.lock.withLock { state.installs == 0 && state.deviceFrees == 1 && state.clientFrees == (atDevice ? 0 : 1) })
            }
        }
        // Deadline wins after the connection is stored but before its result
        // is delivered: the consumer side owns and closes both late handles.
        state.reset(); state.lock.withLock { state.blockStore = true }
        let stored = launch()
        try await wait { state.lock.withLock { state.storeEntered } }
        try await expectFailure(stored, .timedOut(operation: "install connection"))
        await gateAvailable()
        precondition(state.lock.withLock { state.installs == 0 && state.deviceFrees == 1 && state.clientFrees == 1 })
        precondition(AbandonedWork.count == 1)
        state.storeRelease.signal()
        try await wait { AbandonedWork.count == 0 }

        // Cancellation in the handoff gap must close a successful connection
        // exactly once, without ever submitting the guest mutation.
        state.reset(); state.lock.withLock { state.blockHandoff = true }
        let handoff = launch()
        try await wait { state.lock.withLock { state.handoffEntered } }
        handoff.cancel(); state.resumeHandoff()
        try await expectFailure(handoff, nil)
        precondition(state.lock.withLock { state.installs == 0 && state.deviceFrees == 1 && state.clientFrees == 1 })
        precondition(AbandonedWork.count == 0)
        await gateAvailable()

        // A real submitted installation remains owned, even after cancellation,
        // until its terminal callback; queued reads cannot interrupt it.
        state.reset()
        let normal = launch()
        try await wait { state.lock.withLock { state.installs == 1 } }
        let read = Task { try await DeviceGate.shared.serialized { state.lock.withLock { state.readStarted = true }; return 9 } }
        normal.cancel(); state.emit(1)
        try await Task.sleep(for: .milliseconds(20))
        precondition(state.lock.withLock { state.clientFrees == 0 && state.deviceFrees == 0 && !state.readStarted })
        precondition(AbandonedWork.count == 0)
        state.emit(2)
        try await normal.value
        let value = try await read.value
        precondition(value == 9)
        precondition(state.lock.withLock { state.clientFrees == 1 && state.deviceFrees == 1 && state.progress >= 2 && state.readStarted })
        // One progress call came from the C free's simulated final callback.

        state.reset(); state.lock.withLock { state.installResult = -4 }
        try await expectFailure(launch(), .instproxy(.init(code: -4), phase: "start"))
        precondition(state.lock.withLock { state.clientFrees == 1 && state.deviceFrees == 1 && state.progress == 1 })
        state.reset()
        let rejected = launch()
        try await wait { state.lock.withLock { state.installs == 1 } }
        state.emit(3)
        try await expectFailure(rejected, .instproxy(.init(code: -5), phase: "rejected fixture"))
        precondition(state.lock.withLock { state.clientFrees == 1 && state.deviceFrees == 1 })

        // The existing mutation watchdog alone accounts for an idle install.
        // It must not be nested inside a second deadline or free live callbacks.
        state.reset()
        try await expectFailure(launch(), .timedOut(operation: "install"))
        precondition(AbandonedWork.count == 1)
        precondition(state.lock.withLock { state.installs == 1 && state.clientFrees == 0 && state.deviceFrees == 0 })
        await gateAvailable()
        try await wait { AbandonedWork.count == 0 }
        print("PASS: bounded device/service startup, cancellation/handoff races, late-handle cleanup, gate reuse, owned terminal callback and single watchdog accounting")
    }
}
'''
with tempfile.TemporaryDirectory(prefix="ltm-install-startup-") as directory:
    path = Path(directory)
    swift = path / "check.swift"
    swift.write_text(fixture + main)
    (path / "InstallationProxy.swift").write_text(install)
    (path / "DeviceExecution.swift").write_text(execution)
    binary = path / "check"
    subprocess.run(["xcrun", "swiftc", *leaves(root), *local_engine_stub(path), "-parse-as-library", "-swift-version", "6",
                    "-default-isolation", "MainActor", "-module-cache-path", str(path / "modules"),
                    str(path / "InstallationProxy.swift"), str(path / "DeviceExecution.swift"),
                    str(swift), "-o", str(binary)], check=True)
    subprocess.run([str(binary)], check=True, timeout=15)
