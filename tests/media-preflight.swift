import Foundation
import AVFoundation
enum DeviceToolsError: Error { case failed(String) }
@main struct Check {
    static func main() async throws {
        let root = URL(fileURLWithPath: CommandLine.arguments[1])
        for name in ["aac.m4a", "tone.mp3", "stereo.wav", "lossless.m4a"] {
            let source = root.appendingPathComponent(name)
            let song = try await MediaSong.prepare(source)
            defer { try? FileManager.default.removeItem(at: song.directory) }
            let identical = try Data(contentsOf: song.audio) == Data(contentsOf: source)
            precondition(identical)
            let p = try PropertyListSerialization.propertyList(from: Data(contentsOf: song.metadata), format: nil) as! [String: Any]
            precondition(abs((p["duration_ms"] as! Double) - 6000) < 100)
            precondition(p["filename"] as? String == song.audio.lastPathComponent)
            precondition(UUID(uuidString: song.id) != nil)
        }
        let raw = URL(fileURLWithPath: CommandLine.arguments[2])
        let converted = try await MediaSong.prepare(raw)
        defer { try? FileManager.default.removeItem(at: converted.directory) }
        precondition(converted.audio.pathExtension == "m4a")
        let decoded = try AVAudioFile(forReading: converted.audio)
        precondition(abs(Double(decoded.length) / decoded.processingFormat.sampleRate - 6) < 0.15)
        precondition(!FileManager.default.fileExists(atPath: converted.directory.appendingPathComponent("audio.aac").path))
        let invalid = FileManager.default.temporaryDirectory.appendingPathComponent("it-media-invalid-" + UUID().uuidString + ".m4a")
        try Data("not audio".utf8).write(to: invalid)
        defer { try? FileManager.default.removeItem(at: invalid) }
        do { _ = try await MediaSong.prepare(invalid); fatalError("accepted invalid audio") }
        catch {}
        let cancelled = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            do { _ = try await MediaSong.prepare(root.appendingPathComponent("aac.m4a")); fatalError("ignored cancellation") }
            catch is CancellationError {}
        }
        try await cancelled.value
        print("PASS: production metadata/codec preflight, immutable copies, malformed input and cancellation")
    }
}
