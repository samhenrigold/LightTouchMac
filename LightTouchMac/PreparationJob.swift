// One IPSW → device preparation: runs `firmwarekit create` into
// State/Preparing/<id>/, reads its JSON Lines, and publishes the result as
// Devices/<id>/base plus device.json. See "Preparer contract" in
// docs/multi-device-plan.md.
//
// The job id is also the new device's id and its identity seed. Staging and
// the published device are on one volume, so the publish is a rename and the
// sparse NAND stays sparse. Nothing outside Preparing/<id> is written until
// the preparer says done; a record written last is what makes it a device,
// so a failure never leaves a half device and never touches a published one.

import CryptoKit
import Foundation

nonisolated final class PreparationJob: @unchecked Sendable {
    struct Request: Sendable {
        var entry: FirmwareCatalog.Entry
        var ipsw: URL
        /// The state directory (Preparing/ and Devices/ are under it).
        var state: URL
        var preparer: URL
        var helper: URL
        /// Decrypted components by IPSW sha1; this IPSW's are deleted after a publish.
        var cache: URL
        var activationHook: String?
        /// The preparer's stderr.
        var log: URL
    }

    enum Event: Sendable, Equatable {
        /// The preparer's expected seconds per step (empty if it gave none), before the first step.
        case begin(seconds: [Double])
        case step(Int, of: Int, name: String)
        /// Within the current step, 0...1, and what the step is doing.
        case progress(Double, detail: String?)
        case warning(String)
        case published(DeviceInstance)
        case failed(String)
        case cancelled
    }

    /// One line of the preparer's stdout.
    enum Line: Equatable {
        case begin(steps: Int, seconds: [Double] = [])
        case step(index: Int, name: String)
        case progress(Double, detail: String? = nil)
        case warning(String)
        case done(lock: String)
        case error(code: String, message: String)

        init?(_ text: some StringProtocol) {
            guard let data = text.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let event = object["event"] as? String else { return nil }
            let int = { (key: String) in (object[key] as? NSNumber)?.intValue }
            switch event {
            case "begin": guard let steps = int("steps") else { return nil }
                self = .begin(steps: steps, seconds: (object["seconds"] as? [NSNumber])?.map(\.doubleValue) ?? [])
            case "step": guard let index = int("index") else { return nil }
                self = .step(index: index, name: object["name"] as? String ?? "")
            case "progress": guard let fraction = (object["fraction"] as? NSNumber)?.doubleValue else { return nil }
                self = .progress(fraction, detail: object["detail"] as? String)
            case "warning": self = .warning(object["message"] as? String ?? "")
            case "done": self = .done(lock: object["lock"] as? String ?? "device.lock.json")
            case "error": self = .error(code: object["code"] as? String ?? "internal", message: object["message"] as? String ?? "")
            default: return nil
            }
        }
    }

    /// What the row says for an error event.
    static func message(code: String, detail: String) -> String {
        switch code {
        case "key_missing": "This firmware’s keys are missing."
        case "sha_mismatch": "This IPSW doesn’t match the one Light Touch knows."
        case "unsupported": "Not a supported firmware."
        case "hook_failed": "The activation hook failed."
        case "oneshot_failed": "The device’s first boot didn’t finish."
        case "disk_full": "Not enough disk space to prepare this device."
        default: detail.isEmpty ? "Preparation failed." : "Preparation failed: \(detail)"
        }
    }

    let id = UUID()
    let request: Request
    private let onEvent: @Sendable (Event) -> Void
    private let process = Process()
    private let lock = NSLock()
    private var steps = 0
    private var outcome: Line?
    private var cancelled = false

    var staging: URL { Self.preparing(request.state).appendingPathComponent(id.uuidString, isDirectory: true) }
    private var entryFile: URL { Self.preparing(request.state).appendingPathComponent("\(id.uuidString).entry.json") }
    static func preparing(_ state: URL) -> URL { state.appendingPathComponent("Preparing", isDirectory: true) }

    /// Events arrive on a background queue, `.published`, `.failed` or `.cancelled` last.
    init(_ request: Request, onEvent: @escaping @Sendable (Event) -> Void) {
        self.request = request
        self.onEvent = onEvent
    }

    func start() {
        do {
            try StorageLocations.privateDirectory(staging)
            try JSONEncoder().encode(request.entry).write(to: entryFile)
            try StorageLocations.privateDirectory(request.log.deletingLastPathComponent())
            FileManager.default.createFile(atPath: request.log.path, contents: nil)
            process.executableURL = request.preparer
            process.arguments = ["create", "--entry", entryFile.path, "--ipsw", request.ipsw.path, "--out", staging.path,
                                 "--seed", id.uuidString, "--helper", request.helper.path, "--cache", request.cache.path]
                + (request.activationHook.map { ["--activation-hook", $0] } ?? [])
            let stdout = Pipe()
            process.standardOutput = stdout
            process.standardError = try FileHandle(forWritingTo: request.log)
            process.standardInput = FileHandle.nullDevice
            try process.run()
            if lock.withLock({ cancelled }) { cancel() }
            Thread.detachNewThread { [self] in read(stdout.fileHandleForReading) }
        } catch {
            finish(.failed("Couldn’t start the preparer: \(error.localizedDescription)"))
        }
    }

    /// SIGTERM, and SIGKILL if the preparer is still there after 5 s (the
    /// contract gives it 2). The staging directory goes when it exits.
    func cancel() {
        lock.withLock { cancelled = true }
        guard process.isRunning else { return }
        let pid = process.processIdentifier
        process.terminate()
        DispatchQueue.global().asyncAfter(deadline: .now() + 5) { [process] in
            if process.isRunning { kill(pid, SIGKILL) }
        }
    }

    private func read(_ handle: FileHandle) {
        var buffer = Data()
        while case let chunk = handle.availableData, !chunk.isEmpty {
            buffer.append(chunk)
            while let newline = buffer.firstIndex(of: 0x0A) {
                let text = String(decoding: buffer[..<newline], as: UTF8.self)
                buffer.removeSubrange(...newline)
                receive(Line(text))
            }
        }
        process.waitUntilExit()
        let status = process.terminationStatus
        if lock.withLock({ cancelled }) { return finish(.cancelled) }
        switch lock.withLock({ outcome }) {
        case let .done(lockName)? where status == 0:
            do { finish(.published(try publish(lock: lockName))) }
            catch { finish(.failed("Couldn’t save the prepared device: \(error.localizedDescription)")) }
        case let .error(code, detail)?: finish(.failed(Self.message(code: code, detail: detail)))
        default: finish(.failed("The preparer stopped unexpectedly (exit \(status))."))
        }
    }

    private func receive(_ line: Line?) {
        switch line {
        case let .begin(count, seconds)?:
            lock.withLock { steps = count }
            onEvent(.begin(seconds: seconds))
        case let .step(index, name)?: onEvent(.step(index, of: lock.withLock { steps }, name: name))
        case let .warning(message)?: onEvent(.warning(message))
        case .done?, .error?: lock.withLock { if outcome == nil { outcome = line } }
        case let .progress(fraction, detail)?: onEvent(.progress(fraction, detail: detail))
        case nil: break
        }
    }

    private func finish(_ event: Event) {
        if case .published = event {} else { IPSWStore.removeTree(staging) }
        try? FileManager.default.removeItem(at: entryFile)
        onEvent(event)
    }

    // MARK: - Publish

    /// Renames the staging directory to Devices/<id>/base and writes the
    /// record. Until the record exists nothing is a device, so any failure
    /// removes Devices/<id> whole.
    func publish(lock lockName: String) throws -> DeviceInstance {
        let fm = FileManager.default
        for name in ["kboot.bin", "nand", "identity.json", lockName] where !fm.fileExists(atPath: staging.appendingPathComponent(name).path) {
            throw FirmwareError.failed("The preparer’s output has no \(name).")
        }
        let lockURL = staging.appendingPathComponent(lockName)
        let lockData = try Data(contentsOf: lockURL)
        let identity = Self.identity(identityJSON: try? Data(contentsOf: staging.appendingPathComponent("identity.json")),
                                     lock: lockData, seed: id.uuidString)
        let directory = DeviceInstance.directory(id, state: request.state)
        let relative = "Devices/\(id.uuidString)"
        let entry = request.entry
        let instance = DeviceInstance(
            id: id, name: entry.profile?.displayName ?? entry.productType, board: entry.board, firmware: entry.id,
            created: DeviceInstance.now, base: .init(kind: .prepared, path: "\(relative)/base"),
            storage: .init(key: String(Self.sha256(lockData).prefix(16)), overlay: "\(relative)/overlay",
                           writableNOR: fm.fileExists(atPath: staging.appendingPathComponent("nor.bin").path)
                               ? "\(relative)/nor.bin" : nil,
                           snapshot: "\(relative)/snapshot", resetMarker: nil, usbmuxConf: "\(relative)/usbmuxd-conf"),
            identity: identity, provenance: .init(lock: "\(relative)/base/\(lockName)", sha256: Self.sha256(lockData)))
        do {
            try StorageLocations.privateDirectory(directory)
            try fm.moveItem(at: staging, to: directory.appendingPathComponent("base", isDirectory: true))
            try instance.write(state: request.state)
        } catch {
            IPSWStore.removeTree(directory)
            throw error
        }
        IPSWStore.removeTree(request.cache.appendingPathComponent(entry.source.sha1 ?? "-", isDirectory: true))
        return instance
    }

    /// udid and die id from identity.json, else the lock's identity; the seed is ours.
    static func identity(identityJSON: Data?, lock: Data, seed: String) -> DeviceInstance.Identity {
        func object(_ data: Data?) -> [String: Any] {
            data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
        }
        let file = object(identityJSON), locked = object(lock)["identity"] as? [String: Any] ?? [:]
        func dieID(_ value: Any?) -> String? { (value as? [String])?.joined(separator: ":") ?? value as? String }
        return .init(seed: locked["seed"] as? String ?? seed,
                     udid: file["udid"] as? String ?? locked["udid"] as? String,
                     dieID: dieID(file["die-id"] ?? file["die_id"]) ?? dieID(locked["die_id"]))
    }

    static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
