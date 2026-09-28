// For the recording tests: LightTouchDevice's AudioPump, in process. Drains a
// qemu_ios_audio_capture_* implementation (a C fixture, or the dylib) into the
// GuestAudioCapture the app's recorder reads, as the helper's `.audio` and
// `.audioEnded` events would, with the capture's own clock.

import Foundation

nonisolated func pumpedGuestAudio(
    start: () -> UInt64,
    read: @escaping @Sendable (UInt64, UnsafeMutableRawPointer?, Int32, UnsafeMutablePointer<Double>?) -> Int32,
    time: @escaping @Sendable (UInt64) -> Double,
    stop: @escaping @Sendable (UInt64) -> Void
) throws -> GuestAudioCapture {
    let generation = start()
    guard generation != 0 else { throw CaptureError.failed("The device is not ready to record audio.") }
    final class Flag: @unchecked Sendable { let lock = NSLock(); var stopped = false }
    let flag = Flag()
    let capture = GuestAudioCapture(clock: { time(generation) }, stop: { _ in flag.lock.withLock { flag.stopped = true } })
    capture.begin(generation: generation)
    Thread.detachNewThread {
        var buffer = [UInt8](repeating: 0, count: 16384)
        while true {
            var seconds = -1.0
            let n = buffer.withUnsafeMutableBytes { read(generation, $0.baseAddress, 16384, &seconds) }
            if n < 0 { return capture.receive(.audioEnded(generation: generation, failed: true)) }
            if n > 0 || seconds >= 0 {
                capture.receive(.audio(generation: generation, seconds: seconds, pcm: Data(buffer[0..<Int(n)])))
                if n > 0 { continue }
            }
            if flag.lock.withLock({ flag.stopped }) {
                stop(generation)
                return capture.receive(.audioEnded(generation: generation, failed: false))
            }
            usleep(5000)
        }
    }
    return capture
}
