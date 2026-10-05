import Foundation

/// Receives device-native interleaved Float32 frames from a capture engine.
public protocol FrameSink: AnyObject {
    func ingest(_ frames: [Float], channels: Int, sampleRate: Double)
}

/// A source of audio frames. Real implementation (Milestone 2C) is AUHAL; tests use a fake.
/// `prepare()` is called once when the runtime starts (kept warm); `start(sink:)` begins delivering
/// frames to the sink on a serial queue; `stop()` halts delivery without tearing the prepared unit down.
///
/// ORDERING CONTRACT (load-bearing — spec Section 2 "no lost first words"): the take's consumer
/// (e.g. `CapturePipeline`) MUST be started for the take BEFORE this engine begins delivering
/// frames. Frames delivered to a not-yet-started consumer are dropped — that would lose the first
/// word. In the runtime wiring (2C) start the pipeline take, then start the engine.
public protocol CaptureEngine: AnyObject {
    func prepare() throws
    func start(sink: FrameSink) throws
    func stop()
}

/// Optional capability for engines that can change hardware while retaining their current sink.
public protocol LiveCaptureRetargeting: AnyObject {
    func retarget(to deviceID: UInt32) throws
}

/// Converts device-native interleaved Float32 frames to 16 kHz mono Int16.
/// Real implementation (2C) wraps AVAudioConverter; tests inject a deterministic stub.
public protocol AudioConverting {
    func convert(_ frames: [Float], channels: Int, sampleRate: Double) -> [Int16]
}

/// Sink for converted 16 kHz mono Int16 samples (the fallback/insurance WAV). `finish()` finalizes it.
public protocol SampleSink: AnyObject {
    func write(_ samples: [Int16])
    func finish()
}
