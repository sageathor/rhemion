import Foundation

/// Wires a capture engine's frames through conversion into the ring buffer and the WAV sink,
/// and records the hotkey->first-frame latency per take. Conforms to FrameSink so an engine
/// feeds it directly. `ingest` runs on the engine's serial delivery queue (NOT the real-time
/// render callback); conversion allocates, which is fine there. `start`/`ingest`/`stop` are
/// serialized by a lock so a `stop` cannot interleave a converted write.
public final class CapturePipeline: FrameSink, @unchecked Sendable {
    private let converter: AudioConverting
    private let ring: AudioRingBuffer
    private let now: () -> Double
    private let lock = NSLock()
    /// Optional hook invoked with each take's converted samples, right after conversion, on this
    /// same serial delivery queue (never the RT render callback). Left unthrottled here on
    /// purpose -- throttling and level computation are the caller's concern (see
    /// `ThrottledLevelTap` in the composition root), so this stays a plain pass-through seam.
    private let levelTap: (@Sendable ([Int16]) -> Void)?

    private var sink: SampleSink?          // per-take, set in start(sink:)
    private var active = false
    private var startTime: Double?
    private var firstFrameTime: Double?

    public init(
        converter: AudioConverting,
        ring: AudioRingBuffer,
        now: @escaping () -> Double,
        levelTap: (@Sendable ([Int16]) -> Void)? = nil
    ) {
        self.converter = converter
        self.ring = ring
        self.now = now
        self.levelTap = levelTap
    }

    /// Begins a take. Each take gets its own sink (its own WAV file).
    ///
    /// `firstFrameLatency` is measured from HERE (`now()`, the pipeline's monotonic clock) to the
    /// first ingested frame -- how fast the audio unit delivers samples once the take begins, with
    /// BOTH endpoints on one clock. The `at:` argument (the client's keypress time) is a DIFFERENT
    /// clock (the client's wall clock) and is deliberately NOT used as the baseline: subtracting a
    /// wall-clock stamp from a monotonic one produced a garbage (huge negative) latency. It is kept
    /// only for source compatibility; the raw client stamp is logged separately upstream.
    public func start(sink: SampleSink, at startTime: Double? = nil) {
        lock.lock(); defer { lock.unlock() }
        if active { self.sink?.finish() }   // finalize an orphaned take instead of corrupting it
        ring.reset()
        self.sink = sink
        active = true
        self.startTime = now()              // monotonic baseline (NOT the cross-clock `at:` value)
        firstFrameTime = nil
    }

    public func ingest(_ frames: [Float], channels: Int, sampleRate: Double) {
        lock.lock(); defer { lock.unlock() }
        guard active else { return }
        if firstFrameTime == nil { firstFrameTime = now() }
        let samples = converter.convert(frames, channels: channels, sampleRate: sampleRate)
        ring.write(samples)
        sink?.write(samples)
        levelTap?(samples)
    }

    public func stop() {
        lock.lock(); defer { lock.unlock() }
        guard active else { return }
        active = false
        sink?.finish()
        sink = nil
    }

    /// Hotkey->first-frame latency of the current/last take, in seconds; nil if no frame arrived.
    public var firstFrameLatency: Double? {
        lock.lock(); defer { lock.unlock() }
        guard let s = startTime, let f = firstFrameTime else { return nil }
        return f - s
    }

    public var integrityCompromised: Bool { ring.integrityCompromised }
}
