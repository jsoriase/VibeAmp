import Foundation

/// Pure DSP for the 10-band peaking EQ + preamp.
///
/// Uses RBJ cookbook peaking-EQ coefficients (Q = 1.4, matching the original
/// VibeAmp Web Audio chain). This type is deliberately free of AVFoundation so
/// it can be unit-tested without audio hardware.
///
/// The realtime tap (`EqualizerTap`) reuses the coefficient math below and
/// applies the same series chain: preamp gain -> 10 biquads in frequency order.
enum EqualizerDSP {
    static let frequencies: [Double] = [60, 170, 310, 600, 1000, 3000, 6000, 12000, 14000, 16000]
    static let defaultQ: Double = 1.4

    struct Biquad: Equatable, Sendable {
        var b0: Double
        var b1: Double
        var b2: Double
        var a1: Double
        var a2: Double
    }

    /// RBJ peaking EQ. Gain in dB, freq and sampleRate in Hz.
    static func peakingCoefficients(
        frequency: Double,
        sampleRate: Double,
        gainDB: Double,
        q: Double = defaultQ
    ) -> Biquad {
        // A flat band is exactly identity — avoids denormals and needless work.
        guard gainDB != 0, frequency > 0, sampleRate > 0, q > 0 else {
            return Biquad(b0: 1, b1: 0, b2: 0, a1: 0, a2: 0)
        }
        let a = pow(10, gainDB / 40)
        let omega = 2 * Double.pi * frequency / sampleRate
        let sinOmega = sin(omega)
        let cosOmega = cos(omega)
        let alpha = sinOmega / (2 * q)

        let b0 = 1 + alpha * a
        let b1 = -2 * cosOmega
        let b2 = 1 - alpha * a
        let a0 = 1 + alpha / a
        let a1 = -2 * cosOmega
        let a2 = 1 - alpha / a

        return Biquad(b0: b0 / a0, b1: b1 / a0, b2: b2 / a0, a1: a1 / a0, a2: a2 / a0)
    }

    static func preampLinear(gainDB: Double) -> Double {
        pow(10, gainDB / 20)
    }

    static func coefficients(
        sampleRate: Double,
        preampDB: Double,
        bandGainsDB: [Double]
    ) -> (preamp: Double, bands: [Biquad]) {
        let bands = frequencies.enumerated().map { index, freq in
            let gain = index < bandGainsDB.count ? bandGainsDB[index] : 0
            return peakingCoefficients(frequency: freq, sampleRate: sampleRate, gainDB: gain)
        }
        return (preampLinear(gainDB: preampDB), bands)
    }
}

/// Offline / testable series processor: preamp then 10 biquads.
/// Mirrors exactly what the realtime tap does per sample, but in Swift
/// value semantics for determinism in tests.
struct EQProcessor: Sendable {
    var preamp: Double
    var bands: [EqualizerDSP.Biquad]
    // State per band: x1, x2, y1, y2 (mono for tests; the tap extends this per channel).
    private var state: [(x1: Double, x2: Double, y1: Double, y2: Double)]

    init(preampDB: Double = 0, bandGainsDB: [Double] = Array(repeating: 0, count: 10), sampleRate: Double = 44100) {
        let coeffs = EqualizerDSP.coefficients(
            sampleRate: sampleRate,
            preampDB: preampDB,
            bandGainsDB: bandGainsDB
        )
        self.preamp = coeffs.preamp
        self.bands = coeffs.bands
        self.state = Array(repeating: (0, 0, 0, 0), count: bands.count)
    }

    mutating func reset() {
        state = Array(repeating: (0, 0, 0, 0), count: bands.count)
    }

    mutating func process(_ input: [Float]) -> [Float] {
        input.map { processOne(Double($0)) }.map { Float($0) }
    }

    private mutating func processOne(_ x0: Double) -> Double {
        var y = x0 * preamp
        for i in bands.indices {
            let c = bands[i]
            var s = state[i]
            let out = c.b0 * y + c.b1 * s.x1 + c.b2 * s.x2 - c.a1 * s.y1 - c.a2 * s.y2
            s.x2 = s.x1
            s.x1 = y
            s.y2 = s.y1
            s.y1 = out
            state[i] = s
            y = out
        }
        // Guard against NaN/denormal blowups from pathological streams.
        if !y.isFinite { y = 0 }
        return y
    }
}
