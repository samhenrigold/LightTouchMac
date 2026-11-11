// What's counted across every Mac that shares usage and error reports (Settings ▸ General): a failure, or a feature
// used, by a stable name (Area.whatHappened) with parameters that say nothing about the user, and an error as its
// domain and code only. The packages have no TelemetryDeck; the app's Analytics sets `sink` at launch, and without it
// (tests, the command-line tools) a report goes nowhere and its parameters are never worked out. Each call sits beside
// the logEvent that says it in full.

import Foundation

public nonisolated enum AppReports {
    public enum Kind: Sendable { case failure, use }
    /// Set once, at launch, before any report.
    nonisolated(unsafe) public static var sink:
        (@Sendable (Kind, String, (any Error)?, [String: String], Double?) -> Void)?

    /// Something failed: `id` names what ("Media.importFailed").
    public static func failed(
        _ id: String,
        _ error: (any Error)? = nil,
        _ parameters: @autoclosure () -> [String: String] = [:]
    ) {
        sink?(.failure, id, error, parameters(), nil)
    }

    /// A feature was used ("Capture.screenshot"); `value` is a measure of it, such as seconds.
    public static func used(
        _ name: String, _ parameters: @autoclosure () -> [String: String] = [:], value: Double? = nil
    ) {
        sink?(.use, name, nil, parameters(), value)
    }
}
