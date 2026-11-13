import Cocoa
import DeviceRuntime
import FirmwareSchema
import HostRuntime
import HostServiceClient
import HostServiceWire
import LightTouchCore
import Observation

extension EmulatorController {
    /// Why the helper died, for the row and the dead overlay.
    var deathReason: String? { bootWatch.deathReason }
    func failBoot(_ error: Error) {
        Analytics.failure("Device.bootFailed", error, analyticsParameters)
        bootWatch.failBoot(error)
    }
    func startBootWatch() { bootWatch.start() }
    func abortBoot(_ reason: String) { bootWatch.abort(reason) }

    /// iOS is up: lockdown answered (the helper's uiReady is QEMU's display, lit
    /// by iBoot too). Without a USB bridge (--no-appsync) painting has to do.
    var bootFinished: Bool { deviceReachable == true || (usbmux.session == nil && state == .running) }

    /// Status is read from the helper's shared block: the old per-frame poll,
    /// now on its own timer so a hidden device (no display link) still flips
    /// booting -> running, notices storage failures and its power-off.
    /// 30 Hz while the screen is on show, 4 Hz otherwise.
    func startStatusPoll() {
        statusTimer?.invalidate()
        let interval = HostPower.pollInterval(screenVisible: screenVisible)
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.pollStorageFailure() }
        }
        timer.tolerance = interval / 5
        RunLoop.main.add(timer, forMode: .common)
        statusTimer = timer
    }

    /// The window shows this device's screen (DisplayView: on screen, not occluded, minimized or hidden).
    /// Hidden, the helper publishes a few frames a second and lets the Mac idle-sleep, and the status poll slows.
    var screenVisible: Bool {
        get { hostPower.screenVisible }
        set { hostPower.screenVisible = newValue }
    }

    /// Restart, Delete, Prepare Again and file system edits: stop this device's tasks and usbmuxd, halt its helper
    /// (stop()'s SIGTERM: a guest that powered off quits at once, a running one is paused, flushed and quit), kill it
    /// if it outlives the halt budget, and wait until it is gone. False if it would not exit. Both signals are the
    /// app's, so the exit reads as stopped, not as a crash (issue 109's Recent errors).
    func release() async -> Bool {
        releasing = true
        stop()
        guard let process, process.link.pid > 0 else {
            await workers.awaitTeardown(budget: ladder.budgets.serviceTeardown)
            return true
        }
        var exited = await process.waitForExit(timeout: ladder.budgets.halt)
        if !exited {
            logEvent("release: the device helper did not exit in \(Int(ladder.budgets.halt)) s; killing it")
            Analytics.fault("Device.releaseTimedOut", analyticsParameters)
            process.kill()
            exited = await process.waitForExit(timeout: ladder.budgets.kill)
        }
        await workers.awaitTeardown(budget: ladder.budgets.serviceTeardown)
        return exited
    }

    /// The iPod machine has the guest agent's channel; a stock iPad has none,
    /// so its media import and agent extras are skipped.
    var hasGuestTools: Bool { profile.hasGuestTools }

    func stopTimeZoneSync() { timeZone.stop() }
    func startTimeZoneSync() { timeZone.start() }
    func setGuestTimeZone(_ identifier: String) async throws {
        // A pinned clock (a dated beta, or Tweaks' Time Machine) is the guest's own: the Mac's would undo it.
        let dated = lock?.pinsClock == true || tweaks.bootClock != nil
        try await services.setTimeZone(identifier, keepClock: dated, guest: guest, region: .mac)
    }

    /// App quit (after the clean shutdowns) and restarts. The helper gets
    /// SIGTERM: a guest that already powered off quits at once; one that
    /// didn't gets the helper's own bounded clean shutdown after we are gone.
    func ensureUSBMux() { usbmux.ensureRunning() }

    func publishDeveloperConnection() {
        guard GuestDeveloperTools.supports(build: instance.firmware.split(separator: "-").last.map(String.init) ?? "")
        else { return }
        guard let socket = usbmux.session?.clientSocket else { return }
        do {
            try DeveloperConnectionProfile.publish(
                instance: instance.id,
                session: bootScope.id,
                socket: socket,
                udid: guestUDID
            )
        } catch { logEvent("developer access: \(error.localizedDescription)") }
    }

    private func retireDeveloperConnection() {
        DeveloperConnectionProfile.retire(instance: instance.id, session: bootScope.id)
    }

    func retireBoot() {
        guard !bootScope.retired else { return }
        let endpoint = try? services
        retireDeveloperConnection()
        stopTimeZoneSync()
        bootScope.retire()
        workers.chain { await endpoint?.stopWorker() }
    }

    func stop() {
        stopped = true
        retireBoot()  // cancels every task of this boot (BootSessionScope)
        statusTimer?.invalidate()
        statusTimer = nil
        updateVibration(nil)
        process?.terminate()
        fileWatch = nil
        // Unlink the owned FIFO paths now, keeping readers alive until the
        // helper is finished writing.
        serialCapture?.removeEndpoints()
        usbmux.stop()
        removeSockets()
    }

    /// The boot's web proxy and debug port sockets (usbmuxd's go in usbmux.stop()): a listener keeps its socket open
    /// after its path is gone, and the paths pile up otherwise (HelperSandbox's folder isn't purged).
    private func removeSockets() {
        proxy.forgetEndpoint()
        _ = options.chooseDebugSocket(booting: false)
    }

    /// Booting and recording: a notice (non-blocking) below 2 GB free, gone once there's room.
    /// The volume query (CacheDelete, ~0.1 s) runs off the main thread.
    func warnIfLowOnSpace() {
        let stateDir = stateDir
        Task {
            let warning = await Self.lowSpaceWarning(at: stateDir)
            if let warning { reportDeviceNotice(warning, for: .lowSpace) } else { resolveDeviceNotice(for: .lowSpace) }
        }
    }
    @concurrent nonisolated static func unpackGuestTools() async { _ = Bundled.guestRoot }
    @concurrent private nonisolated static func lowSpaceWarning(at url: URL) async -> String? {
        IPSWStore.lowSpaceWarning(at: url)
    }

    /// The helper is gone (QEMU returned, it crashed or was killed). Flip to
    /// `.dead`; the window shows a Restart overlay, and the other devices keep running.
    func helperDied(_ reason: String) {
        var parameters = analyticsParameters
        parameters["exit"] = process?.exitStatus
        // a boot that ended before iOS answered (a stop, a quit, a timeout): how far it got
        if reachableSince == nil { parameters["bootStage"] = "\(bootStage)" }
        if !halting, !shuttingDown, !state.isDead {
            // an aborted boot (BootWatch.abort) has its reason already, and its helper stopped as asked
            if let aborted = deathReason {
                let recovery = aborted == BootWatch.recoveryReason(profile)
                Analytics.failure(recovery ? "Device.recoveryMode" : "Device.bootTimedOut", nil, parameters)
            } else if let death = process?.death, death != .stopped {
                if case .startFailed(let error) = death { parameters["errorCode"] = "\((error as NSError).code)" }
                Analytics.failure("Device.helperDied", nil, parameters)
            }
        } else if !state.isDead {
            // how long devices run, and on what
            Analytics.signal("Device.stopped", parameters, value: Date().timeIntervalSince(poweredOn))
        }
        bootWatch.helperDied(reason)
    }

    /// What every device signal carries: its firmware (board, iOS version and build), how it was prepared, its guest
    /// tools and the app in front, nothing of the device's own.
    var analyticsParameters: [String: String] {
        var parameters = ["board": profile.rawValue, "iosVersion": iosVersion, "firmware": instance.firmware]
        if let lock {
            parameters["jailbreak"] = "\(lock.jailbroken)"
            parameters["skipSetup"] = "\(lock.skippedSetup)"
            parameters["recipe"] = lock.recipeVersion.map(String.init)
        }
        parameters["guestTools"] = guestOffer.map { "\($0.serial)" }
        parameters["network"] = "\(network)"
        parameters["frontApp"] = frontBundleID
        return parameters
    }

    func releaseBootResources() {
        fileWatch = nil
        statusTimer?.invalidate()
        statusTimer = nil
        updateVibration(nil)
        audioSink?(.audioEnded(generation: 0, failed: true))
        usbmux.stop()
        removeSockets()
        serialCapture?.finish()
        serialCapture = nil
    }
}
