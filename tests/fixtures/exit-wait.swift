import Foundation
import CoreFoundation
import Darwin
import HostRuntime
import DeviceRuntime

nonisolated enum Bundled {
    static var logsDirectory: URL { URL(fileURLWithPath: CommandLine.arguments[2]) }
}
nonisolated func logEvent(_ message: String, _ arguments: CVarArg...) {
    let value = arguments.isEmpty ? message : String(format: message, arguments: arguments)
    print("LOG \(value)")
}

@main struct ExitWaitAudit {
    static func main() {
        Task { @MainActor in
            do { try await run(); exit(0) }
            catch { print("FAIL \(error)"); exit(1) }
        }
        CFRunLoopRun()
    }

    @MainActor static func run() async throws {
        let helper = URL(fileURLWithPath: CommandLine.arguments[1])
        let dir = URL(fileURLWithPath: CommandLine.arguments[2])
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let capture = try ProcessLogCapture(url: dir.appendingPathComponent("native.log"))
        var configuration = DeviceLink.Configuration(instance: UUID(), outputDescriptor: capture.writeDescriptor)
        configuration.machine = "ipod-touch-2g"
        configuration.helper = helper
        configuration.arguments = ["--lease", dir.appendingPathComponent("lease").path]
        configuration.requirement = CommandLine.arguments.count > 6 ? CommandLine.arguments[6] : nil
        let process = DeviceSessionProcess(configuration: configuration)
        defer { withExtendedLifetime(capture) {} }
        var deathCount = 0
        process.onDeath = { _ in deathCount += 1 }
        var ownedPID: pid_t = 0
        var exitTimer: DispatchWorkItem?
        defer { exitTimer?.cancel() }
        do {
            let info: HelperInfo = try await withCheckedThrowingContinuation { continuation in
                // Actual link hello, deliberately no .boot request.
                process.link.start { continuation.resume(with: $0) }
                ownedPID = process.link.pid
                if let identity = StorageLocations.daemonIdentity(ownedPID) {
                    emit(["event": "spawn", "pid": ownedPID, "parent": identity.parent,
                          "uid": identity.uid, "started": identity.started,
                          "micros": identity.micros, "path": identity.path])
                }
            }
            emit(["event": "hello", "pid": info.pid, "dylib": info.dylibPath,
                  "buildID": info.buildID ?? "unknown", "guestStarted": false])
            let pid = process.link.pid
            guard pid > 0, info.pid == pid, !process.isDead else { throw Failure.invalidHello }
            if CommandLine.arguments[3] == "failure" { throw Failure.injected }
            let killDelay = CommandLine.arguments.count > 4 ? Int(CommandLine.arguments[4])! : 1200
            let waitTimeout = CommandLine.arguments.count > 5 ? Double(CommandLine.arguments[5])! : 1
            let clock = ContinuousClock()
            let began = clock.now
            var heartbeat: Duration?
            DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(100)) {
                heartbeat = began.duration(to: clock.now)
            }
            var usageBefore = rusage()
            getrusage(RUSAGE_SELF, &usageBefore)
            // Terminate only the still-owned helper through its actual link;
            // DeviceLink exclusively reaps. This test does not assert a UI hang.
            let timer = DispatchWorkItem {
                if process.link.pid == ownedPID { process.terminate() }
            }
            exitTimer = timer
            DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(killDelay), execute: timer)
            let wait = Task { @MainActor in await process.waitForExit(timeout: waitTimeout) }
            if CommandLine.arguments[3] == "cancelled" { wait.cancel() }
            if CommandLine.arguments[3] == "during" {
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(100))
                    wait.cancel()
                }
            }
            let reportedExit = await wait.value
            let returnedAt = began.duration(to: clock.now)
            var usageAfter = rusage()
            getrusage(RUSAGE_SELF, &usageAfter)
            let userCPU = Double(usageAfter.ru_utime.tv_sec - usageBefore.ru_utime.tv_sec) + Double(usageAfter.ru_utime.tv_usec - usageBefore.ru_utime.tv_usec) / 1_000_000
            let systemCPU = Double(usageAfter.ru_stime.tv_sec - usageBefore.ru_stime.tv_sec) + Double(usageAfter.ru_stime.tv_usec - usageBefore.ru_stime.tv_usec) / 1_000_000
            let deadAtReturn = process.isDead
            let pidAtReturn = process.link.pid
            // Explicit fresh cleanup owner: cancellation never abandons reaping.
            if !reportedExit {
                do {
                    let premature = try StorageLease(dir.appendingPathComponent("lease"))
                    premature.close()
                    throw Failure.prematureLeaseRelease
                } catch StorageLease.Failure.inUse { }
            }
            let cleanup = Task { @MainActor in await process.waitForExit(timeout: 5) }
            let reaped = await cleanup.value
            guard reaped, process.link.pid == 0, deathCount == 1 else { throw Failure.notReaped }
            var status: Int32 = 0
            errno = 0
            guard waitpid(pid, &status, WNOHANG) == -1, errno == ECHILD else { throw Failure.otherReaper }
            let successor = try StorageLease(dir.appendingPathComponent("lease"))
            successor.close()
            let alreadyDead = await process.waitForExit(timeout: 0)
            guard alreadyDead, deathCount == 1 else { throw Failure.notReaped }
            // Ensure the heartbeat callback is delivered before producing evidence.
            try await Task.sleep(for: .milliseconds(20))
            let seconds = { (duration: Duration) -> Double in
                let parts = duration.components
                return Double(parts.seconds) + Double(parts.attoseconds) / 1e18
            }
            emit(["event": "result", "mode": CommandLine.arguments[3],
                  "timeout": waitTimeout, "killDelay": killDelay,
                  "wait": reportedExit, "returned": seconds(returnedAt),
                  "cpu": userCPU + systemCPU,
                  "heartbeat": heartbeat.map(seconds) ?? -1,
                  "deadAtReturn": deadAtReturn, "pidAtReturn": pidAtReturn,
                  "reaped": reaped, "deathCount": deathCount,
                  "guestStarted": false, "alreadyDead": alreadyDead])
        } catch {
            exitTimer?.cancel()
            if ownedPID > 0, process.link.pid == ownedPID { process.kill() }
            // A fresh cleanup scope must not inherit a failed/cancelled waiter.
            let cleanup = Task { @MainActor in await process.waitForExit(timeout: 5) }
            let reaped = await cleanup.value
            var status: Int32 = 0
            errno = 0
            let exclusivelyReaped = ownedPID > 0 && reaped && waitpid(ownedPID, &status, WNOHANG) == -1 && errno == ECHILD
            emit(["event": "failureCleanup", "pid": ownedPID,
                  "exclusiveReap": exclusivelyReaped,
                  "reaped": reaped, "remainingPID": process.link.pid,
                  "error": String(describing: error)])
            throw error
        }
    }
    @MainActor static func emit(_ value: [String: Any]) {
        let data = try! JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
        print(String(decoding: data, as: UTF8.self))
        fflush(stdout)
    }

    enum Failure: Error { case invalidHello, notReaped, otherReaper, prematureLeaseRelease, injected }
}
