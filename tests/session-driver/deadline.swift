// A base that never starts iOS (tests/check-boot-deadline.py): booted as the app boots it, with the
// app's serial watch for iBoot's "Entering recovery mode" and the board's boot budget. Emits what the
// app would act on first: the recovery marker (seconds after boot), lockdown answering (the app's
// "iOS is up"), or the deadline. Then a halt, as EmulatorController.abortBoot does (SIGTERM, kill
// after the halt budget).

import Foundation

struct DeadlineConfig: Decodable {
    var board: String   // "ipod" | "ipad"
    var base: String
    /// Seconds to wait for uiReady or the marker (the app: DeviceProfile.bootBudget).
    var budget: Double?
}

@MainActor func runDeadline(_ c: DeadlineConfig) async {
    let ipad = c.board == "ipad"
    let d = Device(name: c.board, profile: ipad ? .iPad1 : .iPodTouch2G)
    let b = URL(fileURLWithPath: c.base)
    if !ipad {
        let gid = b.appendingPathComponent("gid-blobs.bin").path
        d.ipod = .init(nand: b.appendingPathComponent("nand").path, nor: b.appendingPathComponent("nor.bin").path,
                       iBoot: b.appendingPathComponent("iBoot.bin").path, gidBlobs: FileManager.default.fileExists(atPath: gid) ? gid : nil,
                       machine: BootRecipe.lockMachine(b.appendingPathComponent("device.lock.json")))
    }
    let matched = Matched()
    d.serialWatch = (["Entering recovery mode"], { phrase in matched.set(phrase) })
    let budget = c.budget ?? d.profile.bootBudget
    do { try d.boot(generation: 1) } catch { fail("boot: \(error)") }
    let start = Date()
    var outcome = "deadline", lastProbe = Date.distantPast
    while Date().timeIntervalSince(start) < budget {
        if d.process.isDead { outcome = "died"; break }
        if let phrase = matched.get() { outcome = "recovery"; emit("recovery", ["phrase": phrase, "seconds": Date().timeIntervalSince(start)]); break }
        if Date().timeIntervalSince(lastProbe) >= 2 {
            lastProbe = Date()
            if let type = await d.productType() { outcome = "lockdown"; emit("usb", ["device": d.name, "productType": type]); break }
        }
        try? await Task.sleep(for: .milliseconds(250))
    }
    emit("outcome", ["outcome": outcome, "seconds": Date().timeIntervalSince(start), "budget": budget, "deaths": d.deaths])
    let quit = Date()
    d.process.terminate()
    var exited = await d.process.waitForExit(timeout: 10)
    if !exited { d.process.kill(); exited = await d.process.waitForExit(timeout: 5) }
    emit("quit", ["device": d.name, "exited": exited, "seconds": Date().timeIntervalSince(quit), "reason": d.process.deathReason ?? ""])
    d.mux.stop()
    d.serial?.finish()
    emit("done")
    exit(0)
}

final class Matched: @unchecked Sendable {
    private let lock = NSLock()
    private var phrase: String?
    func set(_ value: String) { lock.withLock { phrase = value } }
    func get() -> String? { lock.withLock { phrase } }
}
