// One prepared device (tests/check-sessions.py --single, build-release.py's verify): a firmwarekit base booted
// as the app boots it, through the bundled helper, dylib and usbmuxd. It must light, answer lockdown over its
// own usbmuxd, take AFC round trips past 16 KiB (max-packet multiples, whose transfers end in a real ZLP), take
// an IPA, and shut down cleanly. No restore is involved. Screenshots of each stage land in the work directory.

import Foundation

struct SingleConfig: Decodable {
    var board: String   // "ipod" | "ipad"
    var base: String
    /// AFC upload + download sizes; 16384 and 65536 are 512-byte multiples (a ZLP ends each transfer).
    var afcBytes: [Int]?
}

@MainActor func runSingle(_ s: SingleConfig) async {
    let ipad = s.board == "ipad"
    let d = Device(name: s.board, profile: ipad ? .iPad1 : .iPodTouch2G)
    if !ipad {
        let b = URL(fileURLWithPath: s.base)
        d.ipod = .init(nand: b.appendingPathComponent("nand").path, nor: b.appendingPathComponent("nor.bin").path,
                       iBoot: b.appendingPathComponent("iBoot.bin").path, gidBlobs: b.appendingPathComponent("gid-blobs.bin").path,
                       machine: BootRecipe.lockMachine(b.appendingPathComponent("device.lock.json")))
    }
    do { try d.boot(generation: 1) } catch { fail("boot: \(error)") }
    await waitLit(d, ipad ? 0.2 : 0.03, 240)
    await waitUSB(d, expecting: ipad ? "iPad1,1" : "iPod2,1", 300)
    if !ipad {   // wake: the display may have slept while it booted
        d.process.link.send(.button(0, down: true)); try? await Task.sleep(for: .milliseconds(150))
        d.process.link.send(.button(0, down: false))
    }
    try? await Task.sleep(for: .seconds(3))
    d.screenshot("lock")
    if ipad { await d.drag(0.9365, 0.621, 0.9365, 0.0612) } else { await d.drag(0.18, 0.9, 0.92, 0.9) }
    try? await Task.sleep(for: .seconds(5))
    d.screenshot("home")

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

    await install(d)
    try? await Task.sleep(for: .seconds(3))
    d.screenshot("installed")

    // Clean shutdown, as the app's quit path starts it: iPad powerdown, iPod agent halt.
    let quit = Date()
    if ipad { d.process.link.send(.machine(.powerdown)) }
    else { _ = try? await d.process.link.request(.agent(request: "\(UUID().uuidString) halt \n", deadline: 0), timeout: 5) }
    var confirmed = -1.0
    while Date().timeIntervalSince(quit) < 50 {
        if d.process.status?.shutdownConfirmed == true { confirmed = Date().timeIntervalSince(quit); break }
        try? await Task.sleep(for: .milliseconds(100))
    }
    d.process.terminate()
    let exited = await d.process.waitForExit(timeout: 30)
    emit("quit", ["device": d.name, "confirmed": confirmed, "exited": exited, "reason": d.process.deathReason ?? ""])
    d.mux.stop()
    d.serial?.finish()
    emit("done")
    exit(0)
}
