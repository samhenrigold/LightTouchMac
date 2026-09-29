// Archive: IPSW member access through ZIPFoundation (zip64 included: the central directory is read once per call).
//
//   let ipsw = IPSWArchive(url)
//   try ipsw.names()                        // every member path
//   try ipsw.contains("BuildManifest.plist")
//   try ipsw.read("Restore.plist")          // small members, into memory
//   try ipsw.extract("018-8370-001.dmg", to: file)   // large members, streamed to disk
//   try ipsw.stream("018-8370-001.dmg") { handle in ... }  // or read straight off a pipe
//
// Errors are FirmwareError, shared by every FirmwareKit module; `code` is the preparer contract's
// error code (docs/multi-device-plan.md, "Preparer contract").

import Foundation
import ZIPFoundation

public struct FirmwareError: Error, CustomStringConvertible, Sendable {
    public enum Code: String, Sendable { case keyMissing = "key_missing", shaMismatch = "sha_mismatch", unsupported, activationFailed = "activation_failed",
                                           oneshotFailed = "oneshot_failed", diskFull = "disk_full", `internal` }
    public var code: Code
    public var message: String
    public init(_ code: Code, _ message: String) { self.code = code; self.message = message }
    public var description: String { "\(code.rawValue): \(message)" }
}

final class StreamFailure: @unchecked Sendable { var error: Error? }

public struct IPSWArchive: Sendable {
    public let url: URL
    public init(_ url: URL) { self.url = url }

    /// unzip's output buffer: the same write pattern lays a file extracted into a mounted volume out the same way
    /// (the kernelcache; HFS+ allocates per write), which the golden store hashes depend on.
    static let chunk = 1 << 15

    public func names() throws -> [String] { try archive().map(\.path) }

    public func contains(_ member: String) throws -> Bool { try archive()[member] != nil }

    public func read(_ member: String) throws -> Data {
        var out = Data()
        try each(member) { out.append($0) }
        return out
    }

    /// Streams `member` to `file` (created or truncated) without holding it in memory.
    public func extract(_ member: String, to file: URL) throws {
        guard FileManager.default.createFile(atPath: file.path, contents: nil) else {
            throw FirmwareError(.internal, "cannot create \(file.path)")
        }
        let out = try FileHandle(forWritingTo: file)
        defer { try? out.close() }
        try each(member) { try out.write(contentsOf: $0) }
    }

    /// Runs `body` with a handle reading `member` off a pipe (a thread inflates into it); `body` should read to EOF.
    public func stream<T>(_ member: String, _ body: (FileHandle) throws -> T) throws -> T {
        let archive = try archive(), entry = try entry(member, in: archive)
        let pipe = Pipe()
        let failure = StreamFailure(), done = DispatchSemaphore(value: 0)
        Thread.detachNewThread {
            let w = pipe.fileHandleForWriting
            do { _ = try archive.extract(entry, bufferSize: Self.chunk, skipCRC32: true) { try w.write(contentsOf: $0) } }
            catch { failure.error = error }   // EPIPE when body stopped reading: body's error wins below
            try? w.close()
            done.signal()
        }
        let result = Result { try body(pipe.fileHandleForReading) }
        try? pipe.fileHandleForReading.close()
        done.wait()
        let value = try result.get()
        if let error = failure.error { throw FirmwareError(.unsupported, "\(url.lastPathComponent): could not read \(member): \(error)") }
        return value
    }

    func each(_ member: String, _ consumer: (Data) throws -> Void) throws {
        let archive = try archive()
        do { _ = try archive.extract(try entry(member, in: archive), bufferSize: Self.chunk, consumer: consumer) }
        catch let e as Archive.ArchiveError { throw FirmwareError(.unsupported, "\(url.lastPathComponent): could not read \(member): \(e)") }
    }

    func archive() throws -> Archive {
        do { return try Archive(url: url, accessMode: .read) }
        catch { throw FirmwareError(.unsupported, "\(url.lastPathComponent): not a zip archive (\(error))") }
    }

    func entry(_ member: String, in archive: Archive) throws -> Entry {
        guard let e = archive[member] else { throw FirmwareError(.unsupported, "\(url.lastPathComponent): no member \(member)") }
        return e
    }
}
