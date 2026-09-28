// Archive: IPSW member access through /usr/bin/unzip (no zip reader of our own).
//
//   let ipsw = IPSWArchive(url)
//   try ipsw.names()                        // every member path (unzip -Z1)
//   try ipsw.contains("BuildManifest.plist")
//   try ipsw.read("Restore.plist")          // small members, into memory
//   try ipsw.extract("018-8370-001.dmg", to: file)   // large members, streamed to disk
//   try ipsw.stream("018-8370-001.dmg") { handle in ... }  // or read straight off the pipe
//
// Errors are FirmwareError, shared by every FirmwareKit module; `code` is the preparer contract's
// error code (docs/multi-device-plan.md, "Preparer contract").

import Foundation

public struct FirmwareError: Error, CustomStringConvertible, Sendable {
    public enum Code: String, Sendable { case keyMissing = "key_missing", shaMismatch = "sha_mismatch", unsupported, hookFailed = "hook_failed",
                                           oneshotFailed = "oneshot_failed", diskFull = "disk_full", `internal` }
    public var code: Code
    public var message: String
    public init(_ code: Code, _ message: String) { self.code = code; self.message = message }
    public var description: String { "\(code.rawValue): \(message)" }
}

public struct IPSWArchive: Sendable {
    public let url: URL
    public init(_ url: URL) { self.url = url }

    public func names() throws -> [String] {
        String(decoding: try run(["-Z1", url.path]), as: UTF8.self).split(separator: "\n").map(String.init)
    }

    public func contains(_ member: String) throws -> Bool { try names().contains(member) }

    public func read(_ member: String) throws -> Data { try run(["-p", url.path, Self.literal(member)]) }

    /// Streams `member` to `file` (created or truncated) without holding it in memory.
    public func extract(_ member: String, to file: URL) throws {
        guard FileManager.default.createFile(atPath: file.path, contents: nil) else {
            throw FirmwareError(.internal, "cannot create \(file.path)")
        }
        let out = try FileHandle(forWritingTo: file)
        defer { try? out.close() }
        try run(["-p", url.path, Self.literal(member)], stdout: out)
    }

    /// Runs `body` with a handle reading `member` off unzip's stdout; `body` should read to EOF.
    public func stream<T>(_ member: String, _ body: (FileHandle) throws -> T) throws -> T {
        let pipe = Pipe()
        let p = process(["-p", url.path, Self.literal(member)], stdout: pipe.fileHandleForWriting)
        try p.run()
        try? pipe.fileHandleForWriting.close()
        let result: T
        do { result = try body(pipe.fileHandleForReading) } catch {
            p.terminate(); p.waitUntilExit(); throw error
        }
        _ = try? pipe.fileHandleForReading.readToEnd()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { throw FirmwareError(.unsupported, "\(url.lastPathComponent): unzip could not read \(member)") }
        return result
    }

    /// unzip treats member arguments as wildcards; bracket the wildcard characters.
    static func literal(_ member: String) -> String {
        member.map { "*?[".contains($0) ? "[\($0)]" : String($0) }.joined()
    }

    private func process(_ args: [String], stdout: FileHandle) -> Process {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        p.arguments = args
        p.standardOutput = stdout
        p.standardError = FileHandle.nullDevice
        return p
    }

    @discardableResult
    private func run(_ args: [String], stdout: FileHandle? = nil) throws -> Data {
        let pipe = Pipe()
        let p = process(args, stdout: stdout ?? pipe.fileHandleForWriting)
        try p.run()
        try? pipe.fileHandleForWriting.close()
        let data = stdout == nil ? (try pipe.fileHandleForReading.readToEnd() ?? Data()) : Data()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else {
            throw FirmwareError(.unsupported, "\(url.lastPathComponent): unzip \(args.first ?? "") \(args.last ?? "") failed (\(p.terminationStatus))")
        }
        return data
    }
}
