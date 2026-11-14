import Foundation

/// iOS 5's Setup Assistant on a fresh iPad (session-driver's Setup5): which page a fingerprint is, and the tap-retry
/// core. The fingerprint is the white fraction of seven boxes of the 1024x768 panel (see Setup5.printBoxes).
public enum SetupPages {
    /// Which kind of Setup page a fingerprint is: "list" (language, country), "location", "wi-fi", "set up",
    /// "apple id", "diagnostics", "thank you"; nil for anything else (Terms, a page mid-transition, a dark panel).
    public static func kind(_ f: [Double]) -> String? {
        guard f.count == 7 else { return nil }
        let (b1, b2, gap, left, frame, mid, list) = (f[0], f[1], f[2], f[3], f[4], f[5], f[6])
        if b1 > 0.85, b2 > 0.85, gap < 0.2, frame < 0.1 { return "apple id" }
        if b1 > 0.85, b2 > 0.85, gap > 0.9, left < 0.1, frame > 0.9, mid < 0.1 { return "set up" }
        if b1 > 0.85, gap > 0.7, left > 0.8, frame > 0.9, mid > 0.8 { return "list" }
        // a guessed country's language page (its few languages under the Welcome words) and country page (it and
        // Show More over the moving world map): a short list on the right, the rest dark or animated
        if b1 < 0.85, b2 > 0.7, gap > 0.85, left < 0.2 { return "list" }
        if b1 > 0.85, b2 < 0.1, gap > 0.85 { return "location" }
        if b1 < 0.1, b2 < 0.1, left > 0.9, frame > 0.15, frame < 0.45 { return "diagnostics" }
        if b1 < 0.1, b2 < 0.1, left < 0.2, frame < 0.1, mid < 0.1, list > 0.9 { return "diagnostics" }  // 5.0 beta 1
        if b1 < 0.1, b2 > 0.7 { return "thank you" }
        if b1 < 0.1, b2 < 0.1, gap < 0.1, left > 0.15, left < 0.45, frame < 0.1, mid < 0.1 { return "wi-fi" }
        return nil
    }

    /// The page kind each walk step shows (Terms has no fingerprint of its own).
    public static func kind(of page: String) -> String? {
        [
            "language": "list", "country": "list", "location": "location", "wi-fi": "wi-fi", "set up": "set up",
            "apple id": "apple id", "diagnostics": "diagnostics", "thank you": "thank you"
        ][page]
    }

    /// Taps until `answered` holds on `hold` consecutive polls (one per `unit` seconds), or `budget` runs out, tapping
    /// again every `every` while nothing answered. A lost tap (a page still sliding in, a frame the host was too loaded
    /// to deliver) is retried instead of failing the walk; a pressed button's flash (the title bar changes for a moment,
    /// the page stays: 9B176's Set Up Next) is not an answer; a tap that did land is not repeated. `budget` and `every`
    /// are in units (seconds in the walk; the tests shrink the unit).
    public static func tapUntil(
        budget: Double,
        every: Double,
        hold: Int = 3,
        unit: Double = 1,
        tap: () async -> Void,
        answered: () -> Bool
    ) async -> Bool {
        let t0 = Date()
        let budget = budget * unit
        let every = every * unit
        var streak = 0
        while Date().timeIntervalSince(t0) < budget {
            await tap()
            let t1 = Date()
            while Date().timeIntervalSince(t1) < every || streak > 0, Date().timeIntervalSince(t0) < budget {
                streak = answered() ? streak + 1 : 0
                if streak >= hold { return true }
                try? await Task.sleep(for: .seconds(unit))
            }
        }
        return false
    }
}

/// A phone's Setup Assistant (6.x and 7.x on the iPod touch 4G, iPhone 4 and 3GS, session-driver's SetupPhone): what
/// to tap on a page, from the labels Vision read off it. An alert's button labeled exactly as one of `alertYes` goes
/// first, then the first of `picks` the page shows, then its Next (the language page's is an arrow, top right).
public enum SetupPlan {
    public static let picks = [
        "Start Using iPod touch", "Start Using iPod", "Start Using iPhone", "Get Started",
        "Set Up as New iPod touch", "Set Up as New iPod", "Set Up as New iPhone",
        "Disable Location Services", "Skip This Step", "Agree", "Don't Add Passcode",
        "Don't Use iCloud", "Don't Send", country
    ]
    /// The country row the walk picks, by its name wherever the list puts it: 7.x's list has no suggestions and starts
    /// at Afghanistan, and a row picked by place gave the device a Persian or Arabic region.
    public static let country = "United States"
    public static let alertYes = ["OK", "Skip", "Agree", "Continue", "Don't Use", "Don't Add"]
    public static let nextArrow = (x: 587.0 / 640, y: 84.0 / 960)
    /// The navigation bar's Back (top left), in any language.
    public static let back = (x: 0.08, y: 84.0 / 960)
    /// Rows the language page shows together only when it lists every language: 5.x and 6.x Setup does that when it
    /// guessed no country (no SIM country, no 802.11d country from a Wi-Fi scan), and then has no Welcome animation
    /// above the list; a guessed country's page offers at most four of its languages and More.
    public static let everyLanguage = ["English", "Deutsch", "Nederlands", "Italiano"]

    /// Whether a language page (`read`, the labels on it) lists every language rather than a country's few.
    public static func listsEveryLanguage(_ read: [String: (x: Double, y: Double)]) -> Bool {
        let found = normalized(read)
        return everyLanguage.allSatisfy { found[$0] != nil }
    }

    public enum Step: Equatable, Sendable {
        case tap(Double, Double, String?)
        case pause(Double)
        case slideIfLockScreen
        /// A vertical drag through the list at mid-width, from y to y: `fast` lets it fling on.
        case scroll(Double, Double, fast: Bool)
    }

    /// The labels as the plan matches them: Vision reads 7.x's curly apostrophe as such and sometimes a stray mark
    /// before a label ("• Don't Add Passcode" on 11D257's passcode page, which kept the walk there until a read came
    /// back clean or the page budget ran out), so a label's leading marks go and its apostrophes are straight. A mark
    /// alone (a row's chevron) goes with them.
    public static func normalized(_ found: [String: (x: Double, y: Double)]) -> [String: (x: Double, y: Double)] {
        var out: [String: (x: Double, y: Double)] = [:]
        for (label, p) in found {
            let key = String(
                label.replacingOccurrences(of: "\u{2019}", with: "'").drop { !$0.isLetter && !$0.isNumber }
            )
            if !key.isEmpty, out[key] == nil { out[key] = p }
        }
        return out
    }

    /// One Setup page's taps, from the labels read on it (`pages`: what the walk has tapped so far).
    public static func plan(_ read: [String: (x: Double, y: Double)], pages: [String]) -> [Step] {
        let found = normalized(read)
        // Setup's Home sheet (Emergency Call / Start Over) dims the page, whose labels Vision still reads and whose
        // rows and Next it would tap in vain (n88 6.0.1: 40 pages of English): dismiss it before anything else.
        if let cancel = found["Cancel"], found["Start Over"] != nil {
            return [.tap(cancel.x, cancel.y, "(Cancel)")]
        }
        if let yes = alertYes.first(where: { found[$0] != nil }), let p = found[yes] {
            return [.tap(p.x, p.y, "(\(yes))")]
        }
        var steps: [Step] = []
        let pick = picks.first { found[$0] != nil }
        let heading = found.keys.contains { $0.localizedCaseInsensitiveContains("countr") }
        // The page after the language page's English (and its arrow) is the country page in English: its heading or
        // United States. A read (the status bar at least) with neither, and English gone, is the country page in a
        // language chosen before English was (n90 11D257: 繁體中文, by a slide, under whose "Setting language" alert
        // English was tapped in vain), which the walk can't read: back to the languages, again until they are up.
        let language = pages.filter { $0 != "(Back)" }.suffix(2).first == "English"
        if language, !found.isEmpty, found["English"] == nil, !heading, pick != country {
            return [.tap(back.x, back.y, "(Back)")]
        }
        // The country list without United States on screen (its title or section heading, or a list the walk has
        // scrolled): scroll toward it by the names on screen. Next stays disabled until a country is chosen.
        let list = pages.last == "(scroll)" || heading
        if pick == nil, list, let move = scroll(found) {
            return [move]
        }
        if let pick, let p = found[pick] {
            // a label tapped again and again: nudge the tap (as walk_setup, the digitizer's edges)
            let again = pages.filter { $0 == pick }.count
            steps.append(.tap(p.x, p.y + [0, -14, 14, -24, 24][again % 5] / 960, pick))
            if pick.hasPrefix("Start Using") || pick == "Get Started" { return steps }
            steps.append(.pause(1.5))
        }
        // The language page: 7.x moves on when its English row is tapped; 6.x needs its arrow after (top right).
        if pick == nil, let english = found["English"] {
            steps += [.tap(english.x, english.y, "English"), .pause(1.5)]
        }
        if let next = found["Next"] ?? (found["English"] != nil ? nextArrow : nil) {
            steps.append(
                .tap(
                    next.x,
                    next.y,
                    pick == nil
                        ? (found.filter { $0.value.y < 130.0 / 960 && $0.key != "Next" }.keys.first ?? "?") : nil
                )
            )
        } else if pick == nil {
            steps.append(.slideIfLockScreen)
        }
        return steps
    }

    /// Which way the country list moves toward `country`, from the names on screen (labels below the status bar that
    /// start with a capital, not the page's own): a fling on while every name is before T, a screen on from there, a
    /// screen back once every name is past it; nil without names.
    static func scroll(_ found: [String: (x: Double, y: Double)]) -> Step? {
        let names = found.filter {
            $0.value.y > 0.06 && $0.key.first?.isUppercase == true && !["Back", "Next"].contains($0.key)
                && !$0.key.localizedCaseInsensitiveContains("countr")
                && !$0.key.localizedCaseInsensitiveContains("region")
        }
        .keys.sorted { order($0, $1) == .orderedAscending }
        guard let first = names.first, let last = names.last else { return nil }
        if order(first, country) == .orderedDescending { return .scroll(0.25, 0.85, fast: false) }
        return .scroll(0.85, 0.25, fast: order(last, "T") == .orderedAscending)
    }

    static func order(_ a: String, _ b: String) -> ComparisonResult {
        a.compare(b, options: [.caseInsensitive, .diacriticInsensitive])
    }
}
