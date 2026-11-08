// Original IPSWs contain either an encrcdsa root image or an unencrypted UDIF.
// Detect on the stream: clear images need no key and encrypted images retain VFDecrypt's validation.
import BinaryParsing
import Foundation

enum RootFilesystemImage {
    static func extract(from fd: Int32, output: URL, key: () throws -> Data) throws {
        var header = [UInt8](repeating: 0, count: 256)
        guard VFDecrypt.readFully(fd, &header, 0, header.count) == header.count else {
            throw FirmwareError(.unsupported, "short root filesystem image")
        }
        var complete = false
        defer { if !complete { try? FileManager.default.removeItem(at: output) } }
        if header.starts(with: "encrcdsa".utf8) {
            try VFDecrypt.decrypt(from: fd, header: header, output: output, key: key())
        } else {
            guard FileManager.default.createFile(atPath: output.path, contents: nil) else {
                throw FirmwareError(.internal, "cannot create \(output.path)")
            }
            let out = try FileHandle(forWritingTo: output)
            defer { try? out.close() }
            try out.write(contentsOf: header)
            var buffer = [UInt8](repeating: 0, count: 1 << 16)
            while true {
                let n = read(fd, &buffer, buffer.count)
                if n < 0, errno == EINTR { continue }
                guard n >= 0 else { throw FirmwareError(.unsupported, "cannot read root filesystem image") }
                if n == 0 { break }
                try out.write(contentsOf: buffer.prefix(n))
            }
            // Check the container before admitting a keyless image. The normal UDIF extraction step
            // subsequently validates block tables, compression and partition boundaries.
            let input = try FileHandle(forReadingFrom: output)
            defer { try? input.close() }
            let size = try input.seekToEnd()
            guard size >= 512 else { throw FirmwareError(.unsupported, "short UDIF root filesystem") }
            try input.seek(toOffset: size - 512)
            let trailer = try input.read(upToCount: 512) ?? Data()
            try parsing(trailer, "root filesystem UDIF trailer") { s in
                guard trailer.starts(with: "koly".utf8) else {
                    throw FirmwareError(.unsupported, "root filesystem is neither encrcdsa nor UDIF")
                }
                try s.seek(toAbsoluteOffset: 4)
                guard try UInt32(parsingBigEndian: &s) == 4,
                    try UInt32(parsingBigEndian: &s) == 512
                else { throw FirmwareError(.unsupported, "unsupported root filesystem UDIF header") }
                try s.seek(toAbsoluteOffset: 0xD8)
                let xmlAt = try UInt64(parsingBigEndian: &s)
                let xmlLength = try UInt64(parsingBigEndian: &s)
                guard xmlLength > 0, xmlAt < size - 512, xmlLength <= size - 512 - xmlAt else {
                    throw FirmwareError(.unsupported, "root filesystem UDIF XML is outside the image")
                }
            }
        }
        complete = true
    }
}
