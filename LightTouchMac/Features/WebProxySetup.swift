// The web proxy on one running device: the host side's CA (WebProxyCA,
// served by the helper's WebProxy), then, through the agent, the route (a legacy image without the
// PAC) and the trust; lockdown's MCInstall profile only for a guest without an
// agent (LockdownTools).

import Foundation
import Security

struct WebProxySetup: Sendable {
    let services: DeviceServices
    let guest: GuestServices
    /// This device's web-proxy files (WebProxyConfiguration.directory).
    let proxyDirectory: URL

    private var proxyFile: String { WebProxyConfiguration.file(in: proxyDirectory).path }

    /// Both boards, no guest helper: routing is the image's PAC (always the proxy, DIRECT as fallback), or
    /// itproxy's configd setting on an image without one (GuestServices.routeThroughProxy), and the helper's
    /// proxy mode. Turning the proxy on trusts this
    /// device's CA in the guest silently through the agent (GuestServices.trustCertificate, the store
    /// keeps it); only a guest without an agent gets the configuration profile through lockdown's stock
    /// MCInstall service (lockdown-mcinstall, a child process like lockdown-tz), once: an installed
    /// profile is never offered again, and the UI says to tap Install (`.needsTap`).
    /// ponytail: turning it off leaves the trust in place (the CA is this device's own and its key
    /// never leaves the Mac); add `ittrust remove` / RemoveProfile if asked.
    func configure(enabled: Bool) async throws -> WebProxyStatus {
        guard enabled else { return .ready }
        let config = URL(fileURLWithPath: proxyFile)
        let der: Data
        do {
            der = SecCertificateCopyData(try await Task.detached { try WebProxyCA.prepare(config: config) }.value.certificate) as Data
        } catch {
            logEvent("proxy: certificate preparation failed: \(error)")
            throw DeviceToolsError.failed("Couldn’t prepare the proxy certificate.")
        }
        // The agent claims its channel shortly after lockdown answers; give it a moment before falling back.
        if await guest.agent.waitAlive(seconds: 15) {
            do {
                try await guest.routeThroughProxy(localTool: Self.bundledGuestTool)
                try await guest.trustCertificate(der, localTool: Self.bundledGuestTool)
                logEvent("proxy: certificate trusted through the guest agent")
                return .ready
            } catch is CancellationError { throw CancellationError() }
            catch { logEvent("proxy: agent trust failed, offering the profile instead: \(error.localizedDescription)") }
        }
        return try await services.offerProfile(proxyFile + ".ca.der") ? .needsTap : .ready
    }

    /// A guest binary out of the bundled iPod package (armv6; ittrust runs on the iPad too), for a
    /// guest whose package lacks it.
    static func bundledGuestTool(_ name: String) throws -> Data {
        guard let pack = GuestPackage.bundledPack(arch: "armv6", filesRoot: Bundled.filesRoot),
              let tool = try GuestPackage.package(in: pack, board: "n72ap", build: "7E18")?.1["bin/\(name)"] else {
            throw DeviceToolsError.toolMissing(name)
        }
        return tool
    }
}
