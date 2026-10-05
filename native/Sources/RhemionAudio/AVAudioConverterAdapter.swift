@preconcurrency import AVFoundation
import Foundation

/// Real `AudioConverting` implementation: converts device-native interleaved Float32
/// (N channels, device sample rate) into 16 kHz mono signed-16-bit Int16 using
/// `AVAudioConverter` (channel downmix + anti-aliased resample).
public final class AVAudioConverterAdapter: AudioConverting {
    /// Target format: 16 kHz, mono, interleaved Int16.
    private static let outputFormat = AVAudioFormat(
        commonFormat: .pcmFormatInt16,
        sampleRate: Double(AudioFormat.sampleRate),
        channels: AVAudioChannelCount(AudioFormat.channels),
        interleaved: true
    )!

    private struct CacheKey: Hashable {
        let channels: Int
        let sampleRate: Double
    }

    private let lock = NSLock()
    private var cache: [CacheKey: AVAudioConverter] = [:]

    public init() {}

    /// Converts `frames` to 16 kHz mono Int16. Serializes internally (a single lock spans
    /// cache lookup, the `AVAudioConverter.convert` call, and output extraction), so it is
    /// safe to call from any thread — Rhemion itself only calls it from a single serial
    /// delivery queue, but the API makes no such assumption on its own.
    public func convert(_ frames: [Float], channels: Int, sampleRate: Double) -> [Int16] {
        guard channels > 0, sampleRate > 0, !frames.isEmpty else { return [] }
        guard frames.count % channels == 0 else { return [] }
        let frameCount = frames.count / channels

        guard let inputFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: AVAudioChannelCount(channels),
            interleaved: true
        ) else { return [] }

        lock.lock()
        defer { lock.unlock() }

        guard let converter = converter(for: channels, sampleRate: sampleRate, inputFormat: inputFormat) else {
            return []
        }

        guard let inputBuffer = AVAudioPCMBuffer(
            pcmFormat: inputFormat,
            frameCapacity: AVAudioFrameCount(frameCount)
        ) else { return [] }
        inputBuffer.frameLength = AVAudioFrameCount(frameCount)

        guard let inputData = inputBuffer.floatChannelData else { return [] }
        // Interleaved buffer: all channels live in a single plane at floatChannelData[0].
        frames.withUnsafeBufferPointer { src in
            inputData[0].update(from: src.baseAddress!, count: frames.count)
        }

        // Output capacity: sized by the sample-rate ratio, plus slack for converter priming.
        let ratio = Self.outputFormat.sampleRate / sampleRate
        let estimatedOutputFrames = Int((Double(frameCount) * ratio).rounded(.up)) + 32
        guard let outputBuffer = AVAudioPCMBuffer(
            pcmFormat: Self.outputFormat,
            frameCapacity: AVAudioFrameCount(estimatedOutputFrames)
        ) else { return [] }

        nonisolated(unsafe) var suppliedInput = false
        var conversionError: NSError?
        let status = converter.convert(to: outputBuffer, error: &conversionError) { _, outStatus in
            if suppliedInput {
                outStatus.pointee = .noDataNow
                return nil
            }
            suppliedInput = true
            outStatus.pointee = .haveData
            return inputBuffer
        }

        guard status != .error, conversionError == nil else { return [] }
        guard let outputData = outputBuffer.int16ChannelData else { return [] }

        let outFrameCount = Int(outputBuffer.frameLength)
        return Array(UnsafeBufferPointer(start: outputData[0], count: outFrameCount))
    }

    /// Gets or builds the cached converter for `(channels, sampleRate)`. Assumes `lock` is
    /// already held by the caller (`convert`) — NSLock is not recursive, so this must never
    /// lock itself.
    private func converter(for channels: Int, sampleRate: Double, inputFormat: AVAudioFormat) -> AVAudioConverter? {
        let key = CacheKey(channels: channels, sampleRate: sampleRate)
        if let cached = cache[key] {
            return cached
        }
        guard let converter = AVAudioConverter(from: inputFormat, to: Self.outputFormat) else {
            return nil
        }
        cache[key] = converter
        return converter
    }
}
