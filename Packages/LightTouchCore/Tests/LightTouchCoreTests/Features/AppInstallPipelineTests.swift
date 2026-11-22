import Foundation
import HostRuntime
import HostServiceWire
import Testing

@testable import LightTouchCore

/// On iOS 7 an app install retries its first AFC request (the free-space query) while it times out, bounded, and
/// sends nothing until afcd answers; a different error, or any error on other versions, fails at once
/// (AppInstallPipeline, against services that answer the free-space query only from a given try on).
struct AppInstallPipelineTests {
    final class Services: AppInstallServices, @unchecked Sendable {
        private let lock = NSLock()
        private var log: [String] = []
        let answersFrom: Int?, otherError: Bool
        init(answersFrom: Int?, otherError: Bool = false) {
            self.answersFrom = answersFrom
            self.otherError = otherError
        }
        var calls: [String] { lock.withLock { log } }
        func freeSpaceBytes() async throws -> Int64 {
            let tries = lock.withLock {
                log.append("free")
                return log.filter { $0 == "free" }.count
            }
            if let answersFrom, tries >= answersFrom { return 1 << 40 }
            if otherError { throw DeviceError.unavailable }
            throw DeviceError.timedOut(operation: "free space")
        }
        func stage(_ ipa: URL, progress: @escaping @Sendable (Double) -> Void) async throws -> String {
            lock.withLock { log.append("stage") }
            return "s"
        }
        func removeStaged(_ path: String) async {}
        func install(_ ipa: URL, staged: String, bundleID: String, progress: @escaping @Sendable (Int, String) -> Void)
            async throws
        {
            lock.withLock { log.append("install") }
        }
    }
    struct NoAgent: InstallPlaceholderAgent {
        var isAlive: Bool { false }
        func placeholder(_ action: String, id: String, bundleID: String?) async throws -> Bool { false }
    }
    nonisolated final class Phrases: @unchecked Sendable {  // lock-protected
        private let lock = NSLock()
        private var all: [String] = []
        func add(_ s: String) { lock.withLock { all.append(s) } }
        var list: [String] { lock.withLock { all } }
    }

    func run(os: String, answersFrom: Int?, otherError: Bool = false, timeout: Duration) async throws -> (
        Services, Phrases, Error?
    ) {
        try await withTemporaryState { dir in
            let ipa = dir.appendingPathComponent("x.ipa")
            try makeIPA(at: ipa)
            let services = Services(answersFrom: answersFrom, otherError: otherError)
            let phrases = Phrases()
            let pipeline = AppInstallPipeline(
                services: services,
                agent: NoAgent(),
                deviceOS: os,
                soc: .s5l8930,
                afcReadyTimeout: timeout
            )
            do {
                try await pipeline.install(ipa) { phrases.add($0) }
                return (services, phrases, nil)
            } catch { return (services, phrases, error) }
        }
    }

    @Test func iOS7WaitsForAFCThenSends() async throws {
        let (services, phrases, error) = try await run(os: "7.1.2", answersFrom: 3, timeout: .seconds(60))
        #expect(error == nil)
        #expect(services.calls == ["free", "free", "free", "stage", "install"])
        #expect(phrases.list.first == "Waiting for iOS to finish starting…")
    }

    @Test func iOS7GivesUpAfterTheBoundHavingSentNothing() async throws {
        let (services, _, error) = try await run(os: "7.0.6", answersFrom: nil, timeout: .seconds(2))
        guard case .failed(let message)? = error as? DeviceError else {
            Issue.record("\(String(describing: error))")
            return
        }
        #expect(message.contains("didn’t answer"))
        #expect(!services.calls.contains("stage") && services.calls.count >= 2)
    }

    @Test func iOS7DoesNotRetryAnotherError() async throws {
        let (services, _, error) = try await run(os: "7.1.2", answersFrom: nil, otherError: true, timeout: .seconds(60))
        guard case .unavailable? = error as? DeviceError else {
            Issue.record("\(String(describing: error))")
            return
        }
        #expect(services.calls == ["free"])
    }

    @Test func iOS6FailsAtOnce() async throws {
        let (services, _, error) = try await run(os: "6.1.3", answersFrom: 3, timeout: .seconds(60))
        guard case .timedOut? = error as? DeviceError else {
            Issue.record("\(String(describing: error))")
            return
        }
        #expect(services.calls == ["free"])
    }
}
