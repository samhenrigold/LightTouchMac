import Foundation
import Testing
@testable import FirmwareKit

struct A6RestoreKernelTests {
    @Test func rejectsUnknownKernelForQualifiedBuild() {
        #expect(throws: FirmwareError.self) { try A6RestoreKernel.prepare(Data(), build: "12A365") }
    }
    @Test func leavesOtherBuildsUnchanged() throws {
        let input = Data([1, 2, 3])
        #expect(try A6RestoreKernel.prepare(input, build: "10A405") == input)
        #expect(try A6RestoreKernel.prepare(input, build: "13A344") == input)
    }
    @Test(.enabled(if: ProcessInfo.processInfo.environment["FK_A6_RESTORE_KERNEL_12A365"] != nil,
                   "Set FK_A6_RESTORE_KERNEL_12A365 to the original kernel"))
    func matchesNativeQualifiedWrapperAndPreservesEverythingElse() throws {
        let path = try #require(ProcessInfo.processInfo.environment["FK_A6_RESTORE_KERNEL_12A365"])
        let input = try Data(contentsOf: URL(fileURLWithPath: path))
        let output = try A6RestoreKernel.prepare(input, build: "12A365")
        #expect(Preparer.sha256(output) == "7dc389cd3641b807c1feeea2c0f68770d57effbef1e6e2ae733358fa8c81f304")
        #expect(output.count == input.count)
        #expect(throws: FirmwareError.self) { try A6RestoreKernel.prepare(output, build: "12A365") }
    }
}
