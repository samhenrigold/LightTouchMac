// Whether a process just started runs sandboxed, read the way a process can change: a sandbox is applied while the
// process starts (usbmuxd starts as the services worker, which takes its grants and execs it) and never lifted, so a
// first "not sandboxed" may only be early, while "sandboxed" is final.

import Foundation

public enum SandboxReading {
    /// `read`'s answer, asked again every 50 ms while it says "not sandboxed" and a sandbox is `expected`, for at
    /// most `patience`.
    public static func settled(expected: Bool, patience: Duration = .seconds(2), _ read: () -> Bool) -> Bool {
        let deadline = ContinuousClock.now + patience
        var sandboxed = read()
        while expected, !sandboxed, ContinuousClock.now < deadline {
            usleep(50_000)
            sandboxed = read()
        }
        return sandboxed
    }
}
