import Foundation
import RhemionAudio
import RhemionCore

public final class WAVSinkFactory: CaptureSinkFactory {
    private let resolveHistoryDirectory: () -> URL
    private let now: () -> Date
    private let ids: ULIDGenerator
    private let lock = NSLock()
    private var _lastURL: URL?

    public init(historyDirectory: @escaping () -> URL = { RuntimePaths.historyDirectory() }, now: @escaping () -> Date = Date.init,
                ids: ULIDGenerator = ULIDGenerator()) {
        self.resolveHistoryDirectory = historyDirectory; self.now = now; self.ids = ids
    }
    public convenience init(historyDirectory: URL, now: @escaping () -> Date = Date.init,
                            ids: ULIDGenerator = ULIDGenerator()) {
        self.init(historyDirectory: { historyDirectory }, now: now, ids: ids)
    }
    public var lastURL: URL? { lock.lock(); defer { lock.unlock() }; return _lastURL }

    public func makeSink() throws -> SampleSink {
        let date = now(), id = ids.generate(date: date)
        let c = Calendar.current.dateComponents([.year, .month], from: date)
        let month = String(format: "%04d-%02d", c.year!, c.month!)
        let directory = resolveHistoryDirectory().appendingPathComponent(month, isDirectory: true)
            .appendingPathComponent("Audio", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let stem = "\(HistoryStore.fileTimestamp(date))--\(id)"
        let final = directory.appendingPathComponent(stem + ".wav")
        let active = directory.appendingPathComponent(".\(stem).wav.in-progress")
        lock.lock(); _lastURL = final; lock.unlock()
        return try AtomicWAVSink(activeURL: active, finalURL: final)
    }
}

private final class AtomicWAVSink: SampleSink {
    private let sink: WAVFileSink
    private let activeURL: URL, finalURL: URL
    private var finished = false
    init(activeURL: URL, finalURL: URL) throws {
        self.activeURL = activeURL; self.finalURL = finalURL; self.sink = try WAVFileSink(url: activeURL)
    }
    func write(_ samples: [Int16]) { sink.write(samples) }
    func finish() {
        guard !finished else { return }; finished = true
        sink.finish()
        do { try FileManager.default.moveItem(at: activeURL, to: finalURL) }
        catch { FileHandle.standardError.write(Data("rhemion-runtime: WAV finalize failed: \(error)\n".utf8)) }
    }
}
