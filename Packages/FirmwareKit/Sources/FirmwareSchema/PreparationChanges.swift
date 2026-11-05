// Which tree prepared a base, and what a base prepared from the current tree would have that it lacks.
import Foundation

/// The changes to what `firmwarekit create` puts in a base, in the order they landed. device.lock.json's
/// `preparation` is the serial of the last change the preparing tree had (`serial`); a lock written before
/// serials existed is judged by its `created` date against each change's `landed` date instead.
///
/// The rule: a commit that changes what preparation writes into a base for some rows (a system edit, the seal boot, an
/// activation step, a baked guest tool whose effect the seal boot records, a recipe derivation) appends a change here,
/// naming those rows, in the same commit, when a base prepared before it doesn't get it by itself at its next start
/// (boot admission, the guest package offered at boot or the emulator). A change every user's device must be prepared again for bumps the
/// catalog row's recipe version as well (FirmwareWire.Entry.Recipe.version: the app offers Prepare Again); a change
/// here only tells the checks (sessions) that an older base no longer stands for what the tree prepares.
nonisolated public enum PreparationChanges {
    public struct Change: Sendable {
        public let serial: Int
        /// The commit on main that made the change, and its commit date (ISO 8601).
        public let commit: String
        public let landed: String
        /// The rows it changes: boards, product version prefixes ("3.1" holds 3.1.3), builds and a recipe option the
        /// row has on; nil matches every row.
        public var boards: Set<String>? = nil
        public var versions: [String]? = nil
        public var builds: Set<String>? = nil
        public var option: String? = nil
        /// What a base prepared before it lacks.
        public let what: String

        public func applies(board: String, version: String, build: String, options: [String: Bool]) -> Bool {
            (boards?.contains(board) ?? true)
                && (versions?.contains { version == $0 || version.hasPrefix($0 + ".") } ?? true)
                && (builds?.contains(build) ?? true) && (option.map { options[$0] == true } ?? true)
        }
    }

    /// The serial a base prepared now records.
    public static var serial: Int { all.last?.serial ?? 0 }

    /// The changes after a base's preparation that apply to its row: after `serial` when the lock records one, else
    /// those that landed after `created`; every change when the lock records neither.
    public static func missing(
        serial: Int?,
        created: Date?,
        board: String,
        version: String,
        build: String,
        options: [String: Bool]
    ) -> [Change] {
        all.filter { change in
            let after: Bool
            if let serial {
                after = change.serial > serial
            } else if let created, let landed = ISO8601DateFormatter().date(from: change.landed) {
                after = landed > created
            } else {
                after = true
            }
            return after && change.applies(board: board, version: version, build: build, options: options)
        }
    }

    /// What differs between the recipe a base was prepared by (its lock's `entry.content.recipe`) and its row's in
    /// the catalog now: an older recipe version than boot admission migrates to, or an option the catalog row sets
    /// that the base's recipe had otherwise. Options the catalog no longer sets (they became derivations) are left out.
    public static func recipeDifferences(
        board: String,
        baseVersion: Int,
        baseOptions: [String: Bool],
        current: FirmwareWire.Entry.Recipe
    ) -> [String] {
        var differences: [String] = []
        let admitted = FirmwareWire.admittedRecipe(baseVersion, board: board)
        if admitted < current.version { differences.append("recipe \(admitted), the catalog's is \(current.version)") }
        for (key, value) in current.options.sorted(by: { $0.key < $1.key }) where (baseOptions[key] ?? false) != value {
            differences.append(
                "recipe option \(key) \(value ? "on" : "off") in the catalog, \(value ? "off" : "on") in the base"
            )
        }
        return differences
    }

    /// A prepared base judged against the tree: how it was made (one line) and why it is stale (empty: fresh).
    public struct Verdict: Sendable {
        public let fingerprint: String
        public let stale: [String]
    }

    /// `lock`: a base's device.lock.json; `catalog`: the catalog's entries now.
    public static func verdict(lock: [String: Any], catalog: [FirmwareWire.Entry]) -> Verdict {
        let entry = lock["entry"] as? [String: Any]
        let content = entry?["content"] as? [String: Any]
        let recipe = content?["recipe"] as? [String: Any]
        let id = entry?["id"] as? String
        let serial = lock["preparation"] as? Int
        let createdText = lock["created"] as? String
        let package = lock["guest_package"] as? [String: Any]
        let fingerprint = [
            id ?? "no catalog entry", "prepared \(createdText ?? "-")",
            "preparation \(serial.map(String.init) ?? "- (before serials)")",
            "recipe \((recipe?["version"] as? Int).map(String.init) ?? "-")",
            "firmwarekit \((lock["tool"] as? [String: Any])?["version"] as? String ?? "-")",
            "guest package \(package?["version"] as? String ?? "-") seed \((package?["seed"] as? Int).map(String.init) ?? "-")"
        ].joined(separator: ", ")
        guard let id, let content, let recipe else {
            return Verdict(
                fingerprint: fingerprint,
                stale: ["its lock names no catalog entry: firmwarekit did not prepare it"]
            )
        }
        guard let row = catalog.first(where: { $0.id == id }) else {
            return Verdict(fingerprint: fingerprint, stale: ["the catalog has no row \(id) any more"])
        }
        let options = recipe["options"] as? [String: Bool] ?? [:]
        var stale =
            row.recipe.map {
                recipeDifferences(
                    board: row.board,
                    baseVersion: recipe["version"] as? Int ?? 0,
                    baseOptions: options,
                    current: $0
                )
            } ?? []
        let created = createdText.flatMap { ISO8601DateFormatter().date(from: $0) }
        stale += missing(
            serial: serial,
            created: created,
            board: row.board,
            version: content["version"] as? String ?? row.version,
            build: row.build,
            options: options
        ).map { "\($0.commit) (\($0.landed.prefix(10))): \($0.what)" }
        return Verdict(fingerprint: fingerprint, stale: stale)
    }

    /// Serial 1 to 11 were listed when serials began (2026-10-20), from the preparation commits since the oldest
    /// firmwarekit base then (2026-10-04); a later change for the same rows stands for the ones before it. A change the
    /// catalog's recipe makes alone (an option turned on or off: 0248ff8f's bluetooth, 36f54957's and 61e549e2's
    /// ca_ogl) needs no entry, since recipeDifferences sees it in the lock.
    public static let all: [Change] = [
        Change(
            serial: 1,
            commit: "8b15001c",
            landed: "2026-10-05T19:19:16Z",
            boards: ["n88ap", "n90ap"],
            what: "the seal and keybag boots ran without the modem, so the activation state they stored is Unactivated"
        ),
        Change(
            serial: 2,
            commit: "298ede2f",
            landed: "2026-10-09T18:47:39Z",
            option: "appsync",
            what: """
                the seal boot's AppSync read only 4 KiB of load commands, so installd made no container for apps \
                whose entitlements lie past it (YouTube.migrator then crashes in DataMigrator)
                """
        ),
        Change(
            serial: 3,
            commit: "9c810e4e",
            landed: "2026-10-13T17:29:35Z",
            what: "AppleLanguages and AppleLocale are not seeded from the Mac's language and region"
        ),
        Change(
            serial: 4,
            commit: "6441a0c3",
            landed: "2026-10-14T02:38:29Z",
            what: ".GlobalPreferences has no AppleKeyboards seeded from the Mac's keyboards"
        ),
        Change(
            serial: 5,
            commit: "b518d9ae",
            landed: "2026-10-14T03:49:25Z",
            boards: ["n72ap"],
            what: "the NOR's SHSH is wrapped under the UID decrypt key and the lock boots aes-uid=engine"
        ),
        Change(
            serial: 6,
            commit: "87176ebc",
            landed: "2026-10-15T20:20:32Z",
            boards: ["n88ap", "n18ap", "k48ap", "n81ap", "n90ap"],
            versions: ["5", "6", "7"],
            option: "jailbreak",
            what: "the kernel's Seatbelt is stock, so sandboxed apps die when Substrate's library loads"
        ),
        Change(
            serial: 7,
            commit: "c4ad1d50",
            landed: "2026-10-17T14:06:04Z",
            boards: ["n88ap", "n18ap", "k48ap", "n81ap", "n90ap"],
            versions: ["4"],
            option: "jailbreak",
            what: "the sandbox patch missed sb_evaluate on 4.x, so sandboxed apps die when Substrate's library loads"
        ),
        Change(
            serial: 8,
            commit: "59889406",
            landed: "2026-10-18T17:16:45Z",
            boards: ["n45ap"],
            versions: ["1.1.3", "1.1.4", "1.1.5"],
            what:
                "the identity's serial can read as made before 2008, so lockdownd hides Mail, Maps, Stocks, Weather and Notes"
        ),
        Change(
            serial: 9,
            commit: "2db3a570",
            landed: "2026-10-19T20:50:36Z",
            boards: ["n88ap"],
            versions: ["3.1"],
            what: "the data volume is journaled, which 3.1's mount_hfs refuses: /private/var stays on the system volume"
        ),
        Change(
            serial: 10,
            commit: "eb35e92f",
            landed: "2026-10-20T02:31:30Z",
            boards: ["n81ap", "n90ap"],
            what: """
                kboot.bin's device tree is not the one iBoot hands the kernel (chip revision, panel and backlight ids, \
                pmgr clocks, clock frequencies, the A4 bridge and NAND timings)
                """
        ),
        Change(
            serial: 11,
            commit: "cedfc2d3",
            landed: "2026-10-20T05:59:20Z",
            boards: ["n90ap"],
            versions: ["7"],
            what: """
                the read-only root keeps the guest package it was prepared with (before serial 33), whose it_seal \
                crashes at every boot
                """
        ),
        Change(
            serial: 12,
            commit: "f3e5c8d8",
            landed: "2026-10-20T10:37:10Z",
            boards: ["n88ap", "n18ap"],
            versions: ["4", "5", "6"],
            what: "BTServer is disabled, though the machine answers the Bluetooth HCI"
        ),
        Change(
            serial: 13,
            commit: "92e707b4",
            landed: "2026-10-20T14:49:16Z",
            boards: ["n90ap"],
            versions: ["7"],
            what: "DeviceOMatic's job doesn't load it_msmquiet, so nothing hides its USB \"not supported\" notice"
        ),
        Change(
            serial: 14,
            commit: "76944f75",
            landed: "2026-10-20T15:38:50Z",
            boards: ["n90ap"],
            versions: ["7"],
            what: """
                the read-only root keeps the guest package it was prepared with (before serial 35), whose AppSync \
                carries Apple's certificate
                """
        ),
        Change(
            serial: 15,
            commit: "44b92c0b",
            landed: "2026-10-20T18:36:11Z",
            boards: ["n45ap", "m68ap"],
            versions: ["1.1.3", "1.1.4", "1.1.5"],
            what: """
                the Wi-Fi known network and the PAC'd AirPort service are in root's home, where configd from 1.1.3 \
                never looks, so it joins nothing at boot
                """
        ),
        Change(
            serial: 16,
            commit: "e50c6d02",
            landed: "2026-10-20T19:51:47Z",
            boards: ["n90ap"],
            versions: ["7"],
            what: """
                the read-only root keeps the guest package it was prepared with (before serial 36), whose it_prefs \
                crashes in libdispatch at every boot
                """
        ),
        Change(
            serial: 17,
            commit: "fdfd67a4",
            landed: "2026-10-20T22:35:15Z",
            boards: ["n88ap", "n18ap"],
            builds: ["8A230m"],
            what: """
                its seal boot set Auto-Lock Never only in ManagedConfiguration, which 4.0 beta 1's SpringBoard \
                doesn't time the lock by, so the device locks a minute after the last touch
                """
        ),
        Change(
            serial: 18,
            commit: "3eb0c3c3",
            landed: "2026-11-05T22:30:00Z",
            boards: ["n88ap", "n18ap", "k48ap", "n81ap", "n90ap"],
            option: "jailbreak",
            what: """
                its sandbox patch left sb_evaluate's action byte empty, so the kernel kills a sandboxed daemon that \
                switches profiles on exec: BTServer restarts all session on the boards that keep it
                """
        )
    ]
}
