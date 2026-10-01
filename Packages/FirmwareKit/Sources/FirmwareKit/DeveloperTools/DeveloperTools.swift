import CryptoKit
import Foundation

/// Optional developer access is installed by the existing guest package loader,
/// not by editing live NAND or introducing a second remote command protocol.
nonisolated public enum DeveloperTools {
    public static let targets = ["usr/sbin/sshd", "usr/libexec/sftp-server", "bin/bash",
        "usr/lib/libcrypto.0.9.8.dylib"]
    public static let source = "Legacy-iOS-Kit/2f818780e5c808b09c3497f1745dde1bdce8e372+GNU/bash-4.0.40/minimal-v1"
    private static let expectedHashes: [String: String] = [
        "bin/bash": "ef8ec95c81d8b48a088d5603bd4a652505b9f641ebafd9ba93e261074a4d971c",
        "usr/lib/libcrypto.0.9.8.dylib": "bb7cff246d604171a4179cd2fb1a1d97f06ac2e534342b7039ad40aed8bb30de",
        "usr/libexec/sftp-server": "c6ea137ba834febc9b69848f02a68b529a3eaa88a11768f6682e159c05db0906",
        "usr/sbin/sshd": "737a9b0decfe7008641b38f3be18c2bb9006f258f2fb81d3598f52f510b8357b"
    ]
    public struct BundleManifest: Codable, Sendable {
        public var source: String
        public var files: [String: String]
        public init(source: String, files: [String: String]) { self.source = source; self.files = files }
    }
    public struct Result: Codable, Sendable {
        public let instance: UUID
        public let serial: Int
        public let hostPublicKey: String
        public let payloadSource: String
        public let clientIdentity: String?
    }
    private static func hash(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
    public struct Failure: Error, LocalizedError, Sendable {
        public let message: String
        public var errorDescription: String? { message }
    }
    private static func fail(_ message: String) -> Failure { Failure(message: message) }

    /// Augment a disposable, already-composed offer. Payload hashes must match
    /// its upstream bundle manifest. State stores per-instance keys and is never
    /// bundled, shared between instances, or regenerated on every boot.
    public static func augment(offer: URL, payload: URL, state: URL, instance: UUID,
                               authorizedPublicKey: String? = nil, serial: Int) throws -> Result {
        let fm = FileManager.default
        let text = try String(contentsOf: offer.appendingPathComponent("offer"), encoding: .utf8)
        var lines = text.split(separator: "\n").map(String.init)
        guard lines.first == "ltpkg 1", let build = lines.first(where: { $0.hasPrefix("build ") })?.split(separator: " ").last,
              ["7E18", "7B500"].contains(String(build)) else { throw fail("developer OpenSSH payload is limited to the 7E18 and 7B500 developer profiles") }
        guard let serialIndex = lines.firstIndex(where: { $0.hasPrefix("serial ") }),
              lines[serialIndex].split(separator: " ").count == 3,
              let previous = Int(lines[serialIndex].split(separator: " ")[1]), previous > 0, serial > previous, serial <= Int(Int32.max),
              !lines.contains(where: { $0.contains(" developer/") }) else { throw fail("developer offer needs a fresh package and newer serial") }
        let binaries = try validatedBinaries(payload: payload)
        var count = lines.filter { ["file", "hook", "job"].contains(String($0.split(separator: " ").first ?? "")) }.count
        let hooks = lines.filter { $0.hasPrefix("hook ") }.count
        guard count + binaries.count + 5 <= 64, hooks + binaries.count + 2 <= 32 else { throw fail("developer tools exceed guest-package loader limits") }
        let keyDirectory = state.appendingPathComponent(instance.uuidString.lowercased(), isDirectory: true)
        try fm.createDirectory(at: keyDirectory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: keyDirectory.path)
        let client = keyDirectory.appendingPathComponent("id_ecdsa")
        if authorizedPublicKey == nil && !fm.fileExists(atPath: client.path) {
            try generateKey(client)
        }
        let loginKey = try authorizedPublicKey ?? publicKey(for: client)
        let fields = loginKey.split(whereSeparator: { $0 == " " || $0 == "\t" })
        guard !loginKey.contains("\n"), !loginKey.contains("\r"), fields.count >= 2,
              ["ecdsa-sha2-nistp256", "ssh-ed25519"].contains(String(fields[0])),
              let decoded = Data(base64Encoded: String(fields[1])), decoded.count >= 32 else {
            throw fail("supply one ECDSA P-256 or Ed25519 authorized public key")
        }
        let key = keyDirectory.appendingPathComponent("ssh_host_ecdsa_key")
        if !fm.fileExists(atPath: key.path) {
            try generateKey(key)
        }
        let keyValues = try key.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard keyValues.isRegularFile == true, keyValues.isSymbolicLink != true else { throw fail("host private key must be a regular file") }
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: key.path)
        let privateKey = try Data(contentsOf: key)
        guard privateKey.starts(with: Data("-----BEGIN EC PRIVATE KEY-----".utf8)) else { throw fail("legacy sshd requires a PEM ECDSA host key") }
        let publicKey = try publicKey(for: key)
        let knownHosts = keyDirectory.appendingPathComponent("known_hosts")
        let pin = "lighttouch-" + instance.uuidString.lowercased() + " " + publicKey + "\n"
        if fm.fileExists(atPath: knownHosts.path) {
            let existing = try String(contentsOf: knownHosts, encoding: .utf8)
            let trusted = existing.split(whereSeparator: { $0.isWhitespace })
            let expected = pin.split(whereSeparator: { $0.isWhitespace })
            guard existing.split(separator: "\n").count == 1, trusted.count >= 3,
                  Array(trusted.prefix(3)) == Array(expected.prefix(3)) else {
                throw fail("instance host-key pin differs; refusing to overwrite trusted keys")
            }
        } else { try Data(pin.utf8).write(to: knownHosts, options: .atomic) }
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: knownHosts.path)
        let prefix = "/usr/local/lighttouch/current/developer/"
        let config = """
        Port 22
        ListenAddress 127.0.0.1
        Protocol 2
        HostKey \(prefix)ssh_host_ecdsa_key
        AuthorizedKeysFile .ssh/lighttouch_authorized_keys
        PubkeyAuthentication yes
        PasswordAuthentication no
        ChallengeResponseAuthentication no
        PermitEmptyPasswords no
        PermitRootLogin without-password
        StrictModes yes
        UsePrivilegeSeparation no
        UseDNS no
        PidFile /var/run/lighttouch-sshd.pid
        Subsystem sftp /usr/libexec/sftp-server
        LogLevel VERBOSE

        """
        let job: [String: Any] = ["Label": "com.lighttouch.developer.sshd", "RunAtLoad": true, "KeepAlive": true,
            "ProgramArguments": ["/usr/sbin/sshd", "-D", "-e", "-f", prefix + "sshd_config"],
            "StandardErrorPath": "/private/var/log/lighttouch-sshd.log"]
        let jobData = try PropertyListSerialization.data(fromPropertyList: job, format: .xml, options: 0)
        // Prepare everything before changing the offer; loader verifies each hash.
        var extra: [(String, Data, String, String?)] = binaries.map { ("developer/" + $0.0.replacingOccurrences(of: "/", with: "_"), $0.1, "0755", "/" + $0.0) }
        extra += [("developer/sh", binaries.first(where: { $0.0 == "bin/bash" })!.1, "0755", "/bin/sh"),
                  ("developer/ssh_host_ecdsa_key", privateKey, "0600", nil),
                  ("developer/authorized_keys", Data((loginKey + "\n").utf8), "0600", "/private/var/root/.ssh/lighttouch_authorized_keys"),
                  ("developer/sshd_config", Data(config.utf8), "0600", nil),
                  ("developer/sshd.plist", jobData, "0644", nil)]
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: offer.path)
        for (path, data, mode, target) in extra {
            let file = offer.appendingPathComponent(path)
            try fm.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try data.write(to: file, options: .atomic)
            try fm.setAttributes([.posixPermissions: mode == "0600" ? 0o600 : 0o700], ofItemAtPath: file.path)
            let kind = target == nil ? (path.hasSuffix(".plist") ? "job" : "file") : "hook"
            lines.append("\(kind) \(count) \(path) \(mode) \(data.count) \(hash(data))" + (target.map { " " + $0 } ?? ""))
            count += 1
        }
        lines[serialIndex] = "serial \(serial) developer-openssh-6.7p1"
        try Data((lines.joined(separator: "\n") + "\n").utf8).write(to: offer.appendingPathComponent("offer"), options: .atomic)
        return Result(instance: instance, serial: serial, hostPublicKey: publicKey, payloadSource: source,
                      clientIdentity: authorizedPublicKey == nil ? client.path : nil)
    }
    /// Read-only audit for both composition and release packaging. Redistribution
    /// requires the exact qualified source/notice inventory as well as binaries.
    public static func audit(payload: URL, redistribution: Bool = false) throws {
        _ = try validatedBinaries(payload: payload)
        guard redistribution else { return }
        let fm = FileManager.default
        let allowed = Set(targets + ["developer-tools.json"])
        let root = payload.resolvingSymlinksInPath()
        guard let enumerator = fm.enumerator(atPath: root.path) else {
            throw fail("cannot enumerate developer payload")
        }
        var sourceLines: [String] = []
        for case let relative as String in enumerator {
            let file = root.appendingPathComponent(relative)
            let values = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .isDirectoryKey])
            guard values.isSymbolicLink != true else { throw fail("developer payload must not contain symlinks") }
            if values.isDirectory == true { continue }
            guard values.isRegularFile == true else { throw fail("developer payload must contain regular files") }
            if relative.hasPrefix("Sources/") || relative.hasPrefix("Licenses/") {
                let data = try Data(contentsOf: file)
                sourceLines.append("\(relative) \(hash(data))\n")
            } else if !allowed.contains(relative) {
                throw fail("unexpected developer resource (instance state must never ship): \(relative)")
            }
        }
        let inventory = Data(sourceLines.sorted().joined().utf8)
        guard hash(inventory) == "adeed55eec6ae871617d20c79b2200db9776e3a6fc4eb9dddfd6600a73d8db90" else {
            throw fail("developer redistribution sources or notices are missing or changed")
        }
    }

    private static func validatedBinaries(payload: URL) throws -> [(String, Data)] {
        let manifest = try JSONDecoder().decode(BundleManifest.self, from: Data(contentsOf: payload.appendingPathComponent("developer-tools.json")))
        guard manifest.source == source, manifest.files == expectedHashes else { throw fail("developer bundle does not match the supported upstream payload") }
        var binaries: [(String, Data)] = []
        for target in targets {
            let file = payload.appendingPathComponent(target)
            let values = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard values.isRegularFile == true, values.isSymbolicLink != true else { throw fail("developer payload must be regular files") }
            let data = try Data(contentsOf: file)
            guard hash(data) == manifest.files[target], data.count <= 16 * 1024 * 1024 else { throw fail("developer payload hash mismatch: \(target)") }
            binaries.append((target, data))
        }
        return binaries
    }

    private static func publicKey(for key: URL) throws -> String {
        let values = try key.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true else { throw fail("instance private key must be a regular file") }
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: key.path)
        let task = Process(), output = Pipe()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/ssh-keygen")
        task.arguments = ["-y", "-f", key.path]
        task.standardOutput = output
        try task.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        guard task.terminationStatus == 0, let text = String(data: data, encoding: .utf8) else { throw fail("cannot derive instance public key") }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    private static func generateKey(_ key: URL) throws {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/ssh-keygen")
        task.arguments = ["-q", "-t", "ecdsa", "-b", "256", "-m", "PEM", "-N", "", "-f", key.path]
        task.standardOutput = FileHandle.nullDevice
        try task.run(); task.waitUntilExit()
        guard task.terminationStatus == 0 else { throw fail("instance key generation failed") }
    }

}
