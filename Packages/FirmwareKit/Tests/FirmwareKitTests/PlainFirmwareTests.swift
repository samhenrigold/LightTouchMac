import Foundation
import Testing

@testable import FirmwareKit

struct PlainFirmwareTests {
    /// A generated IPSW with no keys: exercise the kernel route, not just the IMG3 reader.
    /// No Apple firmware or other binary fixtures are embedded in this test.
    @Test(arguments: [false, true]) func clearKernelStillRequiresValidChecksum(_ corrupt: Bool) throws {
        try Oracle.withTemp { dir in
            func word(_ value: UInt32, bigEndian: Bool = false) -> Data {
                let bytes = (0..<4).map { UInt8(truncatingIfNeeded: value >> ($0 * 8)) }
                return Data(bigEndian ? Array(bytes.reversed()) : bytes)
            }
            func img3(_ payload: Data) -> Data {
                let tag = Data("ATAD".utf8) + word(UInt32(12 + payload.count))
                    + word(UInt32(payload.count)) + payload
                return Data("3gmI".utf8) + word(UInt32(20 + tag.count)) + Data(count: 12) + tag
            }
            let plain = Data("abcdefgh".utf8)
            let stream = Data([0xFF]) + plain
            var kernel = Data("complzss".utf8)
                + word(corrupt ? 1 : Adler32.checksum(plain), bigEndian: true)
                + word(UInt32(plain.count), bigEndian: true) + word(UInt32(stream.count), bigEndian: true)
            kernel += Data(count: 0x180 - kernel.count)
            kernel += stream
            var manifest: [String: Any] = [:]
            for (_, component) in FirmwareDecryptor.components {
                let path = component + ".img3"
                try img3(component == "KernelCache" ? kernel : Data(component.utf8))
                    .write(to: dir.appendingPathComponent(path))
                manifest[component] = ["Info": ["Path": path]]
            }
            let build: [String: Any] = ["BuildIdentities": [[
                "Info": ["DeviceClass": "testap", "RestoreBehavior": "Erase"], "Manifest": manifest
            ]]]
            try PropertyListSerialization.data(fromPropertyList: build, format: .xml, options: 0)
                .write(to: dir.appendingPathComponent("BuildManifest.plist"))
            try K48Oracle.sh(["/usr/bin/zip", "-q", "fixture.ipsw", "BuildManifest.plist"]
                + FirmwareDecryptor.components.map { $0.1 + ".img3" }, cwd: dir)
            let entry = try JSONDecoder().decode(FirmwareEntry.self, from: Data(#"{"id":"clear-test","board":"testap","product_type":"test","version":"10.3.4","build":"test","status":"experimental","source":{"kind":"ipsw"},"keys":{},"emulator":{"min_protocol":1},"estimates":{"prepared_bytes":0,"peak_bytes":0,"seconds":0}}"#.utf8))
            let output = dir.appendingPathComponent("out")
            if corrupt {
                #expect(throws: FirmwareError.self) {
                    try FirmwareDecryptor.decrypt(ipsw: dir.appendingPathComponent("fixture.ipsw"),
                                                  entry: entry, into: output, rootfs: false)
                }
            } else {
                let result = try FirmwareDecryptor.decrypt(ipsw: dir.appendingPathComponent("fixture.ipsw"),
                                                          entry: entry, into: output, rootfs: false)
                #expect(!result.plainTail)
                #expect(try Data(contentsOf: output.appendingPathComponent("kernelcache.mach")) == plain)
                #expect(result.files.count == FirmwareDecryptor.components.count)
            }
        }
    }
}
