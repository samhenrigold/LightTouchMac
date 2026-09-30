import Foundation
import Testing

/// Corpus tests are explicitly opted in. Missing prerequisites in a selected
/// corpus run are failures, never successful returns.
enum FixtureRequirements {
    struct Missing: Error, CustomStringConvertible {
        let description: String
    }
    static func missing(_ reason: String, sourceLocation: SourceLocation = #_sourceLocation) throws -> Never {
        throw Missing(description: "Required fixture unavailable: " + reason)
    }
    static var corpusEnabled: Bool {
        let env = ProcessInfo.processInfo.environment
        return env["FK_TEST_CORPUS"] == "1" || env["FK_REQUIRE_FIXTURES"] == "1"
    }
}
