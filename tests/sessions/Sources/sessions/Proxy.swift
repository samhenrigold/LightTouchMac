import Foundation
import HostRuntime
import SessionKit

/// contrib/it-proxy/httpget of the pinned qemu-ios checkout (armv6; the guest's own CFNetwork client), or --httpget.
/// iOS 10 runs no armv6 code: its build for armv7 (httpget-armv7) there, or the one scripts/vendor stages in the vendor
/// directory's ipad-guest-tools when the checkout has none built.
func httpget(_ args: Inputs, major: Int = 0) -> URL {
    let name = major >= 10 ? "httpget-armv7" : "httpget"
    let built = checkout("qemu-ios").appendingPathComponent("contrib/it-proxy/" + name)
    let staged = vendorDirectory()?.appendingPathComponent("work/guest/ipad-guest-tools/" + name)
    let url =
        args.httpget
        ?? [built, staged].compactMap { $0 }.first { FileManager.default.fileExists(atPath: $0.path) } ?? built
    guard FileManager.default.fileExists(atPath: url.path) else {
        die("no httpget at \(url.path) (contrib/it-proxy/build.sh, or --httpget)")
    }
    return url
}

/// `sessions proxy-trust BASE` (an n72 or k48 base): enabling the web proxy trusts its certificate in the guest silently,
/// never an "Install Profile" screen (session-driver's proxy.swift). The guest's HTTPS client through the proxy fails before
/// the trust and gets the proxy's own answer after; Safari stays in front on the HTTPS page and its request reached the
/// proxy; a restart on the same overlay, unlocked, shows the Home screen and no profile screen after the trust runs again.
func proxyTrust(_ args: ProxyTrustCheck) -> Never {
    let base = Base(args.base, args.inputs)
    guard ["n72ap", "k48ap"].contains(base.board) else { die("proxy-trust boots an n72ap or k48ap base") }
    let b = base.driverBoard
    let ipad = b == "ipad"
    let work = workDirectory(args.inputs, "proxy-trust")
    let tools = Tools.resolve(args.inputs, work: work)
    let packs = tools.guest.appendingPathComponent("guest-tools")
    let url = args.url
    var config = driverConfig(tools, work: work)
    config["timeout"] = 900
    if ipad {
        config["ipadItpack"] = packs.appendingPathComponent("armv7.itpack").path
        config["ipadBase"] = base.url.path
    }
    config["proxy"] = [
        "board": b, "base": base.url.path, "itpack": packs.appendingPathComponent("armv6.itpack").path,
        "httpget": httpget(args.inputs).path, "url": url
    ]
    let (e, status) = sessionDriver(
        config,
        work: work,
        timeout: 900,
        environment: driverEnvironment(tools).merging(["LTM_WEB_PROXY_TRACE": "1"]) { $1 }
    )
    let r = Report()
    r.check(!e.one("lit").isEmpty, "\(b): lit in \(format(e.one("lit").double("seconds"))) s")
    r.check(
        e.one("usb").string("productType") == base.productType,
        "\(b): lockdown over its usbmuxd: \(e.one("usb").string("productType") ?? "none")"
    )
    let agent = e.one("agent", ["generation": 1])
    r.check(
        agent.bool("alive"),
        "\(b): the guest agent is up (packaged \(agent.bool("packaged")), ActivationState \(agent.string("state") ?? ""))"
    )
    let route = e.one("route")
    r.check(
        route.bool("ok"),
        "\(b): the guest routed through the proxy" + (route.bool("ok") ? "" : ": \(route.string("error") ?? "")")
    )
    let http = e.one("httpget", ["label": "http"])
    r.check(
        http.bool("ok"),
        "\(b): plain HTTP through the proxy (Wi-Fi up, the proxy answers): \(clip(http.string("output") ?? "", 60))"
    )
    // Refused before the trust: through the PAC the guest takes its DIRECT fallback and the .invalid host has no origin
    // (-1003), or -1202 "untrusted server certificate" / -1200 where a guest fails the tunnel without falling back.
    let untrusted = e.one("httpget", ["label": "untrusted"])
    let before = untrusted.string("output") ?? ""
    r.check(
        !untrusted.isEmpty && !untrusted.bool("ok") && before.hasPrefix("ERROR")
            && ["-1200", "-1202", "-1003"].contains { before.contains($0) },
        "\(b): HTTPS through the proxy refused before the trust: \(clip(before, 90))"
    )
    let trust = e.one("trust", ["generation": 1])
    r.check(
        trust.bool("ok"),
        "\(b): certificate trusted through the agent in \(format(trust.double("seconds"))) s"
            + (trust.bool("ok") ? "" : ": \(trust.string("error") ?? "")")
    )
    r.check(
        e.one("httpget", ["label": "trusted"]).bool("ok"),
        "\(b): HTTPS through the proxy answers after the trust: \(clip(e.one("httpget", ["label": "trusted"]).string("output") ?? "", 40))"
    )
    let afterTrust = e.one("front", ["label": "after-trust"])
    r.check(
        afterTrust.string("bundleID") == "com.apple.springboard",
        "\(b): no screen took over after the trust (front: \(afterTrust.string("bundleID") ?? ""))"
    )
    r.check(e.one("safari").string("launched") == "Safari", "\(b): Safari launched")
    let safari = e.one("front", ["label": "safari"])
    r.check(
        safari.string("bundleID") == "com.apple.mobilesafari",
        "\(b): Safari still in front after the page load (front: \(safari.string("bundleID") ?? ""))"
    )
    // Safari's own page request in the helper's LTM_WEB_PROXY_TRACE lines (nothing else asks for that host). 4.x's
    // MobileSafari is sandboxed: with the PAC under /usr/local it went DIRECT while unsandboxed clients used the proxy.
    let host = ipad ? URL(string: url)?.host ?? "" : "www.apple.com"
    let native = (try? String(contentsOf: work.appendingPathComponent("\(b)/native.log"), encoding: .utf8)) ?? ""
    let seen = native.split(separator: "\n").first { $0.contains("web-proxy: ") && $0.contains(host) }
    r.check(seen != nil, "\(b): Safari's page (\(host)) came through the proxy")
    let forks = e.one("forks")
    r.check(
        forks.bool("watched") && forks.int("count") == 0,
        "\(b): the helper started no process for the proxy's connections (forks: \(forks.int("count") ?? -1))"
    )
    r.check(
        e.one("quit").bool("exited"),
        "\(b): clean halt, helper exited in \(format(e.one("quit").double("seconds"))) s"
    )
    r.check(e.one("agent", ["generation": 2]).bool("alive"), "\(b): restarted on the same overlay, agent up")
    r.check(e.one("trust", ["generation": 2]).bool("ok"), "\(b): the trust runs again after the restart, silently")
    // The lock screen is SpringBoard too (it_agent answers `com.apple.springboard / Lock Screen`).
    let rebooted = e.one("front", ["label": "rebooted"])
    r.check(
        rebooted.string("bundleID") == "com.apple.springboard" && rebooted.string("name") == "Home Screen",
        "\(b): unlocked after the restart: the Home screen, no profile screen (front: \(rebooted.string("bundleID") ?? "") / \(rebooted.string("name") ?? ""))"
    )
    r.check(e.one("httpget", ["label": "rebooted"]).bool("ok"), "\(b): HTTPS still answers after the restart")
    r.check(e.any("done") && status == 0, "driver finished (exit \(status.map(String.init) ?? "timeout"))")
    finish(r, work: work)
}

// MARK: - Attach to Local Network

/// The socket shim: every connect/sendto/sendmsg/connectx destination of a process it is inserted into, to LTM_SOCKET_LOG.
let socketShim = #"""
    #include <arpa/inet.h>
    #include <fcntl.h>
    #include <stdio.h>
    #include <stdlib.h>
    #include <sys/socket.h>
    #include <sys/time.h>
    #include <unistd.h>
    #define INTERPOSE(n, o) __attribute__((used)) static struct { const void *a, *b; } i_##o \
        __attribute__((section("__DATA,__interpose"))) = { (const void *)n, (const void *)o };
    static void note(const char *kind, const struct sockaddr *a) {
        char host[INET6_ADDRSTRLEN] = "", line[200]; int port; struct timeval tv; const char *path = getenv("LTM_SOCKET_LOG");
        if (!a || !path) return;
        if (a->sa_family == AF_INET) { const struct sockaddr_in *s = (const void *)a; inet_ntop(AF_INET, &s->sin_addr, host, sizeof host); port = ntohs(s->sin_port); }
        else if (a->sa_family == AF_INET6) { const struct sockaddr_in6 *s = (const void *)a; inet_ntop(AF_INET6, &s->sin6_addr, host, sizeof host); port = ntohs(s->sin6_port); }
        else return;
        gettimeofday(&tv, NULL);
        int fd = open(path, O_WRONLY | O_APPEND | O_CREAT, 0644);
        if (fd < 0) return;
        write(fd, line, snprintf(line, sizeof line, "%ld.%06d %s %s %s %d\n", (long)tv.tv_sec, (int)tv.tv_usec, getprogname(), kind, host, port));
        close(fd);
    }
    static int c(int fd, const struct sockaddr *a, socklen_t l) { note("connect", a); return connect(fd, a, l); }
    static ssize_t st(int fd, const void *b, size_t n, int f, const struct sockaddr *a, socklen_t l) { note("sendto", a); return sendto(fd, b, n, f, a, l); }
    static ssize_t sm(int fd, const struct msghdr *m, int f) { note("sendmsg", m ? m->msg_name : NULL); return sendmsg(fd, m, f); }
    static int cx(int fd, const sa_endpoints_t *e, sae_associd_t as, unsigned int fl, const struct iovec *v, unsigned int vc, size_t *len, sae_connid_t *id)
        { note("connectx", e ? e->sae_dstaddr : NULL); return connectx(fd, e, as, fl, v, vc, len, id); }
    INTERPOSE(c, connect) INTERPOSE(st, sendto) INTERPOSE(sm, sendmsg) INTERPOSE(cx, connectx)
    """#

/// A destination macOS counts as the local network (and asks the user about): one of this Mac's DNS servers, or
/// an address NetworkPolicy, the rule the helper's proxy and slirp apply, puts on the local network. This Mac's own
/// addresses (loopback: the proxy's egress among them) are not.
func localNetwork(_ host: String, dnsServers: Set<String>) -> Bool {
    let host = String(host.split(separator: "%").first ?? "")
    if dnsServers.contains(host) { return true }
    return NetworkPolicy.address(host).map { NetworkPolicy.reach($0) == .localNetwork } ?? false
}

/// A one-page HTTP listener on `address` standing in for a host on the Mac's LAN: the paths it was asked for.
final class LANProbe: @unchecked Sendable {
    let port: Int
    private let fd: Int32
    private let lock = NSLock()
    private var paths: [String] = []
    var hits: [String] { lock.withLock { paths } }

    init?(address: String) {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        inet_pton(AF_INET, address, &addr.sin_addr)
        var size = socklen_t(MemoryLayout<sockaddr_in>.size)
        let bound = withUnsafeMutablePointer(to: &addr) { p in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, size) == 0 && listen(fd, 8) == 0 && getsockname(fd, $0, &size) == 0
            }
        }
        guard bound else {
            close(fd)
            return nil
        }
        self.fd = fd
        port = Int(UInt16(bigEndian: addr.sin_port))
        Thread.detachNewThread { [self] in
            while true {
                let client = accept(fd, nil, nil)
                if client < 0 { return }
                var buffer = [UInt8](repeating: 0, count: 4096)
                var request = Data()
                while !request.contains(Data("\r\n\r\n".utf8)) {
                    let n = read(client, &buffer, buffer.count)
                    if n <= 0 { break }
                    request.append(contentsOf: buffer[0..<n])
                }
                let line = String(decoding: request, as: UTF8.self).split(separator: "\r\n").first ?? ""
                let parts = line.split(separator: " ")
                if parts.count > 1 {
                    let p = String(parts[1])
                    lock.withLock { paths.append(p) }
                }
                let reply = "HTTP/1.0 200 OK\r\nContent-Length: 9\r\n\r\nlan probe"
                _ = reply.withCString { write(client, $0, strlen($0)) }
                close(client)
            }
        }
    }
    func stop() { close(fd) }
}

/// `sessions local-network BASE [--restricted]` (an n72 or k48 base: its PAC sends private addresses DIRECT): Attach to Local Network is off
/// by default. One iPod boots as the app does (the helper's web proxy on the wifi guestfwd, slirp's lan=off); a listener
/// on this Mac's LAN address stands in for a LAN host. The guest's httpget reaches the internet (through the proxy) and
/// its own DNS while off, but not the listener; once `.netLocalNetwork(true)` it does. A socket shim in the driver,
/// usbmuxd, the services worker and a copy of the helper signed without the hardened runtime logs every destination:
/// while off, none may be one macOS counts as the local network (that is what raises its Local Network prompt), and
/// usbmuxd may open none at all (the iPad's USB Ethernet bridge once gave the guest its own unfiltered slirp there).
/// --restricted boots wifi0 restricted (5.x Setup offline): no internet, no DNS, and no LAN even once turned on.
func localNetworkCheck(_ args: LocalNetworkCheck) -> Never {
    let base = Base(args.base, args.inputs)
    guard ["n72ap", "k48ap"].contains(base.board) else { die("local-network boots an n72ap or k48ap base") }
    let restricted = args.restricted
    guard
        let lanIP = ["en0", "en1"].lazy.map({
            output("/usr/sbin/ipconfig", ["getifaddr", $0]).trimmingCharacters(in: .whitespacesAndNewlines)
        })
        .first(where: { !$0.isEmpty })
    else {
        print("SKIP: this Mac has no en0/en1 address to stand in for a LAN host")
        exit(0)
    }
    let work = workDirectory(args.inputs, "local-network")
    let tools = Tools.resolve(args.inputs, work: work)
    guard let probe = LANProbe(address: lanIP) else { die("could not listen on \(lanIP)") }
    let lanURL = "http://\(lanIP):\(probe.port)/lan-probe"
    // This Mac's own services, never the device's: through slirp's gateway, and through the proxy (the PAC sends
    // these there) by the unspecified address, a v4-mapped one, and a public name that resolves to loopback.
    guard let loopback = LANProbe(address: "127.0.0.1") else { die("could not listen on 127.0.0.1") }
    let loopbackURLs = [
        "10.0.2.2:\(loopback.port)/nat", "0.0.0.0:\(loopback.port)/zero",
        "[::ffff:127.0.0.1]:\(loopback.port)/mapped", "localtest.me:\(loopback.port)/name"
    ].map { "http://" + $0 }

    // The shim, for every architecture a child may be (system tools are arm64e), and a helper copy it can load into.
    let source = work.appendingPathComponent("socket-log.c")
    let shim = work.appendingPathComponent("socket-log.dylib")
    try? socketShim.write(to: source, atomically: true, encoding: .utf8)
    guard
        run(
            "/usr/bin/clang",
            ["-dynamiclib", "-arch", "arm64", "-arch", "arm64e", "-arch", "x86_64", "-o", shim.path, source.path],
            log: work.appendingPathComponent("shim.log")
        ) == 0
    else { die("could not build the socket shim") }
    // ad-hoc and without the hardened runtime, so DYLD_INSERT_LIBRARIES reaches it
    let observed = helperCopy(tools.helper, named: "observed", in: work, options: [])
    var t = tools
    t.helper = observed
    t.requirement = nil
    let dnsServers = Set(
        output("/usr/sbin/scutil", ["--dns"]).split(separator: "\n").compactMap { line -> String? in
            guard line.contains("nameserver["), let value = line.split(separator: ":", maxSplits: 1).last else {
                return nil
            }
            return value.trimmingCharacters(in: .whitespaces)
        }
    )

    var config = driverConfig(t, work: work)
    config["timeout"] = 600
    if base.driverBoard == "ipad" {
        config["ipadItpack"] = tools.guest.appendingPathComponent("guest-tools/armv7.itpack").path
        config["ipadBase"] = base.url.path
    }
    config["proxy"] = [
        "board": base.driverBoard, "base": base.url.path, "restricted": restricted,
        "itpack": tools.guest.appendingPathComponent("guest-tools/armv6.itpack").path,
        "httpget": httpget(args.inputs).path, "url": "", "lan": lanURL, "loopback": loopbackURLs,
        "internet": args.internet,
        "dns": args.dns, "domain": args.domain
    ]
    // In a folder of its own: a sandboxed helper is granted the log's folder, never the run's root (its library).
    let sockets = work.appendingPathComponent("sockets/sockets.log")
    try? FileManager.default.createDirectory(at: sockets.deletingLastPathComponent(), withIntermediateDirectories: true)
    let (e, status) = sessionDriver(
        config,
        work: work,
        timeout: 600,
        environment: driverEnvironment(t).merging(
            ["DYLD_INSERT_LIBRARIES": shim.path, "LTM_SOCKET_LOG": sockets.path]) { $1 }
    )
    probe.stop()
    loopback.stop()

    func got(_ label: String) -> String { e.find("get", ["label": label]).first?.string("output") ?? "" }
    let r = Report()
    let off = got("lan-off")
    let on = got("lan-on")
    r.check(
        got("internet").hasPrefix(restricted ? "ERROR" : "HTTP 200"),
        "\(restricted ? "no internet while restricted" : "internet through the proxy"): \(clip(got("internet"), 60))"
    )
    r.check(off.hasPrefix("ERROR"), "the LAN refused while off: \(clip(off, 60))")
    r.check(
        restricted
            ? on.hasPrefix("ERROR") && probe.hits.isEmpty : on.hasPrefix("HTTP 200") && probe.hits == ["/lan-probe"],
        "the LAN \(restricted ? "still refused" : "reached") once turned on: \(clip(on, 60)), the listener saw \(probe.hits)"
    )
    let asked = loopbackURLs.indices.flatMap { i in
        ["off", "on"].map { "\(loopbackURLs[i]) (LAN \($0)): \(clip(got("loopback-\($0)-\(i)"), 40))" }
    }
    r.check(
        loopback.hits.isEmpty && asked.count == 2 * loopbackURLs.count,
        "this Mac's loopback never reached, the LAN off or on: the listener saw \(loopback.hits); \(asked.joined(separator: "; "))"
    )
    r.check(
        got("dns").hasPrefix(restricted ? "ERROR" : "HTTP "),
        "the guest's own DNS while off (\(args.dns) DIRECT): \(clip(got("dns"), 60))"
    )
    let lines = ((try? String(contentsOf: sockets, encoding: .utf8)) ?? "").split(separator: "\n").map {
        $0.split(separator: " ").map(String.init)
    }
    .filter { $0.count >= 5 }
    let flip = e.one("lan-on").double("at")
    r.check(
        flip != nil && lines.contains { $0[1].hasPrefix("LightTouchDevice") },
        "the helper's sockets observed (\(lines.count) in \(sockets.path))"
    )
    let leaks = Set(
        lines.filter { flip != nil && (Double($0[0]) ?? 0) < flip! && localNetwork($0[3], dnsServers: dnsServers) }
            .map { $0[1...].joined(separator: " ") }
    ).sorted()
    r.check(
        leaks.isEmpty,
        "nothing sent to the local network while off: \(leaks.isEmpty ? "none" : leaks.joined(separator: "; "))"
    )
    let usbmuxd = Set(lines.filter { $0[1] == "usbmuxd" }.map { $0[1...].joined(separator: " ") }).sorted()
    r.check(
        usbmuxd.isEmpty,
        "usbmuxd opened no network socket: \(usbmuxd.isEmpty ? "none" : usbmuxd.joined(separator: "; "))"
    )
    if !restricted {
        r.check(
            lines.contains {
                flip != nil && (Double($0[0]) ?? 0) >= flip! && $0[3] == lanIP && $0[4] == String(probe.port)
            },
            "the helper connected to the LAN listener once turned on"
        )
    }
    r.check(e.any("done") && status == 0, "driver finished (exit \(status.map(String.init) ?? "timeout"))")
    finish(r, work: work)
}

/// The first line of `text`, at most `count` characters.
func clip(_ text: String, _ count: Int) -> String { String((text.split(separator: "\n").first ?? "").prefix(count)) }
