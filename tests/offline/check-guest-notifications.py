#!/usr/bin/env python3
"""Exercise the production notification watcher with a controllable C-service boundary."""
from pathlib import Path
from host_service_fixtures import leaves
import subprocess
import tempfile

root = Path(__file__).resolve().parents[2]
execution = (root / "LightTouchMac/Transport/DeviceExecution.swift").read_text()
watcher = (root / "LightTouchMac/Services/NotificationProxy.swift").read_text()
# Only accelerate periodic retry/icon ticks. The actual stream/cancellation,
# client ownership, gate and deadline code is compiled unchanged.
watcher = watcher.replace(".seconds(1)", ".milliseconds(5)")
watcher = watcher.replace(".seconds(ok ? 2 : 10)", ".milliseconds(ok ? 5 : 10)")
fixture = r'''
import Foundation
import Dispatch
nonisolated enum DeviceServices { static let session = UUID() }
actor HostServiceWorkers {
 static let shared = HostServiceWorkers()
 func observe(endpoint: HostServiceEndpoint, onChange: @escaping @Sendable () -> Void) async -> Bool {
  fatalError("notification C-engine fixture must inject its observer")
 }
}
nonisolated func logEvent(_ message: String) { }

nonisolated final class Library: @unchecked Sendable {
    static let shared = Library()
    struct Client: @unchecked Sendable {
        var callback: IMobileDevice.NpNotifyCB?
        var context: UnsafeMutableRawPointer?
    }
    let lock = NSLock()
    var clients: [Int: Client] = [:]
    var starts = 0, frees = 0, subscriptions = 0
    var blockStart = false, startEntered = false
    var blockFree = false, freeEntered = false
    var failObserve = false
    let startRelease = DispatchSemaphore(value: 0)
    let freeRelease = DispatchSemaphore(value: 0)

    func start(_ output: UnsafeMutablePointer<OpaquePointer?>) -> Int32 {
        let (id, blocked) = lock.withLock {
            starts += 1
            clients[starts] = Client()
            startEntered = blockStart
            return (starts, blockStart)
        }
        if blocked { startRelease.wait() }
        output.pointee = OpaquePointer(bitPattern: id)
        return 0
    }
    func free(_ client: OpaquePointer?) -> Int32 {
        precondition(!Thread.isMainThread, "C-client join must never run on the main actor")
        let id = Int(bitPattern: client!)
        let blocked = lock.withLock {
            precondition(clients[id] != nil, "client freed twice")
            freeEntered = blockFree
            return blockFree
        }
        if blocked { freeRelease.wait() }
        lock.withLock { clients.removeValue(forKey: id); frees += 1 }
        return 0
    }
    func emit(_ name: String) {
        let client = lock.withLock { clients[starts]! }
        name.withCString { client.callback?($0, client.context) }
    }
}

nonisolated enum IMobileDevice {
    static let success: Int32 = 0
    static let isAvailable = true
    typealias NpNotifyCB = @convention(c) (UnsafePointer<CChar>?, UnsafeMutableRawPointer?) -> Void
    typealias NewDevice = @convention(c) (UnsafeMutablePointer<OpaquePointer?>, UnsafePointer<CChar>?) -> Int32
    typealias NewClient = @convention(c) (OpaquePointer?, UnsafeMutablePointer<OpaquePointer?>, UnsafePointer<CChar>?) -> Int32
    typealias FreeHandle = @convention(c) (OpaquePointer?) -> Int32
    typealias Observe = @convention(c) (OpaquePointer?, UnsafePointer<CChar>?) -> Int32
    typealias SetCallback = @convention(c) (OpaquePointer?, NpNotifyCB?, UnsafeMutableRawPointer?) -> Int32
    static let idevice_new: NewDevice? = { output, _ in output.pointee = OpaquePointer(bitPattern: 42); return 0 }
    static func openDevice(_ output: inout OpaquePointer?) -> Int32 { idevice_new!(&output, nil) }
    static let idevice_free: FreeHandle? = { _ in 0 }
    static let np_client_start_service: NewClient? = { _, output, _ in Library.shared.start(output) }
    static let np_client_free: FreeHandle? = { Library.shared.free($0) }
    static let np_observe_notification: Observe? = { _, _ in
        Library.shared.lock.withLock {
            Library.shared.subscriptions += 1
            return Library.shared.failObserve ? -3 : 0
        }
    }
    static let np_set_notify_callback: SetCallback? = { client, callback, context in
        Library.shared.lock.withLock {
            let id = Int(bitPattern: client!)
            Library.shared.clients[id] = .init(callback: callback, context: context)
        }
        return 0
    }
}

@MainActor final class Activity {
    var allowed = false
    var changes = 0
    var attachChecks = 0
    func canAttach() -> Bool { attachChecks += 1; return allowed }
    func changed() { changes += 1 }
}
@main struct Check {
    @MainActor static func wait(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(2)
        while !condition(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(1)) }
        precondition(condition(), "condition did not complete")
    }
    @MainActor static func main() async throws {
        Timeouts.serviceProbe = 0.025
        let library = Library.shared
        let activity = Activity()
        let watcher = NotificationProxy(clientSocket: "127.0.0.1:1", observe: { endpoint, allowed, change in
            await NotificationProxy.localObserveOnce(socket: endpoint.socket, attachAllowed: allowed, onChange: change)
        }) { 0 }
        func start() {
            watcher.start(attachAllowed: { await activity.canAttach() }) {
                Task { @MainActor in activity.changed() }
            }
        }
        start()
        try await Task.sleep(for: .milliseconds(30))
        precondition(library.lock.withLock { library.starts == 0 }, "attach during active operation")
        activity.allowed = true
        try await wait { library.lock.withLock { library.clients[1]?.callback != nil } }
        precondition(library.lock.withLock { library.subscriptions == 2 })
        library.emit("com.apple.mobile.application_installed")
        library.emit("not-an-app-change")
        library.emit("com.apple.mobile.application_uninstalled")
        try await wait { activity.changes == 2 }

        // A long install must not close a perfectly healthy notification socket.
        activity.allowed = false
        try await Task.sleep(for: .milliseconds(80))
        precondition(library.lock.withLock { library.starts == 1 && library.frees == 0 })

        // The service can die while USB stays attached. Empty callback means
        // reconnect, not an app change; reconnection waits out active work.
        library.emit("")
        try await wait { library.lock.withLock { library.frees == 1 } }
        try await Task.sleep(for: .milliseconds(30))
        precondition(activity.changes == 2)
        precondition(library.lock.withLock { library.starts == 1 })
        activity.allowed = true
        try await wait { library.lock.withLock { library.clients[2]?.callback != nil } }
        library.emit("com.apple.mobile.application_uninstalled")
        try await wait { activity.changes == 3 }
        watcher.stop()
        try await wait { library.lock.withLock { library.frees == 2 } }
        try await Task.sleep(for: .milliseconds(30))
        precondition(library.lock.withLock { library.starts == 2 })

        // Cancellation still schedules teardown. A blocked C join leaves the
        // main actor responsive and keeps its callback context alive until done.
        start()
        try await wait { library.lock.withLock { library.clients[3]?.callback != nil } }
        library.lock.withLock { library.blockFree = true }
        watcher.stop()
        try await wait { library.lock.withLock { library.freeEntered } }
        try await wait { AbandonedWork.count == 1 }
        library.emit("")
        library.lock.withLock { library.blockFree = false }
        library.freeRelease.signal()
        try await wait { library.lock.withLock { library.frees == 3 } && AbandonedWork.count == 0 }

        // Failed subscription never leaves a silently useless watcher open.
        library.lock.withLock { library.failObserve = true }
        start()
        try await wait { library.lock.withLock { library.frees >= 4 } }
        watcher.stop()
        try await Task.sleep(for: .milliseconds(30))
        precondition(library.lock.withLock { library.clients.isEmpty })

        // A connect that returns only after cancellation must free exactly once.
        library.lock.withLock { library.failObserve = false; library.blockStart = true }
        start()
        try await wait { library.lock.withLock { library.startEntered } }
        watcher.stop()
        try await wait { AbandonedWork.count == 1 }
        library.startRelease.signal()
        try await wait { library.lock.withLock { library.clients.isEmpty } && AbandonedWork.count == 0 }
        precondition(library.lock.withLock { library.starts == library.frees })

        // Host activity is rechecked after waiting for the service gate: an
        // install can begin between the outside eligibility check and connect.
        library.lock.withLock { library.blockStart = false }
        let entered = ResumeOnce<Void>(), release = ResumeOnce<Void>()
        let owner = Task {
            try await DeviceGate.shared.serialized {
                entered.resume(.success(()))
                try await withCheckedThrowingContinuation { release.attach($0) }
            }
        }
        try await withCheckedThrowingContinuation { entered.attach($0) }
        let checks = activity.attachChecks
        let starts = library.lock.withLock { library.starts }
        start()
        try await wait { activity.attachChecks > checks }
        activity.allowed = false
        release.resume(.success(()))
        try await owner.value
        try await wait { activity.attachChecks >= checks + 2 }
        watcher.stop()
        precondition(library.lock.withLock { library.starts == starts }, "connected after an install took the device")
        print("PASS: notification disconnect/reconnect, install deferral/gate recheck, cancellation, blocked cleanup, failed subscription, late-client ownership")
    }
}
'''
with tempfile.TemporaryDirectory(prefix="ltm-notifications-") as directory:
    source = Path(directory) / "check.swift"
    source.write_text(fixture + execution + watcher)
    binary = Path(directory) / "check"
    subprocess.run(["xcrun", "swiftc", *leaves(root), "-parse-as-library", "-swift-version", "6",
                    "-default-isolation", "MainActor", "-module-cache-path", directory + "/modules",
                    str(source), "-o", str(binary)], check=True)
    subprocess.run([str(binary)], check=True, timeout=15)
