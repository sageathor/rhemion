import Foundation
import Darwin

public enum HistoryRetention {
    public static func expiredMonthNames(in names: [String], retaining months: Int, now: Date,
                                         calendar: Calendar = .current) -> [String] {
        guard months > 0,
              let currentStart = calendar.date(from: calendar.dateComponents([.year, .month], from: now)),
              let cutoff = calendar.date(byAdding: .month, value: -(months - 1), to: currentStart) else { return [] }
        let formatter = DateFormatter(); formatter.calendar = calendar; formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = calendar.timeZone; formatter.dateFormat = "yyyy-MM"
        return names.filter { name in
            guard name.range(of: #"^\d{4}-(0[1-9]|1[0-2])$"#, options: .regularExpression) != nil,
                  let date = formatter.date(from: name) else { return false }
            return date < cutoff
        }.sorted()
    }

    /// The IDs of every entry whose timestamp is strictly before `cutoff`, across all monthly logs.
    /// These are handed to `HistoryStore.deleteEntries` so transcript expiry reuses the exact,
    /// review-hardened deletion path (raw-line JSONL rewrite + owned-audio removal + exported-note
    /// pruning) rather than a parallel one. A record with an unparseable timestamp is never expired.
    public static func expiredTranscriptIDs(stateDirectory: URL, historyDirectory: URL,
                                            before cutoff: Date) -> Set<String> {
        var ids = Set<String>()
        for month in HistoryStore.availableMonths(stateDirectory: stateDirectory, historyDirectory: historyDirectory) {
            guard let records = try? HistoryStore.readRecords(month: month, stateDirectory: stateDirectory) else { continue }
            for record in records {
                guard let date = HistoryStore.parseTimestamp(record.ts) else { continue }
                if date < cutoff { ids.insert(record.id) }
            }
        }
        return ids
    }

    /// Delete the local WAV of every retained take older than `cutoff`, keeping the transcript record.
    /// The exemption is persisted BEFORE unlinking (so an interrupted pass can't be mistaken for a user
    /// deletion by the next reconcile), then the affected months are re-rendered. `excludingIDs` are the
    /// entries transcript-expiry is deleting wholesale this pass — their audio is left to that path.
    /// Returns the months whose audio changed.
    @discardableResult
    public static func runAudioExpiry(historyDirectory: URL, stateDirectory: URL, before cutoff: Date,
                                      excludingIDs: Set<String> = [], now: Date = Date(),
                                      calendar: Calendar = .current) throws -> Set<String> {
        let fm = FileManager.default
        let vaultNames = (try? fm.contentsOfDirectory(atPath: historyDirectory.path)) ?? []
        // Map excluded IDs to their audio file names so a wholesale-expiring entry's WAV isn't also
        // touched here (its removal, and its record's, belongs to deleteEntries).
        var excludedAudio = Set<String>()
        if !excludingIDs.isEmpty {
            for month in vaultNames {
                guard let records = try? HistoryStore.readRecords(month: month, stateDirectory: stateDirectory) else { continue }
                for record in records where excludingIDs.contains(record.id) {
                    if let audio = record.audio, !audio.isEmpty { excludedAudio.insert(audio) }
                }
            }
        }
        var expiredAudio: [String: [URL]] = [:]
        for month in vaultNames {
            let audioDir = historyDirectory.appendingPathComponent("\(month)/Audio", isDirectory: true)
            let audio = (try? fm.contentsOfDirectory(at: audioDir,
                includingPropertiesForKeys: [.contentModificationDateKey, .creationDateKey])) ?? []
            for file in audio where file.pathExtension.lowercased() == "wav" {
                if excludedAudio.contains(file.lastPathComponent) { continue }
                let values = try? file.resourceValues(forKeys: [.contentModificationDateKey, .creationDateKey])
                guard let date = values?.creationDate ?? values?.contentModificationDate, date < cutoff else { continue }
                expiredAudio[month, default: []].append(file)
            }
        }
        var affected = Set<String>()
        for (month, files) in expiredAudio {
            try HistoryStore.markAudioNotRetained(names: Set(files.map(\.lastPathComponent)), month: month,
                                                  stateDirectory: stateDirectory)
            for file in files { try fm.removeItem(at: file) }
            affected.insert(month)
        }
        for month in affected {
            _ = try HistoryStore.renderMonth(month, stateDirectory: stateDirectory,
                                             historyDirectory: historyDirectory, calendar: calendar, generatedAt: now)
        }
        return affected
    }

    /// Retention runs at most once per calendar day (a marker file records the last run's day). Split
    /// from `markRanToday` so a caller can run the async delete/audio passes between the check and the
    /// mark.
    public static func shouldRunToday(stateDirectory: URL, now: Date = Date(), calendar: Calendar = .current) -> Bool {
        let marker = stateDirectory.appendingPathComponent("history-retention-last-run")
        let today = dayKey(now, calendar: calendar)
        return (try? String(contentsOf: marker, encoding: .utf8)) != today
    }

    public static func markRanToday(stateDirectory: URL, now: Date = Date(), calendar: Calendar = .current) throws {
        try FileManager.default.createDirectory(at: stateDirectory, withIntermediateDirectories: true)
        let marker = stateDirectory.appendingPathComponent("history-retention-last-run")
        let temporary = stateDirectory.appendingPathComponent(".history-retention-\(UUID().uuidString).tmp")
        try Data(dayKey(now, calendar: calendar).utf8).write(to: temporary)
        guard Darwin.rename(temporary.path, marker.path) == 0 else {
            let error = POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            try? FileManager.default.removeItem(at: temporary); throw error
        }
    }

    private static func dayKey(_ date: Date, calendar: Calendar) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year!, c.month!, c.day!)
    }
}
