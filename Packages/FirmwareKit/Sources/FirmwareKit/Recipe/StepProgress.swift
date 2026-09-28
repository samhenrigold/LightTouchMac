// The contract's `progress` events for Preparer.create: one per second while a step runs, plus a 1.0
// when it ends. The fraction is measured where the step can say (bytes hashed) and otherwise follows
// the step's plan: serial-log milestones of the one-shot boots, and elapsed time against the expected
// seconds in between. It never goes back and stays below 1 until the step is over.
//
//   let p = StepProgress(emit: emit)          // heartbeat thread until p.stop()
//   p.next(index: 3, name: "Writing the NAND") // ends the previous step (1.0), emits the step event
//   p.measure = { hashed / total }             // optional, for this step only
//   p.finish()                                 // the last step's 1.0

import Foundation

/// What one step expects: its seconds on a recent Mac, what to say, and (boots) the serial-log lines it passes.
struct StepPlan: Sendable {
    /// A line in a serial log under the work directory, `at` seconds into the step. `file` ending in "-" is a
    /// prefix: the newest match (keybag-1.log, keybag-2.log on a retry).
    struct Milestone: Sendable { var file: String, marker: String, at: Double, text: String }
    var seconds: Double, text: String, milestones: [Milestone] = []

    // Timings: firmwarekit create of 7B500 and 8C148 on an M4 Max, 2026-09-28 (the seal is most of it; its
    // flash indexing took 1-12 s and the NAND 3-13 s across runs).
    static let plans: [String: StepPlan] = [
        "Verifying the IPSW": .init(seconds: 2, text: "Checking the IPSW’s checksum"),
        "Decrypting the firmware": .init(seconds: 5, text: "Decrypting the firmware"),
        "Writing the identity and boot image": .init(seconds: 1, text: "Writing the boot image"),
        "Building the system and data volumes": .init(seconds: 12, text: "Building the system and data volumes"),
        "Writing the NAND": .init(seconds: 8, text: "Writing the flash image"),
        "Creating the data-protection keybag": .init(seconds: 6, text: "Booting the restore ramdisk", milestones: [
            .init(file: "keybag-", marker: "FTL_Open", at: 2, text: "Opening the flash"),
            .init(file: "keybag-", marker: "it_keybag:", at: 4, text: "Creating the keybag"),
        ]),
        "Sealing the NAND": .init(seconds: 72, text: "Booting to seal the flash", milestones: [
            .init(file: "seal.log", marker: "CXT is not valid", at: 1, text: "Booting to seal the flash: indexing the new flash"),
            .init(file: "seal.log", marker: "FTL_Open", at: 6, text: "Booting to seal the flash: opening the flash"),
            .init(file: "seal.log", marker: "launchd[1] has started", at: 19, text: "Booting to seal the flash: starting iOS"),
            .init(file: "seal.log", marker: "it_prefs:", at: 41, text: "Booting to seal the flash: first-boot setup"),
            .init(file: "seal.log", marker: "it_seal:", at: 65, text: "Shutting down to seal the flash"),
            .init(file: "check.log", marker: "iBoot version", at: 68, text: "Checking the sealed flash"),
        ]),
        "Writing the lock": .init(seconds: 3, text: "Hashing the prepared flash"),
        // n72 (N72Recipe; ~35 s for 7E18)
        "Writing the identity, NOR and boot files": .init(seconds: 2, text: "Writing the NOR and boot files"),
        "Building the system volume": .init(seconds: 20, text: "Building the system volume"),
        // 4.x data protection (N72Keybag): iBoot, the kernel entry handoff, then the ramdisk's it_keybag
        "Booting the restore ramdisk": .init(seconds: 40, text: "Booting the restore ramdisk", milestones: [
            .init(file: "keybag.log", marker: "FTL_Open", at: 10, text: "Booting the restore ramdisk: opening the flash"),
            .init(file: "keybag.log", marker: "it_keybag:", at: 30, text: "Creating the data-protection keybag"),
        ]),
    ]

    static func plan(_ name: String) -> StepPlan { plans[name] ?? .init(seconds: 10, text: name) }

    /// 0..<1 at `elapsed` s: the last milestone seen (`seen[i]`, when it was first seen) plus time toward the next.
    func fraction(elapsed: Double, seen: [Double?]) -> Double {
        let reached = seen.lastIndex { $0 != nil }
        let from = reached.map { milestones[$0].at } ?? 0, since = reached.map { seen[$0]! } ?? 0
        let to = reached.map { $0 + 1 < milestones.count ? milestones[$0 + 1].at : seconds } ?? (milestones.first?.at ?? seconds)
        let t = from + min(max(elapsed - since, 0), 0.95 * max(to - from, 0))   // time alone never reaches the next milestone
        return min(0.99, t / seconds)
    }
}

final class StepProgress: @unchecked Sendable {
    private let emit: @Sendable (PrepareEvent) -> Void
    private let work: URL?
    private let lock = NSLock(), done = DispatchSemaphore(value: 0), stopped = DispatchSemaphore(value: 0)
    private var plan: StepPlan?, text = "", started = Date(), last = 0.0, seen: [Double?] = [], measured: (@Sendable () -> Double)?

    /// `work` holds the one-shots' serial logs.
    init(work: URL?, emit: @escaping @Sendable (PrepareEvent) -> Void) {
        self.emit = emit
        self.work = work
        Thread.detachNewThread { [self] in
            while done.wait(timeout: .now() + 1) == .timedOut { lock.withLock { tick() } }
            stopped.signal()
        }
    }

    /// This step's own fraction (0...1), e.g. bytes hashed; the plan's time estimate otherwise.
    var measure: (@Sendable () -> Double)? {
        get { lock.withLock { measured } }
        set { lock.withLock { measured = newValue } }
    }

    /// Ends the current step with 1.0, then emits the step event and the new step's first progress.
    func next(index: Int, name: String) {
        lock.withLock {
            end()
            emit(.step(index: index, name: name))
            plan = StepPlan.plan(name)
            text = plan!.text; started = Date(); last = 0; seen = Array(repeating: nil, count: plan!.milestones.count); measured = nil
            tick()
        }
    }

    /// The last step's 1.0.
    func finish() { lock.withLock { end() } }

    /// Stops the heartbeat; no events after it returns.
    func stop() {
        done.signal()
        stopped.wait()
    }

    private func end() {
        guard let plan else { return }
        emit(.progress(1, detail: detail(text)))
        self.plan = nil
    }

    private func detail(_ text: String) -> String { "\(text) — \(Int(Date().timeIntervalSince(started))) s" }

    private func tick() {
        guard let plan else { return }
        let elapsed = Date().timeIntervalSince(started)
        if let work, !plan.milestones.isEmpty {
            var logs: [String: String] = [:]
            for (i, m) in plan.milestones.enumerated() {
                if seen[i] == nil {
                    let serial = logs[m.file] ?? Self.log(work, m.file)
                    logs[m.file] = serial
                    if serial.contains(m.marker) { seen[i] = elapsed }
                }
                if seen[i] != nil { text = m.text }
            }
        }
        let f = max(last, min(0.99, measured?() ?? plan.fraction(elapsed: elapsed, seen: seen)))
        last = f
        emit(.progress((f * 1000).rounded() / 1000, detail: detail(text)))
    }

    /// A serial log's text ("" until it exists); a "prefix-" names the newest of prefix*.log.
    static func log(_ work: URL, _ file: String) -> String {
        var name = file
        if file.hasSuffix("-") {
            let names = (try? FileManager.default.contentsOfDirectory(atPath: work.path)) ?? []
            guard let newest = names.filter({ $0.hasPrefix(file) && $0.hasSuffix(".log") })
                .max(by: { $0.localizedStandardCompare($1) == .orderedAscending }) else { return "" }
            name = newest
        }
        return (try? String(contentsOf: work.appendingPathComponent(name), encoding: .isoLatin1)) ?? ""
    }
}

/// Bytes done of a total, as a step's `measure`.
final class ByteCount: @unchecked Sendable {
    private let total: Int, lock = NSLock()
    private var done = 0
    init(total: Int) { self.total = total }
    func add(_ n: Int) { lock.withLock { done += n } }
    var fraction: Double { lock.withLock { total > 0 ? Double(done) / Double(total) : 0 } }
}
