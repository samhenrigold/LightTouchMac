import Foundation
import Testing

@testable import FirmwareKit

struct A6RestoreCacheTests {
    @Test(
        .enabled(
            if: ProcessInfo.processInfo.environment["FK_A6_CACHE_LIBRARY_14G61"] != nil
                && ProcessInfo.processInfo.environment["FK_A6_CACHE_WORKER"] != nil,
            "Set paths to original iOS 10 restore library and source-built worker"))
    func admitsOriginalIOS10Library() throws {
        let env = ProcessInfo.processInfo.environment
        let library = try Data(contentsOf: URL(fileURLWithPath: #require(env["FK_A6_CACHE_LIBRARY_14G61"])))
        let helper = try Data(contentsOf: URL(fileURLWithPath: #require(env["FK_A6_CACHE_WORKER"])))
        try A6RestoreCache.validate(plan: plan("14G61"), originalLibrary: library, helper: helper)
        var stale = helper
        let marker = try #require(stale.range(of: Data("it_mobilegestalt_container_v1\0".utf8)))
        stale.replaceSubrange(marker, with: Data(repeating: 0x78, count: marker.count))
        #expect(throws: FirmwareError.self) {
            try A6RestoreCache.validate(plan: plan("14G61"), originalLibrary: library, helper: stale)
        }
        var unreadable = helper
        let readableMarker = try #require(unreadable.range(of: Data("it_mobilegestalt_readable_cache_v1\0".utf8)))
        unreadable.replaceSubrange(readableMarker, with: Data(repeating: 0x78, count: readableMarker.count))
        #expect(throws: FirmwareError.self) {
            try A6RestoreCache.validate(plan: plan("14G61"), originalLibrary: library, helper: unreadable)
        }
        #expect(throws: FirmwareError.self) {
            try A6RestoreCache.validate(plan: plan("13A344"), originalLibrary: library, helper: helper)
        }
    }
    private func plan(_ build: String = "12A365", value: Any = true) throws -> Data {
        try PropertyListSerialization.data(
            fromPropertyList: ["Build": build, "Overrides": ["test-policy": value]], format: .binary, options: 0)
    }

    @Test func rejectsUnqualifiedBuildAndNonBooleanPolicy() throws {
        #expect(throws: FirmwareError.self) {
            try A6RestoreCache.validate(plan: plan("13A000"), originalLibrary: Data(), helper: Data())
        }
        #expect(throws: FirmwareError.self) {
            try A6RestoreCache.validate(plan: plan(value: "true"), originalLibrary: Data(), helper: Data())
        }
    }

    @Test func rejectsUnknownRestoreLibrary() throws {
        #expect(throws: FirmwareError.self) {
            try A6RestoreCache.validate(plan: plan(), originalLibrary: Data(), helper: Data())
        }
    }

    @Test(
        .enabled(
            if: ProcessInfo.processInfo.environment["FK_A6_CACHE_LIBRARY_12A365"] != nil
                && ProcessInfo.processInfo.environment["FK_A6_CACHE_WORKER"] != nil,
            "Set paths to original restore library and source-built worker"))
    func admitsQualifiedInputsAndRejectsWrongHelper() throws {
        let env = ProcessInfo.processInfo.environment
        let library = try Data(contentsOf: URL(fileURLWithPath: #require(env["FK_A6_CACHE_LIBRARY_12A365"])))
        let helper = try Data(contentsOf: URL(fileURLWithPath: #require(env["FK_A6_CACHE_WORKER"])))
        try A6RestoreCache.validate(plan: plan(), originalLibrary: library, helper: helper)
        #expect(throws: FirmwareError.self) {
            try A6RestoreCache.validate(plan: plan(), originalLibrary: library, helper: Data())
        }
        var wrongArchitecture = helper
        wrongArchitecture[4] = 7  // x86 rather than ARM
        #expect(throws: FirmwareError.self) {
            try A6RestoreCache.validate(plan: plan(), originalLibrary: library, helper: wrongArchitecture)
        }
    }

    @Test(
        .enabled(
            if: ProcessInfo.processInfo.environment["FK_A6_CACHE_LIBRARY_13A344"] != nil
                && ProcessInfo.processInfo.environment["FK_A6_CACHE_WORKER"] != nil,
            "Set paths to original iOS 9 restore library and source-built worker"))
    func ios9RejectsWorkerWithoutPrivateMappingEntitlement() throws {
        let env = ProcessInfo.processInfo.environment
        let library = try Data(contentsOf: URL(fileURLWithPath: #require(env["FK_A6_CACHE_LIBRARY_13A344"])))
        let helper = try Data(contentsOf: URL(fileURLWithPath: #require(env["FK_A6_CACHE_WORKER"])))
        try A6RestoreCache.validate(plan: plan("13A344"), originalLibrary: library, helper: helper)
        var stale = helper
        let key = try #require(stale.range(of: Data("get-task-allow".utf8)))
        stale.replaceSubrange(key, with: Data(repeating: 0x78, count: key.count))
        #expect(throws: FirmwareError.self) {
            try A6RestoreCache.validate(plan: plan("13A344"), originalLibrary: library, helper: stale)
        }
        let signature = try #require(MachOSignature.codeSignature(in: helper))
        var truncated = helper
        truncated.removeSubrange(signature.offset..<truncated.count)
        #expect(throws: FirmwareError.self) {
            try A6RestoreCache.validate(plan: plan("13A344"), originalLibrary: library, helper: truncated)
        }
    }
}
