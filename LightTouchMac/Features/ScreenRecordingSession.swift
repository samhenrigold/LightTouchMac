import Cocoa
import AVFoundation

/// Owns one recording from its first frame through a durable save. A failed
/// destination leaves the completed movie available for another save attempt.
@MainActor
final class ScreenRecordingSession {
    enum Phase: Equatable {
        case idle, starting, recording, saving, saved(URL), recovery(URL)
    }
    enum Completion: Equatable {
        case saved(URL), discarded, recovery(URL), failed
    }
    struct RecoveryReport {
        var saved: [URL] = []
        var remaining: [URL] = []
        /// Unplayable takes: deleted, since nothing can recover them.
        var deleted: [URL] = []
    }

    private(set) var phase: Phase = .idle { didSet { onChange?() } }
    private(set) var elapsedSeconds = 0
    private(set) var failure: Error?
    private(set) var previewImage: CGImage?
    var onChange: (() -> Void)?
    var onFinished: ((Bool) -> Void)?
    var onCompleted: ((Completion) -> Void)?
    /// A failed preferred location falls back to a per-file save panel. The
    /// completed source remains durable if the panel is cancelled or fails.
    var chooseSaveDestination: ((Error) async -> URL?)?
    var onBeganRecording: (() -> Void)?
    var onStoppedRecording: (() -> Void)?
    private var didBeginRecording = false
    private let writer = ScreenMovieWriter()
    private var producer: Task<Void, Never>?
    private var output: URL?
    private var startedAt: CFTimeInterval = 0
    private var writerStarted = false
    private(set) var id = UUID()
    private var stopRequested = false
    private var discardRequested = false
    private var destination: (() throws -> URL)?

    var isActive: Bool { phase == .starting || phase == .recording || phase == .saving }
    var needsRecovery: Bool { if case .recovery = phase { true } else { false } }
    var canStop: Bool { phase == .starting || phase == .recording }
    var elapsed: String {
        let seconds = elapsedSeconds % 60
        let minutes = (elapsedSeconds / 60) % 60
        let hours = elapsedSeconds / 3600
        let tail = "\(seconds < 10 ? "0" : "")\(seconds)"
        return hours > 0 ? "\(hours):\(minutes < 10 ? "0" : "")\(minutes):\(tail)"
            : "\(minutes):\(tail)"
    }
    static var recoveryDirectory: URL {
        Bundled.stateDirectory.appendingPathComponent("Recordings", isDirectory: true)
    }

    /// Recordings/ is out of backups while a take is being written into it
    /// (a large, changing file), and back in once it's idle.
    private static func excludeRecordingsFromBackup(_ excluded: Bool) {
        var folder = recoveryDirectory
        var values = URLResourceValues()
        values.isExcludedFromBackup = excluded
        try? folder.setResourceValues(values)
    }

    /// `audio` starts the device's guest audio capture (nil: a silent movie).
    func start(frame: @escaping () throws -> CGImage?, audio: @escaping () async throws -> GuestAudioCapture? = { nil }, prepare: @escaping () async throws -> CGSize? = { nil }, cleanup: @escaping () async -> Void = {}, background: CGImage? = nil, destination: @escaping () throws -> URL) {
        guard !isActive else { return }
        if case .recovery = phase { return }
        begin(frame: frame, audio: audio, prepare: prepare, cleanup: cleanup, background: background, destination: destination)
    }

    private func begin(frame: @escaping () throws -> CGImage?, audio: @escaping () async throws -> GuestAudioCapture?, prepare: @escaping () async throws -> CGSize?, cleanup: @escaping () async -> Void, background: CGImage?, destination: @escaping () throws -> URL) {
        failure = nil
        previewImage = nil
        id = UUID()
        writerStarted = false
        didBeginRecording = false
        elapsedSeconds = 0
        stopRequested = false
        discardRequested = false
        self.destination = destination
        phase = .starting
        producer = Task { [weak self] in
            guard let self else { return }
            do {
                let folder = Self.recoveryDirectory
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                Self.excludeRecordingsFromBackup(true)
                let url = folder.appendingPathComponent("Recording \(UUID().uuidString).mov")
                output = url
                let canvasSize = try await prepare()
                let capture = try await audio()
                do { try await writer.start(url: url, audio: capture, canvasSize: canvasSize, background: background) }
                catch { capture?.stop(); throw error }
                writerStarted = true
                startedAt = CACurrentMediaTime()
                // A stop during startup still produces a playable first frame.
                let firstFrame = try frame()
                previewImage = firstFrame
                try await writer.append(firstFrame, seconds: 0)
                if !stopRequested {
                    phase = .recording
                    didBeginRecording = true
                    onBeganRecording?()
                }
                while !stopRequested {
                    try await Task.sleep(for: .milliseconds(canvasSize == nil ? 33 : 16))
                    guard !stopRequested else { break }
                    try await writer.append(try frame(), seconds: CACurrentMediaTime() - startedAt)
                    let seconds = Int(CACurrentMediaTime() - startedAt)
                    if elapsedSeconds != seconds { elapsedSeconds = seconds; onChange?() }
                }
            } catch {
                failure = error
                stopRequested = true
            }
            await cleanup()
            await complete()
        }
    }

    func stop(discard: Bool = false) {
        guard canStop else { return }
        if didBeginRecording {
            didBeginRecording = false
            onStoppedRecording?()
        }
        discardRequested = discard
        stopRequested = true
        phase = .saving
    }

    private func complete() async {
        defer { Self.excludeRecordingsFromBackup(false) }
        // Also announce an interrupted take, once, if frames had started.
        if didBeginRecording {
            didBeginRecording = false
            onStoppedRecording?()
        }
        phase = .saving
        if discardRequested {
            await writer.cancel()
            discardOutput()
            return
        }
        do {
            if let failure {
                // An audio-source error can leave valid video in a healthy
                // writer. Finalize that partial take before offering recovery.
                if writerStarted { try? await writer.finish(seconds: max(CACurrentMediaTime() - startedAt, 0.034)) }
                await writer.cancel()
                throw failure
            }
            try await writer.finish(seconds: max(CACurrentMediaTime() - startedAt, 0.034))
            guard let output, let destination else { throw CaptureError.failed("No recording file is available.") }
            let saved: URL
            do {
                let preferred = try destination()
                try await Self.save(output, to: preferred)
                saved = preferred
            } catch {
                guard let chosen = await chooseSaveDestination?(error) else { throw error }
                // NSSavePanel obtained any replacement confirmation. Choosing
                // a file here does not change the preferred capture location.
                try await Self.save(output, to: chosen, replaceExisting: true)
                saved = chosen
            }
            self.output = nil
            failure = nil
            phase = .saved(saved)
            completed(.saved(saved))
        } catch {
            failure = error
            if let output, FileManager.default.fileExists(atPath: output.path) {
                phase = .recovery(output)
                completed(.recovery(output))
            } else {
                phase = .idle
                completed(.failed)
            }
        }
    }

    func retrySave(to url: URL) {
        guard case let .recovery(source) = phase else { return }
        phase = .saving
        Task {
            do {
                try await Self.save(source, to: url, replaceExisting: true)
                output = nil
                failure = nil
                phase = .saved(url)
                completed(.saved(url))
            } catch {
                failure = error
                phase = .recovery(source)
                completed(.recovery(source))
            }
        }
    }

    /// Called only after the user confirms discarding an unsaved take.
    func discardRecovery() {
        guard case let .recovery(source) = phase else { return }
        output = source
        discardOutput()
    }

    private func discardOutput() {
        do {
            if let output, FileManager.default.fileExists(atPath: output.path) {
                try FileManager.default.removeItem(at: output)
            }
            output = nil
            failure = nil
            previewImage = nil
            phase = .idle
            completed(.discarded)
        } catch {
            failure = error
            if let output {
                phase = .recovery(output)
                completed(.recovery(output))
            } else {
                phase = .idle
                completed(.failed)
            }
        }
    }

    private func completed(_ result: Completion) {
        producer = nil
        onCompleted?(result)
        switch result {
        case .saved, .discarded: onFinished?(true)
        case .recovery, .failed: onFinished?(false)
        }
    }

    /// Recover only older, playable recordings. An unplayable one is deleted
    /// (report.deleted, for the log); new takes and unrelated files are never swept up.
    static func recoverRecordings(createdBefore cutoff: Date,
                                  destination: (URL) throws -> URL) async throws -> RecoveryReport {
        let folder = recoveryDirectory
        guard FileManager.default.fileExists(atPath: folder.path) else { return RecoveryReport() }
        let keys: Set<URLResourceKey> = [.creationDateKey, .isRegularFileKey, .isSymbolicLinkKey]
        let files = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: Array(keys),
                                                                options: .skipsHiddenFiles)
        var report = RecoveryReport()
        for source in files.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            guard source.pathExtension.lowercased() == "mov" else { continue }
            let values = try? source.resourceValues(forKeys: keys)
            guard values?.isRegularFile == true, values?.isSymbolicLink != true,
                  let created = values?.creationDate, created < cutoff else { continue }
            let asset = AVURLAsset(url: source)
            guard let duration = try? await asset.load(.duration), duration.isNumeric, duration.seconds > 0,
                  let tracks = try? await asset.loadTracks(withMediaType: .video), !tracks.isEmpty,
                  (try? await asset.load(.isPlayable)) == true else {
                if (try? FileManager.default.removeItem(at: source)) != nil { report.deleted.append(source) }
                else { report.remaining.append(source) }
                continue
            }
            do {
                let saved = try destination(source)
                try await save(source, to: saved)
                report.saved.append(saved)
            } catch {
                report.remaining.append(source)
            }
        }
        return report
    }

    func dismiss() {
        guard !isActive else { return }
        // Recovery files remain on disk, including across application launches.
        output = nil
        failure = nil
        phase = .idle
    }

    @concurrent
    private static func save(_ source: URL, to destination: URL, replaceExisting: Bool = false) async throws {
        // Saving in place is already durable. Do not remove the destination
        // when the user chooses the recovery file itself in Save As.
        if source.resolvingSymlinksInPath().standardizedFileURL == destination.resolvingSymlinksInPath().standardizedFileURL { return }
        let staged = destination.deletingLastPathComponent().appendingPathComponent(".ltm-\(UUID().uuidString).mov")
        defer { try? FileManager.default.removeItem(at: staged) }
        try FileManager.default.copyItem(at: source, to: staged)
        if replaceExisting, FileManager.default.fileExists(atPath: destination.path) {
            // NSSavePanel obtained the user's replacement decision.
            _ = try FileManager.default.replaceItemAt(destination, withItemAt: staged)
        } else {
            try FileManager.default.moveItem(at: staged, to: destination)
        }
        try? FileManager.default.removeItem(at: source)
    }
}
