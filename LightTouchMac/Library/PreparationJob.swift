// One IPSW → device preparation: runs `firmwarekit create` into
// State/Preparing/<id>/, reads its JSON Lines, and publishes the result as
// Devices/<id>/base plus device.json. See "Preparer contract" in
// docs/multi-device-plan.md.
//
// The job id is also the new device's id and its identity seed. Staging and
// the published device are on one volume, so the publish is a rename and the
// sparse NAND stays sparse. Nothing outside Preparing/ is written until the
// preparer says done; the whole device is assembled in Preparing/<id>.publish
// and appears in Devices/ with one rename, so a failure never leaves a half
// device and never touches a published one.

import CryptoKit
import Foundation

nonisolated final class PreparationJob: @unchecked Sendable {
    struct Request: Sendable {
        var entry: FirmwareCatalog.Entry
        var ipsw: URL
        /// recipe.keybag_ramdisk_from: that entry and its IPSW (its ramdisk boots the keybag one-shot).
        var sibling: (entry: FirmwareCatalog.Entry, ipsw: URL)?
        /// The state directory (Preparing/ and Devices/ are under it).
        var state: URL
        var preparer: URL
        var helper: URL
        /// Decrypted components by IPSW sha1; this IPSW's are deleted when the job ends, however it ends.
        var cache: URL
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
        /// `piece`: a required fit check's piece that didn't fit ("OpenGLES front end (contrib/gles-public)").
        case error(code: String, message: String, piece: String? = nil)

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
            case "error": self = .error(code: object["code"] as? String ?? "internal", message: object["message"] as? String ?? "",
                                        piece: object["piece"] as? String)
            default: return nil
            }
        }
    }

    /// What the row says for an error event. The detail stays in the preparer's log.
    static func message(code: String, detail: String, piece: String? = nil, beta: Bool = false) -> String {
        switch code {
        case "key_missing": "Light Touch doesn’t have the keys for this firmware."
        case "sha_mismatch": "This IPSW doesn’t match the one Light Touch knows."
        case "unsupported" where piece != nil:
            "Light Touch can’t prepare this \(beta ? "beta" : "version") yet: \(unsupportedReason(piece!))."
        case "unsupported": "This IPSW isn’t supported."
        case "activation_failed", "hook_failed": "Couldn’t activate this device."
        case "oneshot_failed": "The device’s first boot didn’t finish."
        case "disk_full": "Not enough disk space to prepare this device."
        default: detail.isEmpty ? "Preparation failed." : "Preparation failed: \(detail)"
        }
    }

    /// A fit check's piece (FirmwareKit's FitCheck names) in the user's words.
    static func unsupportedReason(_ piece: String) -> String {
        if piece.hasPrefix("OpenGLES") { return "its graphics library isn’t supported" }
        if piece.hasPrefix("kernelcache") || piece.hasPrefix("boot-arg") || piece.hasPrefix("DeviceTree") { return "the way it starts up isn’t supported" }
        if piece.localizedCaseInsensitiveContains("appsync") { return "installing apps on it isn’t supported" }
        return "the guest tools don’t run on it"   // it_boot, the guest package's pieces, the helpers
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
    private var siblingFile: URL { Self.preparing(request.state).appendingPathComponent("\(id.uuidString).sibling.json") }
    static func preparing(_ state: URL) -> URL { state.appendingPathComponent("Preparing", isDirectory: true) }

    /// Events arrive on a background queue, `.published`, `.failed` or `.cancelled` last.
    init(_ request: Request, onEvent: @escaping @Sendable (Event) -> Void) {
        self.request = request
        self.onEvent = onEvent
    }

    func start() {
        do {
            try StorageLocations.privateDirectory(staging)
            StorageLocations.excludeFromBackup(Self.preparing(request.state))
            try JSONEncoder().encode(request.entry).write(to: entryFile)
            try StorageLocations.privateDirectory(request.log.deletingLastPathComponent())
            FileManager.default.createFile(atPath: request.log.path, contents: nil)
            process.executableURL = request.preparer
            process.arguments = ["create", "--entry", entryFile.path, "--ipsw", request.ipsw.path, "--out", staging.path,
                                 "--seed", id.uuidString, "--helper", request.helper.path, "--cache", request.cache.path]
            if let sibling = request.sibling {
                try JSONEncoder().encode(sibling.entry).write(to: siblingFile)
                process.arguments! += ["--sibling-entry", siblingFile.path, "--sibling-ipsw", sibling.ipsw.path]
            }
            let stdout = Pipe()
            process.standardOutput = stdout
            process.standardError = try FileHandle(forWritingTo: request.log)
            process.standardInput = FileHandle.nullDevice
            try process.run()
            if lock.withLock({ cancelled }) { cancel() }
            Thread.detachNewThread { [self] in read(stdout.fileHandleForReading) }
        } catch {
            finish(.failed("Couldn’t start preparing the device: \(error.localizedDescription)"))
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
        case let .error(code, detail, piece)?:
            // A cached or imported IPSW that fails its SHA is never used again.
            if code == "sha_mismatch" { try? FileManager.default.removeItem(at: request.ipsw) }
            finish(.failed(Self.message(code: code, detail: detail, piece: piece, beta: request.entry.prerelease != nil)))
        default:
            logEvent("firmware: firmwarekit exited \(status) without a result")
            finish(.failed("Preparation stopped unexpectedly."))
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
        if case .published = event {} else { try? DeviceStateStorage.removeTree(staging) }
        try? FileManager.default.removeItem(at: entryFile)
        // Retain verified results for reuse. Cleanup is coordinated by the
        // preparer's cache-prune command, which holds the same root lease as
        // every reader; a completed job cannot delete another job's inputs.
        onEvent(event)
    }

    /// Launch, under the app lock: nothing in Preparing/ is a device. Disk
    /// images a killed preparer left attached there are detached first, or
    /// their files couldn't go.
    static func sweep(state: URL) {
        let preparing = preparing(state)
        let names = (try? FileManager.default.contentsOfDirectory(atPath: preparing.path)) ?? []
        guard !names.isEmpty else { return }
        detachImages(under: preparing)
        for name in names { try? DeviceStateStorage.removeTree(preparing.appendingPathComponent(name)) }
    }

    /// `hdiutil detach -force` for every attached image whose file is under `root`.
    static func detachImages(under root: URL) {
        func run(_ arguments: [String]) -> Data? {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
            process.arguments = arguments
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = FileHandle.nullDevice
            guard (try? process.run()) != nil else { return nil }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return process.terminationStatus == 0 ? data : nil
        }
        let prefix = DeviceStateStorage.canonicalPath(root) + "/"
        guard let data = run(["info", "-plist"]),
              let info = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else { return }
        for image in info["images"] as? [[String: Any]] ?? [] {
            guard let path = image["image-path"] as? String,
                  DeviceStateStorage.canonicalPath(URL(fileURLWithPath: path)).hasPrefix(prefix),
                  let device = (image["system-entities"] as? [[String: Any]])?.compactMap({ $0["dev-entry"] as? String })
                      .min(by: { $0.count < $1.count }) else { continue }
            logEvent("firmware: detaching \(device), left attached from \(path)")
            _ = run(["detach", device, "-force"])
        }
    }

    // MARK: - Publish

    func publish(lock lockName: String) throws -> DeviceInstance {
        try Self.publish(staging: staging, entry: request.entry, id: id, state: request.state, lock: lockName)
    }

    /// Assembles Preparing/<id>.publish/{base, device.json} (the staging
    /// directory renamed to base) and renames it to Devices/<id> in one
    /// step. Any failure before that rename leaves Devices/ untouched. Also
    /// a development base's record (`staging` absolute, kept in place: `keep`).
    static func publish(staging: URL, entry: FirmwareCatalog.Entry, id: UUID, state: URL,
                        lock lockName: String = "device.lock.json", keep: Bool = false) throws -> DeviceInstance {
        let fm = FileManager.default
        let profile = entry.profile ?? .iPad1
        let lockURL = staging.appendingPathComponent(lockName)
        let boot = profile.preparedBoot(strategy: BootRecipe.bootStrategy(lockURL))
        for name in [boot.boot, "nand", "identity.json", lockName] + boot.files
            where !fm.fileExists(atPath: staging.appendingPathComponent(name).path) {
            throw FirmwareError.failed("The prepared device is incomplete (\(name) is missing).")
        }
        let lockData = try Data(contentsOf: lockURL)
        let identity = identity(identityJSON: try? Data(contentsOf: staging.appendingPathComponent("identity.json")),
                                lock: lockData, seed: id.uuidString)
        let directory = DeviceInstance.directory(id, state: state)
        let relative = "Devices/\(id.uuidString)"
        let base = keep ? staging.path : "\(relative)/base"
        let instance = DeviceInstance(
            id: id, name: entry.profile?.displayName ?? entry.productType, board: entry.board, firmware: entry.id,
            created: DeviceInstance.now, base: .init(kind: .prepared, path: base),
            storage: .init(key: String(sha256(lockData).prefix(16)), overlay: "\(relative)/overlay",
                           writableNOR: fm.fileExists(atPath: staging.appendingPathComponent("nor.bin").path)
                               ? "\(relative)/nor.bin" : nil,
                           snapshot: "\(relative)/snapshot", usbmuxConf: "\(relative)/usbmuxd-conf"),
            identity: identity, provenance: .init(lock: "\(base)/\(lockName)", sha256: sha256(lockData)))
        let publishing = preparing(state).appendingPathComponent("\(id.uuidString).publish", isDirectory: true)
        do {
            try StorageLocations.privateDirectory(publishing)
            if !keep { try fm.moveItem(at: staging, to: publishing.appendingPathComponent("base", isDirectory: true)) }
            try DeviceInstance.encoder.encode(instance)
                .write(to: publishing.appendingPathComponent(DeviceInstance.recordName), options: .atomic)
            try StorageLocations.privateDirectory(directory.deletingLastPathComponent())
            guard rename(publishing.path, directory.path) == 0 else { throw StorageLocations.posixError() }
        } catch {
            try? DeviceStateStorage.removeTree(publishing)
            throw error
        }
        if !keep { DeviceStateStorage.lockBase(directory.appendingPathComponent("base", isDirectory: true)) }
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
