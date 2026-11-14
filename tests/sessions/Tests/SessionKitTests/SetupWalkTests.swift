import Testing

@testable import SessionKit

/// The Setup walks' logic without an emulator: the iPad's tap-retry core against fake taps (a unit of 50 ms), the page
/// fingerprints measured off real Setup screenshots, and the phone walk's plan against label sets read off real pages.
struct SetupWalkTests {
    static let unit = 0.05

    @Test func aLostTapIsTappedAgain() async {
        var taps = 0
        let r = await SetupPages.tapUntil(
            budget: 6,
            every: 1.5,
            unit: Self.unit,
            tap: { taps += 1 },
            answered: { taps >= 2 }
        )
        #expect(r && taps == 2)
    }

    @Test func aLandedTapIsNotRepeated() async {
        var taps = 0
        let r = await SetupPages.tapUntil(
            budget: 6,
            every: 1.5,
            unit: Self.unit,
            tap: { taps += 1 },
            answered: { taps >= 1 }
        )
        #expect(r && taps == 1)
    }

    @Test func aPageThatNeverAnswersFailsAfterTheBudgetOneTapPerInterval() async {
        var taps = 0
        let r = await SetupPages.tapUntil(budget: 5, every: 2, unit: Self.unit, tap: { taps += 1 }, answered: { false })
        #expect(!r && taps == 3)
    }

    @Test func aOnePollFlashIsNotAnAnswer() async {
        var taps = 0
        var polls = 0
        let r = await SetupPages.tapUntil(
            budget: 12,
            every: 3,
            unit: Self.unit,
            tap: {
                taps += 1
                polls = 0
            },
            answered: {
                polls += 1
                return taps >= 2 || polls == 1
            }
        )
        #expect(r && taps == 2)
    }

    /// Fingerprints measured off real Setup screenshots (9A5220p, 9A334, 9A405, 9B176, 9B206; the first three are
    /// 9B206's language page with a guessed country, under the Welcome words, and its country page over the map).
    static let measured: [(String?, [Double])] = [
        ("list", [0.55, 0.97, 1.0, 0.04, 0.0, 0.06, 0.0]), ("list", [0.55, 0.97, 1.0, 0.01, 0.04, 0.03, 0.01]),
        ("list", [0.0, 0.87, 1.0, 0.0, 0.43, 0.0, 0.0]),
        ("list", [0.97, 0.92, 0.83, 0.92, 1.0, 0.95, 0.8]), ("list", [0.98, 0.92, 0.83, 0.92, 1.0, 0.96, 0.79]),
        ("location", [0.97, 0.0, 0.95, 0.05, 0.0, 0.34, 0.0]), ("wi-fi", [0.0, 0.0, 0.0, 0.28, 0.0, 0.0, 0.75]),
        ("set up", [0.93, 0.92, 0.99, 0.0, 1.0, 0.0, 0.0]), ("set up", [0.94, 0.92, 0.99, 0.0, 1.0, 0.0, 0.0]),
        ("apple id", [0.92, 0.92, 0.0, 0.07, 0.0, 0.09, 0.0]), ("apple id", [0.92, 0.92, 0.0, 0.04, 0.0, 0.1, 0.0]),
        ("diagnostics", [0.0, 0.0, 0.0, 1.0, 0.27, 0.01, 0.0]), ("diagnostics", [0.0, 0.0, 0.0, 1.0, 0.29, 0.0, 0.0]),
        ("diagnostics", [0.0, 0.0, 0.0, 0.12, 0.0, 0.0, 0.95]), ("thank you", [0.0, 0.83, 0.17, 0.05, 0.0, 0.18, 0.0]),
        (nil, [0.0, 0.0, 0.0, 0.0, 0.0, 0.04, 0.0]), (nil, [0.78, 0.69, 0.86, 1.0, 1.0, 0.74, 0.92])
    ]

    @Test func measuredPagesAreRecognized() {
        for (want, f) in Self.measured {
            #expect(SetupPages.kind(f) == want, "page \(want ?? "unrecognized") from \(f)")
        }
    }

    func taps(_ steps: [SetupPlan.Step]) -> [String] {
        steps.compactMap {
            if case .tap(_, _, let log) = $0 { return log ?? "(next)" }
            return nil
        }
    }

    /// n88ap-10A523 (3GS 6.0.1): the language page with the Home sheet up.
    static let sheetOnLanguage: [String: (x: Double, y: Double)] = [
        "Test Network": (0.2, 0.02), "9:43 PM": (0.5, 0.02), "English": (0.15, 0.2), "Français": (0.15, 0.29),
        "Deutsch": (0.15, 0.39), "Emergency Call": (0.5, 0.66), "Start Over": (0.5, 0.77), "Cancel": (0.5, 0.91)
    ]

    @Test func theHomeSheetIsCancelledFirst() {
        #expect(SetupPlan.plan(Self.sheetOnLanguage, pages: []) == [.tap(0.5, 0.91, "(Cancel)")])
        var onPick = Self.sheetOnLanguage
        onPick["Skip This Step"] = (0.82, 0.95)
        #expect(taps(SetupPlan.plan(onPick, pages: [])) == ["(Cancel)"])
    }

    @Test func theLanguagePageTakesEnglishThenTheArrow() {
        var language = Self.sheetOnLanguage
        for title in ["Emergency Call", "Start Over", "Cancel"] { language[title] = nil }
        let plan = SetupPlan.plan(language, pages: [])
        #expect(plan.count == 3 && plan[0] == .tap(0.15, 0.2, "English"))
        guard case .tap(let x, let y, _) = plan.last else {
            Issue.record("no arrow tap: \(plan)")
            return
        }
        #expect(x == SetupPlan.nextArrow.x && y == SetupPlan.nextArrow.y)
    }

    /// n90ap-11D257 (7.1.2): the Country page as Vision reads it, which starts at Afghanistan.
    static let country7: [String: (x: Double, y: Double)] = [
        "••••• Light Touch A 7:17 PM": (0.29, 0.02), "< Back": (0.12, 0.09), "Select Your Country": (0.5, 0.19),
        "or Region": (0.47, 0.27), "MORE COUNTRIES AND REGIONS": (0.4, 0.5), "Afghanistan": (0.2, 0.6),
        ">": (0.94, 0.6), "Åland Islands": (0.22, 0.72), "Albania": (0.15, 0.84), "Algeria": (0.14, 0.97)
    ]

    @Test func theCountryListIsScrolledToUnitedStates() {
        // never a row by its place: fling on from the top of the list
        #expect(SetupPlan.plan(Self.country7, pages: []) == [.scroll(0.85, 0.25, fast: true)])
        // a scrolled list (no heading left): a screen at a time from T on, a screen back once past it
        let s: [String: (x: Double, y: Double)] = ["Back": (0.12, 0.09), "Syria": (0.2, 0.3), "Taiwan": (0.2, 0.5)]
        #expect(SetupPlan.plan(s, pages: ["(scroll)"]) == [.scroll(0.85, 0.25, fast: false)])
        let v: [String: (x: Double, y: Double)] = ["Uruguay": (0.2, 0.3), "Vietnam": (0.2, 0.5)]
        #expect(SetupPlan.plan(v, pages: ["(scroll)"]) == [.scroll(0.25, 0.85, fast: false)])
        let us: [String: (x: Double, y: Double)] = ["United Kingdom": (0.2, 0.3), "United States": (0.2, 0.42)]
        #expect(taps(SetupPlan.plan(us, pages: ["(scroll)"])) == ["United States"])
        // a page that is not the list is not scrolled
        #expect(SetupPlan.plan(["Syria": (0.2, 0.3)], pages: ["Skip This Step"]) == [.slideIfLockScreen])
    }

    /// n90ap-11D257 (7.1.2): a slide over the language list chose 繁體中文, the walk tapped English under its "Setting
    /// language" alert in vain, and read only the status bar on the country page that followed ("選擇您的國家或地區")
    /// for the rest of its 80 pages. The page after English is the country page in English (its heading, or United
    /// States where the country was guessed); anything else that reads goes back.
    @Test func aCountryPageInAnotherLanguageGoesBackToTheLanguages() {
        let afterEnglish = ["English", "Light Touch 5:06 AM"]
        let chinese: [String: (x: Double, y: Double)] = ["•••• Light Touch 5:06 AM": (0.29, 0.02), "<": (0.05, 0.09)]
        #expect(SetupPlan.plan(chinese, pages: afterEnglish) == [.tap(SetupPlan.back.x, SetupPlan.back.y, "(Back)")])
        // a Back that didn't land is tapped again; back on the languages, English again
        #expect(taps(SetupPlan.plan(chinese, pages: afterEnglish + ["(Back)"])) == ["(Back)"])
        #expect(taps(SetupPlan.plan(Self.language7, pages: afterEnglish + ["(Back)"])).first == "English")
        // the country page in English, its list or its guess, and the language page still up: no Back
        #expect(SetupPlan.plan(Self.country7, pages: afterEnglish) == [.scroll(0.85, 0.25, fast: true)])
        let guessed: [String: (x: Double, y: Double)] = [
            "•••• Light Touch 5:06 AM": (0.29, 0.02), "United States": (0.24, 0.39), "Afghanistan": (0.2, 0.72)
        ]
        #expect(taps(SetupPlan.plan(guessed, pages: afterEnglish)) == ["United States"])
        #expect(taps(SetupPlan.plan(Self.language7, pages: afterEnglish)).first == "English")
        // a read that failed (nothing at all) is not a page to leave
        #expect(SetupPlan.plan([:], pages: afterEnglish) == [.slideIfLockScreen])
    }

    /// n90ap-11D257 (7.1.2): the passcode page as Vision read it on 15 pages in a row (a stray mark, a curly apostrophe).
    @Test func thePasscodePageIsReadPastAStrayMark() {
        let passcode: [String: (x: Double, y: Double)] = [
            "Create a Passcode": (0.5, 0.17), "• Don\u{2019}t Add Passcode": (0.48, 0.49), "1": (0.17, 0.59)
        ]
        #expect(taps(SetupPlan.plan(passcode, pages: [])) == ["Don't Add Passcode"])
    }

    @Test func anAlertsOKAndTheWelcomeSlide() {
        #expect(taps(SetupPlan.plan(["OK": (0.5, 0.6), "Location Services": (0.5, 0.4)], pages: [])) == ["(OK)"])
        #expect(SetupPlan.plan(["slide to set up": (0.5, 0.9)], pages: []) == [.slideIfLockScreen])
    }

    /// 5.x and 6.x's language page with a guessed country (issue 102) offers its languages under the Welcome words;
    /// with none it lists every language.
    @Test func aCountrysLanguagePageIsNotEveryLanguage() {
        let country: [String: (x: Double, y: Double)] = [
            "Vítejte": (0.4, 0.22), "Bienven": (0.8, 0.38), "Bem-vindo": (0.4, 0.45), "Välkommen": (0.6, 0.53),
            "English": (0.14, 0.73), "Español": (0.14, 0.82)
        ]
        let every: [String: (x: Double, y: Double)] = [
            "English": (0.14, 0.2), "Français": (0.16, 0.29), "Deutsch": (0.16, 0.38), "日本語": (0.13, 0.48),
            "Nederlands": (0.2, 0.57), "Italiano": (0.16, 0.66), "Español": (0.16, 0.75)
        ]
        #expect(!SetupPlan.listsEveryLanguage(country))
        #expect(SetupPlan.listsEveryLanguage(every))
        #expect(taps(SetupPlan.plan(country, pages: [])).first == "English")
    }

    /// n90ap-11D257 (7.1.2): the language page as Vision reads it.
    static let language7: [String: (x: Double, y: Double)] = [
        "•••• Light Touch = 9:11 PM": (0.29, 0.02), "English": (0.14, 0.27), ">": (0.94, 0.27),
        "Français": (0.16, 0.4), "Deutsch": (0.16, 0.52)
    ]

    /// The pages four walks stopped on with "Setup still up after 80 pages" (10-18), as Vision reads them: each has a
    /// step, so a walk that took none there had read nothing (TextReader). "Light Touch = 9:11 PM" is the status bar
    /// (carrier and clock) the language page's arrow tap is logged by.
    @Test func thePagesWalksStoppedOnEachHaveAStep() {
        #expect(taps(SetupPlan.plan(Self.language7, pages: [])) == ["English", "Light Touch = 9:11 PM"])
        let k: [String: (x: Double, y: Double)] = [
            "•••• Light Touch F 9:12 PM": (0.29, 0.02), "stan": (0.29, 0.07), "< Back": (0.12, 0.09),
            "Kenya": (0.13, 0.19), ">": (0.94, 0.19), "Kiribati": (0.14, 0.32), "Kuwait": (0.14, 0.44),
            "Kyrgyzstan": (0.2, 0.57), "Laos": (0.11, 0.69), "Latvia": (0.13, 0.82), "Lebanon": (0.16, 0.94)
        ]
        #expect(SetupPlan.plan(k, pages: ["(scroll)"]) == [.scroll(0.85, 0.25, fast: true)])
        let appleID: [String: (x: Double, y: Double)] = [
            "•ll Light Touch & 7:56 PM": (0.3, 0.02), "Back": (0.1, 0.09), "Apple ID": (0.5, 0.09),
            "Sign In with an Apple ID": (0.5, 0.71), "Create a Free Apple ID": (0.5, 0.85),
            "Skip This Step": (0.82, 0.96)
        ]
        #expect(taps(SetupPlan.plan(appleID, pages: ["(Skip)"])) == ["Skip This Step"])
    }
}
