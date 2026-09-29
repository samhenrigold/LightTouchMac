// The built-in iPod: a `firmwarekit create` output packed as one blob in the
// app bundle (Resources/device/<entry>.itbase, made by scripts/pack-base.py),
// unpacked into Preparing/<id>/ on first launch and published like any other
// preparation (FirmwareJobs.prepareBundled). The format is the guest
// package's (.itpack): "ITPACK01", a little-endian u32 index length, a JSON
// index of the files in stream order, then one zlib stream of their bytes.
// Not an archive the notary opens, and read here as a stream: the pages of
// an iPod base never sit in memory at once.

import Compression
import Foundation

nonisolated enum BundledBase {
    static let magic = Data("ITPACK01".utf8)

    struct Index: Decodable {
        struct Entry: Decodable {
            var name: String
            var size: Int
            var mode: Int?
        }
        var entries: [Entry]
    }

    static func invalid(_ blob: URL, _ why: String) -> Error {
        CocoaError(.fileReadCorruptFile, userInfo: [NSFilePathErrorKey: blob.path, NSLocalizedDescriptionKey: "\(blob.lastPathComponent): \(why)"])
    }

    /// Unpacks `blob` into `directory` (created), reporting the fraction of
    /// bytes written about every percent. Nothing outside `directory` is
    /// written; a name that leaves it is refused before any file is made.
    static func unpack(_ blob: URL, into directory: URL, progress: (Double) -> Void = { _ in }) throws {
        let fm = FileManager.default
        let input = try FileHandle(forReadingFrom: blob)
        defer { try? input.close() }
        guard let head = try input.read(upToCount: 12), head.count == 12, head.prefix(8) == magic else {
            throw invalid(blob, "not a packed device")
        }
        let length = Int(head[8]) | Int(head[9]) << 8 | Int(head[10]) << 16 | Int(head[11]) << 24
        guard let indexData = try input.read(upToCount: length), indexData.count == length else { throw invalid(blob, "truncated index") }
        let entries = try JSONDecoder().decode(Index.self, from: indexData).entries
        for entry in entries where entry.size < 0 || entry.name.hasPrefix("/") || entry.name.isEmpty
            || entry.name.split(separator: "/", omittingEmptySubsequences: false).contains(where: { $0 == ".." || $0.isEmpty }) {
            throw invalid(blob, "bad entry \(entry.name)")
        }
        guard try input.read(upToCount: 2)?.count == 2 else { throw invalid(blob, "no stream") }   // zlib's header: Compression decodes raw deflate
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)

        let total = entries.reduce(0) { $0 + $1.size }
        let step = max(total / 100, 1)
        var written = 0, reported = 0
        var next = 0, remaining = 0
        var output: FileHandle?
        /// Opens the next entry with bytes to receive, creating every empty one on the way; false past the end.
        func open() throws -> Bool {
            while next < entries.count {
                let entry = entries[next]
                next += 1
                let url = directory.appendingPathComponent(entry.name)
                try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                // Written owner-writable; the packed mode (a read-only nor.bin) is set once it is complete.
                guard fm.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
                    throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: url.path])
                }
                if entry.size > 0 {
                    output = try FileHandle(forWritingTo: url)
                    remaining = entry.size
                    return true
                }
                chmod(url.path, mode_t(entry.mode ?? 0o644))
            }
            return false
        }
        func emit(_ bytes: UnsafeRawBufferPointer) throws {
            var offset = 0
            while offset < bytes.count {
                if remaining == 0 { guard try open() else { throw invalid(blob, "more data than its index names") } }
                let take = min(remaining, bytes.count - offset)
                try output?.write(contentsOf: Data(bytes[offset..<offset + take]))
                remaining -= take
                offset += take
                written += take
                if remaining == 0 {
                    try output?.close()
                    output = nil
                    chmod(directory.appendingPathComponent(entries[next - 1].name).path, mode_t(entries[next - 1].mode ?? 0o644))
                }
            }
            if written / step != reported { reported = written / step; progress(Double(written) / Double(max(total, 1))) }
        }

        let chunk = 1 << 20
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: chunk)
        defer { buffer.deallocate() }
        var stream = compression_stream(dst_ptr: buffer, dst_size: 0, src_ptr: UnsafePointer(buffer), src_size: 0, state: nil)
        guard compression_stream_init(&stream, COMPRESSION_STREAM_DECODE, COMPRESSION_ZLIB) == COMPRESSION_STATUS_OK else {
            throw invalid(blob, "decoder unavailable")
        }
        defer { compression_stream_destroy(&stream) }
        var finished = false
        while !finished {
            let source = try input.read(upToCount: chunk) ?? Data()
            let flags = source.isEmpty ? Int32(COMPRESSION_STREAM_FINALIZE.rawValue) : 0
            try source.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
                stream.src_ptr = raw.baseAddress?.assumingMemoryBound(to: UInt8.self) ?? UnsafePointer(buffer)
                stream.src_size = raw.count
                // The decoder hands out what it has in slices; ask again until it yields nothing
                // without input (more is needed), or the end of the stream.
                while true {
                    stream.dst_ptr = buffer
                    stream.dst_size = chunk
                    let status = compression_stream_process(&stream, flags)
                    guard status != COMPRESSION_STATUS_ERROR else { throw invalid(blob, "corrupt stream") }
                    let produced = chunk - stream.dst_size
                    try emit(UnsafeRawBufferPointer(start: buffer, count: produced))
                    if status == COMPRESSION_STATUS_END { finished = true; break }
                    if stream.src_size == 0, produced == 0 {
                        guard flags == 0 else { throw invalid(blob, "truncated stream") }
                        break
                    }
                }
            }
        }
        try output?.close()
        // Every named byte arrived, and the trailing empty files exist.
        guard remaining == 0, try !open() else { throw invalid(blob, "short file \(entries[next - 1].name)") }
        progress(1)
    }
}
