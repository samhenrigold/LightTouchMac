import Foundation
import Testing

@testable import HostRuntime

/// The helper's lease hold against a stopped device's edit intent (was tests/offline/check-storage-edit-lease.py).
struct HeldLeaseTests {
    @Test func editIntentRefusesBootKeepsNothingAndResolvingItAdmits() throws {
        let work = FileManager.default.temporaryDirectory.appendingPathComponent("held-lease-\(UUID().uuidString)/work")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: work.deletingLastPathComponent()) }
        let path = work.appendingPathComponent("lease").path
        let edit = work.appendingPathComponent("edit.json")
        var logged: [String] = []

        let held = HeldLease()
        #expect(held.take(path) { logged.append($0) }, "a stopped device takes its lease")
        #expect(held.lease != nil)
        held.release()

        try Data("{}".utf8).write(to: edit)
        let refused = HeldLease()
        #expect(!refused.take(path) { logged.append($0) }, "a durable edit refuses the boot")
        #expect(refused.lease == nil, "a refusal keeps no lease")
        #expect(logged.last?.contains("unfinished storage edit \(edit.path)") == true)
        #expect(refused.failure == logged.last)

        try FileManager.default.removeItem(at: edit)
        let resumed = HeldLease()
        #expect(resumed.take(path) { logged.append($0) }, "resolving the edit admits the next boot")
        resumed.release()
    }

    @Test func noPathIsNothingToTake() {
        let held = HeldLease()
        #expect(held.take(nil) { _ in Issue.record("nothing to log") })
        #expect(held.lease == nil)
    }

    @Test func aHeldLeaseRefusesASecondHelper() throws {
        let work = FileManager.default.temporaryDirectory.appendingPathComponent("held-lease-\(UUID().uuidString)/work")
        defer { try? FileManager.default.removeItem(at: work.deletingLastPathComponent()) }
        let path = work.appendingPathComponent("lease").path
        let first = HeldLease()
        let second = HeldLease()
        var logged: [String] = []
        #expect(first.take(path) { logged.append($0) })
        #expect(!second.take(path) { logged.append($0) })
        #expect(logged == ["lease \(path) is held"])
        #expect(second.failure == nil, "held by another helper: the link's own refusal says so")
        first.release()
    }

    /// Issue 137: a lease the helper can't open is not a device in use.
    @Test func aLeaseItCantOpenSaysWhy() throws {
        let work = FileManager.default.temporaryDirectory.appendingPathComponent("held-lease-\(UUID().uuidString)/work")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: work.deletingLastPathComponent()) }
        let path = work.appendingPathComponent("lease")
        try FileManager.default.createSymbolicLink(at: path, withDestinationURL: work)
        let held = HeldLease()
        #expect(!held.take(path.path) { _ in })
        #expect(held.failure == "lease \(path.path): \(String(cString: strerror(ELOOP)))")
    }
}
