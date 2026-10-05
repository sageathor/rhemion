import Foundation
import RhemionAudio

/// Routes a capture take's converted-sample frames (from `CapturePipeline`'s level tap seam) to
/// a level callback, computing a normalized level via `AudioLevelMeter` and throttling emission
/// to ~15 Hz -- an event roughly every 66ms; frames arriving faster than that are dropped, not
/// queued or coalesced. `tap(_:)` always runs on the capture pipeline's serial delivery queue
/// (see `CapturePipeline.ingest`), never the RT render callback, so the unguarded `lastEmit`
/// mutation is safe -- it is only ever touched from that one serial context.
///
/// `onLevel` is assigned exactly once, by the composition root, strictly before the runtime
/// starts accepting socket connections -- i.e. before any capture take (and so any call to
/// `tap`) can happen. That ordering guarantee is what makes the mutable `var` safe despite the
/// `@unchecked Sendable`, matching `CaptureController`'s same rationale.
final class ThrottledLevelTap: @unchecked Sendable {
    private let meter: AudioLevelMeter
    private let minInterval: Double
    private let now: () -> Double
    private var lastEmit: Double = -.infinity

    var onLevel: (@Sendable (Double) -> Void)?

    init(
        // gain 20: raw RMS of normal speech is ~0.02-0.03 of full scale, so unity gain barely
        // moved the notch orb and left silence indistinguishable from speech. 20x maps normal
        // speech to ~0.4-0.7 (orb reacts) and room tone to ~0.02-0.04 (below the silence gate).
        meter: AudioLevelMeter = AudioLevelMeter(gain: 20),
        minInterval: Double = 1.0 / 15.0,
        now: @escaping () -> Double = { Double(DispatchTime.now().uptimeNanoseconds) / 1_000_000_000 }
    ) {
        self.meter = meter
        self.minInterval = minInterval
        self.now = now
    }

    func tap(_ samples: [Int16]) {
        let t = now()
        guard t - lastEmit >= minInterval else { return }
        lastEmit = t
        onLevel?(meter.level(samples))
    }
}
