import Foundation
import Testing

@testable import SessionKit

/// A click with three resonances (as a UI sound is), made at 22.05 kHz: played at its own rate it comes out at scale
/// 1, its samples played at 44.1 kHz come out twice as fast and high, and at 16 kHz slower and lower.
struct SoundScaleTests {
    static func click(rate: Double, seconds: Double = 0.4) -> [Float] {
        var seed: UInt32 = 1
        return (0..<Int(rate * seconds)).map { n in
            let t = Double(n) / rate
            seed = seed &* 1_664_525 &+ 1_013_904_223
            let noise = Double(Int32(bitPattern: seed)) / Double(Int32.max) * 0.02
            let ring = [700.0, 1900, 3100].enumerated().reduce(0.0) { sum, r in
                sum + sin(2 * .pi * r.element * t) * exp(-t * Double(12 + 8 * r.offset)) / Double(r.offset + 1)
            }
            return Float((ring + noise) * 0.5)
        }
    }

    /// `x` after `seconds` of silence, as the WAV holds a sound that starts a moment after the button.
    static func late(_ x: [Float], rate: Double, seconds: Double = 0.3) -> [Float] {
        [Float](repeating: 0, count: Int(rate * seconds)) + x
    }

    @Test func playedAtItsOwnRate() throws {
        let scale = try #require(
            SoundScale.scale(
                reference: Self.click(rate: 22050),
                referenceRate: 22050,
                recording: Self.late(Self.click(rate: 44100), rate: 44100),
                recordingRate: 44100
            )
        )
        #expect(abs(scale.factor - 1) < 0.01)
        #expect(scale.match > 0.9)
    }

    @Test func playedAtTheWrongRate() throws {
        let samples = Self.click(rate: 22050)
        let fast = try #require(
            SoundScale.scale(
                reference: samples,
                referenceRate: 22050,
                recording: Self.late(samples, rate: 44100),
                recordingRate: 44100
            )
        )
        #expect(abs(fast.factor - 2) < 0.02)
        let slow = try #require(
            SoundScale.scale(
                reference: samples,
                referenceRate: 22050,
                recording: Self.late(samples, rate: 16000),
                recordingRate: 16000
            )
        )
        #expect(abs(slow.factor - 16000 / 22050) < 0.01)
    }

    /// The click at its own rate, then after a pause a louder unrelated tone (VoiceOver speaking as the device locks):
    /// the click is still the sound measured.
    @Test func aLouderSoundAfterDoesNotStandIn() throws {
        let tone = (0..<44100).map { Float(0.9 * sin(2 * Double.pi * 180 * Double($0) / 44100)) }
        let scale = try #require(
            SoundScale.scale(
                reference: Self.click(rate: 22050),
                referenceRate: 22050,
                recording: Self.late(Self.click(rate: 44100), rate: 44100) + Self.late(tone, rate: 44100, seconds: 0.5),
                recordingRate: 44100
            )
        )
        #expect(abs(scale.factor - 1) < 0.01)
        #expect(scale.match > 0.9)
    }

    /// A lock sound through a phone's speaker: the file is a bright click over a slower thump, the speaker plays the
    /// click and little of the thump (the iPhone 5's, 16 dB down below 200 Hz), so the recording's tail is the click's
    /// and the file's is the thump's. The click still measures at its own speed, in more than one stretch.
    @Test func aSoundWithoutItsBassStillMeasures() throws {
        func sound(rate: Double, bass: Bool) -> [Float] {
            let click = Self.click(rate: rate, seconds: 0.3)
            return click.indices.map { n in
                let t = Double(n) / rate
                return click[n] * Float(exp(-t * 10)) + (bass ? Float(0.8 * sin(2 * .pi * 90 * t) * exp(-t * 6)) : 0)
            }
        }
        let scale = try #require(
            SoundScale.scale(
                reference: sound(rate: 22050, bass: true),
                referenceRate: 22050,
                recording: Self.late(sound(rate: 44100, bass: false), rate: 44100),
                recordingRate: 44100
            )
        )
        #expect(abs(scale.factor - 1) < 0.02)
        #expect(scale.match > 0.5 && scale.support >= 2)
    }

    @Test func silenceHasNoScale() {
        #expect(
            SoundScale.scale(
                reference: Self.click(rate: 22050),
                referenceRate: 22050,
                recording: [Float](repeating: 0, count: 44100),
                recordingRate: 44100
            ) == nil
        )
    }
}
