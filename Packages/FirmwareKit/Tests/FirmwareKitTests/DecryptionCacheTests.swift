import Foundation
import Testing
@testable import FirmwareKit

struct DecryptionCacheTests {
    @Test func reuseInvalidationAndFailure() throws {
        try Oracle.withTemp { root in
            var entry = try Oracle.entry("k48ap-7B500")
            let identity = DecryptionCache.Identity(ipsw: "fixture", entry: entry)
            var runs = 0
            func produce(_ dir: URL) throws -> [String] {
                runs += 1
                try Data("firmware".utf8).write(to: dir.appendingPathComponent("iBoot.bin"))
                return ["iBoot.bin"]
            }
            let first = try DecryptionCache.resolve(root: root, identity: identity, produce: produce)
            let second = try DecryptionCache.resolve(root: root, identity: identity, produce: produce)
            #expect(first == second && runs == 1)
            entry.keys["fixture"] = .init(file: "fixture", iv: nil, key: "new-key")
            let changed = try DecryptionCache.resolve(root: root, identity: .init(ipsw: "fixture", entry: entry), produce: produce)
            #expect(changed != first && runs == 2)
            try Data().write(to: first.appendingPathComponent("iBoot.bin"))
            #expect(throws: CocoaError.self) {
                try DecryptionCache.resolve(root: root, identity: identity, produce: { _ in throw CocoaError(.fileReadCorruptFile) })
            }
            #expect(FileManager.default.fileExists(atPath: first.appendingPathComponent("manifest.json").path))
            _ = try DecryptionCache.resolve(root: root, identity: identity, produce: produce)
            #expect(runs == 3)
            try Data("corrupt!".utf8).write(to: first.appendingPathComponent("iBoot.bin"))
            _ = try DecryptionCache.resolve(root: root, identity: identity, produce: produce)
            #expect(runs == 4)
            #expect(try Data(contentsOf: first.appendingPathComponent("iBoot.bin")) == Data("firmware".utf8))
        }
    }

    @Test func concurrentProducersPublishOnce() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("decrypt-cache-test-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        do {
            let identity = DecryptionCache.Identity(ipsw: "fixture", entry: try Oracle.entry("k48ap-7B500"))
            final class Count: @unchecked Sendable {
                let lock = NSLock(); var value = 0
                func add() { lock.withLock { value += 1 } }
            }
            let count = Count()
            let results = try await withThrowingTaskGroup(of: URL.self, returning: [URL].self) { group in
                for _ in 0..<8 {
                    group.addTask {
                        try DecryptionCache.resolve(root: root, identity: identity, produce: { dir in
                            count.add(); Thread.sleep(forTimeInterval: 0.05)
                            try Data("complete".utf8).write(to: dir.appendingPathComponent("iBoot.bin"))
                            return ["iBoot.bin"]
                        })
                    }
                }
                var all: [URL] = []
                for try await result in group { all.append(result) }
                return all
            }
            #expect(Set(results).count == 1)
            #expect(count.value == 1)
            for url in results { #expect(try Data(contentsOf: url.appendingPathComponent("iBoot.bin")) == Data("complete".utf8)) }
        }
    }
}
