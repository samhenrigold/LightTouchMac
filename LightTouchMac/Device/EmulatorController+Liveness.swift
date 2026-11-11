import Cocoa
import DeviceRuntime
import FirmwareSchema
import HostRuntime
import HostServiceClient
import HostServiceWire
import LightTouchCore
import Observation

extension EmulatorController {
    private func noteFrameAdvanced() {
        lastFrameAdvance = Date()
        if state.runsAfterFrame(poweringOn: poweringOn) {
            transition(to: .running)
            // A full battery, charging as it would on USB (auto): the machines start at their own levels (the
            // iPad at 80%, the S5L8920 boards at their PMU's), set before configd reads the gauge.
            control(.battery(level: 100, charging: 0))
            keyboard.applyHardware()
        }
    }

    /// Frames within the last ~2s. Not sufficient alone for "healthy": a
    /// locked/idle device legitimately stops painting.
    var framesRecentlyAdvanced: Bool {
        Date().timeIntervalSince(lastFrameAdvance) < 2.0
    }

    /// The helper's shared status block, so the status poll announces the flip (withMutation) for observers.
    var storageFailed: Bool {
        access(keyPath: \.storageFailed)
        return status?.storageFailed ?? false
    }
    /// The guest agent, live: 0 absent or not running, 1 alive, 2 stale.
    var liveAgentStatus: Int { status?.agentStatus ?? 0 }

    var agentStatusText: String {
        guard state == .running || state == .paused else { return "Waiting for device" }
        return agentStatus == 1 ? "Connected" : agentStatus == 2 ? "Not responding" : "Unavailable"
    }

    func pollStorageFailure() {
        updateVibration(status)
        guard let status else { return }
        if status.frameSerial != lastFrameSerial {
            lastFrameSerial = status.frameSerial
            noteFrameAdvanced()
        }
        if bootStage < .system,
            status.agentStatus == 1
                || (status.guestPackage != nil && status.guestPackage != readiness.reportAtBootStart)
        {
            noteBoot(.guestTools)
        }
        let now = Date()
        if now.timeIntervalSince(lastAgentStatusCheck) >= 1 {
            lastAgentStatusCheck = now
            if status.agentStatus != agentStatus {
                // A restarted agent may be a different version: ping it again.
                agentCache.reset()
                agentStatus = status.agentStatus
            }
            if status.agentStatus == 2 { agentStaleSince = agentStaleSince ?? now } else { agentStaleSince = nil }
            // the guest froze, or its tools did (issues 83, 123): once a boot
            if case .notResponding = guestToolsState, !reportedToolsQuiet {
                reportedToolsQuiet = true
                Analytics.fault("Guest.toolsNotResponding", analyticsParameters)
            }
        }
        if !poweringOn, status.shutdownConfirmed, !isDead, !isPoweredOff { endBoot(.guestPoweredOff) }
        if state == .running, !preparingDevice, !shuttingDown {
            isSleeping = status.displaySleeping
        } else if isSleeping {
            isSleeping = false
        }

        if storageFailed, !reportedStorageFailure {
            reportedStorageFailure = true
            withMutation(keyPath: \.storageFailed) {}
            reportDeviceNotice(statusLine, for: .storage)
            // the helper couldn't write the device's NAND or NOR
            Analytics.fault(
                "Device.storageFailed", analyticsParameters.merging(["freeSpace": Analytics.freeSpace]) { $1 })
        }
    }

    var isRunning: Bool {
        state == .running && !storageFailed && !preparingDevice && readinessFailure == nil && !restartingSpringBoard
            && !shuttingDown && !isErasing
    }
    var isPaused: Bool { state == .paused }
    var isDead: Bool { if case .dead = state { return true } else { return false } }
    /// The guest takes input whenever its screen is live (state == .running: the display paints). Readiness —
    /// SpringBoard answering, a startup that judged failure — never holds it back.
    var acceptsInput: Bool {
        state == .running && !storageFailed && !restartingSpringBoard && !shuttingDown && !isErasing
    }

    /// One line for the window's status area.
    var statusLine: String {
        if isErasing { return "Erasing \(profile.shortName)…" }
        if storageFailed { return "Couldn’t save to disk — \(profile.shortName) stopped; recent changes weren’t saved" }
        if shuttingDown, !isPoweredOff { return isShuttingDownCleanly ? "Shutting down…" : "Stopping…" }
        switch state {
        case .poweredOff: return "Powered off"
        case .notStarted: return "Starting…"
        case .booting: return "Starting iOS…"
        case .running:
            if let issue = connectionIssue, issue.persistent { return issue.summary }
            if preparingDevice { return preparationStatus }
            if isSleeping { return "Sleeping" }
            if restartingSpringBoard { return "Restarting the Home screen…" }
            if let readinessFailure { return "Startup failed — \(readinessFailure)" }
            guard canManageApps else { return "Running — USB unavailable" }
            // Quiet when all is well; the guest tools only when they need attention.
            return guestToolsState.needsAttention ? "Running — " + guestToolsLine : "Running"
        case .paused: return "Paused"
        case .dead: return "Stopped"
        }
    }

    /// The "Guest tools" line: the loader's report as the package watch judged it
    /// (GuestPackage.status), overridden by what the boot and the agent show now.
    var guestToolsLine: String { "Guest tools: " + guestToolsState.text }
    var guestToolsState: GuestPackage.Status {
        if inRecovery { return .recovery }
        if !bootFinished { return .notBooted }
        // The agent's heartbeat, on any board whose guest package runs it (the iPad's too).
        if let since = agentStaleSince, Date().timeIntervalSince(since) > 60 { return .notResponding }
        return guestToolsStatus
    }

    /// Which libqemu-arm.dylib this device's helper loaded, and when it was
    /// built (its hello). The dylib lives in a build tree other sessions rebuild
    /// under our feet; when "did this run have that fix?" comes up, this answers it.
    var dylibProvenance: String {
        guard let info = process?.info else { return "dylib: helper not connected" }
        return
            "dylib: \(info.dylibPath) (built \(Date(timeIntervalSince1970: info.dylibModified)), build \(info.buildID ?? "unknown"))"
    }

    func logEmulatorBuild() { logEvent("emulator \(dylibProvenance)") }
}
