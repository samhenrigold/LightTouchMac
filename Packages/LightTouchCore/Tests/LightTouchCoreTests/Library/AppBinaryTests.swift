import Foundation
import HostRuntime
import HostServiceWire
import Testing

@testable import LightTouchCore

/// An app's binary is read on the Mac before anything is sent: a copy that is still encrypted, or has no slice the
/// device's processor runs, is refused with its reason instead of uploading, installing and dying at launch
/// (AppBinary, AppInstallPipeline).
struct AppBinaryTests {
    /// A 32-bit ARM Mach-O header with a segment command, then LC_ENCRYPTION_INFO when `cryptid` is given.
    static func machO(subtype: UInt32, cryptid: UInt32? = nil, cputype: UInt32 = 12) -> Data {
        var commands: [UInt32] = [1, 56] + Array(repeating: 0, count: 12)
        if let cryptid { commands += [0x21, 20, 4096, 4096, cryptid] }
        let header: [UInt32] = [0xfeed_face, cputype, subtype, 2, cryptid == nil ? 1 : 2, UInt32(commands.count * 4), 0]
        return (header + commands).reduce(into: Data()) { data, word in
            withUnsafeBytes(of: word.littleEndian) { data.append(contentsOf: $0) }
        }
    }

    /// A fat file of `slices`, each at its own 128 KiB boundary (past one inflate chunk).
    static func fat(_ slices: [(cputype: UInt32, subtype: UInt32, image: Data)]) -> Data {
        var data = Data()
        func big(_ word: UInt32) { withUnsafeBytes(of: word.bigEndian) { data.append(contentsOf: $0) } }
        big(0xcafe_babe)
        big(UInt32(slices.count))
        for (index, slice) in slices.enumerated() {
            for word in [slice.cputype, slice.subtype, UInt32(index + 1) << 17, UInt32(slice.image.count), 12] {
                big(word)
            }
        }
        for (index, slice) in slices.enumerated() {
            data.append(Data(count: (index + 1) << 17 - data.count))
            data.append(slice.image)
        }
        return data
    }

    static func slices(_ binary: Data) -> [AppBinary.Slice]? {
        AppBinary.slices { range in
            range.lowerBound <= binary.count ? binary[range.clamped(to: 0..<binary.count)] : nil
        }
    }

    @Test func aThinBinarysSliceAndEncryptionAreRead() {
        #expect(Self.slices(Self.machO(subtype: 6)) == [.init(subtype: 6, isEncrypted: false)])
        #expect(Self.slices(Self.machO(subtype: 9, cryptid: 1)) == [.init(subtype: 9, isEncrypted: true)])
        #expect(Self.slices(Self.machO(subtype: 9, cryptid: 0)) == [.init(subtype: 9, isEncrypted: false)])
    }

    @Test func aFatBinarysARMSlicesAreReadAndItsOthersLeftOut() {
        let binary = Self.fat([
            (0x0100_000c, 0, Data(repeating: 0xcf, count: 64)),
            (12, 9, Self.machO(subtype: 9, cryptid: 1)),
            (12, 11, Self.machO(subtype: 11, cryptid: 0))
        ])
        #expect(
            Self.slices(binary) == [.init(subtype: 9, isEncrypted: true), .init(subtype: 11, isEncrypted: false)]
        )
    }

    @Test func aBinaryWithNo32BitARMSliceHasNone() {
        #expect(Self.slices(Data([0xcf, 0xfa, 0xed, 0xfe]) + Data(count: 60)) == [])
        #expect(Self.slices(Self.machO(subtype: 3, cputype: 7)) == [])
    }

    @Test func whatIsNotAReadableMachOHasNoVerdict() {
        #expect(Self.slices(Data("#!/bin/sh\n".utf8)) == nil)
        #expect(Self.slices(Data()) == nil)
        #expect(Self.slices(Self.machO(subtype: 9, cryptid: 1).dropLast(8)) == nil)
        var wrapping = Self.machO(subtype: 9)
        wrapping.replaceSubrange(32..<36, with: [0, 0, 0, 0])  // a load command of size 0
        #expect(Self.slices(wrapping) == nil)
        #expect(AppBinary.problem(nil, soc: .s5l8720, name: "X.ipa") == nil)
    }

    @Test func theSliceTheProcessorTakesDecides() {
        let v6 = AppBinary.Slice(subtype: 6, isEncrypted: false)
        let v7 = AppBinary.Slice(subtype: 9, isEncrypted: false)
        let v7Encrypted = AppBinary.Slice(subtype: 9, isEncrypted: true)
        let v7sEncrypted = AppBinary.Slice(subtype: 11, isEncrypted: true)
        func problem(_ slices: [AppBinary.Slice], _ soc: Board.SoC) -> String? {
            AppBinary.problem(slices, soc: soc, name: "X.ipa")
        }
        #expect(problem([v6], .s5l8720) == nil)
        #expect(problem([v6], .s5l8950) == nil)
        #expect(problem([.init(subtype: 0, isEncrypted: false)], .s5l8900) == nil)
        #expect(problem([v7], .s5l8720)?.contains("newer processor") == true)
        #expect(problem([v7], .s5l8930) == nil)
        #expect(problem([], .s5l8930)?.contains("32-bit") == true)
        // An armv6 iPod runs the decrypted v6 slice of a copy whose v7 slice is still encrypted; an iPhone 4 takes the v7.
        #expect(problem([v6, v7Encrypted], .s5l8720) == nil)
        #expect(problem([v6, v7Encrypted], .s5l8930)?.contains("encrypted") == true)
        // A copy decrypted on an older device keeps its v7s slice encrypted: only the iPhone 5 takes that one.
        #expect(problem([v7, v7sEncrypted], .s5l8920) == nil)
        #expect(problem([v7, v7sEncrypted], .s5l8950)?.contains("encrypted") == true)
    }

    func install(_ executable: Data, soc: Board.SoC) async throws -> (calls: [String], error: Error?) {
        try await withTemporaryState { dir in
            let ipa = dir.appendingPathComponent("x.ipa")
            try makeIPA(at: ipa, executable: executable)
            let services = AppInstallPipelineTests.Services(answersFrom: 1)
            let pipeline = AppInstallPipeline(
                services: services, agent: AppInstallPipelineTests.NoAgent(), deviceOS: "6.1.3", soc: soc)
            do {
                try await pipeline.install(ipa)
                return (services.calls, nil)
            } catch { return (services.calls, error) }
        }
    }

    @Test func anEncryptedCopyIsRefusedBeforeAnythingIsSent() async throws {
        let binary = Self.fat([(0x0100_000c, 0, Data(count: 64)), (12, 9, Self.machO(subtype: 9, cryptid: 1))])
        let (calls, error) = try await install(binary, soc: .s5l8930)
        guard case .preflight(let message)? = error as? DeviceError else {
            Issue.record("\(String(describing: error))")
            return
        }
        #expect(message.contains("still encrypted") && message.contains("x.ipa"))
        #expect(calls.isEmpty)
    }

    @Test func aCopyForANewerProcessorIsRefusedBeforeAnythingIsSent() async throws {
        let (calls, error) = try await install(Self.machO(subtype: 9, cryptid: 0), soc: .s5l8720)
        guard case .preflight(let message)? = error as? DeviceError else {
            Issue.record("\(String(describing: error))")
            return
        }
        #expect(message.contains("newer processor"))
        #expect(calls.isEmpty)
    }

    @Test func aDecryptedCopyTheProcessorRunsIsSent() async throws {
        let (calls, error) = try await install(Self.machO(subtype: 9, cryptid: 0), soc: .s5l8930)
        #expect(error == nil)
        #expect(calls == ["free", "stage", "install"])
    }
}
