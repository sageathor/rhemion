import Foundation

/// A read-only projection of the runtime's JSONL record; no runtime dependency.
struct JournalEntry: Identifiable, Sendable, Equatable {
    let id: String
    let ts: Date
    let engine: String
    let ms: Int?
    let audioDurationMS: Int?
    let raw: String
    let clean: String
    let enhanced: String?
    let delivered: Bool
    let deliveryMethod: String?
    let appName: String?
    let appBundleID: String?
    let audio: String?
    let audioRetained: Bool?
    let preDictionary: String?

    // enhanced wins only when it has real non-whitespace text (empty/blank enhanced falls back to clean,
    // matching RecallStore) — else Final would show/copy an empty string.
    var transcript: String {
        if let enhanced, enhanced.contains(where: { !$0.isWhitespace }) { return enhanced }
        return clean
    }
    /// The local WAV for this entry, or nil when there is no audio (never retained, or pruned by
    /// retention). Mirrors where the runtime files retained takes: the app's own data dir
    /// (`RHEMION_DATA_DIR = <stateDir>/data`), month-foldered, under `Audio/`.
    var audioURL: URL? {
        guard let audio, !audio.isEmpty else { return nil }
        let url = AppPaths.dataDir
            .appendingPathComponent("history/\(JournalDoc.monthFolder(ts))/Audio/\(audio)", isDirectory: false)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }
    var duration: String { audioDurationMS.map { JournalDoc.duration(Double($0) / 1000) } ?? "—" }
}

enum JournalGrouping: String, CaseIterable {
    case monthWeekDay = "Month · Week · Day"
    case monthDay = "Month · Day"
    case day = "By day"
    case flat = "No grouping"
}

struct JournalGroup: Identifiable {
    enum Level { case month, week, day }
    let id: String
    let level: Level
    let title: String
    let entries: [JournalEntry]
    let children: [JournalGroup]
}

struct JournalDoc: Sendable {
    let entries: [JournalEntry]
    let skippedLines: Int
    let unreadableFiles: Int

    static func load(directory: URL = AppPaths.stateDir.appendingPathComponent("log", isDirectory: true)) -> JournalDoc {
        let names: [String]
        do { names = try FileManager.default.contentsOfDirectory(atPath: directory.path) }
        catch {
            let missing = (error as NSError).code == NSFileReadNoSuchFileError
            return JournalDoc(entries: [], skippedLines: 0, unreadableFiles: missing ? 0 : 1)
        }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let seconds = ISO8601DateFormatter()
        var entries: [JournalEntry] = [], skipped = 0, unreadable = 0
        var seen = Set<String>()
        for name in names.sorted(by: >) where name.range(of: #"^dictate-\d{4}-(0[1-9]|1[0-2])\.jsonl$"#, options: .regularExpression) != nil {
            guard let data = try? Data(contentsOf: directory.appendingPathComponent(name)) else {
                unreadable += 1; continue
            }
            // Split bytes first: invalid UTF-8 in one line must not discard an entire month.
            for line in data.split(separator: 0x0A) {
                guard let object = (try? JSONSerialization.jsonObject(with: Data(line))) as? [String: Any],
                      let id = object["id"] as? String, !id.isEmpty,
                      let timestamp = object["ts"] as? String,
                      let date = fractional.date(from: timestamp) ?? seconds.date(from: timestamp),
                      let raw = object["raw"] as? String, let clean = object["clean"] as? String
                else { skipped += 1; continue }
                guard seen.insert(id).inserted else { continue }
                entries.append(JournalEntry(
                    id: id, ts: date, engine: object["engine"] as? String ?? "—",
                    ms: object["ms"] as? Int, audioDurationMS: object["audio_duration_ms"] as? Int,
                    raw: raw, clean: clean, enhanced: object["enhanced"] as? String,
                    delivered: object["delivered"] as? Bool ?? false,
                    deliveryMethod: object["delivery_method"] as? String,
                    appName: object["app_name"] as? String, appBundleID: object["app_bundle_id"] as? String,
                    audio: object["audio"] as? String, audioRetained: object["audio_retained"] as? Bool,
                    preDictionary: object["pre_dictionary"] as? String))
            }
        }
        entries.sort { $0.ts == $1.ts ? $0.id > $1.id : $0.ts > $1.ts }
        return JournalDoc(entries: entries, skippedLines: skipped, unreadableFiles: unreadable)
    }

    /// ISO weeks use the local time zone, including ISO week-years at the December boundary.
    static func groups(_ entries: [JournalEntry], by grouping: JournalGrouping,
                       timeZone: TimeZone = .current) -> [JournalGroup] {
        var calendar = Calendar(identifier: .iso8601)
        calendar.timeZone = timeZone
        func partition(_ values: [JournalEntry], level: JournalGroup.Level, parent: String) -> [JournalGroup] {
            let component: Calendar.Component = level == .month ? .month : level == .week ? .weekOfYear : .day
            let buckets = Dictionary(grouping: values) { calendar.dateInterval(of: component, for: $0.ts)!.start }
            return buckets.keys.sorted(by: >).map { start in
                let members = buckets[start]!.sorted { $0.ts > $1.ts }
                let id = "\(parent)/\(level)/\(start.timeIntervalSince1970)"
                let title: String
                let children: [JournalGroup]
                switch level {
                case .month:
                    title = label(start, "LLLL yyyy", timeZone: timeZone).capitalized
                    children = partition(members, level: grouping == .monthWeekDay ? .week : .day, parent: id)
                case .week:
                    let end = calendar.date(byAdding: .day, value: 6, to: start)!
                    title = "WEEK \(calendar.component(.weekOfYear, from: start)) · \(label(start, "dd.MM", timeZone: timeZone))–\(label(end, "dd.MM", timeZone: timeZone))"
                    children = partition(members, level: .day, parent: id)
                case .day:
                    title = label(start, "d MMMM · EEE", timeZone: timeZone)
                    children = []
                }
                return JournalGroup(id: id, level: level, title: title, entries: members, children: children)
            }
        }
        guard grouping != .flat else { return [] }
        return partition(entries, level: grouping == .day ? .day : .month, parent: "")
    }

    // Reused, lock-guarded formatters keyed by format+time zone — building a DateFormatter per group
    // title on every render is expensive on large journals. English locale is the default chrome;
    // localization (incl. Russian date names) comes later.
    private static let formatterLock = NSLock()
    nonisolated(unsafe) private static var formatters: [String: DateFormatter] = [:]
    static func label(_ date: Date, _ format: String, timeZone: TimeZone = .current) -> String {
        let key = "\(format)|\(timeZone.identifier)"
        formatterLock.lock(); defer { formatterLock.unlock() }
        let formatter: DateFormatter
        if let cached = formatters[key] { formatter = cached }
        else {
            formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US")
            formatter.timeZone = timeZone
            formatter.dateFormat = format
            formatters[key] = formatter
        }
        return formatter.string(from: date)
    }

    /// "yyyy-MM" for the audio month folder — uses Calendar.current to match the runtime's
    /// `HistoryStore.month` / `WAVSinkFactory` exactly (same calendar identifier and time zone).
    static func monthFolder(_ date: Date) -> String {
        let c = Calendar.current.dateComponents([.year, .month], from: date)
        return String(format: "%04d-%02d", c.year ?? 0, c.month ?? 0)
    }

    static func duration(_ seconds: Double) -> String {
        let value = Int(max(0, seconds))
        return String(format: "%d:%02d", value / 60, value % 60)
    }
}
