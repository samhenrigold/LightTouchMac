import Accelerate

/// How much faster a recorded sound came out than its source: 2 when samples made for 22.05 kHz are played at
/// 44.1 kHz (an octave up, in half the time), 1 when they are played at the rate they were made for. Found as the
/// speed-up of the source that lines up the stretches of the recording, sample for sample (normalized
/// cross-correlation over every offset), so it needs no listening and holds for any sound. Each sounding twentieth of
/// a second finds the speed-up that matches its loudest stretch best; the answer is the best-matching speed-up at
/// least two stretches agree on, so a stray stretch of another sound in the recording (VoiceOver's speech or its own
/// sound beside the lock sound), which can match some speed-up of the source by chance, does not stand in for it. A
/// best match at the end of the range searched is no match.
public nonisolated enum SoundScale {
    /// The stretch of the recording compared, in seconds.
    static let window = 0.025
    /// Stretches tried: one in each of the first `candidates` segments of `segment` seconds with sound.
    static let candidates = 24
    static let segment = 0.05
    /// A stretch counts when it matches at least this well; speed-ups within `agree` are the same.
    static let voting = 0.55
    static let agree = 0.02
    static let range = (low: 0.4, high: 2.6)
    /// Both sounds are compared above this (a second-order high-pass): a phone's speaker plays little of a sound's
    /// bass, which the file's slow-decaying tail is mostly made of. The iPhone 5 (iOS 10) plays the lock sound 16 dB
    /// down below 200 Hz, and its tail, the file's thump, matched only at a wrong speed.
    static let bassCutoff = 500.0

    /// The factor, from 0.4 to 2.6 to within 0.5%, how well the source at that speed matches (the best correlation
    /// of the stretches that agree on it, at most 1), and how many stretches agree (0: no two do, the single best
    /// stretch's); nil if either sound is silent or too short.
    public static func scale(
        reference: [Float],
        referenceRate: Double,
        recording: [Float],
        recordingRate: Double
    ) -> (factor: Double, match: Double, support: Int)? {
        let width = Int(window * recordingRate)
        guard recording.count > width, reference.count > 1 else { return nil }
        let reference = highPassed(reference, rate: referenceRate)
        let recording = highPassed(recording, rate: recordingRate)
        let votes = stretches(recording, width: width, segment: Int(segment * recordingRate)).map { start in
            let stretch = Array(recording[start..<start + width])
            func match(_ k: Double) -> Double {
                correlation(stretch, resampled(reference, step: k * referenceRate / recordingRate))
            }
            var here = stride(from: range.low, through: range.high, by: 0.04).map { ($0, match($0)) }.max {
                $0.1 < $1.1
            }!
            for k in stride(from: here.0 - 0.04, through: here.0 + 0.04, by: 0.005) where k > 0 {
                let m = match(k)
                if m > here.1 { here = (k, m) }
            }
            return here
        }
        let voters = votes.filter { $0.1 >= voting && $0.0 > range.low + agree && $0.0 < range.high - agree }
        let agreed = voters.map { v in
            let with = voters.filter { abs($0.0 - v.0) <= agree }
            return (factor: v.0, match: v.1, support: with.count)
        }.filter { $0.support >= 2 }
        if let won = agreed.max(by: { $0.match < $1.match }) { return won }
        return votes.max { $0.1 < $1.1 }.flatMap { $0.1 > 0 ? ($0.0, $0.1, 0) : nil }
    }

    /// Where the loudest `width` samples of each of the first `candidates` `segment`-sample segments of `x` louder than
    /// a thousandth of the loudest start. Empty if `x` is silent.
    static func stretches(_ x: [Float], width: Int, segment: Int) -> [Int] {
        let step = max(segment, width)
        let segments = stride(from: 0, to: x.count - width, by: step).map { start in
            (start, x[start..<min(start + step, x.count)].reduce(0) { $0 + Double($1) * Double($1) })
        }
        let floor = (segments.map(\.1).max() ?? 0) * 1e-3
        let starts = segments.filter { $0.1 > floor && floor > 0 }.prefix(candidates).compactMap { start, _ in
            loudest(Array(x[start..<min(start + step + width, x.count)]), width: width).map { start + $0 }
        }
        // A segment's loudest stretch can run into the next one's and be the same stretch: it votes once.
        return starts.enumerated().filter { $0.offset == 0 || starts[$0.offset - 1] != $0.element }.map(\.element)
    }

    /// Where the `width` samples of `x` with the most energy start, or nil if `x` is silent or too short.
    static func loudest(_ x: [Float], width: Int) -> Int? {
        guard x.count > width else { return nil }
        let energy = x.map { Double($0) * Double($0) }
        var sum = energy[0..<width].reduce(0, +)
        var best = (start: 0, sum: sum)
        for start in 1...(x.count - width) {
            sum += energy[start + width - 1] - energy[start - 1]
            if sum > best.sum { best = (start, sum) }
        }
        return best.sum > 0 ? best.start : nil
    }

    /// `x` above `bassCutoff` (two one-pole high-pass sections), at `rate`.
    static func highPassed(_ x: [Float], rate: Double) -> [Float] {
        let a = Float(exp(-2 * .pi * bassCutoff / rate))
        var y = x
        for _ in 0..<2 {
            var (previousIn, previousOut): (Float, Float) = (0, 0)
            for i in y.indices {
                let input = y[i]
                previousOut = a * (previousOut + input - previousIn)
                previousIn = input
                y[i] = previousOut
            }
        }
        return y
    }

    /// `x` read every `step` samples (linear interpolation).
    static func resampled(_ x: [Float], step: Double) -> [Float] {
        let count = Int(Double(x.count - 1) / step)
        return (0..<count).map { i in
            let p = Double(i) * step
            let j = Int(p)
            let t = Float(p - Double(j))
            return x[j] * (1 - t) + x[j + 1] * t
        }
    }

    /// The best normalized cross-correlation of `stretch` against `source` at any offset where it fits.
    static func correlation(_ stretch: [Float], _ source: [Float]) -> Double {
        let n = stretch.count
        guard source.count >= n else { return -1 }
        let lags = source.count - n + 1
        var dots = [Float](repeating: 0, count: lags)
        vDSP_conv(source, 1, stretch, 1, &dots, 1, vDSP_Length(lags), vDSP_Length(n))
        let norm = vDSP.sumOfSquares(stretch)
        // The source's energy under the stretch at each offset, summed afresh at each (a running sum loses the
        // quiet stretches to rounding); offsets where the source is near silent don't count.
        var energy = [Float](repeating: 0, count: lags)
        vDSP_conv(
            vDSP.square(source),
            1,
            [Float](repeating: 1, count: n),
            1,
            &energy,
            1,
            vDSP_Length(lags),
            vDSP_Length(n)
        )
        let floor = (energy.max() ?? 0) * 1e-4
        var best = -1.0
        for lag in 0..<lags where energy[lag] > floor {
            best = max(best, Double(dots[lag]) / (Double(energy[lag]) * Double(norm)).squareRoot())
        }
        return best
    }
}
