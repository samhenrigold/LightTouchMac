import Foundation
import os

/// A device helper's hold on its storage lease (Devices/<uuid>/work/lease): taken at hello, kept until the process
/// exits, so a second helper on the same storage — from another Light Touch, or beside one still finishing its
/// shutdown — is refused before it boots. Taken on the link's queue, read on the boot path.
public nonisolated final class HeldLease: Sendable {
    private let held = OSAllocatedUnfairLock<StorageLease?>(initialState: nil)
    private let refusal = OSAllocatedUnfairLock<String?>(initialState: nil)
    public init() {}

    public var lease: StorageLease? { held.withLock { $0 } }

    /// Why the last take was refused, when it wasn't that another helper holds the lease.
    public var failure: String? { refusal.withLock { $0 } }

    /// True when there is no lease to take (`path` nil) or it was taken; a refusal keeps nothing and says why.
    public func take(_ path: String?, log: (String) -> Void) -> Bool {
        guard let path else { return true }
        do {
            let lease = try StorageLease(URL(fileURLWithPath: path))
            held.withLock { $0 = lease }
            return true
        } catch let error as StorageLease.Failure {
            switch error {
            case .openFailed(let code): refuse("lease \(path): \(String(cString: strerror(code)))", log)
            case .inUse: log("lease \(path) is held")
            case .pendingEdit:
                refuse(
                    "unfinished storage edit \(URL(fileURLWithPath: path).deletingLastPathComponent().appendingPathComponent("edit.json").path); resolve it before booting",
                    log
                )
            }
        } catch { refuse("lease \(path): \(error.localizedDescription)", log) }
        return false
    }

    private func refuse(_ why: String, _ log: (String) -> Void) {
        refusal.withLock { $0 = why }
        log(why)
    }

    /// Give the lease up (tests; a helper keeps it until it exits).
    public func release() {
        held.withLock {
            $0?.close()
            $0 = nil
        }
    }
}
