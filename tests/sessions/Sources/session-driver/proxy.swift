import DeviceRuntime
import Foundation
import HostRuntime
import HostServiceClient
import HostServiceWire

@testable import LightTouchCore

// The web proxy's certificate, trusted the way the app does it (`sessions proxy-trust`): one prepared base booted with the helper's web proxy on the wifi guestfwd, the CA from WebProxyCA
// trusted through the guest agent (GuestServices.trustCertificate: the package's ittrust or the app's copy
// out of the armv6 itpack), never the MCInstall profile screen. Proof: httpget (the guest's own CFNetwork
// over the proxy, to a host only the proxy answers) fails before the trust and gets the proxy's answer after; Safari opens the HTTPS page
// (screenshot); a reboot on the same overlay, unlocked, shows the home screen and no profile screen after
// the trust runs again.

struct ProxyConfig: Decodable {
    var board: String  // "ipod" | "ipad"
    /// A prepared base (firmwarekit create output).
    var base: String
    /// The app's armv6.itpack: ittrust for a guest whose package lacks it (WebProxySetup.bundledGuestTool).
    var itpack: String
    /// contrib/it-proxy/httpget, built for armv6; optional.
    var httpget: String?
    /// Safari's page (the httpget fetches use `ProxyProbe`, a host only the proxy answers).
    var url: String
    /// `sessions local-network`: after the route, httpget `internet` and `lan` (a Mac listener on its
    /// LAN address) with Attach to Local Network off, then `lan` again once `.netLocalNetwork(true)` opens it; then stop.
    var lan: String?
    var internet: String?
    /// Pages on a listener on this Mac's loopback, asked for every way a guest could (10.0.2.2 through slirp,
    /// addresses and a name through the proxy): fetched with the LAN off and again once it is on.
    var loopback: [String]?
    /// A plain host name's page, fetched DIRECT (the PAC) while the LAN is off: the guest's own DNS through slirp,
    /// with the netdev's `domainname` completing the name.
    var dns: String?
    var domain: String?
    /// Boot with wifi0 restricted (`sessions local-network --restricted`).
    var restricted: Bool?
}

/// The host the proof fetches ask for: one that cannot resolve (RFC 6761 `.invalid`), so only the proxy answers it, with
/// its own 502 "Destination unavailable" (inside the TLS tunnel for https) once its upstream lookup fails. A real origin
/// can't tell the proxy's answer from the PAC's DIRECT fallback: CFNetwork, refusing the proxy's certificate, retries
/// DIRECT (3.1.3 and 4.2.1), and 4.2.1 got example.com's 200 that way before the trust (smoke #66, a wifi0 pcap).
nonisolated enum ProxyProbe {
    static let host = "proxy-trust.invalid"
    static func answered(_ output: String) -> Bool {
        output.hasPrefix("HTTP 502") && output.contains("Destination unavailable")
    }
}

@MainActor func runProxy(_ p: ProxyConfig) async {
    let ipad = p.board == "ipad"
    let d = Device(name: p.board, profile: ipad ? .k48 : .n72, base: URL(fileURLWithPath: p.base))
    d.restricted = p.restricted ?? false
    // The proxy's files, as WebProxyConfiguration keeps them per device: routing (direct) and the CA.
    let proxyDir = work.appendingPathComponent("\(p.board)/proxy")
    var routing = WebProxyConfiguration()
    routing.mode = .direct
    do { try routing.save(in: proxyDir) } catch { fail("routing: \(error)") }
    let der: Data
    do {
        der =
            SecCertificateCopyData(try WebProxyCA.prepare(config: WebProxyConfiguration.file(in: proxyDir)).certificate)
            as Data
    } catch { fail("proxy CA: \(error)") }
    let endpoint = WebProxyConfiguration.endpoint(directory: proxyDir)
    d.webProxy = endpoint
    d.netdevExtra =
        WebProxyConfiguration.guestForward(socket: endpoint.socket) + (p.domain.map { ",domainname=\($0)" } ?? "")
    let cache = GuestAgentCache()
    var agent: GuestAgent { GuestAgent(link: d.process.link, cache: cache) }
    var forks: ForkWatch?
    func localTool(_ name: String) throws -> Data {
        guard
            let tool = try GuestPackage.package(in: URL(fileURLWithPath: p.itpack), board: "n72ap", build: "7E18")?.1[
                "bin/\(name)"
            ]
        else {
            throw DeviceToolsError.toolMissing(name)
        }
        return tool
    }

    func boot(_ generation: Int) async {
        do { try d.boot(generation: generation) } catch { fail("boot \(generation): \(error)") }
        await waitLit(d, ipad ? 0.2 : 0.03, 240)
        // From the helper's hello on (its pid), before the guest has a network.
        if generation == 1 { forks = ForkWatch(pid: d.helloPID ?? d.process.link.pid) }
        await waitUSB(d, expecting: ipad ? "iPad1,1" : "iPod2,1", 300)
        let alive = await agent.waitAlive(seconds: 90)
        let packaged = d.process.status?.guestPackage != nil
        emit(
            "agent",
            [
                "device": d.name, "generation": generation, "alive": alive, "packaged": packaged,
                "state": await d.lockdownValue("ActivationState") ?? ""
            ]
        )
        if !ipad {  // wake: the display may have slept while it booted
            d.process.link.send(.button(0, down: true))
            try? await Task.sleep(for: .milliseconds(150))
            d.process.link.send(.button(0, down: false))
        }
        try? await Task.sleep(for: .seconds(3))
        d.screenshot("lock\(generation)")
        await d.slideToUnlock(generation, agent: agent)
        d.screenshot("home\(generation)")
    }

    /// The guest's own HTTP(S) client through the proxy, to `ProxyProbe.host`: the proxy's own answer once the CA is
    /// trusted, a certificate error (-1200/-1202 on iOS 3/4) before. Wi-Fi associates a while after lockdown answers:
    /// "offline" (-1009) is retried.
    func fetch(_ label: String, scheme: String = "https") async {
        guard let httpget = p.httpget, let bytes = try? Data(contentsOf: URL(fileURLWithPath: httpget)) else { return }
        let url = "\(scheme)://\(ProxyProbe.host)/"
        var status = -1
        var text = ""
        for attempt in 0..<8 {
            if attempt > 0 { try? await Task.sleep(for: .seconds(10)) }
            do {
                // the v1 exec fallback where spawn is missing
                let output = try await agent.spawn([agent.httpget(bytes), url])
                status = 0
                text = String(decoding: output.prefix(300), as: UTF8.self)
            } catch let error as GuestAgentError {
                status = error.status
                text = String(decoding: error.output.prefix(300), as: UTF8.self)
            } catch {
                status = -1
                text = "\(error)"
            }
            if !text.contains("-1009") { break }
        }
        emit(
            "httpget",
            [
                "device": d.name, "label": label, "status": status, "output": text,
                "ok": status == 0 && ProxyProbe.answered(text)
            ]
        )
    }

    func trust(_ generation: Int) async {
        let packaged = d.process.status?.guestPackage != nil
        let guest = GuestServices(agent: agent, packaged: packaged)
        let start = Date()
        do {
            try await guest.routeThroughProxy(localTool: localTool)
            try await guest.trustCertificate(der, localTool: localTool)
            emit(
                "trust",
                [
                    "device": d.name, "generation": generation, "ok": true, "packaged": packaged,
                    "seconds": Date().timeIntervalSince(start)
                ]
            )
        } catch {
            emit(
                "trust",
                ["device": d.name, "generation": generation, "ok": false, "packaged": packaged, "error": "\(error)"]
            )
        }
    }

    /// Safari's address field on the iPad: tap it, clear it, type, Return (macOS virtual key codes; the helper's usb-kbd
    /// path). That path drops modifiers (':' comes out ';', ⌘A an "a") and 3.2.2's Safari
    /// has no it_typein, so text is unshifted characters only: a scheme-less address Safari completes to http://.
    func typeURL(_ url: String, shot: String? = nil) async {
        func tap(_ x: Double, _ y: Double) async {
            d.process.link.send(.touch(slot: 0, phase: 0, x: x, y: y))
            try? await Task.sleep(for: .milliseconds(120))
            d.process.link.send(.touch(slot: 0, phase: 2, x: x, y: y))
            try? await Task.sleep(for: .seconds(2))
        }
        func key(_ code: Int) async {
            d.process.link.send(.key(macKeyCode: code, down: true))
            try? await Task.sleep(for: .milliseconds(150))
            d.process.link.send(.key(macKeyCode: code, down: false))
            try? await Task.sleep(for: .milliseconds(150))
        }
        let (x, y, clear) = (0.065, 0.55, 0.285)
        await tap(x, y)
        await tap(x, y)  // twice: the first can land while Safari is still settling
        await tap(x - 0.01, clear)  // the field's clear button
        let codes: [Character: Int] = [
            "a": 0, "b": 11, "c": 8, "d": 2, "e": 14, "f": 3, "g": 5, "h": 4, "i": 34, "j": 38, "k": 40,
            "l": 37, "m": 46, "n": 45, "o": 31, "p": 35, "q": 12, "r": 15, "s": 1, "t": 17, "u": 32,
            "v": 9, "w": 13, "x": 7, "y": 16, "z": 6, ".": 47, "/": 44, "-": 27, "=": 24, " ": 49,
            "1": 18, "2": 19, "3": 20, "4": 21, "5": 23, "6": 22, "7": 26, "8": 28, "9": 25, "0": 29
        ]
        for ch in url.lowercased() { if let code = codes[ch] { await key(code) } }
        if let shot { d.screenshot(shot) }
        await key(36)  // Return
    }

    /// The front app after a few seconds: Safari, or whatever took the screen (a profile screen would be Preferences).
    func front(_ label: String) async {
        let guest = GuestServices(agent: agent, packaged: d.process.status?.guestPackage != nil)
        let name = (try? await guest.foregroundAppName()) ?? ""
        let id = (try? await agent.frontmost().bundleID) ?? ""
        emit("front", ["device": d.name, "label": label, "name": name, "bundleID": id])
    }

    /// httpget `url` once Wi-Fi is up ("offline" -1009 retried): its status and first output.
    func get(_ label: String, _ url: String) async {
        guard let httpget = p.httpget, let bytes = try? Data(contentsOf: URL(fileURLWithPath: httpget)) else { return }
        var status = -1
        var text = ""
        for attempt in 0..<8 {
            if attempt > 0 { try? await Task.sleep(for: .seconds(10)) }
            do {
                text = String(decoding: try await agent.spawn([agent.httpget(bytes), url]).prefix(300), as: UTF8.self)
                status = 0
            } catch let error as GuestAgentError {
                status = error.status
                text = String(decoding: error.output.prefix(300), as: UTF8.self)
            } catch {
                status = -1
                text = "\(error)"
            }
            if !text.contains("-1009") { break }
        }
        emit("get", ["device": d.name, "label": label, "status": status, "output": text])
    }

    await boot(1)
    // Routing first (the app does it in the same step as the trust), so the untrusted fetch below reaches
    // the proxy: without it an image lacking the PAC goes straight to the origin, and its -1200 is only
    // 3.1.3's TLS against a modern server, not the proxy's certificate.
    do {
        try await GuestServices(agent: agent, packaged: d.process.status?.guestPackage != nil).routeThroughProxy(
            localTool: localTool
        )
        emit("route", ["device": d.name, "ok": true])
    } catch { emit("route", ["device": d.name, "ok": false, "error": "\(error)"]) }
    if let lan = p.lan {
        if let internet = p.internet { await get("internet", internet) }
        if let dns = p.dns { await get("dns", dns) }
        await get("lan-off", lan)
        for (i, url) in (p.loopback ?? []).enumerated() { await get("loopback-off-\(i)", url) }
        emit("lan-on", ["at": Date().timeIntervalSince1970])
        d.process.link.send(.netLocalNetwork(true))
        try? await Task.sleep(for: .seconds(1))
        await get("lan-on", lan)
        for (i, url) in (p.loopback ?? []).enumerated() { await get("loopback-on-\(i)", url) }
        d.process.terminate()
        _ = await d.process.waitForExit(timeout: 30)
        d.mux.stop()
        d.serial?.finish()
        emit("done")
        exit(0)
    }
    // Plain HTTP through the proxy first: whether the guest has a network at all (no certificate involved).
    await fetch("http", scheme: "http")
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
            await typeURL(
                p.url.replacingOccurrences(of: "https://", with: "").replacingOccurrences(of: "http://", with: ""),
                shot: "typed"
            )
        } else {
            // No keyboard path on the iPod (it_typein is a package hook the legacy images lack): the stock "Apple"
            // bookmark Safari opens on, which www.apple.com redirects to HTTPS, so the page loads only through the
            // trusted proxy CA. iOS 3 shows the bookmarks as a sheet over the page, iOS 4 full screen.
            let major = (await d.lockdownValue("ProductVersion") ?? "3").prefix(1)
            let row = major == "4" ? 0.27 : 0.645
            await d.settled(top: row - 0.05, bottom: row + 0.05)
            await d.drag(0.5, row, 0.5, row)
            emit("typed", ["device": d.name, "status": 0, "bookmark": "Apple", "major": String(major)])
        }
        try? await Task.sleep(for: .seconds(12))
        await front("safari")
        d.screenshot("safari-https")
    }
    emit("safari", ["device": d.name, "launched": launched])
    // Every proxy connection so far (the fetches, the route, Safari's page) reached the helper without it starting a
    // process: slirp connects them to the proxy's socket itself (WebProxyConfiguration.guestForward).
    emit("forks", ["device": d.name, "watched": forks != nil, "count": forks?.count ?? -1])
    // A restart on the same overlay: the trust runs again (idempotent, silent); unlocked, the home screen, no profile screen.
    _ = try? await d.process.link.request(.agent(request: "\(UUID().uuidString) halt \n", deadline: 0), timeout: 5)
    let quit = Date()
    while Date().timeIntervalSince(quit) < 50, d.process.status?.shutdownConfirmed != true {
        try? await Task.sleep(for: .milliseconds(100))
    }
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

/// How many processes `pid` forks from now on (kqueue NOTE_FORK; forks between two reads may count once, so a
/// lower bound): the helper starts none while the guest uses the web proxy.
final class ForkWatch: @unchecked Sendable {
    private let lock = NSLock()
    private var forks = 0

    init?(pid: pid_t) {
        let queue = kqueue()
        var change = kevent(
            ident: UInt(pid),
            filter: Int16(EVFILT_PROC),
            flags: UInt16(EV_ADD | EV_CLEAR),
            fflags: UInt32(NOTE_FORK) | UInt32(NOTE_EXIT),
            data: 0,
            udata: nil
        )
        guard pid > 0, queue >= 0, kevent(queue, &change, 1, nil, 0, nil) == 0 else { return nil }
        Thread.detachNewThread { [self] in
            var event = kevent()
            while kevent(queue, nil, 0, &event, 1, nil) >= 0 {
                if event.fflags & UInt32(NOTE_FORK) != 0 { lock.withLock { forks += 1 } }
                if event.fflags & UInt32(NOTE_EXIT) != 0 { break }
            }
            close(queue)
        }
    }

    var count: Int { lock.withLock { forks } }
}
