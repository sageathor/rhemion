import Foundation

/// Computes a normalized 0...1 loudness value from a frame of 16 kHz mono Int16 samples.
/// Pure and deterministic: RMS of the samples, normalized by the Int16 full-scale magnitude,
/// scaled by an optional gain, and clamped to 0...1. No side effects -- safe to call from any
/// thread, including repeatedly on the capture pipeline's serial delivery queue.
public struct AudioLevelMeter: Sendable {
    private let gain: Double

    public init(gain: Double = 1.0) {
        self.gain = gain
    }

    public func level(_ samples: [Int16]) -> Double {
        guard !samples.isEmpty else { return 0 }
        var sumSquares = 0.0
        for sample in samples {
            let normalized = Double(sample) / 32768.0
            sumSquares += normalized * normalized
        }
        let rms = (sumSquares / Double(samples.count)).squareRoot()
        return min(1.0, max(0.0, rms * gain))
    }
}
