// One prepared base, booted as the app boots it, asked the question the app asks on the first
// lockdown answer (tests/check-activation-gate.py): lockdown's ActivationState, mapped through
// DeviceConnectionIssue.activation, and whether a service refusal (-34) maps to the same issue.
// Also what the lock says (DeviceInstance.lockLacksActivation): the sidebar's note.

import Foundation

struct ActivationConfig: Decodable {
    var board: String   // "ipod" | "ipad"
    var base: String
}

@MainActor func runActivation(_ a: ActivationConfig) async {
    let ipad = a.board == "ipad"
    let d = Device(name: a.board, profile: ipad ? .iPad1 : .iPodTouch2G)
    let b = URL(fileURLWithPath: a.base)
    if !ipad {
        d.ipod = .init(nand: b.appendingPathComponent("nand").path, nor: b.appendingPathComponent("nor.bin").path,
                       iBoot: b.appendingPathComponent("iBoot.bin").path, gidBlobs: FileManager.default.fileExists(atPath: b.appendingPathComponent("gid-blobs.bin").path) ? b.appendingPathComponent("gid-blobs.bin").path : nil,
                       machine: BootRecipe.lockMachine(b.appendingPathComponent("device.lock.json")))
    }
    emit("lock", ["lacksActivation": DeviceInstance.lockLacksActivation(b.appendingPathComponent("device.lock.json"))])
    do { try d.boot(generation: 1) } catch { fail("boot: \(error)") }
    await waitLit(d, ipad ? 0.2 : 0.03, 240)
    await waitUSB(d, expecting: ipad ? "iPad1,1" : "iPod2,1", 300)
    d.screenshot("first-answer")
    let state = await d.services.activationState()
    let issue = DeviceConnectionIssue.activation(state: state, profile: d.profile)
    emit("activation", ["state": state ?? "", "summary": issue?.summary ?? "", "persistent": issue?.persistent ?? false,
                        "blocks": issue?.blocksCommands ?? false, "retries": issue?.reconnectManagement ?? false])
    // The same question the inspector's first list read asks; -34 lands on the same issue.
    var serviceIssue: DeviceConnectionIssue?, serviceError = ""
    do { _ = try await d.services.installedApps() } catch {
        serviceError = "\(error)"
        serviceIssue = DeviceConnectionIssue(error: error, operation: "Refreshing apps", profile: d.profile)
    }
    emit("service", ["error": serviceError, "summary": serviceIssue?.summary ?? "", "persistent": serviceIssue?.persistent ?? false])
    let quit = Date()
    d.process.terminate()
    let exited = await d.process.waitForExit(timeout: 30)
    emit("quit", ["device": d.name, "exited": exited, "seconds": Date().timeIntervalSince(quit), "reason": d.process.deathReason ?? ""])
    d.mux.stop()
    d.serial?.finish()
    emit("done")
    exit(0)
}
