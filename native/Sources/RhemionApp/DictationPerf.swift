// DictationPerf — per-dictation latency by phase, measured where the user feels it (the app), on the
// monotonic clock. One `perf:` line per dictation in app.log, numbers only (never the text):
//
//   perf: press→rec 41 · release→stopped 12 · →transcript 168 (engine 153) · →deliver 3 · →inserted 9 ·
//         total 192 · audio 1173 · paste-submitted
//
//   press→rec      key down → the runtime reports recording started
//   release→stopped key up → the runtime has closed the capture
//   →transcript    capture closed → text recognized (engine = the recognizer's own time inside it)
//   →deliver       transcript → the app gets the final text (dictionary replacements applied)
//   →inserted      the app gets the text → the insertion call returned
//   total          key up → inserted: the number to keep low
//
// deploy/latency-report.sh turns these lines into p50/p95 per phase. Hands-free takes that stop on their
// own have no key-up; their "release" is the stop event, so total covers stopped → inserted.

import Foundation

final class DictationPerf: @unchecked Sendable {
    private let lock = NSLock()
    private var pressed: UInt64?, started: UInt64?, released: UInt64?, stopped: UInt64?
    private var transcript: UInt64?, delivered: UInt64?
    private var engineMS: Int?

    private static func now() -> UInt64 { DispatchTime.now().uptimeNanoseconds }
    private static func ms(_ a: UInt64?, _ b: UInt64?) -> Int? {
        guard let a, let b, b >= a else { return nil }
        return Int((b - a) / 1_000_000)
    }

    func markPress()   { lock.withLock { reset(); pressed = Self.now() } }
    func markStarted() { lock.withLock { if started == nil { started = Self.now() } } }
    func markRelease() { lock.withLock { released = Self.now() } }
    func markStopped() { lock.withLock { stopped = Self.now() } }
    func markTranscript(engineMS ms: Double) { lock.withLock { transcript = Self.now(); engineMS = Int(ms) } }
    func markDeliver() { lock.withLock { delivered = Self.now() } }
    func cancel()      { lock.withLock { reset() } }

    /// The insertion finished: write the line and forget this dictation.
    func markInserted(method: String) {
        let line: String? = lock.withLock {
            let end = Self.now()
            guard stopped != nil || released != nil else { reset(); return nil }
            let from = released ?? stopped
            var parts: [String] = []
            if let v = Self.ms(pressed, started) { parts.append("press→rec \(v)") }
            if let v = Self.ms(released, stopped) { parts.append("release→stopped \(v)") }
            if let v = Self.ms(stopped ?? released, transcript) {
                parts.append("→transcript \(v)" + (engineMS.map { " (engine \($0))" } ?? ""))
            }
            if let v = Self.ms(transcript, delivered) { parts.append("→deliver \(v)") }
            if let v = Self.ms(delivered, end) { parts.append("→inserted \(v)") }
            if let v = Self.ms(from, end) { parts.append("total \(v)") }
            if let v = Self.ms(started, stopped) { parts.append("audio \(v)") }
            parts.append(method)
            reset()
            return "perf: " + parts.joined(separator: " · ")
        }
        if let line { log(line) }
    }

    private func reset() {
        pressed = nil; started = nil; released = nil; stopped = nil; transcript = nil; delivered = nil
        engineMS = nil
    }
}
