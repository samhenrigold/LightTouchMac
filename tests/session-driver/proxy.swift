// The web proxy's certificate, trusted the way the app does it (tests/check-proxy-trust.py): one prepared
// base (or the shipping iPod image) booted with itwebproxy on the wifi guestfwd, the CA from `--init-ca`
// trusted through the guest agent (GuestServices.trustCertificate: the package's ittrust or the app's copy
// out of the armv6 itpack), never the MCInstall profile screen. Proof: httpget (the guest's own CFNetwork
// over the proxy) fails before the trust and answers HTTP 200 after; Safari opens the HTTPS page
// (screenshot); a reboot on the same overlay, unlocked, shows the home screen and no profile screen after
// the trust runs again.

import Foundation

struct ProxyConfig: Decodable {
    var board: String   // "ipod" | "ipad"
    /// A firmwarekit base; empty for an iPod: the shipping image (config.ipodNAND).
    var base: String
    var itwebproxy: String
    /// The app's armv6.itpack: ittrust for a guest whose package lacks it (DeviceTools.bundledGuestTool).
    var itpack: String
    /// contrib/it-proxy/httpget, built for armv6; optional.
    var httpget: String?
    var url: String
}

@MainActor func runProxy(_ p: ProxyConfig) async {
    let ipad = p.board == "ipad"
    let d = Device(name: p.board, profile: ipad ? .iPad1 : .iPodTouch2G)
    if !ipad, !p.base.isEmpty {
        let b = URL(fileURLWithPath: p.base)
        d.ipod = .init(nand: b.appendingPathComponent("nand").path, nor: b.appendingPathComponent("nor.bin").path,
                       iBoot: b.appendingPathComponent("iBoot.bin").path, gidBlobs: b.appendingPathComponent("gid-blobs.bin").path,
                       machine: BootRecipe.lockMachine(b.appendingPathComponent("device.lock.json")))
    }
    // The proxy's files, as WebProxyConfiguration keeps them per device: routing (direct) and the CA.
    let proxyDir = work.appendingPathComponent("\(p.board)/proxy")
    var routing = WebProxyConfiguration(); routing.mode = .direct
    do { try routing.save(in: proxyDir) } catch { fail("routing: \(error)") }
    let conf = WebProxyConfiguration.file(in: proxyDir).path
    let initCA = Process()
    initCA.executableURL = URL(fileURLWithPath: p.itwebproxy)
    initCA.arguments = ["--init-ca", conf]
    do { try initCA.run() } catch { fail("itwebproxy: \(error)") }
    initCA.waitUntilExit()
    guard initCA.terminationStatus == 0, let der = try? Data(contentsOf: URL(fileURLWithPath: conf + ".ca.der")) else { fail("--init-ca failed") }
    d.netdevExtra = WebProxyConfiguration.guestForward(helper: p.itwebproxy, directory: proxyDir)
    let cache = GuestAgentCache()
    var agent: GuestAgent { GuestAgent(link: d.process.link, cache: cache) }
    func localTool() throws -> Data {
        guard let tool = try GuestPackage.package(in: URL(fileURLWithPath: p.itpack), board: "n72ap", build: "7E18")?.1["bin/ittrust"] else {
            throw DeviceToolsError.toolMissing("ittrust")
        }
        return tool
    }

    func boot(_ generation: Int) async {
        do { try d.boot(generation: generation) } catch { fail("boot \(generation): \(error)") }
        await waitLit(d, ipad ? 0.2 : 0.03, 240)
        await waitUSB(d, expecting: ipad ? "iPad1,1" : "iPod2,1", 300)
        let alive = await agent.waitAlive(seconds: 90)
        let packaged = d.process.status?.guestPackage != nil
        emit("agent", ["device": d.name, "generation": generation, "alive": alive, "packaged": packaged,
                       "state": await d.lockdownValue("ActivationState") ?? ""])
        if !ipad {   // wake: the display may have slept while it booted
            d.process.link.send(.button(0, down: true)); try? await Task.sleep(for: .milliseconds(150))
            d.process.link.send(.button(0, down: false))
        }
        try? await Task.sleep(for: .seconds(3))
        d.screenshot("lock\(generation)")
        if ipad { await d.drag(0.9365, 0.621, 0.9365, 0.0612) } else { await d.drag(0.18, 0.9, 0.92, 0.9) }
        try? await Task.sleep(for: .seconds(5))
        d.screenshot("home\(generation)")
    }

    /// The guest's own HTTPS client through the proxy: "HTTP 200" once the CA is trusted, a certificate
    /// error (-1202) before. Wi-Fi associates a while after lockdown answers: "offline" (-1009) is retried.
    func fetch(_ label: String, url: String? = nil) async {
        guard let httpget = p.httpget, let bytes = try? Data(contentsOf: URL(fileURLWithPath: httpget)) else { return }
        let url = url ?? p.url
        let remote = "/tmp/ltm-httpget"
        var status = -1, text = ""
        for attempt in 0..<8 {
            if attempt > 0 { try? await Task.sleep(for: .seconds(10)) }
            do {
                try await agent.put(remote, mode: 0o755, bytes)
                let output = try await agent.spawn([remote, url])   // the v1 exec fallback where spawn is missing
                status = 0; text = String(decoding: output.prefix(300), as: UTF8.self)
            } catch let error as GuestAgentError {
                status = error.status; text = String(decoding: error.output.prefix(300), as: UTF8.self)
            } catch { status = -1; text = "\(error)" }
            if !text.contains("-1009") { break }
        }
        emit("httpget", ["device": d.name, "label": label, "status": status, "output": text, "ok": status == 0 && text.hasPrefix("HTTP 200")])
    }

    func trust(_ generation: Int) async {
        let packaged = d.process.status?.guestPackage != nil
        let guest = GuestServices(agent: agent, packaged: packaged)
        let start = Date()
        do {
            try await guest.trustCertificate(der, localTool: localTool)
            emit("trust", ["device": d.name, "generation": generation, "ok": true, "packaged": packaged, "seconds": Date().timeIntervalSince(start)])
        } catch { emit("trust", ["device": d.name, "generation": generation, "ok": false, "packaged": packaged, "error": "\(error)"]) }
    }

    /// The front app after a few seconds: Safari, or whatever took the screen (a profile screen would be Preferences).
    func front(_ label: String) async {
        let guest = GuestServices(agent: agent, packaged: d.process.status?.guestPackage != nil)
        let name = (try? await guest.foregroundAppName()) ?? ""
        let id = (try? await agent.frontmost().bundleID) ?? ""
        emit("front", ["device": d.name, "label": label, "name": name, "bundleID": id])
    }

    await boot(1)
    // Plain HTTP through the proxy first: whether the guest has a network at all (no certificate involved).
    await fetch("http", url: p.url.replacingOccurrences(of: "https://", with: "http://"))
    await fetch("untrusted")
    await trust(1)
    await fetch("trusted")
    await front("after-trust")
    d.screenshot("after-trust")

    // Safari on the HTTPS page: launch, tap the address field, type the URL, Go.
    let guest = GuestServices(agent: agent, packaged: d.process.status?.guestPackage != nil)
    do { try await guest.launch("com.apple.mobilesafari") } catch { emit("launchError", ["error": "\(error)"]) }
    var launched = ""
    for _ in 0..<20 where launched != "Safari" {
        try? await Task.sleep(for: .seconds(1))
        launched = (try? await guest.foregroundAppName()) ?? ""
    }
    d.screenshot("safari")
    if launched == "Safari" {
        if ipad {
            await d.drag(0.065, 0.55, 0.065, 0.55)
            try? await Task.sleep(for: .seconds(2))
            // macOS virtual key codes; the helper's usb-kbd path. ⌘A first clears the field.
            func key(_ code: Int, _ modifier: Int? = nil) async {
                if let modifier { d.process.link.send(.key(macKeyCode: modifier, down: true)) }
                d.process.link.send(.key(macKeyCode: code, down: true)); try? await Task.sleep(for: .milliseconds(80))
                d.process.link.send(.key(macKeyCode: code, down: false)); try? await Task.sleep(for: .milliseconds(120))
                if let modifier { d.process.link.send(.key(macKeyCode: modifier, down: false)) }
            }
            let codes: [Character: Int] = ["a": 0, "b": 11, "c": 8, "d": 2, "e": 14, "f": 3, "g": 5, "h": 4, "i": 34, "j": 38, "k": 40,
                                           "l": 37, "m": 46, "n": 45, "o": 31, "p": 35, "q": 12, "r": 15, "s": 1, "t": 17, "u": 32,
                                           "v": 9, "w": 13, "x": 7, "y": 16, "z": 6, ".": 47, "/": 44, ":": 41, "-": 27]
            await key(0, 55)   // ⌘A
            for ch in p.url.lowercased() {
                if ch == ":" { await key(41, 56) } else if let code = codes[ch] { await key(code) }   // ':' is shift-';'
            }
            await key(36)   // Return
        } else {
            // No keyboard path on the iPod (it_typein is a package hook the legacy images lack): the stock "Apple"
            // bookmark Safari opens on, which www.apple.com redirects to HTTPS, so the page loads only through the
            // trusted proxy CA. iOS 3 shows the bookmarks as a sheet over the page, iOS 4 full screen.
            let major = (await d.lockdownValue("ProductVersion") ?? "3").prefix(1)
            await d.drag(0.5, major == "4" ? 0.27 : 0.645, 0.5, major == "4" ? 0.27 : 0.645)
            emit("typed", ["device": d.name, "status": 0, "bookmark": "Apple", "major": String(major)])
        }
        try? await Task.sleep(for: .seconds(12))
        await front("safari")
        d.screenshot("safari-https")
    }
    emit("safari", ["device": d.name, "launched": launched])

    // A restart on the same overlay: the trust runs again (idempotent, silent); unlocked, the home screen, no profile screen.
    _ = try? await d.process.link.request(.agent(request: "\(UUID().uuidString) halt \n", deadline: 0), timeout: 5)
    let quit = Date()
    while Date().timeIntervalSince(quit) < 50, d.process.status?.shutdownConfirmed != true { try? await Task.sleep(for: .milliseconds(100)) }
    d.process.terminate()
    let exited = await d.process.waitForExit(timeout: 30)
    emit("quit", ["device": d.name, "generation": 1, "exited": exited, "seconds": Date().timeIntervalSince(quit)])
    d.mux.stop()
    d.serial?.removeEndpoints()
    await boot(2)
    await trust(2)
    try? await Task.sleep(for: .seconds(3))
    await front("rebooted")
    d.screenshot("rebooted-unlocked")
    await fetch("rebooted")
    d.process.terminate()
    _ = await d.process.waitForExit(timeout: 30)
    d.mux.stop()
    d.serial?.finish()
    emit("done")
    exit(0)
}
