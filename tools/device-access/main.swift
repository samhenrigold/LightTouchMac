// Developer access through stock OpenSSH/SFTP, libusbmuxd inetcat and QEMU GDB.
// Compile: swiftc tools/device-access/main.swift -o /tmp/ltm-device-access
import Foundation

struct AccessError: Error, CustomStringConvertible {
    let description: String
}
func fail(_ message: String) throws -> Never { throw AccessError(description: message) }
func sshLiteral(_ value: String) -> String { value.replacingOccurrences(of: "%", with: "%%") }
func shellQuote(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'" }
func endpoint(_ value: String) throws -> String {
    let parts = value.split(separator: ":", omittingEmptySubsequences: false)
    guard parts.count == 2, parts[0] == "127.0.0.1", let port = UInt16(parts[1]), port > 0 else {
        try fail("Endpoint must be 127.0.0.1:PORT (1–65535).")
    }
    return "127.0.0.1:\(port)"
}
func executable(_ value: String) throws -> String {
    guard value.hasPrefix("/"), !value.contains("\n"), !value.contains("\r"),
          FileManager.default.isExecutableFile(atPath: value) else {
        try fail("Tool must be an executable absolute path: \(value)")
    }
    return value
}
func run() throws -> Int32 {
    var args = Array(CommandLine.arguments.dropFirst())
    guard let mode = args.first, ["ssh", "sftp", "config", "gdb", "enable", "disable"].contains(mode) else {
        try fail("Usage: ltm-device-access {enable|disable|ssh|sftp|config|gdb} --instance UUID --usbmux 127.0.0.1:PORT --inetcat /path/to/inetcat [--identity /path/to/private-key] [--state /private/directory] [--gdb 127.0.0.1:PORT] [-- remote-command]")
    }
    args.removeFirst()
    var options: [String: String] = [:]
    var command: [String] = []
    while !args.isEmpty {
        let key = args.removeFirst()
        if key == "--" { command = args; break }
        guard ["--instance", "--usbmux", "--inetcat", "--identity", "--state", "--gdb", "--batch"].contains(key),
              !args.isEmpty, options[key] == nil else { try fail("Unknown, duplicate or incomplete option: \(key)") }
        options[key] = args.removeFirst()
    }
    guard let id = options["--instance"].flatMap(UUID.init(uuidString:)) else { try fail("A device instance UUID is required.") }
    guard command.isEmpty || mode == "ssh" else { try fail("Remote commands are supported only for ssh.") }
    if let supplied = options["--usbmux"] { _ = try endpoint(supplied) }
    if mode == "gdb", let supplied = options["--gdb"] {
        print("target remote \(try endpoint(supplied))")
        return 0
    }
    let alias = "lighttouch-" + id.uuidString.lowercased()
    if let directory = options["--state"], !directory.hasPrefix("/") {
        try fail("State directory must be an absolute path.")
    }
    let base = options["--state"].map { URL(fileURLWithPath: $0, isDirectory: true) }
        ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Light Touch/DeveloperSSH", isDirectory: true)
    guard base.path.hasPrefix("/"), !base.path.contains("\n"), !base.path.contains("\r") else { try fail("State directory must be an absolute path without newlines.") }
    let state = base.appendingPathComponent(id.uuidString.lowercased(), isDirectory: true)
    try FileManager.default.createDirectory(at: state, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: state.path)
    let profile = state.appendingPathComponent("connection.json")
    if FileManager.default.fileExists(atPath: profile.path), mode != "enable", mode != "disable" {
        struct Connection: Decodable { let instance: UUID; let usbmux: String; let inetcat: String; let gdb: String? }
        let connection = try JSONDecoder().decode(Connection.self, from: Data(contentsOf: profile))
        guard connection.instance == id else { try fail("Connection profile belongs to another instance.") }
        options["--usbmux"] = options["--usbmux"] ?? connection.usbmux
        options["--inetcat"] = options["--inetcat"] ?? connection.inetcat
        options["--gdb"] = options["--gdb"] ?? connection.gdb
    }
    if mode == "enable" || mode == "disable" {
        let marker = state.appendingPathComponent("enabled")
        if mode == "enable" {
            try Data("1\n".utf8).write(to: marker, options: .atomic)
            print("Developer SSH enabled; restart the device to provision its private keys and upstream tools.")
        } else {
            try? FileManager.default.removeItem(at: marker)
            print("Developer SSH disabled; restart the device to revert its package hooks and stop sshd.")
        }
        return 0
    }
    if mode == "gdb" {
        guard let address = options["--gdb"] else { try fail("Supply the actual enabled QEMU GDB stub with --gdb.") }
        print("target remote \(try endpoint(address))")
        return 0
    }
    guard let socket = options["--usbmux"], let tool = options["--inetcat"] else {
        try fail("Supply this instance’s private --usbmux endpoint and --inetcat executable.")
    }
    let socketAddress = try endpoint(socket)
    let inetcat = try executable(tool)
    let knownHosts = state.appendingPathComponent("known_hosts").path
    let proxy = "exec /usr/bin/env " + shellQuote("USBMUXD_SOCKET_ADDRESS=" + socketAddress) + " " + shellQuote(sshLiteral(inetcat)) + " -l %p"
    var sshOptions = ["HostName=localhost", "Port=22", "User=root", "HostKeyAlias=" + alias,
                      "UserKnownHostsFile=" + shellQuote(sshLiteral(knownHosts)), "StrictHostKeyChecking=" + (FileManager.default.fileExists(atPath: knownHosts) ? "yes" : "ask"),
                      "ProxyCommand=" + proxy, "ConnectTimeout=10", "ServerAliveInterval=15", "ServerAliveCountMax=2"]
    let provisionedIdentity = state.appendingPathComponent("id_ecdsa").path
    if let identity = options["--identity"] ?? (FileManager.default.fileExists(atPath: provisionedIdentity) ? provisionedIdentity : nil) {
        guard identity.hasPrefix("/"), !identity.contains("\n"), !identity.contains("\r"), FileManager.default.fileExists(atPath: identity) else {
            try fail("Identity must name an existing absolute private-key path.")
        }
        sshOptions += ["IdentityFile=" + shellQuote(sshLiteral(identity)), "IdentitiesOnly=yes", "PreferredAuthentications=publickey"]
    }
    if mode == "config" {
        print("Host \(alias)")
        for option in sshOptions {
            let pair = option.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            print("  \(pair[0]) \(pair[1])")
        }
        return 0
    }
    var batchArguments: [String] = []
    if let batch = options["--batch"] {
        guard mode == "sftp", batch.hasPrefix("/"), FileManager.default.isReadableFile(atPath: batch) else {
            try fail("--batch requires sftp and a readable absolute file path.")
        }
        batchArguments = ["-b", batch]
    }
    let child = Process()
    child.executableURL = URL(fileURLWithPath: mode == "ssh" ? "/usr/bin/ssh" : "/usr/bin/sftp")
    child.arguments = sshOptions.flatMap { ["-o", $0] } + batchArguments + [alias] + command
    // Standard clients own terminal I/O, authentication and the transfer protocol.
    child.standardInput = FileHandle.standardInput
    child.standardOutput = FileHandle.standardOutput
    child.standardError = FileHandle.standardError
    try child.run()
    child.waitUntilExit()
    return child.terminationStatus
}
do { exit(try run()) }
catch { FileHandle.standardError.write(Data(("ltm-device-access: \(error)\n").utf8)); exit(2) }
