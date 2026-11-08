import Foundation
import Testing
@testable import FirmwareKit

struct ARMv7sFitTests {
    private func le(_ words: [UInt32]) -> Data {
        Data(words.flatMap { n in [UInt8(n & 255), UInt8(n >> 8 & 255), UInt8(n >> 16 & 255), UInt8(n >> 24)] })
    }
    private func thin(_ subtype: UInt32) -> Data {
        le([0xfeedface, 12, subtype, 6, 0, 0, 0])
    }
    @Test func cpuCompatibilityIsDirectional() {
        #expect(MachO32.slice(thin(11), arch: "armv7s")?.arch == "armv7s")
        #expect(MachO32.slice(thin(9), arch: "armv7s")?.arch == "armv7")
        #expect(MachO32.slice(thin(6), arch: "armv7s")?.arch == "armv6")
        #expect(MachO32.slice(thin(0), arch: "armv7s")?.arch == "arm")
        #expect(MachO32.slice(thin(11), arch: "armv7") == nil)
        #expect(MachO32.slice(thin(9), arch: "armv6") == nil)
    }
    @Test func fatImagePrefersNativeSliceOverCompatibleFirstEntry() {
        let words: [UInt32] = [0xcafebabe, 2, 12, 9, 48, 28, 0, 12, 11, 76, 28, 0]
        let header = Data(words.flatMap { n in [UInt8(n >> 24), UInt8(n >> 16 & 255), UInt8(n >> 8 & 255), UInt8(n & 255)] })
        let image = header + thin(9) + thin(11)
        #expect(MachO32.slice(image, arch: "armv7s")?.arch == "armv7s")
        #expect(MachO32.slice(image, arch: "armv7")?.arch == "armv7")
    }
}
