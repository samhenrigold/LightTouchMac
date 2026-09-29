import Foundation
import OSLog

/// Synchronous low-level writer shared by pipe readers. The lock protects the
/// entire rotate/write operation; a writer never holds a descriptor across a
/// rename. This bounds disk usage without truncating a live subprocess's file.
nonisolated final class RotatingLog: @unchecked Sendable {
    let url: URL
    private let limit: Int
    private let lock = NSLock()
    private var failed = false
    private static let logger = Logger(subsystem: StorageLocations.bundleIdentifier, category: "log-storage")

    init(url: URL, limit: Int = StorageLocations.logLimit) {
        self.url = url
        self.limit = limit
    }

    func append(_ data: Data) {
        lock.lock()
        defer { lock.unlock() }
        guard !failed, !data.isEmpty else { return }
        do {
            try StorageLocations.privateDirectory(url.deletingLastPathComponent())
            let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
            if let type = attributes?[.type] as? FileAttributeType, type != .typeRegular {
                throw CocoaError(.fileWriteUnknown)
            }
            let size = (attributes?[.size] as? NSNumber)?.intValue ?? 0
            let bounded = data.suffix(limit)
            if size + bounded.count > limit { try Self.rotate(url) }
            let fd = open(url.path, O_WRONLY | O_APPEND | O_CREAT | O_CLOEXEC | O_NOFOLLOW, 0o600)
            guard fd >= 0 else { throw StorageLocations.posixError() }
            let file = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
            defer { try? file.close() }
            guard fchmod(fd, 0o600) == 0 else { throw StorageLocations.posixError() }
            try file.write(contentsOf: bounded)
        } catch {
            failed = true
            Self.logger.error("Cannot write diagnostic log: \(error.localizedDescription, privacy: .public)")
        }
    }

    static func rotate(_ url: URL) throws {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        let previous = url.appendingPathExtension("1")
        // POSIX rename replaces the previous generation atomically.
        guard rename(url.path, previous.path) == 0 else { throw StorageLocations.posixError() }
    }
}

/// Dispatch sources are the bridge to descriptors owned by native code. Each
/// callback drains at most one bounded chunk; no unbounded async Data queue or
/// per-line allocation can accumulate behind a noisy native writer.
nonisolated final class LogPipeReader: @unchecked Sendable {
    private let source: any DispatchSourceRead
    private let queue: DispatchQueue
    private let descriptor: Int32
    private let cancellation = DispatchGroup()
    private let log: RotatingLog
    // Accessed only on queue, including EOF and explicit teardown.
    private var stopped = false
    /// Phrases to report the first time they pass through (LogWatch), on the reader's queue.
    private var watch: LogWatch?

    /// Bytes in, `onMatch(phrase)` once per phrase, across chunk boundaries.
    nonisolated final class LogWatch {
        private var pending: [Data]
        private var tail = Data()
        private let onMatch: @Sendable (String) -> Void
        init(phrases: [String], onMatch: @escaping @Sendable (String) -> Void) {
            pending = phrases.map { Data($0.utf8) }
            self.onMatch = onMatch
        }
        func scan(_ chunk: Data) {
            guard !pending.isEmpty else { return }
            let window = tail + chunk
            for phrase in pending where window.range(of: phrase) != nil {
                pending.removeAll { $0 == phrase }
                onMatch(String(decoding: phrase, as: UTF8.self))
            }
            let keep = pending.map(\.count).max() ?? 0
            tail = keep > 1 ? window.suffix(keep - 1) : Data()
        }
    }

    init(descriptor: Int32, log: RotatingLog, watch: LogWatch? = nil, cleanup: (@Sendable () -> Void)? = nil) throws {
        let flags = fcntl(descriptor, F_GETFL)
        guard flags >= 0, fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) == 0 else {
            throw StorageLocations.posixError()
        }
        self.descriptor = descriptor
        self.log = log
        self.watch = watch
        self.queue = DispatchQueue(label: "LightTouch.log.\(log.url.lastPathComponent)", qos: .utility)
        source = DispatchSource.makeReadSource(fileDescriptor: descriptor, queue: queue)
        source.setEventHandler { [weak self] in self?.readChunk() }
        let cancellation = self.cancellation
        cancellation.enter()
        source.setCancelHandler {
            Darwin.close(descriptor)
            cleanup?()
            cancellation.leave()
        }
        source.resume()
    }

    private func readChunk() {
        guard !stopped else { return }
        var bytes = [UInt8](repeating: 0, count: 32_768)
        let count = read(descriptor, &bytes, bytes.count)
        if count > 0 {
            let chunk = Data(bytes.prefix(count))
            log.append(chunk)
            watch?.scan(chunk)
        } else if count == 0 || (errno != EAGAIN && errno != EINTR) {
            stopped = true
            source.cancel()
        }
    }

    func flush() {
        queue.sync {
            guard !stopped else { return }
            var bytes = [UInt8](repeating: 0, count: 32_768)
            // Bounded drain: a live writer cannot hold a UI flush forever.
            for _ in 0..<32 {
                let count = read(descriptor, &bytes, bytes.count)
                guard count > 0 else { break }
                let chunk = Data(bytes.prefix(count))
                log.append(chunk)
                watch?.scan(chunk)
            }
        }
    }

    func finish() {
        flush()
        queue.sync {
            guard !stopped else { return }
            stopped = true
            source.cancel()
        }
        cancellation.wait()
    }

    deinit { source.cancel() }
}

/// The owning subprocess task holds this until its child has stopped. stdout
/// and stderr share one pipe, preserving their kernel write ordering.
nonisolated final class ProcessLogCapture: Sendable {
    let writeDescriptor: Int32
    private let reader: LogPipeReader

    init(url: URL) throws {
        var descriptors: [Int32] = [-1, -1]
        guard pipe(&descriptors) == 0 else { throw StorageLocations.posixError() }
        _ = fcntl(descriptors[0], F_SETFD, FD_CLOEXEC)
        _ = fcntl(descriptors[1], F_SETFD, FD_CLOEXEC)
        do {
            reader = try LogPipeReader(descriptor: descriptors[0], log: RotatingLog(url: url))
            writeDescriptor = descriptors[1]
        } catch {
            Darwin.close(descriptors[0]); Darwin.close(descriptors[1])
            throw error
        }
    }

    func flush() { reader.flush() }
    deinit { Darwin.close(writeDescriptor); reader.finish() }
}

/// QEMU's supported pipe backend opens <path>.in/.out. These are private,
/// session-owned FIFOs in the system temporary directory, never durable state.
nonisolated final class SerialLogCapture: Sendable {
    let argument: String
    private let directory: URL
    private let reader: LogPipeReader

    /// `watch`: phrases reported the first time the guest prints them (iBoot's
    /// "Entering recovery mode"), from the reader's queue.
    init(url: URL, temporaryRoot: URL = FileManager.default.temporaryDirectory,
         watch: [String] = [], onMatch: @escaping @Sendable (String) -> Void = { _ in }) throws {
        let directory = temporaryRoot.appendingPathComponent("LightTouch-serial-\(UUID().uuidString)", isDirectory: true)
        self.directory = directory
        try StorageLocations.privateDirectory(directory)
        var descriptor: Int32 = -1
        do {
            let path = directory.appendingPathComponent("serial").path
            guard mkfifo(path + ".in", 0o600) == 0, mkfifo(path + ".out", 0o600) == 0 else {
                throw StorageLocations.posixError()
            }
            descriptor = open(path + ".out", O_RDWR | O_NONBLOCK | O_CLOEXEC)
            guard descriptor >= 0 else { throw StorageLocations.posixError() }
            reader = try LogPipeReader(descriptor: descriptor, log: RotatingLog(url: url),
                                       watch: watch.isEmpty ? nil : .init(phrases: watch, onMatch: onMatch)) {
                try? FileManager.default.removeItem(at: directory)
            }
            argument = "pipe:" + path
        } catch {
            if descriptor >= 0 { Darwin.close(descriptor) }
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
    }

    /// Normal app quit can leave QEMU running until process exit. Unlinking
    /// FIFO names is safe while its open descriptors remain usable; closing the
    /// reader here instead could deliver SIGPIPE to the still-running VM.
    func removeEndpoints() { try? FileManager.default.removeItem(at: directory) }

    /// Use only after QEMU has returned and can no longer write serial data.
    func finish() { reader.finish() }
}

@MainActor enum NativeLogging {
    private static var capture: ProcessLogCapture?

    /// QEMU is linked into the app, so its C diagnostics share process stdout/stderr.
    /// Unified app events use Logger separately and are not mirrored here.
    static func start() throws {
        guard capture == nil else { return }
        let pipe = try ProcessLogCapture(url: Bundled.logsDirectory.appendingPathComponent("native.log"))
        fflush(stdout)
        fflush(stderr)
        let savedError = dup(STDERR_FILENO)
        guard savedError >= 0 else { throw StorageLocations.posixError() }
        defer { Darwin.close(savedError) }
        guard dup2(pipe.writeDescriptor, STDERR_FILENO) >= 0 else { throw StorageLocations.posixError() }
        guard dup2(pipe.writeDescriptor, STDOUT_FILENO) >= 0 else {
            let error = StorageLocations.posixError()
            _ = dup2(savedError, STDERR_FILENO)
            throw error
        }
        capture = pipe
    }

    static func flush() { fflush(stdout); fflush(stderr); capture?.flush() }
}
