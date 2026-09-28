// The guest-services scenario (tests/check-sessions.py --guest): iPods with no
// SSH, through the app's own GuestServices/GuestAgent (typed agent ops, v1
// exec fallback), DeviceServices (installs, AFC staging), GuestServices'
// lockdown-tz child process, and GuestPackage (the boot's offer, the report,
// verdicts, a rollback). Each device: boot with an offer, capabilities, the
// loader's report and verdict, the component upgrade, an install, a launch,
// a respring, the time zone, a photo import, and a clean halt.

import Foundation

struct GuestDeviceConfig: Decodable {
    var name: String
    var nand: String
    var nor: String
    var iBoot: String
    var gidBlobs: String?
    /// A prepared device's device.lock.json (its guest_package record).
    var lock: String?
    /// Judge the package bad and restart: the loader must go back to the seed.
    var rollback: Bool?
}

struct GuestConfig: Decodable {
    var devices: [GuestDeviceConfig]
    var itpack: String
    var lockdownTZ: String
    /// The app's guest binaries by name: itphoto, and the components a legacy
    /// image is upgraded to (it_agent, it_typein.dylib, MBXGLEngine).
    var tools: [String: String]
    var timeZone: String
}

@MainActor final class GuestRun {
    let device: Device
    let spec: GuestDeviceConfig
    let guest: GuestConfig
    var record = DeviceInstance.Guest()
    let cache = GuestAgentCache()
    init(_ spec: GuestDeviceConfig, _ guest: GuestConfig) {
        self.spec = spec
        self.guest = guest
        device = Device(name: spec.name, profile: .iPodTouch2G)
        device.ipod = .init(nand: spec.nand, nor: spec.nor, iBoot: spec.iBoot, gidBlobs: spec.gidBlobs,
                            machine: spec.lock.map { BootRecipe.lockMachine(URL(fileURLWithPath: $0)) } ?? [:])
    }
    var name: String { spec.name }
    var agent: GuestAgent { GuestAgent(link: device.process.link, cache: cache) }
    var status: SharedStatus? { device.process.status }
    var lock: GuestPackage.LockRecord? { spec.lock.flatMap { GuestPackage.lockRecord(URL(fileURLWithPath: $0)) } }
    var services: GuestServices { GuestServices(agent: agent, packaged: status?.guestPackage != nil) }

    func step<T>(_ what: String, _ body: () async throws -> T) async -> T {
        do { return try await body() } catch { fail("\(name) \(what): \(error)") }
    }

    /// EmulatorController.composeGuestOffer, with the driver's record.
    func composeOffer() -> String? {
        let dir = device.dir.appendingPathComponent("work/guest-offer")
        try? FileManager.default.createDirectory(at: dir.deletingLastPathComponent(), withIntermediateDirectories: true)
        if record.seed == nil { record.seed = lock?.seed }
        do {
            let offer = try GuestPackage.compose(itpack: URL(fileURLWithPath: guest.itpack), board: "n72ap", build: "7E18",
                                                 lock: lock, guest: record, into: dir)
            emit("offer", ["device": name, "serial": offer?.serial ?? -1, "bundled": offer?.bundled ?? -1,
                           "text": (try? String(contentsOf: dir.appendingPathComponent("offer"), encoding: .utf8)) ?? ""])
            return offer == nil ? nil : dir.path
        } catch { fail("\(name) offer: \(error)") }
    }

    /// Until the agent claims its channel (a new boot, or an upgraded agent).
    func waitAgent(_ seconds: Double) async {
        guard await agent.waitAlive(seconds: seconds) else { device.screenshot("\(name)-no-agent"); fail("\(name): the agent never came up") }
    }

    /// EmulatorController.startGuestPackageWatch's loop: the report, then a verdict.
    func judge(budget: Duration) async -> (GuestPackageReport?, GuestPackage.Verdict) {
        let started = ContinuousClock.now
        var healthySince: ContinuousClock.Instant?
        while true {
            try? await Task.sleep(for: .seconds(1))
            guard let status else { fail("\(name): no status") }
            let report = status.guestPackage
            if let report { record.active = report.serial }
            let healthy = status.uiReady && status.agentStatus == 1
            if healthy { healthySince = healthySince ?? .now } else { healthySince = nil }
            let steady = healthySince.map { ContinuousClock.now - $0 } ?? .zero
            let elapsed = ContinuousClock.now - started
            if let verdict = GuestPackage.verdict(report: report, healthyFor: steady, elapsed: elapsed, record: record, restored: false) {
                switch verdict {
                case .good(let s): record.lastGood = s; record.bad.removeAll { $0 == s }
                case .bad(let s): record.bad.append(s)
                default: break
                }
                return (report, verdict)
            }
            if elapsed > budget { return (report, .undecided) }
        }
    }

    func emitVerdict(_ label: String, _ result: (GuestPackageReport?, GuestPackage.Verdict)) {
        emit("verdict", ["device": name, "label": label, "serial": result.0?.serial ?? -1, "result": result.0.map { Int($0.result) } ?? -99,
                         "verdict": "\(result.1)", "lastGood": record.lastGood ?? -1, "bad": record.bad])
    }

    /// SpringBoard's pid in launchctl's job table (stock /bin/launchctl, spawned).
    func springBoardPID() async -> Int? {
        let table = String(decoding: (try? await agent.spawn(["/bin/launchctl", "list"])) ?? Data(), as: UTF8.self)
        return table.split(separator: "\n").first { $0.hasSuffix("com.apple.SpringBoard") }
            .flatMap { Int($0.split(separator: "\t").first ?? "") }
    }

    func waitFrontmost(_ bundleID: String?, _ seconds: Double) async -> String? {
        let deadline = Date().addingTimeInterval(seconds)
        var last: String?
        while Date() < deadline {
            if let front = try? await agent.frontmost() {
                last = front.bundleID
                if bundleID == nil || front.bundleID == bundleID { return front.bundleID }
            }
            try? await Task.sleep(for: .seconds(1))
        }
        return bundleID == nil ? nil : last
    }

    func unlock() async {
        device.process.link.send(.button(0, down: true)); try? await Task.sleep(for: .milliseconds(150))
        device.process.link.send(.button(0, down: false))
        try? await Task.sleep(for: .seconds(3))
        for _ in 0..<3 {
            if (try? await agent.isLocked()) == false { break }
            await device.drag(0.18, 0.9, 0.92, 0.9)
            try? await Task.sleep(for: .seconds(3))
        }
        emit("unlocked", ["device": name, "locked": (try? await agent.isLocked()) ?? true])
    }

    func run() async {
        do { try device.boot(generation: 1, guestPackage: composeOffer()) } catch { fail("\(name) boot: \(error)") }
        await waitLit(device, 0.03, 240)
        emit("supported", ["device": name, "guestPackage": status?.guestPackageSupported ?? false])
        await waitUSB(device, expecting: "iPod2,1", 240)
        await waitAgent(120)
        let caps = await step("ping") { try await agent.capabilities() }
        emit("capabilities", ["device": name, "version": caps.version, "ops": caps.ops.sorted()])

        // P5: the loader's report and this boot's verdict (legacy when there is no loader).
        emitVerdict("boot", await judge(budget: .seconds(90)))

        // P2: the component upgrade (a legacy image's agent may go v1 -> v2), no SSH.
        let tool = { (name: String) in URL(fileURLWithPath: self.guest.tools[name] ?? "/nonexistent/\(name)") }
        let parts = GuestServices.Components(engine: tool("MBXGLEngine"), agent: tool("it_agent"), typing: tool("it_typein.dylib"))
        let changed = await step("update components") { try await services.updateComponents(parts) }
        cache.reset()
        await waitAgent(60)
        let after = await step("ping after update") { try await agent.capabilities() }
        _ = await waitFrontmost(nil, 45)   // SpringBoard answers again after a reload
        emit("components", ["device": name, "changed": changed, "version": after.version, "packaged": services.packaged])

        await unlock()
        device.screenshot("\(name)-home")

        // Install (stock installation_proxy through the gate), then launch it through the agent.
        await install(device)
        _ = await step("launch") { try await services.launch(config.bundleID) }
        let front = await waitFrontmost(config.bundleID, 30)
        device.screenshot("\(name)-launched")
        emit("launched", ["device": name, "frontmost": front ?? ""])

        // Respring: launchd restarts SpringBoard; a new pid, and it answers again.
        let before = await springBoardPID()
        await step("respring") { try await services.respring() }
        var respun: Int?
        for _ in 0..<45 {
            try? await Task.sleep(for: .seconds(1))
            if let pid = await springBoardPID(), pid != before, (try? await agent.frontmost()) != nil { respun = pid; break }
        }
        emit("respring", ["device": name, "before": before ?? -1, "after": respun ?? -1])

        // Time zone through the lockdown-tz child process (never an in-process lockdown write).
        let zone = await step("time zone") {
            try await GuestServices.setTimeZone(guest.timeZone, tool: guest.lockdownTZ, socket: device.mux.clientSocket)
        }
        emit("timezone", ["device": name, "zone": zone])

        // Media: a photo (the lock screenshot) staged over AFC, committed with itphoto.
        let shot = device.dir.appendingPathComponent("\(name)-home.png")
        let photo = await step("photo prepare") { try await MediaPhoto.prepare(shot) }
        await step("photo stage") { try await device.services.stagePhoto(photo) { _ in } }
        let imported = await step("photo commit") {
            try await services.commitMedia(id: photo.id, helper: "itphoto",
                                           localHelper: { tool("itphoto") }, metadata: nil)
        }
        let receipt = (try? await agent.get("/var/mobile/Media/LightTouch/\(photo.id)/.photo-receipt")) ?? nil
        emit("media", ["device": name, "imported": imported, "receipt": receipt.map { String(decoding: $0, as: UTF8.self) } ?? ""])
        try? FileManager.default.removeItem(at: photo.directory)

        // P5 rollback: judge the running package bad, then restart as the app does
        // (EmulatorController.restart(with: .previous)): a clean halt, a fresh
        // helper on the same overlay, whose boot carries the new offer.
        // (The seed is the loader's floor: nothing to roll back to when it is running.)
        if spec.rollback == true, let active = status?.guestPackage?.serial, active != record.seed {
            record.bad.append(active)
            if record.lastGood == active { record.lastGood = nil }
            await halt()
            device.mux.stop()
            device.serial?.removeEndpoints()
            do { try device.boot(generation: 2, guestPackage: composeOffer()) } catch { fail("\(name) restart: \(error)") }
            await waitLit(device, 0.03, 240)
            await waitAgent(180)
            emitVerdict("rollback", await judge(budget: .seconds(90)))
        }

        await halt()
        device.mux.stop()
        device.serial?.finish()
    }

    /// Clean halt: the agent's reboot2, confirmed by the PMU, then SIGTERM (the helper quits).
    func halt() async {
        let halt = Date()
        let submitted = await agent.requestHalt()
        while Date().timeIntervalSince(halt) < 40, status?.shutdownConfirmed != true { try? await Task.sleep(for: .milliseconds(100)) }
        let confirmed = status?.shutdownConfirmed == true ? Date().timeIntervalSince(halt) : -1
        device.process.terminate()
        let exited = await device.process.waitForExit(timeout: 30)
        emit("halted", ["device": name, "submitted": submitted, "confirmed": confirmed, "exited": exited,
                        "reason": device.process.deathReason ?? ""])
    }
}

@MainActor func runGuest(_ guest: GuestConfig) async {
    let runs = guest.devices.map { GuestRun($0, guest) }
    await withTaskGroup(of: Void.self) { group in
        for run in runs { group.addTask { await run.run() } }
    }
    emit("done")
    exit(0)
}
