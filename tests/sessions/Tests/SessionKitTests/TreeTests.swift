import Foundation
import Testing

@testable import SessionKit

/// The prepared-base check's listing: a change is seen, Finder rewriting its .DS_Store isn't.
struct TreeTests {
    @Test func finderMetadataIsNotAChangeButAFileIs() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("tree-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("sub"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let stores = [".DS_Store", "sub/.DS_Store"].map { root.appendingPathComponent($0) }
        for store in stores { try Data("x".utf8).write(to: store) }
        let before = SessionJudge.tree(root)
        for store in stores {
            let h = try FileHandle(forWritingTo: store)
            try h.write(contentsOf: Data("finder".utf8))
            try h.close()
        }
        #expect(SessionJudge.tree(root) == before)
        try Data("x".utf8).write(to: root.appendingPathComponent("sub/file"))
        #expect(SessionJudge.tree(root) != before)
    }
}
