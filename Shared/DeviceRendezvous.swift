// How a spawned LightTouchDevice hands its IOSurfaces to the app.
//
// A dynamic NSXPCListener(machServiceName:) is refused for a name launchd does
// not know (docs/multi-device-spikes.md, section 1), so the app checks in
// "<bundle id>.devices.<app pid>" with bootstrap_check_in and the helper sends
// one Mach message per ring: its one-time token and the IOSurfaceCreateMachPort
// ports of [status block, ring0, ring1, ring2] (status only before the first
// frame). The name is visible to every process in the session, so each hello
// is validated before any port is used:
//   1. the sender pid, from the kernel's audit trailer, is a helper this app
//      spawned (and registered) and not yet reaped;
//   2. the code behind that audit token (not just the pid, so a recycled pid
//      cannot pass) satisfies the requirement: same Team ID as the app, or the
//      helper's own designated requirement (its cdhash) for an ad-hoc build;
//   3. the token matches the one on that helper's argv.
// Control never goes over Mach: it is on the private socketpair.

import Foundation
import IOSurface
import LTMLinkC
import Security

nonisolated enum DeviceRendezvous {
    /// Helper side: send the status block (and the ring, once there is one).
    static func sendHello(service: String, token: String, generation: UInt64,
                          surfaces: [IOSurface]) -> kern_return_t {
        let ports = surfaces.map { IOSurfaceCreateMachPort($0) }
        return ports.withUnsafeBufferPointer {
            ltm_send_hello(service, token, UInt32(DeviceLinkWire.protocolVersion), generation,
                           $0.baseAddress, Int32($0.count))
        }
    }

    /// The requirement a helper must satisfy: same Team ID as this process, or
    /// (ad-hoc builds, no Team) the helper executable's designated requirement.
    static func defaultRequirement(helper: URL) -> String? {
        if let team = teamIdentifier() {
            return "anchor apple generic and certificate leaf[subject.OU] = \"\(team)\""
        }
        var staticCode: SecStaticCode?
        var requirement: SecRequirement?
        var text: CFString?
        guard SecStaticCodeCreateWithPath(helper as CFURL, [], &staticCode) == errSecSuccess, let staticCode,
              SecCodeCopyDesignatedRequirement(staticCode, [], &requirement) == errSecSuccess, let requirement,
              SecRequirementCopyString(requirement, [], &text) == errSecSuccess, let text else { return nil }
        return text as String
    }

    static func teamIdentifier() -> String? {
        var code: SecCode?
        var staticCode: SecStaticCode?
        var info: CFDictionary?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code,
              SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode,
              SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let dict = info as? [String: Any] else { return nil }
        return dict[kSecCodeInfoTeamIdentifier as String] as? String
    }

    /// Whether the process behind `audit` satisfies `requirement`.
    static func check(audit: audit_token_t, requirement: String) -> OSStatus {
        var audit = audit
        let tokenData = withUnsafeBytes(of: &audit) { Data($0) }
        var code: SecCode?
        var req: SecRequirement?
        var status = SecCodeCopyGuestWithAttributes(nil, [kSecGuestAttributeAudit: tokenData] as CFDictionary, [], &code)
        guard status == errSecSuccess, let code else { return status }
        status = SecRequirementCreateWithString(requirement as CFString, [], &req)
        guard status == errSecSuccess, let req else { return status }
        return SecCodeCheckValidity(code, [], req)
    }
}

/// App side: the process-wide check-in and hello dispatcher.
nonisolated final class DeviceRendezvousServer: @unchecked Sendable {
    static let shared = DeviceRendezvousServer()

    struct Hello {
        var generation: UInt64
        var surfaces: [IOSurface]
    }
    struct Registration {
        var token: String
        var requirement: String
        var deliver: (Hello) -> Void
        var reject: (String) -> Void
    }

    let serviceName: String
    private let lock = NSLock()
    private var registrations: [pid_t: Registration] = [:]
    private var started = false
    private var checkInError: kern_return_t = 0
    private var port: mach_port_t = 0

    private init() {
        serviceName = "\(Bundle.main.bundleIdentifier ?? "gold.samhenri.LightTouchMac").devices.\(getpid())"
    }

    /// Check in (once per process) and start the receive thread. Nonzero: the kern_return_t.
    func start() -> kern_return_t {
        lock.lock(); defer { lock.unlock() }
        if started { return checkInError }
        started = true
        checkInError = ltm_check_in(serviceName, &port)
        guard checkInError == 0 else { return checkInError }
        let thread = Thread { [self] in receiveLoop() }
        thread.name = "LightTouch.rendezvous"
        thread.qualityOfService = .userInitiated
        thread.start()
        return 0
    }

    /// Spawn under the lock, so a hello that races the spawn waits for the
    /// registration instead of being rejected.
    func spawnAndRegister(_ spawn: () -> pid_t, registration: Registration) -> pid_t {
        lock.lock(); defer { lock.unlock() }
        let pid = spawn()
        if pid > 0 { registrations[pid] = registration }
        return pid
    }

    func unregister(_ pid: pid_t) {
        lock.lock(); registrations[pid] = nil; lock.unlock()
    }

    private func receiveLoop() {
        while true {
            var hello = ltm_hello()
            let kr = ltm_recv_hello(port, -1, &hello)
            if kr != 0 { usleep(10_000); continue }
            let ports = withUnsafeBytes(of: hello.ports) {
                Array($0.bindMemory(to: mach_port_t.self).prefix(Int(max(0, hello.nports))))
            }
            defer { for p in ports where p != 0 { mach_port_deallocate(mach_task_self_, p) } }
            lock.lock()
            let registration = registrations[hello.pid]
            lock.unlock()
            guard let registration else {
                NSLog("LightTouch rendezvous: rejected a hello from pid %d: not a helper this app spawned", hello.pid)
                continue
            }
            if let reason = validate(hello, registration) {
                registration.reject(reason)
                continue
            }
            let surfaces = ports.compactMap { IOSurfaceLookupFromMachPort($0) }
            guard surfaces.count == ports.count else {
                registration.reject("a surface port did not resolve")
                continue
            }
            registration.deliver(Hello(generation: hello.generation, surfaces: surfaces))
        }
    }

    private func validate(_ hello: ltm_hello, _ registration: Registration) -> String? {
        guard hello.nports >= 1 else { return "malformed hello" }
        let status = DeviceRendezvous.check(audit: hello.audit, requirement: registration.requirement)
        guard status == errSecSuccess else { return "code signing requirement failed (\(status))" }
        let token = withUnsafeBytes(of: hello.token) { String(cString: $0.bindMemory(to: CChar.self).baseAddress!) }
        guard token == registration.token else { return "wrong token" }
        guard hello.protocol_version == UInt32(DeviceLinkWire.protocolVersion) else {
            return "protocol \(hello.protocol_version), expected \(DeviceLinkWire.protocolVersion)"
        }
        guard hello.generation == 0 ? hello.nports == 1 : hello.nports == LTM_MAX_PORTS else {
            return "expected \(hello.generation == 0 ? 1 : LTM_MAX_PORTS) surfaces, got \(hello.nports)"
        }
        return nil
    }
}
