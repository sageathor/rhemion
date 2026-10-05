import Foundation

/// Decides whether a captured take is worth transcribing at all. An accidental hotkey tap (press +
/// release with no speech), a held-but-silent take, or a lone click/handling-thump otherwise reaches
/// the ASR engine, which can hallucinate garbage (random letters/digits) that then gets pasted.
///
/// The gate is a lightweight voice-activity check: short frames, DC removed, per-frame RMS, and a
/// requirement of several VOICED frames. This rejects isolated transients (a single loud sample or
/// one click is only one frame) while still passing quiet but SUSTAINED speech — better than a raw
/// peak threshold, which a single click passes. The duration floor stays low enough for short words
/// ("да", "нет", "стоп").
///
/// Thresholds are conservative defaults; the honest way to tune them is to log per-take duration and
/// frame RMS over a few hundred real accepted/canceled takes and fit to the observed room-tone vs
/// quiet-speech distributions (a future refinement).
public enum AudioGate {
    /// Minimum take length. A quick accidental tap is well under this; kept low so short words pass.
    public static let minDurationSeconds = 0.25
    /// Analysis frame = 20 ms at 16 kHz.
    static let frameSize = 320
    /// Per-frame RMS (Int16 scale, 0..32767) above which a frame counts as "voiced". Room tone /
    /// a silent hold sits well below this; speech sits above it.
    static let voicedFrameRMS: Double = 150
    /// How many voiced frames the take must contain (need not be contiguous). ~80 ms of voice —
    /// enough to reject a lone click (1 frame) while accepting a short spoken word.
    static let minVoicedFrames = 4

    /// True if the take is long enough AND contains enough voiced frames to be worth transcribing.
    public static func worthTranscribing(_ samples: [Int16], sampleRate: Double = 16000) -> Bool {
        guard sampleRate > 0 else { return false }
        guard Double(samples.count) / sampleRate >= minDurationSeconds else { return false }

        var voiced = 0
        var i = 0
        while i + frameSize <= samples.count {
            var sum = 0.0
            for j in i..<(i + frameSize) { sum += Double(samples[j]) }
            let mean = sum / Double(frameSize)
            var sq = 0.0
            for j in i..<(i + frameSize) { let v = Double(samples[j]) - mean; sq += v * v }
            let rms = (sq / Double(frameSize)).squareRoot()
            if rms >= voicedFrameRMS {
                voiced += 1
                if voiced >= minVoicedFrames { return true }
            }
            i += frameSize
        }
        return false
    }
}
