import Darwin
import Foundation

/// The rendered history note (`<data>/history/<YYYY-MM>/<YYYY-MM>.md`) and the audio bookkeeping around
/// it — shared by the runtime (retention, reconcile, append) and the app (Clear Data › Recordings), so
/// both write the very same bytes and the same `audio_retained` marks.
///
/// Why the app needs it: the runtime's reconcile drops a record whose audio is missing unless the record
/// says `audio_retained: false` AND the note still names it (`^rh-<id>`). Deleting recordings therefore
/// marks the rows first (before any audio goes) and re-renders the months afterwards — exactly what
/// audio retention does — so no transcript is lost and no dead audio embed remains.
public enum HistoryNote {
    public struct Entry: Sendable {
        public let id, ts, engine, text: String
        public let app, audio: String?
        public let audioRetained: Bool?
        public init(id: String, ts: String, engine: String, text: String, app: String?, audio: String?, audioRetained: Bool?) {
            self.id = id; self.ts = ts; self.engine = engine; self.text = text
            self.app = app; self.audio = audio; self.audioRetained = audioRetained
        }
    }

    static func shortID(_ id: String) -> String { String(id.prefix(8)).lowercased() }

    static func parseTimestamp(_ value: String) -> Date? {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.date(from: value) ?? ISO8601DateFormatter().date(from: value)
    }

    /// THE body of a month's history note (the runtime's `HistoryStore.renderBody` delegates here).
    public static func renderBody(_ records: [Entry], month: String, monthDirectory: URL, calendar: Calendar,
                                  headings: NoteHeadings = .system) -> String {
        let rows = records.enumerated().compactMap { index, record -> (Entry, Date, Int)? in
            guard let date = parseTimestamp(record.ts) else { return nil }; return (record, date, index)
        }.sorted { ($0.1, $0.2) > ($1.1, $1.2) }
        var lines = ["# \(month)", ""], lastWeek: Int?, lastDay: DateComponents?
        for (record, date, _) in rows {
            let day = calendar.dateComponents([.year, .month, .day], from: date), week = calendar.component(.weekOfYear, from: date)
            if week != lastWeek { lines += [headings.weekHeading(week), ""]; lastWeek = week; lastDay = nil }
            if day != lastDay {
                lines += [headings.dayHeading(weekday: calendar.component(.weekday, from: date), day: day), ""]
                lastDay = day
            }
            let hm = calendar.dateComponents([.hour, .minute], from: date)
            var properties = String(format: "**%02d:%02d** · %@", hm.hour!, hm.minute!, record.engine)
            if let app = record.app?.trimmingCharacters(in: .whitespacesAndNewlines), !app.isEmpty { properties += " · \(app)" }
            if record.audioRetained == false { properties += " ^rh-\(shortID(record.id))" }
            lines += [properties, record.text]
            if record.audioRetained != false, let audio = record.audio, !audio.isEmpty,
               FileManager.default.fileExists(atPath: monthDirectory.appendingPathComponent("Audio/\(URL(fileURLWithPath: audio).lastPathComponent)").path) {
                lines.append("![[\(URL(fileURLWithPath: audio).lastPathComponent)]]")
            }
            lines.append("")
        }
        while lines.last == "" { lines.removeLast() }
        return lines.joined(separator: "\n") + "\n"
    }

    /// The month's records as the runtime reads them (lenient: an undecodable line is skipped).
    static func entries(month: String, state: URL) -> [Entry] {
        let url = state.appendingPathComponent("log/dictate-\(month).jsonl")
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        let decoder = JSONDecoder()
        return text.split(separator: "\n").compactMap { line in
            guard let r = try? decoder.decode(ExportNote.Record.self, from: Data(line.utf8)) else { return nil }
            return Entry(id: r.id, ts: r.ts, engine: r.engine, text: r.enhanced ?? r.clean, app: r.app_name,
                         audio: r.audio.map { URL(fileURLWithPath: $0).lastPathComponent }, audioRetained: r.audio_retained)
        }
    }

    /// Re-render one month's note from its log (atomic), as the runtime's `renderMonth` does. A month
    /// with no folder or no log is left alone (nothing to fix; a note is never overwritten from nothing).
    public static func rerender(month: String, state: URL, history: URL, calendar: Calendar) throws {
        let monthDirectory = history.appendingPathComponent(month, isDirectory: true)
        let fm = FileManager.default
        guard fm.fileExists(atPath: monthDirectory.path),
              fm.fileExists(atPath: state.appendingPathComponent("log/dictate-\(month).jsonl").path) else { return }
        let body = renderBody(entries(month: month, state: state), month: month, monthDirectory: monthDirectory, calendar: calendar)
        let target = monthDirectory.appendingPathComponent("\(month).md")
        let temporary = monthDirectory.appendingPathComponent(".\(month).\(UUID().uuidString).tmp")
        do {
            try Data(body.utf8).write(to: temporary)
            let handle = try FileHandle(forWritingTo: temporary); try handle.synchronize(); try handle.close()
            guard Darwin.rename(temporary.path, target.path) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        } catch { try? FileManager.default.removeItem(at: temporary); throw error }
    }

    /// Flip `audio_retained` to false on the rows whose audio file is in `names`, rewriting the JSONL
    /// at the RAW-line level: undecodable lines and unknown fields on the touched rows are preserved
    /// (only the one key changes). A whole-log decode+re-encode would silently drop future-schema rows
    /// and unknown fields — this must not, since audio expiry can run with transcript retention off.
    public static func markAudioNotRetained(names: Set<String>, month: String, state: URL) throws {
        try markNotRetained(month: month, state: state) { obj in
            guard let audio = obj["audio"] as? String else { return false }
            return names.contains(URL(fileURLWithPath: audio).lastPathComponent)
        }
    }

    /// Every row of the month becomes `audio_retained: false` (same raw-line rewrite) — for Clear Data ›
    /// Recordings, which deletes the month's whole `Audio/` folder: a row whose recording is gone but
    /// isn't marked would be dropped by the runtime's reconcile (transcript lost), whatever its `audio`
    /// field says.
    public static func markAllAudioNotRetained(month: String, state: URL) throws {
        try markNotRetained(month: month, state: state) { _ in true }
    }

    private static func markNotRetained(month: String, state: URL, _ matches: ([String: Any]) -> Bool) throws {
        let directory = state.appendingPathComponent("log", isDirectory: true)
        let url = directory.appendingPathComponent("dictate-\(month).jsonl")
        guard let data = try? Data(contentsOf: url) else { return }
        var out = Data(); var changed = false
        for line in data.split(separator: 0x0a, omittingEmptySubsequences: true) {
            if var obj = (try? JSONSerialization.jsonObject(with: Data(line))) as? [String: Any],
               matches(obj), (obj["audio_retained"] as? Bool) != false,
               let encoded = try? {
                   obj["audio_retained"] = false
                   return try JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys])
               }() {
                out.append(encoded); out.append(0x0a); changed = true
            } else {
                out.append(contentsOf: line); out.append(0x0a)   // keep verbatim
            }
        }
        guard changed else { return }
        let temporary = directory.appendingPathComponent(".dictate-\(month).\(UUID().uuidString).tmp")
        do {
            try out.write(to: temporary)
            let handle = try FileHandle(forWritingTo: temporary); try handle.synchronize(); try handle.close()
            guard Darwin.rename(temporary.path, url.path) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        } catch { try? FileManager.default.removeItem(at: temporary); throw error }
    }
}
