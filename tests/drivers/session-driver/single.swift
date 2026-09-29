// One prepared device (tests/sessions/check-sessions.py --single, build-release.py's verify, tests/matrix.py): a firmwarekit
// base booted as the app boots it, through the bundled helper, dylib and usbmuxd. It must light, answer lockdown
// over its own usbmuxd, take AFC round trips past 16 KiB (max-packet multiples, whose transfers end in a real ZLP),
// take an IPA, and shut down cleanly. No restore is involved. Screenshots of each stage land in the work directory.
//
// With `itpack` (an iPod) or the config's ipadItpack (an iPad) the boot carries the app's guest-package offer and
// the loader's report is recorded; `reboot` adds a second boot on the same overlay that must light, answer
// lockdown and still hold a file uploaded before the clean shutdown (tests/matrix.py's persist check).

import Foundation

struct SingleConfig: Decodable {
    var board: String   // "ipod" | "ipad"
    var base: String
    /// AFC upload + download sizes; 16384 and 65536 are 512-byte multiples (a ZLP ends each transfer).
    var afcBytes: [Int]?
    /// An iPod's armv6.itpack: the boot carries the app's composed offer (an iPad's comes from ipadItpack).
    var itpack: String?
    /// A second boot on the same overlay after the clean shutdown, with the persist check.
    var reboot: Bool?
    /// smoke.md #5: this many boots, each starting AFC at lockdown's first answer, then the app's Stop.
    var raceBoots: Int?
    var raceDirty: Bool?
    /// The bundled lockdown-tz: set the zone and the Mac's clock once lockdown answers, as the app does on every
    /// connect (EmulatorController.syncTimeZoneWhenReady). The clock is what clears a 2.x iPod's BrickState.
    var lockdownTZ: String?
    /// false: skip the IPA install (the entry has no AppSync, so the stock installd refuses it).
    var install: Bool?
}

@MainActor func runSingle(_ s: SingleConfig) async {
    let ipad = s.board == "ipad"
    let d = Device(name: s.board, profile: ipad ? .iPad1 : .iPodTouch2G)
    let b = URL(fileURLWithPath: s.base)
    if !ipad {
        d.ipod = .init(nand: b.appendingPathComponent("nand").path, nor: b.appendingPathComponent("nor.bin").path,
                       iBoot: BootRecipe.iPodIBoot(base: b), gidBlobs: b.appendingPathComponent("gid-blobs.bin").path,
                       machine: BootRecipe.lockMachine(b.appendingPathComponent("device.lock.json")))
    }
    var offer: String?
    if !ipad, let itpack = s.itpack {
        do { offer = try d.offer(base: b, board: "n72ap", itpack: itpack) } catch { emit("offerError", ["error": "\(error)"]) }
    }
    let offered = offer != nil || (ipad && config.ipadItpack != nil)
    // The lock says whether the bake installed it_agent (3.1+); 2.x and 3.0 have none to halt the guest.
    let lock = (try? JSONSerialization.jsonObject(with: Data(contentsOf: b.appendingPathComponent("device.lock.json")))) as? [String: Any]
    let agent = ((lock?["derived"] as? [String: Any])?["guest_tools"] as? String)?.hasPrefix("installed") ?? true

    func boot(_ generation: Int) async {
        do { try d.boot(generation: generation, guestPackage: offer) } catch { fail("boot \(generation): \(error)") }
        await waitLit(d, ipad ? 0.2 : 0.03, 240)
        await waitUSB(d, expecting: ipad ? "iPad1,1" : "iPod2,1", 300)
        if let tool = s.lockdownTZ {
            var zone: String?
            for _ in 0..<12 where zone == nil {   // services come up after lockdown answers; the app retries every 5 s
                zone = try? await DeviceServices.setTimeZone(TimeZone.current.identifier, tool: tool, socket: d.mux.clientSocket)
                if zone == nil { try? await Task.sleep(for: .seconds(5)) }
            }
            emit("timezone", ["device": d.name, "generation": generation, "zone": zone ?? ""])
        }
        emit("activation", ["device": d.name, "generation": generation, "state": await d.lockdownValue("ActivationState") ?? ""])
        if offered {   // the loader's report: it_boot reports the serial it ran and R_* (GuestPackage.ReportCode)
            let start = Date()
            while d.process.status?.guestPackage == nil, Date().timeIntervalSince(start) < 60 { try? await Task.sleep(for: .seconds(1)) }
            let r = d.process.status?.guestPackage
            emit("guestPackage", ["device": d.name, "generation": generation, "serial": r?.serial ?? -1, "result": r?.result ?? -99])
        }
        if !ipad {   // wake: the display may have slept while it booted
            d.process.link.send(.button(0, down: true)); try? await Task.sleep(for: .milliseconds(150))
            d.process.link.send(.button(0, down: false))
        }
        try? await Task.sleep(for: .seconds(3))
        d.screenshot(generation == 1 ? "lock" : "lock\(generation)")
        if ipad { await d.drag(0.9365, 0.621, 0.9365, 0.0612) } else { await d.drag(0.18, 0.9, 0.92, 0.9) }
        try? await Task.sleep(for: .seconds(5))
        d.screenshot(generation == 1 ? "home" : "home\(generation)")
    }

    /// Clean shutdown, as the app's quit path starts it: iPad powerdown, iPod agent halt.
    func shutdown(_ generation: Int) async {
        let quit = Date()
        if ipad { d.process.link.send(.machine(.powerdown)) }
        else if agent { _ = try? await d.process.link.request(.agent(request: "\(UUID().uuidString) halt \n", deadline: 0), timeout: 5) }
        else {   // no guest agent (2.x, 3.0): the machine's own hold-power-and-slide sequence
            d.process.link.send(.machine(.powerdown))
        }
        var confirmed = -1.0
        while Date().timeIntervalSince(quit) < 50 {
            if d.process.status?.shutdownConfirmed == true { confirmed = Date().timeIntervalSince(quit); break }
            try? await Task.sleep(for: .milliseconds(100))
        }
        d.process.terminate()
        let exited = await d.process.waitForExit(timeout: 30)
        emit("quit", ["device": d.name, "generation": generation, "confirmed": confirmed, "exited": exited, "reason": d.process.deathReason ?? ""])
        d.mux.stop()
    }

    // smoke.md #5: AFC (the app's listing: StartService, connect, stat of each entry) at lockdown's first
    // answer, polled at 100 ms from power-on; then the app's Stop. raceDirty first installs, uploads a file and
    // starts the agent halt, stopping 20-45 s into the shutdown (the sequence that preceded the one code 1).
    if let n = s.raceBoots {
        for g in 1...n {
            do { try d.boot(generation: g, guestPackage: offer) } catch { fail("boot \(g): \(error)") }
            let start = Date()
            while await d.productType() == nil {
                if d.process.isDead || Date().timeIntervalSince(start) > 300 { fail("boot \(g): lockdown never answered") }
                try? await Task.sleep(for: .milliseconds(100))
            }
            let answered = Date()
            var race: [String: Any] = ["device": d.name, "generation": g, "lockdown": answered.timeIntervalSince(start)]
            do { race["entries"] = try await d.services.files(in: "").count } catch { race["error"] = "\(error)" }
            race["seconds"] = Date().timeIntervalSince(answered)
            emit("race", race)
            if s.raceDirty == true {
                await install(d)
                let local = d.dir.appendingPathComponent("race-\(g).bin")
                try? Data(count: 65_536).write(to: local)
                var stop: [String: Any] = ["device": d.name, "generation": g]
                do { try await d.services.uploadFile(local, into: "") { _ in } } catch { stop["uploadError"] = "\(error)" }
                _ = try? await d.process.link.request(.agent(request: "\(UUID().uuidString) halt \n", deadline: 0), timeout: 5)
                let wait = [20.0, 25, 30, 35, 40, 45][g % 6]
                try? await Task.sleep(for: .seconds(wait))
                stop["afterHalt"] = wait
                stop["confirmed"] = d.process.status?.shutdownConfirmed == true
                emit("raceStop", stop)
            }
            d.process.terminate()
            _ = await d.process.waitForExit(timeout: 30)
            d.mux.stop()
            d.serial?.removeEndpoints()
        }
        d.serial?.finish()
        emit("done")
        exit(0)
    }

    await boot(1)

    for size in s.afcBytes ?? [16384, 16385, 65536, 1_048_583] {
        let name = "ltm-verify-\(size).bin"
        let local = d.dir.appendingPathComponent(name), back = d.dir.appendingPathComponent("back-" + name)
        var bytes = [UInt8](repeating: 0, count: size)
        for i in bytes.indices { bytes[i] = UInt8(truncatingIfNeeded: i &* 2654435761 >> 13) }
        let start = Date()
        do {
            try Data(bytes).write(to: local)
            try await d.services.uploadFile(local, into: "") { _ in }
            guard let file = try await d.services.files(in: "").first(where: { $0.name == name }) else { throw DeviceError.preflight("\(name) not listed") }
            try await d.services.download(file, to: back) { _ in }
            let same = try Data(contentsOf: back) == Data(bytes)
            await d.services.removeStaged(name)
            emit("afc", ["device": d.name, "bytes": size, "listed": Int(file.size), "same": same, "seconds": Date().timeIntervalSince(start)])
        } catch {
            emit("afc", ["device": d.name, "bytes": size, "same": false, "error": "\(error)"])
        }
        try? FileManager.default.removeItem(at: local); try? FileManager.default.removeItem(at: back)
    }

    if s.install != false { await install(d) }
    try? await Task.sleep(for: .seconds(3))
    d.screenshot("installed")

    // The persist marker: a file that must still be there after the clean shutdown and the second boot.
    let marker = "ltm-matrix-persist.bin"
    let markerBytes = Data((0..<65_536).map { UInt8(truncatingIfNeeded: $0 &* 2654435761 >> 11) })
    if s.reboot == true {
        let local = d.dir.appendingPathComponent(marker)
        do {
            try markerBytes.write(to: local)
            try await d.services.uploadFile(local, into: "") { _ in }
        } catch { emit("persist", ["device": d.name, "kept": false, "same": false, "error": "upload: \(error)"]) }
    }

    await shutdown(1)

    if s.reboot == true {
        d.serial?.removeEndpoints()
        await boot(2)
        let back = d.dir.appendingPathComponent("back-" + marker)
        do {
            guard let file = try await d.services.files(in: "").first(where: { $0.name == marker }) else { throw DeviceError.preflight("\(marker) not listed") }
            try await d.services.download(file, to: back) { _ in }
            let same = try Data(contentsOf: back) == markerBytes
            await d.services.removeStaged(marker)
            emit("persist", ["device": d.name, "kept": true, "same": same])
        } catch {
            emit("persist", ["device": d.name, "kept": false, "same": false, "error": "\(error)"])
        }
        let apps = (try? await d.services.installedApps())?.map(\.id) ?? []
        emit("restartedApps", ["device": d.name, "has": apps.contains(config.bundleID)])
        await shutdown(2)
    }
    d.serial?.finish()
    emit("done")
    exit(0)
}
