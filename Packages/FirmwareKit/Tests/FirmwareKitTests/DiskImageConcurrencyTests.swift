// Also run under an external process deadline so the deadlock regression
// cannot hide behind a timeout scheduled on the same exhausted pool.
import Darwin
import Foundation
import Testing
@testable import FirmwareKit

struct DiskImageConcurrencyTests {
    @Test func harmlessCommandsMakeConcurrentProgress() async throws {
        let completed = try await withThrowingTaskGroup(of: Bool.self) { group in
            for index in 0..<64 {
                group.addTask {
                    let expected = "bridge-\(index)"
                    // Await the actual shared disk-tool subprocess leaf.
                    let (status, output) = try await DiskImage.exec([
                        "/usr/bin/printf", "%s", expected
                    ])
                    return status == 0 && output == expected
                }
            }
            var results = [Bool]()
            for try await result in group { results.append(result) }
            return results
        }
        #expect(completed.count == 64)
        #expect(completed.allSatisfy { $0 })
    }
    @Test func exitSignalStdioAndClosedInputRemainDistinct() async throws {
        let exit = try await DiskImage.exec(["/bin/sh", "-c", "printf out; printf err >&2; exit 7"])
        #expect(exit.0 == 7 && exit.1 == "outerr")
        let signal = try await DiskImage.exec(["/bin/sh", "-c", "kill -TERM $$"])
        #expect(signal.0 == -SIGTERM)
        let input = try await DiskImage.exec(["/bin/sh", "-c", "read value; printf 'eof:%s' \"$?\""])
        #expect(input.0 == 0 && input.1 == "eof:1")
        await #expect(throws: (any Error).self) {
            _ = try await DiskImage.exec(["/private/tmp/firmwarekit-no-such-tool-" + UUID().uuidString])
        }
    }

    @Test func cancellingActualToolReapsItsChild() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let pidFile = dir.appendingPathComponent("pid")
        let tool = Task {
            try await DiskImage.exec(["/bin/sh", "-c", "printf '%s' $$ > \"$1\"; exec /bin/sleep 60", "fixture", pidFile.path])
        }
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while !FileManager.default.fileExists(atPath: pidFile.path), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        guard let pid = Int32(try String(contentsOf: pidFile, encoding: .utf8)) else {
            tool.cancel(); _ = try? await tool.value
            throw FirmwareError(.internal, "fixture child did not report its pid")
        }
        tool.cancel()
        await #expect(throws: CancellationError.self) { _ = try await tool.value }
        #expect(kill(pid, 0) == -1 && errno == ESRCH, "tool child must be gone when cancelled await returns")
    }

    @Test func failedAttachmentQueryDoesNotBecomeEmptySuccess() throws {
        let empty = "<?xml version=\"1.0\"?><plist version=\"1.0\"><dict><key>images</key><array/></dict></plist>"
        #expect(try DiskImage.parseAttachments(status: 0, output: empty).isEmpty)
        #expect(throws: FirmwareError.self) { _ = try DiskImage.parseAttachments(status: 1, output: empty) }
        #expect(throws: FirmwareError.self) { _ = try DiskImage.parseAttachments(status: 0, output: "not a plist") }
        #expect(throws: FirmwareError.self) { _ = try DiskImage.parseAttachments(status: 0, output: empty.replacingOccurrences(of: "images", with: "unknown")) }
    }

}
