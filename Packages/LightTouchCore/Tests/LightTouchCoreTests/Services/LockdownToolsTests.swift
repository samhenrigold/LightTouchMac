import Foundation
import HostServiceWire
import Testing

@testable import LightTouchCore

/// DeviceServices.setTimeZone and its lockdown child (LockdownTools) against fake lockdown-tz scripts and a fake guest
/// agent. Serialized: the deadline test shortens the process-wide Timeouts.query.
@Suite(.serialized) struct LockdownToolsTests {
    func script(_ url: URL, _ text: String) throws {
        try text.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
    }

    /// lockdown-tz ZONE: writes so far in $USBMUXD_SOCKET_ADDRESS, how many to drop (exit 4, the device kept
    /// US/Pacific) in its .drops.
    static let droppingTool = """
        #!/bin/sh
        f="$USBMUXD_SOCKET_ADDRESS"; n=$(( $(cat "$f" 2>/dev/null || echo 0) + 1 )); echo $n > "$f"
        if [ $n -le $(cat "$f.drops") ]; then echo US/Pacific; exit 4; fi
        echo "$2"
        """

    func run(_ dir: URL, drops: Int, guest: GuestServices?, retryInterval: Duration = .seconds(5)) async -> (
        result: Result<String, Error>, writes: Int, seconds: Double
    ) {
        let state = dir.appendingPathComponent("state-\(UUID().uuidString)").path
        try! "\(drops)".write(toFile: state + ".drops", atomically: true, encoding: .utf8)
        let start = Date()
        let result: Result<String, Error>
        do {
            result = .success(
                try await DeviceServices.setTimeZone(
                    "America/New_York",
                    tool: dir.appendingPathComponent("lockdown-tz").path,
                    socket: state,
                    guest: guest,
                    retryInterval: retryInterval
                )
            )
        } catch { result = .failure(error) }
        let writes =
            Int(
                (try? String(contentsOfFile: state, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines)
                    ?? "0"
            ) ?? 0
        return (result, writes, Date().timeIntervalSince(start))
    }

    // MARK: Zone retry (a zone write the guest drops is written again)

    @Test func droppedWriteWithoutAnAgentIsWrittenAgainFiveSecondsLater() async throws {
        try await withTemporaryDirectoryAsync { dir in
            try script(dir.appendingPathComponent("lockdown-tz"), Self.droppingTool)
            let r = await run(dir, drops: 1, guest: nil)
            #expect((try? r.result.get()) == "America/New_York" && r.writes == 2 && r.seconds >= 4.5, "\(r)")
        }
    }

    @Test func agentClearsLocationdsFirstZoneAndTheWriteGoesAgainAtOnce() async throws {
        try await withTemporaryDirectoryAsync { dir in
            try script(dir.appendingPathComponent("lockdown-tz"), Self.droppingTool)
            let link = FakeGuestLink()
            let cache = "/var/root/Library/Caches/locationd/cache.plist"
            link.files[cache] = try PropertyListSerialization.data(
                fromPropertyList: ["PreviousTimeZone": "US/Pacific"],
                format: .binary,
                options: 0
            )
            let r = await run(
                dir,
                drops: 1,
                guest: GuestServices(agent: GuestAgent(link: link, cache: GuestAgentCache()))
            )
            #expect((try? r.result.get()) == "America/New_York" && r.writes == 2 && r.seconds < 4, "\(r)")
            #expect(link.spawns.count == 2 && link.ops.contains("put"), "locationd's record cleared once: \(link.ops)")
        }
    }

    @Test func aZoneTheDeviceKeepsIsGivenUpAfterFourWrites() async throws {
        try await withTemporaryDirectoryAsync { dir in
            try script(dir.appendingPathComponent("lockdown-tz"), Self.droppingTool)
            // the five seconds are droppedWriteWithoutAnAgentIsWrittenAgainFiveSecondsLater's
            let r = await run(dir, drops: 99, guest: nil, retryInterval: .milliseconds(50))
            guard case .failure(DeviceToolsError.zoneKept("US/Pacific")) = r.result else {
                Issue.record("not zoneKept: \(r)")
                return
            }
            #expect(r.writes == 4)
        }
    }

    // MARK: Cancellation and deadlines

    /// SIGTERM is ignored deliberately: teardown must escalate, and a delayed writer must never land.
    static func slowTool(started: URL, marker: URL) -> String {
        "#!/bin/sh\ntrap '' TERM\n/usr/bin/touch '\(started.path)'\n/bin/sleep 0.4\n/usr/bin/touch '\(marker.path)'\n"
    }

    @Test func cancelledChildIsReaped() async throws {
        try await withTemporaryDirectoryAsync { root in
            let slow = root.appendingPathComponent("slow.sh")
            let marker = root.appendingPathComponent("late-marker")
            let started = root.appendingPathComponent("started")
            try script(slow, Self.slowTool(started: started, marker: marker))
            let child = Task { try await DeviceServices.lockdownChild(slow.path, [], socket: "127.0.0.1:31411") }
            let spawnDeadline = ContinuousClock.now + .seconds(2)
            while !FileManager.default.fileExists(atPath: started.path) {
                try #require(ContinuousClock.now < spawnDeadline, "child never spawned")
                try await Task.sleep(for: .milliseconds(2))
            }
            child.cancel()
            await #expect(throws: CancellationError.self) { _ = try await child.value }
            try await Task.sleep(for: .milliseconds(500))
            #expect(!FileManager.default.fileExists(atPath: marker.path), "cancelled child left a delayed writer")
        }
    }

    @Test func childPastItsDeadlineIsReaped() async throws {
        try await withTemporaryDirectoryAsync { root in
            let slow = root.appendingPathComponent("slow.sh")
            let marker = root.appendingPathComponent("late-marker")
            try script(slow, Self.slowTool(started: root.appendingPathComponent("started"), marker: marker))
            let saved = Timeouts.query
            Timeouts.query = 0.1
            defer { Timeouts.query = saved }
            do {
                _ = try await DeviceServices.lockdownChild(slow.path, [], socket: "127.0.0.1:31411")
                Issue.record("deadline succeeded")
            } catch DeviceToolsError.failed {}
            try await Task.sleep(for: .milliseconds(500))
            #expect(!FileManager.default.fileExists(atPath: marker.path), "deadline left a delayed writer")
        }
    }

    /// Cancelled during zoneKept's readiness wait, just as the agent comes up: no forget, no retry.
    @Test func cancelledZoneRetryNeitherClearsGuestStateNorWritesAgain() async throws {
        try await withTemporaryDirectoryAsync { root in
            let zone = root.appendingPathComponent("zone.sh")
            let attempts = root.appendingPathComponent("attempts")
            try script(zone, "#!/bin/sh\nprintf 'attempt\\n' >> '\(attempts.path)'\nprintf 'UTC\\n'\nexit 4\n")
            let link = FakeGuestLink()
            link.agent = 0
            link.files["/var/root/Library/Caches/locationd/cache.plist"] = try PropertyListSerialization.data(
                fromPropertyList: ["PreviousTimeZone": "UTC"],
                format: .binary,
                options: 0
            )
            let guest = GuestServices(agent: GuestAgent(link: link, cache: GuestAgentCache()))
            let operation = Task {
                try await DeviceServices.setTimeZone(
                    "Etc/UTC",
                    tool: zone.path,
                    socket: "127.0.0.1:31411",
                    guest: guest
                )
            }
            let deadline = ContinuousClock.now + .seconds(5)
            while !FileManager.default.fileExists(atPath: attempts.path) {
                try #require(ContinuousClock.now < deadline, "the first write never ran")
                try await Task.sleep(for: .milliseconds(2))
            }
            try await Task.sleep(for: .milliseconds(100))  // in waitAlive by now
            link.lock.withLock { link.agent = 1 }
            operation.cancel()
            await #expect(throws: CancellationError.self) { _ = try await operation.value }
            #expect(link.ops.isEmpty, "cancelled timezone touched the guest: \(link.ops)")
            #expect(try String(contentsOf: attempts, encoding: .utf8) == "attempt\n", "cancelled timezone retried")
        }
    }

    @Test func cancelledWaitAliveReturnsPromptly() async throws {
        let link = FakeGuestLink()
        link.agent = 0
        let agent = GuestAgent(link: link, cache: GuestAgentCache())
        let start = ContinuousClock.now
        let pending = Task { await agent.waitAlive(seconds: 60) }
        try await Task.sleep(for: .milliseconds(20))
        pending.cancel()
        #expect(await pending.value == false)
        #expect(ContinuousClock.now - start < .seconds(1), "cancelled waitAlive spun until its deadline")
    }
}
