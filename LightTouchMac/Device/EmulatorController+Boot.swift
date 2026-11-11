import Cocoa
import DeviceRuntime
import FirmwareSchema
import HostRuntime
import HostServiceClient
import HostServiceWire
import LightTouchCore
import Observation

extension EmulatorController {
    // MARK: - Boot

    func start() {
        guard !started else { return }
        let paths = instance.paths
        do {
            try Bundled.requireStorage()
            guard instance.format <= DeviceInstance.currentFormat else { throw DeviceInstance.NewerFormat() }
            try instance.checkBootPaths()
        } catch {
            logEvent("storage: \(error.localizedDescription)")
            failBoot(error)
            return
        }
        started = true
        transition(to: .booting)
        notices.helperStarted()  // the last boot's notices end; a fresh helper opens the files as they are now
        let process = DeviceProcess(
            instance: instance.id,
            profile: profile,
            log: instance.paths.logs.appendingPathComponent("native.log"),
            lease: instance.paths.lease
        )
        self.process = process
        lastFrameSerial = 0
        process.onDeath = { [weak self, weak process] reason in
            Task.detached { PreparedDeviceBoot.syncStorage(overlay: paths.overlay, writableNOR: paths.writableNOR) }
            guard let self, let process, self.process === process else { return }
            helperDied(reason)
        }
        process.onAudio = { [weak self] event in self?.audioSink?(event) }
        process.onGuestPasteboard = { [weak self] text in
            guard let self else { return }
            ClipboardSharing.shared.guestCopied(text, on: self)
        }
        // An empty report is the end of an agent's session (the guest reset, the agent restarted): the next agent
        // may be another version, whatever the status poll's once-a-second sample caught of the change.
        process.onAgentReport = { [weak self] text in
            guard let self, text.isEmpty else { return }
            agentCache.reset()
            agentSessionEnded = Date()
        }
        startStatusPoll()
        // Low space doesn't stop a boot; it's said before writes start failing.
        warnIfLowOnSpace()
        // The boot is built after the hello: usbmuxd must listen before the guest's USB.
        readiness.setStatus("Preparing device…")
        process.start(
            { [weak self] info in self?.bootConfiguration(hardware: info.deviceInfo) },
            preparation: { [weak self] in
                guard let self, !self.releasing, !self.stopped else { throw CancellationError() }
                guard let executable = FirmwareJobs.preparer else {
                    throw DeviceToolsError.failed("The firmware worker is unavailable.")
                }
                // The boot configuration (on main, after the helper's hello) reads the unpacked guest tools: their
                // first read hashes guest.aar, so it happens here, off the main thread.
                await Self.unpackGuestTools()
                // 1.x has no agent to trust the web proxy's CA: once it exists, the stopped device takes it as an anchor.
                let ca = URL(fileURLWithPath: WebProxyConfiguration.file(in: self.proxyDirectory).path + ".ca.der")
                if self.trustsStopped, FileManager.default.fileExists(atPath: ca.path) {
                    self.readiness.setStatus("Trusting the proxy certificate…")
                    if try await FirmwareTool.trustAnchor(
                        device: self.instance.paths.directory,
                        certificate: ca,
                        executable: executable
                    ) {
                        logEvent("proxy: certificate written into the stopped device's trust store")
                    }
                    try Task.checkCancellation()
                }
                // 1.x has no agent to write the tweaks' keys either: the stopped device takes them.
                let device = self.instance.paths.directory
                await self.tweaks.writeStopped {
                    try await FirmwareTool.writePreferences(device: device, changes: $0, executable: executable)
                }
                try Task.checkCancellation()
                let admitted = try await FirmwareTool.admitStart(
                    self.instance,
                    executable: executable,
                    log: self.instance.paths.logs.appendingPathComponent("firmwarekit.log")
                )
                // a storage update that couldn't run (no room, or it failed): the device starts as before
                if let notice = admitted.report.notice { self.reportDeviceNotice(notice, for: .storageUpdate) }
                self.instance = admitted.instance
                self.admittedStorage = admitted.proof
                self.onStorageGenerationChanged?()
            },
            completion: { [weak self] result in
                if case .failure(let error) = result, let self { logEvent("boot: \(instance.name): \(error)") }
            }
        )
        // The boot begins, with its watches, in bootConfiguration(), once it is built and its offer composed.
    }

    /// nil when the device can't boot; the notice says why and the state is dead.
    /// `hardware`: the helper's hello's DeviceInfo, the emulator's facts about this board.
    private func bootConfiguration(hardware: DeviceInfo?) -> BootConfig? {
        guard !isDead, !releasing else { return nil }
        link?.send(.screenVisible(screenVisible))
        proxy.forgetEndpoint()
        var config = preparedBootConfiguration(hardware: hardware)
        config?.webProxy = proxy.endpoint
        config?.storageProof = admittedStorage
        if let socket = options.chooseDebugSocket(booting: config != nil) {
            config?.argv += DebugPort.arguments(socket: socket)
            logEvent("debug port: QEMU gdbstub at \(socket)")
        }
        if config != nil {
            bootSettings = nextBootSettings
            // Stopped migration time is separate from the guest boot budget.
            cycle.begin()
            logEmulatorBuild()
        }
        return config
    }

    /// Storage preparation and argv assembly are shared with headless callers.
    /// DeviceProcess already holds the storage lease when this hello callback runs.
    /// The UDID the guest reports: the record's, or for an iPhone base prepared before its identity carried an IMEI
    /// (n90/n88 recipe 1) the one its seed-derived IMEI makes; DeviceLock.machineOptions passes that IMEI to the modem.
    var guestUDID: String? {
        if profile.kbootPhone,
            let data = try? Data(contentsOf: instance.paths.base.appendingPathComponent("identity.json")),
            let identity = try? JSONSerialization.jsonObject(with: data) as? [String: Any], identity["imei"] == nil,
            let upgraded = IPhoneIdentity.upgraded(identity)
        {
            return upgraded.udid
        }
        return instance.identity?.udid
    }

    private func preparedBootConfiguration(hardware: DeviceInfo?) -> BootConfig? {
        let prepared: PreparedDeviceBoot
        let machine: DeviceInfo
        do {
            guard let hardware else {
                throw DeviceToolsError.failed("The emulator library has no machine for this \(profile.shortName).")
            }
            machine = hardware
            prepared = try instance.preparedBoot(
                board: profile,
                bootrom: BootRecipe.bootrom(profile.bootrom, filesRoot: Bundled.filesRoot),
                clock: tweaks.bootClock
            )
        } catch PreparedDeviceBoot.Failure.baseMismatch {
            baseImageMismatch = true
            reportDeviceNotice("This \(profile.shortName)’s data was made with an older system image.", for: .erase)
            endBoot(.unbuildable)
            return nil
        } catch {
            failBoot(error)
            return nil
        }
        // Keep the bridge listening before the guest USB starts.
        let usbSession = usbmux.start(paths: instance.paths)
        openSerialLog()
        let netdev: String?
        readSetupExpectation()
        foreground.liftsRestrict = false
        if profile.isKBoot {
            let restrict = network && expectsSetup
            netdev =
                network
                ? proxy.forward().map {
                    BootRecipe.wifiNetdev(guestForward: $0, restricted: restrict, localNetwork: localNetworkEnabled)
                } : nil
            foreground.liftsRestrict = netdev != nil && restrict
        } else {
            netdev =
                network
                ? BootRecipe.wifiNetdev(
                    guestForward: proxy.forward() ?? "",
                    restricted: false,
                    localNetwork: localNetworkEnabled
                ) : nil
        }
        do {
            return try prepared.configuration(
                hardware: machine,
                bootArgs: DeviceOptions.bootArgs(),
                usbAddress: usbSession?.guestAddress,
                wifi: network,
                guestPackage: guestPackage.compose(),
                serial: serialCapture?.argument ?? "null",
                // Every board: 16 CoreAudio buffers (186 ms) ride out a busy emulator thread. The A4 boards
                // had QEMU's default 4 (46 ms), and the iPod touch 4's sounds crackled on a slower Mac.
                audio: ["-audio", "driver=coreaudio,out.buffer-count=16"],
                netdev: netdev,
                carrier: profile.hasCellular ? carrierSettings : nil,
                refreshHz: DisplayRefresh.hz,
                angle: ANGLERenderer.isOn
            )
        } catch {
            failBoot(error)
            return nil
        }
    }

    /// What the next fresh helper's boot would be built with (BootSettings): the record's panel, the saved
    /// Internet choice (this device's when none is saved), the debug port and the boot arguments.
    var nextBootSettings: BootSettings {
        BootSettings(
            panel: instance.panel,
            network: NetworkAccessPreference.decided() ?? network,
            debugPort: debugPortEnabled,
            bootArgs: DeviceOptions.bootArgs()
        )
    }
    var nextStartChanged: Bool { bootSettings.map { $0 != nextBootSettings } ?? false }

    /// Whether this boot ends in Setup: iOS 5 or later, prepared without Skip Setup, on an overlay that hasn't finished
    /// it (its mark), read at every boot, so a Restart after Setup waits for the Home screen. Setup's end is watched on
    /// every boot that shows it (the mark, the readiness text), networked or not.
    func readSetupExpectation() {
        let setupDone = FileManager.default.fileExists(atPath: BootRecipe.setupDoneMark(overlay: overlayURL).path)
        expectsSetup = BootRecipe.setupPhonesHome(iosVersion: iosVersion) && !setupDone && lock?.skippedSetup != true
        foreground.setupGate = expectsSetup ? BootRecipe.SetupNetworkGate() : nil
    }

    private func openSerialLog() {
        guestFaultsSeen = []
        poweredOn = Date()
        crashesLogged = []
        do {
            serialCapture = try SerialLogCapture(
                url: instance.paths.logs.appendingPathComponent("serial.log"),
                watch: [BootWatch.recoveryMarker] + BootStage.serialMarkers.keys + GuestFaults.watched
            ) { [weak self] phrase in
                Task { @MainActor in
                    guard let self else { return }
                    switch phrase {
                    case BootWatch.recoveryMarker:
                        if DeviceErase.guestAsked(nor: self.eraseTargets.preparedNOR) {
                            return self.requestFactoryReset()
                        }
                        self.inRecovery = true
                        self.abortBoot(BootWatch.recoveryReason(self.profile))
                    case _ where GuestFaults.watched.contains(phrase):
                        self.guestFaultsSeen.insert(phrase)
                        if let meaning = GuestFaults.phrases[phrase] {
                            logEvent("guest: \(self.instance.name): error: \(meaning) (Device Console: “\(phrase)”)")
                        }
                    default: self.noteBoot(.serial(phrase))
                    }
                }
            }
        } catch { logEvent("logging: serial capture unavailable: \(error.localizedDescription)") }
    }

    /// iOS answered: by now launchd has mounted every volume it is going to.
    func checkGuestMounts() {
        if let fault = GuestFaults.dataVolumeFault(seen: guestFaultsSeen, dataVolume: lock?.hasDataVolume == true) {
            logEvent("guest: \(instance.name): error: \(fault)")
        }
    }

    /// The guest's crash reports, read once iOS answers and every minute after, in the services worker: each process
    /// that crashed during this boot is logged once as an error. Launchd's job lines reach the serial log on two
    /// boards only (1.x's), so this is where a crash-looping daemon shows on the rest (GuestFaults.listsCrashReports).
    func watchCrashReports() {
        guard GuestFaults.listsCrashReports(version: iosVersion) else { return }
        bootScope[.crashReports] = Task { [weak self] in
            while !Task.isCancelled {
                await self?.logNewCrashes()
                try? await Task.sleep(for: .seconds(60))
            }
        }
    }

    private func logNewCrashes() async {
        guard let services = try? services, let ages = try? await services.crashReports() else { return }
        let uptime = Date().timeIntervalSince(poweredOn)
        for process in GuestFaults.crashedProcesses(ages: ages, uptime: uptime)
        where crashesLogged.insert(process).inserted {
            logEvent("guest: \(instance.name): error: \(process) crashed (the device wrote a crash report for it)")
        }
    }

    // MARK: - Files under a running device

    func startFileWatch() {
        guard fileWatch == nil, !filesMeddled else { return }
        let paths = instance.paths
        // Guest-owned files only; the app's own writes under Devices/<uuid> must not fire this.
        let nor = [paths.writableNOR].compactMap { $0 }.filter { !$0.path.hasPrefix(paths.overlay.path + "/") }
        // An image store's live NAND (overlay/nand) holds the chip files QEMU has open.
        let directories = [paths.overlay, PreparedDeviceBoot.liveNAND(overlay: paths.overlay)]
        fileWatch = DeviceFileWatch(directories: directories, files: nor, base: paths.base) { [weak self] path in
            Task { @MainActor in self?.filesChanged(path) }
        }
    }

    private func filesChanged(_ path: String) {
        guard !filesMeddled, !isDead, !isPoweredOff else { return }
        filesMeddled = true
        fileWatch = nil
        logEvent("files: \(path) changed under the running device; Stop will quit without a flush")
        reportDeviceNotice(DeviceFileWatch.notice(shortName: profile.shortName), for: .files)
    }
}
