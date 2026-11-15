import Foundation

/// A guest setting switched from the host and read back from the guest (session-driver's VoiceOver for the lock sound):
/// the switch is tried again when the guest doesn't show it, and the guest is read until it does, as a lockdown child
/// can fail or time out on a loaded host and the guest takes its own time to act on one that went through.
public enum SettingSwitch {
    /// Runs `set` up to `tries` times, each followed by `took` once a `unit` for up to `settle` units, until `took`
    /// holds. Returns each try's outcome (`set`'s, then the seconds it and the reads took) and whether it took.
    /// `settle` is in units (seconds in the driver; the tests shrink the unit).
    public static func apply(
        tries: Int = 3,
        settle: Double = 15,
        unit: Double = 1,
        set: () async -> String,
        took: () async -> Bool
    ) async -> (attempts: [String], took: Bool) {
        var attempts: [String] = []
        for _ in 0..<tries {
            let t0 = Date()
            let outcome = await set()
            let t1 = Date()
            repeat {
                if await took() {
                    attempts.append("\(outcome) in \(seconds(t0, t1)) s, shown at \(seconds(t0, Date())) s")
                    return (attempts, true)
                }
                try? await Task.sleep(for: .seconds(unit))
            } while Date().timeIntervalSince(t1) < settle * unit
            attempts.append("\(outcome) in \(seconds(t0, t1)) s, not shown")
        }
        return (attempts, false)
    }

    private static func seconds(_ from: Date, _ to: Date) -> String {
        String(format: "%.1f", to.timeIntervalSince(from))
    }
}
