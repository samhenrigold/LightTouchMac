import Foundation
import Testing

@testable import SessionKit

/// The driver's wait for a lit screen wakes a panel the guest turned off (auto-lock on a slow boot) with Home, and
/// leaves alone one it never turned on.
struct PanelWakeTests {
    /// The seconds of `timeline` (each a second and what the emulator said of the panel) at which Home is pressed.
    private func presses(_ timeline: [(Double, Bool?)]) -> [Double] {
        var wake = PanelWake()
        let t0 = Date()
        return timeline.filter { wake.pressesHome(sleeping: $0.1, now: t0 + $0.0) }.map(\.0)
    }

    /// On, then off: Home once it has been off 5 s, again 5 s later while it stays off, and once more 5 s after it
    /// went off again, having come back on.
    @Test func aPanelThatWentDarkIsWokenWithHome() {
        let timeline: [(Double, Bool?)] = [
            (0, nil), (1, false), (2, true), (6.9, true), (7, true), (11, true), (12, true), (13, false), (14, true),
            (18, true), (19, true)
        ]
        #expect(presses(timeline) == [7, 12, 19])
    }

    /// Off from the start (the boot hasn't lit its panel yet), however long: no Home.
    @Test func aPanelNeverOnIsLeftAlone() {
        #expect(presses((0..<120).map { (Double($0), true) } + [(200, nil)]).isEmpty)
    }

    /// Off for less than the interval (the panel handed over during boot) presses nothing.
    @Test func aShortBlipOffIsNotAWake() {
        #expect(presses([(0, false), (1, true), (3, true), (4, false), (8, true), (12.9, true)]).isEmpty)
    }
}
