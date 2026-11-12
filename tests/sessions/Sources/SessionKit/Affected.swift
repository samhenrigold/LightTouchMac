import Foundation

/// What a change has to be checked with, from the paths it touches (`sessions affected`): the Unit plan always, and
/// boots of one row per board family when it can reach a boot. A path the rules don't place boots every family: a
/// missed regression costs more than a matrix.
public enum Affected {
    /// One row per board family, the rows that between them cover every recipe family, each with the create flags it
    /// is prepared with (the 5.1 iPod touch also jailbroken: Cydia, Substrate, afc2).
    public static let families: [(row: String, create: [String])] = [
        ("m68ap-1A543a", []), ("n45ap-4A102", []), ("n72ap-7E18", []), ("k48ap-7B500", []),
        ("n81ap-9B176", ["--jailbreak"]), ("n88ap-10B500", []), ("n90ap-11D257", []), ("n42ap-14G61", [])
    ]

    public struct Plan: Equatable {
        /// The boards whose family rows boot; empty: none.
        public var boards: Set<String> = []
        /// Why each board boots: the first path that asked for it.
        public var reasons: [String: String] = [:]
        /// Paths that need nothing past the Unit plan.
        public var unitOnly: [String] = []
        /// Documentation: nothing runs for it.
        public var nothing: [String] = []
    }

    static var allBoards: Set<String> { Set(families.map { String($0.row.prefix { $0 != "-" }) }) }

    /// The boards a path's change can break at boot: nil when it needs only the Unit plan, empty when nothing.
    public static func boards(for path: String) -> Set<String>? {
        let all = allBoards
        if path.hasSuffix(".md") || path == "LICENSE" { return [] }
        // Preparation code for one board family; the rest of FirmwareKit can reach any.
        let firmware = "Packages/FirmwareKit/Sources/FirmwareKit/"
        if path.hasPrefix(firmware) {
            let rest = path.dropFirst(firmware.count)
            // K48Board prepares the iPad, the 3GS and the A4 boards; N45Board the first iPhone and iPod touch;
            // N42Board (with the A6 pieces) the iPhone 5, which boots KBoot's kboot.bin too.
            if rest.hasPrefix("K48") { return ["k48ap", "n81ap", "n88ap", "n90ap"] }
            if rest.hasPrefix("KBoot") { return ["k48ap", "n81ap", "n88ap", "n90ap", "n42ap"] }
            if rest.hasPrefix("N42") || rest.hasPrefix("A6") { return ["n42ap"] }
            if rest.hasPrefix("N45") { return ["n45ap", "m68ap"] }
            if rest.hasPrefix("N72") { return ["n72ap"] }
            return all
        }
        // Tests, and code no boot runs: the app target's own (the drivers stand in for it with the packages' code),
        // except its catalog, which says how every row is prepared.
        if path.hasPrefix("LightTouchMac/") {
            return path.hasPrefix("LightTouchMac/Resources/firmware-catalog") ? all : nil
        }
        let unit = [
            "Packages/FirmwareKit/Tests/", "Packages/LightTouchCore/Tests/", "Packages/HostRuntime/Tests/",
            "Packages/DeviceRuntime/Tests/", "Packages/DeviceServices/Tests/", "Packages/BuildTools/",
            "Packages/ReleaseChecks/", "tests/offline/", "tests/scripts/", "tests/sessions/Tests/", "Models/",
            "Unit.xctestplan", "Release.xctestplan", "scripts/format", "scripts/ship", "scripts/clean",
            ".swift-format", ".github/"
        ]
        if unit.contains(where: { path.hasPrefix($0) }) { return nil }
        return all
    }

    public static func plan(paths: [String]) -> Plan {
        var plan = Plan()
        for path in paths {
            switch boards(for: path) {
            case nil: plan.unitOnly.append(path)
            case let boards? where boards.isEmpty: plan.nothing.append(path)
            case let boards?:
                for board in boards.subtracting(plan.boards) { plan.reasons[board] = path }
                plan.boards.formUnion(boards)
            }
        }
        return plan
    }
}
