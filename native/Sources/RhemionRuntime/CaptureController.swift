import Foundation
import RhemionCore
import RhemionAudio

/// Makes a fresh SampleSink (WAV) per take. Real impl writes into the data dir; tests inject a fake.
public protocol CaptureSinkFactory {
    func makeSink() throws -> SampleSink

    /// URL of the most recently made take's file, if the factory tracks one. Defaults to nil
    /// so existing (URL-agnostic) fakes keep conforming without changes.
    var lastURL: URL? { get }
}

public extension CaptureSinkFactory {
    var lastURL: URL? { nil }
}

/// Coordinates a dictation take's capture: on begin, start the pipeline take THEN the engine
/// (ordering contract: no lost first words); on end, stop the engine THEN finalize the pipeline.
/// `@unchecked Sendable`: not provably Sendable, but its engine/pipeline/sinkFactory
/// collaborators are each internally thread-safe by design (see their headers), and
/// `lastTakeURL` is a simple pass-through read of a lock-guarded property.
public final class CaptureController: @unchecked Sendable {
    private let engine: CaptureEngine
    private let pipeline: CapturePipeline
    private let sinkFactory: CaptureSinkFactory
    private let metrics: Metrics

    public init(engine: CaptureEngine, pipeline: CapturePipeline, sinkFactory: CaptureSinkFactory, metrics: Metrics) {
        self.engine = engine
        self.pipeline = pipeline
        self.sinkFactory = sinkFactory
        self.metrics = metrics
    }

    public func beginTake(session: String, pressedAt: Double) {
        do {
            let sink = try sinkFactory.makeSink()
            pipeline.start(sink: sink, at: pressedAt)   // pipeline ready first
            do {
                try engine.start(sink: pipeline)        // then engine delivers
            } catch {
                pipeline.stop()                         // finalize the sink; don't orphan it
                throw error
            }
        } catch {
            metrics.record("capture_begin_failed", session: session)
        }
    }

    public func endTake(session: String) {
        engine.stop()
        pipeline.stop()
        if let latency = pipeline.firstFrameLatency {
            metrics.record("first_frame_latency=\(latency)", session: session)
        }
    }

    public var lastFirstFrameLatency: Double? { pipeline.firstFrameLatency }

    /// URL of the most recently ended take's WAV file, if the sink factory tracks one
    /// (WAVSinkFactory does; test fakes default to nil via the protocol extension).
    public var lastTakeURL: URL? { sinkFactory.lastURL }

    public func retarget(to deviceID: UInt32) throws {
        guard let retargetable = engine as? LiveCaptureRetargeting else {
            throw NSError(
                domain: "RhemionRuntime.CaptureController",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Capture engine does not support live retargeting."]
            )
        }
        try retargetable.retarget(to: deviceID)
    }
}

/// Thin `TakeSink` adapter over a `CaptureController`, so the composition root can hand
/// `RuntimeService` a capture hook without RuntimeService depending on RhemionAudio directly.
/// `@unchecked Sendable`: CaptureController itself is not provably Sendable, but its
/// engine/pipeline collaborators are each internally thread-safe by design (see their headers).
public final class CaptureControllerTakeSink: CaptureCoordinator.LiveRetargetingTakeSink, @unchecked Sendable {
    private let controller: CaptureController

    public init(controller: CaptureController) {
        self.controller = controller
    }

    public func begin(session: String, pressedAt: Double) {
        controller.beginTake(session: session, pressedAt: pressedAt)
    }

    public func end(session: String) -> URL? {
        controller.endTake(session: session)
        // Read lastTakeURL synchronously, right here, so the URL is captured for THIS take
        // before any later beginTake (from a fast subsequent start) can overwrite it.
        return controller.lastTakeURL
    }

    public func cancel(session: String) {
        // Finalize the pipeline so all resources are released, but deliberately do not expose
        // lastTakeURL: a device-loss take must never enter dictation/transcription.
        controller.endTake(session: session)
    }

    public func retarget(to device: AudioDeviceInfo) throws {
        try controller.retarget(to: device.id)
    }
}
