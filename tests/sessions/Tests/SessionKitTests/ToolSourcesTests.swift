import BuildSupport
import Foundation
import Testing

@testable import SessionKit

struct ToolSourcesTests {
    @Test func testEditsReuseToolsButBuildInputsInvalidateThem() throws {
        try withScratch { root in
            func git(_ arguments: String...) throws {
                let result = try Shell.run(
                    [
                        "git", "-c", "user.name=Test", "-c", "user.email=test@example.invalid",
                        "-c", "commit.gpgsign=false"
                    ] + arguments, directory: root)
                #expect(result.succeeded, "\(result.error)")
            }
            func put(_ path: String, _ text: String) throws {
                let url = root.appendingPathComponent(path)
                try FileManager.default.createDirectory(
                    at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try text.write(to: url, atomically: true, encoding: .utf8)
            }
            try git("init", "-q")
            try put("Packages/Example/Sources/Example/main.swift", "source")
            try put("Packages/Example/Tests/ExampleTests/Test.swift", "test")
            try put("Packages/Example/Package.swift", "manifest")
            try put("Packages/Example/Package.resolved", "resolution")
            try git("add", ".")
            try git("commit", "-qm", "initial")
            let initial = try #require(ToolSources.committedTree(in: root))
            try put("Packages/Example/Tests/ExampleTests/Test.swift", "changed test")
            #expect(ToolSources.committedTree(in: root) == initial)
            try git("add", ".")
            try git("commit", "-qm", "tests only")
            #expect(ToolSources.committedTree(in: root) == initial)
            for path in [
                "Packages/Example/Package.swift", "Packages/Example/Package.resolved",
                "Packages/Example/Sources/Example/main.swift"
            ] {
                try put(path, "changed")
                #expect(ToolSources.committedTree(in: root) == nil)
                try git("add", ".")
                try git("commit", "-qm", "build input")
                #expect(ToolSources.committedTree(in: root) != initial)
            }
            try put("Packages/Example/Sources/Example/new.swift", "untracked source")
            #expect(ToolSources.committedTree(in: root) == nil)
        }
    }

    @Test func gitFailureCannotReuseACommittedBuild() throws {
        try withScratch { root in
            #expect(ToolSources.committedTree(in: root) == nil)
        }
    }
}
