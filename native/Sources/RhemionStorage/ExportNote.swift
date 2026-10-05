import Foundation

/// The exported month note (`YYYY-MM.md`) as Rhemion renders it, and the re-adoption rule built on it.
/// Lives here (not in the runtime) so the app — which never links the runtime — can recognise its own
/// notes the same way before it deletes exported transcripts.
///
/// Re-adoption: a month note that the registry does not currently own with a matching hash, but
/// whose bytes EXACTLY equal what Rhemion renders for that month right now (the month has at least one
/// record), is Rhemion's — e.g. written by another Rhemion version, or before the registry existed. An
/// edited note never matches; an empty month's bare heading proves nothing and is never adopted.
public enum ExportNote {
    /// One journal record, decoded with EXACTLY the shape the runtime's `HistoryRecord` requires (same
    /// required keys and types), so a line the runtime can't decode can't be rendered here either.
    struct Record: Decodable {
        let id, ts, engine: String
        let ms, audio_duration_ms: Int?
        let raw, clean: String
        let enhanced: String?
        let delivered: Bool
        let delivery_method, delivery_error, app_name, app_bundle_id, audio: String?
        let audio_retained: Bool?
        let pre_dictionary: String?
    }

    /// What one record contributes to the note.
    public struct Line: Sendable {
        public let ts: String
        public let text: String
        public let app: String?
        public init(ts: String, text: String, app: String?) { self.ts = ts; self.text = text; self.app = app }
    }

    /// THE render of a month note (the runtime's `TranscriptExport.render` delegates here).
    public static func render(_ records: [Line], month: String, calendar: Calendar,
                              headings: NoteHeadings = .system) -> String {
        var iso = Calendar(identifier: .iso8601)
        iso.timeZone = calendar.timeZone
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let rows = records.enumerated().compactMap { index, record -> (Line, Date, Int)? in
            guard let date = formatter.date(from: record.ts) ?? ISO8601DateFormatter().date(from: record.ts) else { return nil }
            return (record, date, index)
        }.sorted { ($0.1, $0.2) > ($1.1, $1.2) }
        var lines = ["# \(month)", ""], lastWeek: Int?, lastDay: DateComponents?
        for (record, date, _) in rows {
            let day = iso.dateComponents([.year, .month, .day], from: date)
            let week = iso.component(.weekOfYear, from: date)
            if week != lastWeek { lines += [headings.weekHeading(week), ""]; lastWeek = week; lastDay = nil }
            if day != lastDay {
                lines += [headings.dayHeading(weekday: iso.component(.weekday, from: date), day: day), ""]
                lastDay = day
            }
            let time = iso.dateComponents([.hour, .minute], from: date)
            var heading = String(format: "**%02d:%02d**", time.hour!, time.minute!)
            if let app = record.app?.trimmingCharacters(in: .whitespacesAndNewlines), !app.isEmpty { heading += " · \(app)" }
            lines += [heading, record.text, ""]
        }
        while lines.last == "" { lines.removeLast() }
        return lines.joined(separator: "\n") + "\n"
    }

    static func isMonth(_ value: String) -> Bool {
        value.range(of: #"^\d{4}-(0[1-9]|1[0-2])$"#, options: .regularExpression) != nil
    }

    /// The note Rhemion would write for `month` now — nil when that proves nothing: no log, no record,
    /// or ANY non-empty line that doesn't decode (the runtime's export would refuse that month too).
    static func currentBody(month: String, state: URL, calendar: Calendar) -> String? {
        guard isMonth(month) else { return nil }
        let log = state.appendingPathComponent("log/dictate-\(month).jsonl")
        guard let text = try? String(contentsOf: log, encoding: .utf8) else { return nil }
        let decoder = JSONDecoder()
        var lines: [Line] = []
        for raw in text.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let r = try? decoder.decode(Record.self, from: Data(raw.utf8)) else { return nil }
            lines.append(Line(ts: r.ts, text: r.enhanced ?? r.clean, app: r.app_name))
        }
        guard !lines.isEmpty else { return nil }
        return render(lines, month: month, calendar: calendar)
    }

    /// Month notes in `dir` that the registry doesn't currently own (with a matching hash) but that
    /// EXACTLY equal the current render — regular files only, never a symlink. Read-only.
    public static func adoptable(in dir: URL, state: URL, registry: ExportRegistry, calendar: Calendar) -> [String: Data] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        var out: [String: Data] = [:]
        for name in names.sorted() where ExportRegistry.isMonthNote(name) {
            let file = dir.appendingPathComponent(name)
            guard (try? file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])).map({
                $0.isRegularFile == true && $0.isSymbolicLink != true }) == true,
                  let existing = try? Data(contentsOf: file),
                  !registry.owns(name, in: dir, data: existing),
                  let body = currentBody(month: String(name.dropLast(3)), state: state, calendar: calendar),
                  existing == Data(body.utf8) else { continue }
            out[name] = existing
        }
        return out
    }

    /// (Re)record every adoptable note as Rhemion's. Runs before every export write, before a Journal
    /// mutation that re-exports or removes notes, and before an export deletion. Writes the registry only
    /// when something was adopted (never creates one for nothing).
    public static func readopt(directory: URL, state: URL, registryURL: URL, calendar: Calendar) throws {
        guard FileManager.default.fileExists(atPath: directory.path) else { return }
        var registry = ExportRegistry.load(from: registryURL)
        let found = adoptable(in: directory, state: state, registry: registry, calendar: calendar)
        guard !found.isEmpty else { return }
        for (name, data) in found { registry.record(name, in: directory, data: data) }
        try registry.save(to: registryURL)
    }
}
