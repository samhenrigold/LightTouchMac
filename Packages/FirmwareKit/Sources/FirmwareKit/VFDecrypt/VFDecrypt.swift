// VFDecrypt: decrypt an Apple "encrcdsa" v2 disk image (an iOS rootfs DMG) with its known 36-byte key
// (AES-128 key + HMAC-SHA1 key); chunk n's IV = HMAC-SHA1(hmac_key, be32(n))[:16]. Ports imgtools/vfdecrypt.c.
//
//   try VFDecrypt.decrypt(input: encrypted, output: plain, key: key36)       // file to file
//   try VFDecrypt.decrypt(from: fd, output: plain, key: key36)               // any sequential fd (a pipe)
//   try ipsw.stream(osImage) { try VFDecrypt.decrypt(from: $0.fileDescriptor, output: plain, key: key36) }
//
// Streams in fixed-size chunks; the input is read once, front to back, so it can come straight off
// `unzip -p` without a temporary copy of the encrypted image.

import BinaryParsing
import Crypto
import Foundation

public enum VFDecrypt {
    public static func decrypt(input: URL, output: URL, key: Data) throws {
        let fd = open(input.path, O_RDONLY)
        guard fd >= 0 else { throw FirmwareError(.internal, "open \(input.path): \(String(cString: strerror(errno)))") }
        defer { close(fd) }
        try decrypt(from: fd, output: output, key: key)
    }

    public static func decrypt(from fd: Int32, output: URL, key: Data) throws {
        var header = [UInt8](repeating: 0, count: 0x100)
        guard readFully(fd, &header, 0, header.count) == header.count else {
            throw FirmwareError(.unsupported, "short encrcdsa header")
        }
        try decrypt(from: fd, header: header, output: output, key: key)
    }

    /// The caller has consumed exactly the first 256 bytes of a sequential input.
    static func decrypt(from fd: Int32, header: [UInt8], output: URL, key: Data) throws {
        guard key.count == 36 else {
            throw FirmwareError(.keyMissing, "vfdecrypt key must be 36 bytes, got \(key.count)")
        }
        let aesKey = key.prefix(16)
        // Keyed once; each chunk's IV copies the keyed state rather than hashing the key again.
        let keyed = HMAC<Insecure.SHA1>(key: SymmetricKey(data: key.dropFirst(16)))
        guard header.count == 0x100, header[0..<8].elementsEqual("encrcdsa".utf8) else {
            throw FirmwareError(.unsupported, "not encrcdsa")
        }
        // the block size (u32 at 52), the data's size and offset (u64s at 56 and 64), big-endian; an offset past
        // what an Int holds is refused
        let (bs, size, dataOffset) = try parsing(header, "encrcdsa header") { s in
            try s.seek(toAbsoluteOffset: 52)
            return (
                Int(try UInt32(parsingBigEndian: &s)), try UInt64(parsingBigEndian: &s),
                try Int(parsing: &s, storedAsBigEndian: UInt64.self)
            )
        }
        var left = size
        guard bs > 0, bs % 16 == 0, bs <= 1 << 24 else {
            throw FirmwareError(.unsupported, "encrcdsa block size \(bs)")
        }

        // Chunks are decrypted a batch at a time, one AES-CBC call per 64 KiB: CBC across a batch chains each chunk's
        // first block to the previous chunk's last ciphertext block instead of the chunk's own IV, so that block is
        // corrected afterwards (xor both). 64 KiB is a pipe's worth: the IPSW's unzip keeps writing while a batch
        // decrypts (a 1 MiB batch stalled it, 7% slower end to end than one chunk at a time).
        let batch = max(1, (1 << 16) / bs)
        // Position at the data: header bytes already read count toward it; skip forward, never back.
        var ct = [UInt8](repeating: 0, count: bs * batch)
        var carried = 0
        if dataOffset < 0x100 {
            carried = 0x100 - dataOffset
            ct.replaceSubrange(0..<carried, with: header[dataOffset..<0x100])
        } else {
            var skip = dataOffset - 0x100
            while skip > 0 {
                let n = readFully(fd, &ct, 0, min(skip, bs))
                guard n > 0 else { throw FirmwareError(.unsupported, "short image") }
                skip -= n
            }
        }

        guard FileManager.default.createFile(atPath: output.path, contents: nil),
            let out = FileHandle(forWritingAtPath: output.path)
        else {
            throw FirmwareError(.internal, "cannot create \(output.path)")
        }
        defer { try? out.close() }
        var n: UInt32 = 0
        while left > 0 {
            // Whole chunks up to the batch, never past the chunk holding the last byte (as one chunk at a time read).
            let want = min(batch, Int((left + UInt64(bs) - 1) / UInt64(bs))) * bs
            let r = carried + readFully(fd, &ct, carried, want - carried)
            carried = 0
            guard r > 0 else { throw FirmwareError(.unsupported, "short image") }
            guard r % 16 == 0 else {
                throw FirmwareError(
                    .unsupported,
                    "encrcdsa chunk \(n + UInt32(r / bs)) is \(r % bs) bytes, not whole AES blocks"
                )
            }
            let chunks = (r + bs - 1) / bs
            let ivs = (0..<chunks).map { i -> [UInt8] in
                let c = n + UInt32(i)
                var mac = keyed
                mac.update(data: [UInt8(c >> 24 & 0xFF), UInt8(c >> 16 & 0xFF), UInt8(c >> 8 & 0xFF), UInt8(c & 0xFF)])
                return Array(Data(mac.finalize()).prefix(16))
            }
            var pt = try AESCBC.crypt(Data(ct[0..<r]), iv: Data(ivs[0]), key: aesKey)
            pt.withUnsafeMutableBytes { p in
                for i in 1..<max(chunks, 1) {
                    for j in 0..<16 { p[i * bs + j] ^= ct[i * bs - 16 + j] ^ ivs[i][j] }
                }
            }
            let take = min(UInt64(r), left)
            try out.write(contentsOf: pt.prefix(Int(take)))
            left -= take
            n += UInt32(chunks)
        }
    }

    /// Reads until `count` bytes or EOF; returns the bytes read.
    static func readFully(_ fd: Int32, _ buf: inout [UInt8], _ at: Int, _ count: Int) -> Int {
        var got = 0
        buf.withUnsafeMutableBytes { p in
            guard let start = p.baseAddress else { return }  // an empty buffer holds nothing
            while got < count {
                let r = read(fd, start + at + got, count - got)
                if r > 0 { got += r } else if r < 0, errno == EINTR { continue } else { break }
            }
        }
        return got
    }
}
