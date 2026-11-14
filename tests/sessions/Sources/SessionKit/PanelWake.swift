import Foundation

/// When the driver's wait for a lit screen presses Home, as a person would wake a phone that went dark: once the guest
/// has turned its panel off after it was on in this wait, and it has stayed off for `interval` seconds (a boot slower
/// than iOS's idle timer auto-locks before SpringBoard's screen ever counts as lit: serial's
/// "ApplePinotLCD::_lcdEnable: enable: 0" or its board's equivalent); again each `interval` while it stays off. A panel
/// the guest never turned on is left alone: its boot is still under way.
public struct PanelWake: Sendable {
    public let interval: Double
    private var seenOn = false
    /// When the panel went off, or Home was last pressed while it stayed off.
    private var offSince: Date?

    public init(interval: Double = 5) { self.interval = interval }

    /// Whether to press Home now, given what the emulator says of the panel (SharedStatus.displaySleeping; nil before
    /// the helper publishes a status).
    public mutating func pressesHome(sleeping: Bool?, now: Date = Date()) -> Bool {
        guard let sleeping else { return false }
        guard sleeping else {
            seenOn = true
            offSince = nil
            return false
        }
        guard seenOn else { return false }
        guard let since = offSince else {
            offSince = now
            return false
        }
        guard now.timeIntervalSince(since) >= interval else { return false }
        offSince = now
        return true
    }
}
