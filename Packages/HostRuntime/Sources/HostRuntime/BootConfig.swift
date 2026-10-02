import Foundation

public nonisolated struct BootConfig: Codable, Sendable, Equatable {
    /// argv for qemu_ios_main, argv[0] included.
    public var argv: [String]
    /// setenv'd in the helper before QEMU starts (EmulatorController.setBootEnv).
    public var environment: [String: String] = [:]
    /// The -M machine name ("iPod-Touch", "ipad1"). Picks the orphan shutdown.
    public var machine: String
    /// The web proxy the helper serves before QEMU starts (argv's guestfwd connects to its socket).
    public var webProxy: WebProxyEndpoint?
    /// Managed boot: helper rechecks this storage generation under its lease.
    public var storageProof: StorageBootProof?

    public init(argv: [String], environment: [String: String] = [:], machine: String) {
        self.argv = argv
        self.environment = environment
        self.machine = machine
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        argv = try c.decode([String].self, forKey: .argv)
        environment = try c.decodeIfPresent([String: String].self, forKey: .environment) ?? [:]
        machine = try c.decode(String.self, forKey: .machine)
        webProxy = try c.decodeIfPresent(WebProxyEndpoint.self, forKey: .webProxy)
        storageProof = try c.decodeIfPresent(StorageBootProof.self, forKey: .storageProof)
    }

    /// argv's wifi0 user netdev boots restricted (BootRecipe.wifiNetdev): 5.x Setup runs offline. The
    /// helper's web proxy starts offline to match and opens with `.netRestrict(false)`.
    public var wifiRestricted: Bool {
        zip(argv, argv.dropFirst()).contains { $0 == "-netdev" && $1.hasPrefix("user,id=wifi0,") && $1.split(separator: ",").contains("restrict=on") }
    }
}

public nonisolated struct WebProxyEndpoint: Codable, Sendable, Equatable {
    /// The device's web-proxy.conf: routing read per connection; the CA, cache and location beside it.
    public var config: String
    /// The Unix socket the guestfwd's `nc -U` reaches.
    public var socket: String
    public init(config: String, socket: String) { self.config = config; self.socket = socket }
}
