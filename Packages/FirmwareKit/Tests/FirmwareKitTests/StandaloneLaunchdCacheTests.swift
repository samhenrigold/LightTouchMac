import Foundation
import Testing
@testable import FirmwareKit

struct StandaloneLaunchdCacheTests {
    @Test func rejectsMalformedContainers() {
        #expect(throws: (any Error).self) {
            try LaunchdCache.updatingStandalone(Data(repeating: 0, count: 64), jobs: [:], removing: [])
        }
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["FK_NATIVE_XPCD"] != nil,
                   "Optional original universal xpcd fixture"))
    func preservesNativeJobsArchitecturesAndSigningRepresentation() throws {
        let source = try #require(ProcessInfo.processInfo.environment["FK_NATIVE_XPCD"])
        let before = try Data(contentsOf: URL(fileURLWithPath: source))
        let key = "/System/Library/LaunchDaemons/com.qemu.it-agent.plist"
        let job: [String: Any] = ["Label": "com.qemu.it-agent", "ProgramArguments": ["/usr/local/bin/it_agent"],
                                  "RunAtLoad": true, "KeepAlive": true, "ProcessType": "Interactive", "ExecuteAllowed": true]
        let jobData = try PropertyListSerialization.data(fromPropertyList: job, format: .binary, options: 0)
        let after = try LaunchdCache.updatingStandalone(before, jobs: [key: jobData], removing: [])
        #expect(after.count == before.count)
        func be(_ offset: Int) -> Int {
            (0..<4).reduce(0) { $0 | Int(before[offset + $1]) << (24 - 8 * $1) }
        }
        #expect(before.prefix(8 + be(4) * 20) == after.prefix(8 + be(4) * 20))
        var updated = 0
        for index in 0..<be(4) {
            let arch = 8 + index * 20, start = be(arch + 8), size = be(arch + 12)
            let old = before.subdata(in: start..<(start + size)), new = after.subdata(in: start..<(start + size))
            if be(arch) != 12 || ![9, 11].contains(be(arch + 4)) {
                #expect(old == new)
                continue
            }
            let section = try #require(MachO(old).segments.flatMap(\.sections).first(where: { $0.name == "__xpcd_cache" }))
            let range = Int(section.offset)..<(Int(section.offset) + Int(section.size))
            let original = try #require(PropertyListSerialization.propertyList(from: old.subdata(in: range), format: nil) as? [String: Any])
            var changed = try #require(PropertyListSerialization.propertyList(from: new.subdata(in: range), format: nil) as? [String: Any])
            var daemons = try #require(changed["LaunchDaemons"] as? [String: Any])
            #expect(daemons[key] as? NSDictionary == job as NSDictionary)
            daemons[key] = (original["LaunchDaemons"] as? [String: Any])?[key]
            changed["LaunchDaemons"] = daemons
            #expect(changed as NSDictionary == original as NSDictionary)
            #expect(try Activation.signed(new, preservingEmptyCMS: true) == new)
            updated += 1
        }
        #expect(updated == 2)
        let removed = try LaunchdCache.updatingStandalone(after, jobs: [:], removing: [key])
        #expect(removed.count == before.count)
        #expect(throws: (any Error).self) {
            try LaunchdCache.updatingStandalone(before, jobs: ["/unrelated": jobData], removing: [])
        }
        if let output = ProcessInfo.processInfo.environment["FK_NATIVE_XPCD_OUTPUT"] {
            try after.write(to: URL(fileURLWithPath: output), options: .withoutOverwriting)
        }
    }
}
