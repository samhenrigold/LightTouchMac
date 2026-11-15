import Testing

@testable import SessionKit

/// The host-set, guest-read switch against fake sets and reads (a unit of 10 ms).
struct SettingSwitchTests {
    static let unit = 0.01

    @Test func aSwitchTheGuestShowsLateIsReadUntilItShows() async {
        var (sets, reads) = (0, 0)
        let r = await SettingSwitch.apply(
            unit: Self.unit,
            set: {
                sets += 1
                return "ok"
            },
            took: {
                reads += 1
                return reads >= 4
            }
        )
        #expect(r.took && sets == 1 && r.attempts.count == 1)
    }

    @Test func aSetThatFailedIsTriedAgain() async {
        var sets = 0
        let r = await SettingSwitch.apply(
            unit: Self.unit,
            set: {
                sets += 1
                return sets == 1 ? "timed out" : "ok"
            },
            took: { sets >= 2 }
        )
        #expect(r.took && sets == 2)
        #expect(
            r.attempts.first?.hasPrefix("timed out in ") == true && r.attempts.first?.hasSuffix("not shown") == true)
    }

    @Test func aSwitchThatNeverShowsStopsAfterItsTries() async {
        var sets = 0
        let r = await SettingSwitch.apply(
            tries: 3,
            settle: 2,
            unit: Self.unit,
            set: {
                sets += 1
                return "ok"
            },
            took: { false }
        )
        #expect(!r.took && sets == 3 && r.attempts.count == 3)
    }
}
