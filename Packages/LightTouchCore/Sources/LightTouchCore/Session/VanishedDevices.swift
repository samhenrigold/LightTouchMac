// A device whose folder left Devices/ while the app runs (moved to the Trash in Finder, removed in Terminal). It
// halts as Stop does: the helper keeps the pages it has open, so the halt's flush lands in the moved folder (which
// the Trash can put back) or in unlinked inodes, never in a Devices/<uuid> made again by path. Its session is then
// released and dropped, leaving the row unprepared, as Delete does.

import Foundation
import HostRuntime

/// A started device, as VanishedDevices stops it: the app's DeviceSession.
public protocol LibrarySession: AnyObject {
    var instance: DeviceInstance { get }
    var ladder: ShutdownLadder { get }
    var phase: SessionPhase { get }
    /// Waits for the helper to be gone (killing one still running); false if it would not exit.
    func release() async -> Bool
}

extension LibrarySession {
    /// Lets go of a shut-down or dead device's helper before its storage changes (Delete, Prepare Again, a file
    /// system edit); false for one that is running or stopping, or whose helper would not exit.
    public func releaseIfStopped() async -> Bool {
        switch phase {
        case .stopped, .dead: await release()
        case .running, .stopping: false
        }
    }
}

public final class VanishedDevices {
    private var stopping: Set<UUID> = []
    public init() {}

    /// After the library changed: each session whose record it no longer has stops, once at a time; `drop` takes it
    /// out once its helper is gone. One whose helper would not exit stays, so nothing starts a second on its storage,
    /// and the next change to the library tries again.
    public func stop<S: LibrarySession>(_ sessions: [S], library: DeviceLibrary, drop: @escaping (S) -> Void) {
        let present = Set(library.instances.map(\.id))
        for session in sessions where !present.contains(session.instance.id) {
            let id = session.instance.id
            guard stopping.insert(id).inserted else { continue }
            logEvent("library: \(session.instance.name)'s folder left Devices; stopping it")
            AppReports.failed("Library.deviceVanished")
            let halt = session.ladder.halt()
            Task {
                _ = await halt.value
                let released = await session.release()
                stopping.remove(id)
                guard released else { return logEvent("library: \(session.instance.name)'s helper did not exit") }
                drop(session)
            }
        }
    }
}
