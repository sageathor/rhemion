import Foundation

/// SampleSink backed by a WAVWriter — the per-take fallback WAV.
public final class WAVFileSink: SampleSink {
    private let writer: WAVWriter
    private var failed = false

    public init(url: URL) throws {
        self.writer = try WAVWriter(url: url)
    }

    public func write(_ samples: [Int16]) {
        guard !failed else { return }
        do { try writer.append(samples) } catch { failed = true }
    }

    public func finish() {
        try? writer.finalize()
    }
}
