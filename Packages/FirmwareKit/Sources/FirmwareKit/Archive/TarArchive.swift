// TarArchive: the members of a tar archive (ustar, with GNU long names and pax path records; gzip-compressed or
// not), and their extraction into a volume through HFSPlusWriter as the kernel route leaves it (MountedVolume.extract:
// `/usr/bin/tar -xkf` run by an ordinary user into a host folder, merged in file by file): nothing that exists is
// replaced or changed (existing folders included), permission bits less the set-ID and sticky bits and the umask,
// files' and new folders' modification dates restored (symlinks and owners take the writer's), a hard link a copy
// of its file.
//
//   let n = try TarArchive(contentsOf: bootstrap).extract(into: writer, excluding: ["private/var/stash"])

import BinaryParsing
import Foundation
import zlib

struct TarArchive {
    struct Member: Equatable {
        enum Kind: Equatable { case file, directory, symlink, hardLink }
        var path: String  // volume-relative: no leading ./ or /, no trailing /
        var kind: Kind
        var mode: UInt16
        var link: String
        var data: Data
        /// mtime, seconds since 1970.
        var modified: Double = 0
    }

    let members: [Member]

    init(contentsOf url: URL) throws { try self.init(try Data(contentsOf: url)) }

    /// `limit`: the most a gzip-compressed archive may inflate to.
    init(_ archive: Data, limit: Int = .max) throws {
        let bytes = archive.starts(with: [0x1F, 0x8B]) ? try Self.gunzip(archive, limit: limit) : archive
        members = try parsing(bytes, "tar") { input in try Self.members(&input) }
    }

    /// 512-byte headers, each followed by its member's content padded to a 512-byte multiple.
    static func members(_ input: inout ParserSpan) throws -> [Member] {
        var out: [Member] = []
        var longName: String?
        var longLink: String?
        var paxModified: Double?
        while input.count >= 512 {
            let h = try [UInt8](parsing: &input, byteCount: 512)
            if h.allSatisfy({ $0 == 0 }) { break }
            func field(_ o: Int, _ n: Int) -> String {
                String(decoding: h[o..<o + n].prefix { $0 != 0 }, as: UTF8.self)
            }
            func octal(_ o: Int, _ n: Int) -> Int {
                Int(field(o, n).trimmingCharacters(in: .whitespaces), radix: 8) ?? 0
            }
            let size = octal(124, 12)
            let type = h[156]
            guard size >= 0, size <= input.count else { throw FirmwareError(.unsupported, "tar: truncated member") }
            let body = try Data(parsing: &input, byteCount: size)
            try input.seek(toRelativeOffset: min((512 - size % 512) % 512, input.count))
            let text = { String(decoding: body.prefix { $0 != 0 }, as: UTF8.self) }
            switch type {
            case UInt8(ascii: "L"):
                longName = text()
                continue
            case UInt8(ascii: "K"):
                longLink = text()
                continue
            case UInt8(ascii: "x"):
                for (k, v) in Self.pax(String(decoding: body, as: UTF8.self)) {
                    if k == "path" { longName = v }
                    if k == "linkpath" { longLink = v }
                    if k == "mtime" { paxModified = Double(v) }
                }
                continue
            case UInt8(ascii: "g"): continue
            default: break
            }
            let prefix = field(345, 155)
            let name = longName ?? (prefix.isEmpty ? field(0, 100) : prefix + "/" + field(0, 100))
            let link = longLink ?? field(157, 100)
            let modified = paxModified ?? Double(octal(136, 12))
            longName = nil
            longLink = nil
            paxModified = nil
            let kind: Member.Kind
            switch type {
            case 0, UInt8(ascii: "0"), UInt8(ascii: "7"): kind = .file
            case UInt8(ascii: "5"): kind = .directory
            case UInt8(ascii: "2"): kind = .symlink
            case UInt8(ascii: "1"): kind = .hardLink
            default: throw FirmwareError(.unsupported, "tar: \(name): member type \(Character(Unicode.Scalar(type)))")
            }
            out.append(
                Member(
                    path: Self.volumePath(name),
                    kind: kind,
                    mode: UInt16(octal(100, 8) & 0o7777),
                    link: kind == .hardLink ? Self.volumePath(link) : link,
                    data: kind == .file ? body : Data(),
                    modified: modified
                )
            )
        }
        return out
    }

    /// A member name as a volume path: no leading ./ or /, no trailing /.
    static func volumePath(_ name: String) -> String {
        var s = Substring(name)
        while s.hasPrefix("./") || s.hasPrefix("/") { s = s.dropFirst(s.hasPrefix("/") ? 1 : 2) }
        return s == "." ? "" : String(s).trimmingCharacters(in: ["/"])
    }

    static func pax(_ text: String) -> [(String, String)] {
        text.split(separator: "\n").compactMap { line in
            guard let sp = line.firstIndex(of: " "), let eq = line[sp...].firstIndex(of: "=") else { return nil }
            return (String(line[line.index(after: sp)..<eq]), String(line[line.index(after: eq)...]))
        }
    }

    static func gunzip(_ gz: Data, limit: Int = .max) throws -> Data {
        var s = z_stream()
        guard inflateInit2_(&s, 16 + MAX_WBITS, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK else {
            throw FirmwareError(.internal, "inflateInit2")
        }
        defer { inflateEnd(&s) }
        var out = Data()
        var input = [UInt8](gz)
        var buf = [UInt8](repeating: 0, count: 1 << 20)
        var status = Z_OK
        input.withUnsafeMutableBufferPointer { inp in
            s.next_in = inp.baseAddress
            s.avail_in = uInt(inp.count)
            while status == Z_OK {
                buf.withUnsafeMutableBufferPointer { b in
                    s.next_out = b.baseAddress
                    s.avail_out = uInt(b.count)
                    status = inflate(&s, Z_NO_FLUSH)
                }
                out.append(contentsOf: buf.prefix(buf.count - Int(s.avail_out)))
                if out.count > limit { status = Z_BUF_ERROR }
            }
        }
        guard out.count <= limit else { throw FirmwareError(.unsupported, "tar: more than \(limit) bytes inflated") }
        guard status == Z_STREAM_END else { throw FirmwareError(.unsupported, "tar: bad gzip data") }
        return out
    }

    /// Extracts every member not at or under an `excluding` path, keeping whatever exists; returns the number
    /// of members extracted.
    @discardableResult
    func extract(into w: HFSPlusWriter, excluding: [String] = []) throws -> Int {
        let permissions = { (mode: UInt16) in mode & 0o777 & ~HFSPlusWriter.creationMask }
        var n = 0
        let kept = { (path: String) in !excluding.contains { path == $0 || path.hasPrefix($0 + "/") } }
        var files: [String: Member] = [:]
        var folders: [Member] = []
        for e in members where !e.path.isEmpty && kept(e.path) {
            if e.kind == .file { files[e.path] = e }
            guard !w.exists(e.path) else { continue }
            let parent = (e.path as NSString).deletingLastPathComponent
            if !parent.isEmpty { try w.makeDirectory(parent) }
            switch e.kind {
            case .directory:
                try w.makeDirectory(e.path, mode: permissions(e.mode))
                folders.append(e)
            case .file:
                try w.put(e.data, at: e.path, mode: permissions(e.mode))
                try w.setModified(e.path, Date(timeIntervalSince1970: e.modified))
            case .symlink: try w.makeSymlink(e.path, to: e.link)
            case .hardLink:
                // a copy of the file it names, as the kernel route's host extraction merged in file by file
                // (MountedVolume.extract) leaves it
                guard let target = files[e.link] else {
                    try w.link(e.path, to: e.link)
                    break
                }
                try w.put(target.data, at: e.path, mode: permissions(target.mode))
                try w.setModified(e.path, Date(timeIntervalSince1970: target.modified))
            }
            n += 1
        }
        // the folders' dates last, once their contents are in (a write into a folder dates it)
        for f in folders {
            try w.setModified(f.path, Date(timeIntervalSince1970: f.modified))
        }
        return n
    }
}
