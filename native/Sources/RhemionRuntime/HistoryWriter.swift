import Foundation
import Darwin
import RhemionCore
import RhemionStorage

public struct HistoryApplication: Sendable, Equatable {
    public let name: String?
    public let bundleID: String?
    public init(name: String? = nil, bundleID: String? = nil) { self.name = name; self.bundleID = bundleID }
}

public struct HistoryEntry: Sendable, Equatable {
    public let schema: String, id: String, sessionID: String, status: String, engine: String
    public let createdAt: Date
    public let audioDurationMS: Int?, processingDurationMS: Int?
    public let raw: String, clean: String, enhanced: String?
    public let delivered: Bool
    public let deliveryMethod: String?, deliveryError: String?
    public let application: HistoryApplication?
    public let audio: String?, audioFormat: String
    public let audioRetained: Bool
    /// The "as spoken" text before the dictionary/replacement step (see `DeliveryOutcome.preDictionary`),
    /// or nil when there was no real dictionary substitution to undo. Persisted only when non-nil.
    public let preDictionary: String?
    public var transcript: String { enhanced ?? clean }

    public init(schema: String = "rhemion-history/v1", id: String, createdAt: Date, sessionID: String,
                status: String = "completed", engine: String, audioDurationMS: Int? = nil,
                processingDurationMS: Int? = nil, raw: String, clean: String, enhanced: String?,
                delivered: Bool, deliveryMethod: String? = nil, deliveryError: String? = nil,
                application: HistoryApplication? = nil, audio: String? = nil,
                audioFormat: String = "wav", audioRetained: Bool = true, preDictionary: String? = nil) {
        self.schema = schema; self.id = id; self.createdAt = createdAt; self.sessionID = sessionID
        self.status = status; self.engine = engine; self.audioDurationMS = audioDurationMS
        self.processingDurationMS = processingDurationMS; self.raw = raw; self.clean = clean
        self.enhanced = enhanced; self.delivered = delivered; self.deliveryMethod = deliveryMethod
        self.deliveryError = deliveryError; self.application = application; self.audio = audio
        self.audioFormat = audioFormat; self.audioRetained = audioRetained; self.preDictionary = preDictionary
    }
}

public final class ULIDGenerator: @unchecked Sendable {
    private static let alphabet = Array("0123456789ABCDEFGHJKMNPQRSTVWXYZ")
    private let lock = NSLock(); private var lastMilliseconds: UInt64 = 0
    private var randomness = [UInt8](repeating: 0, count: 10)
    public init() {}
    public func generate(date: Date = Date()) -> String {
        lock.lock(); defer { lock.unlock() }
        let milliseconds = UInt64(max(0, date.timeIntervalSince1970 * 1000))
        if milliseconds > lastMilliseconds {
            lastMilliseconds = milliseconds
            for i in randomness.indices { randomness[i] = UInt8.random(in: .min ... .max) }
        } else {
            for i in randomness.indices.reversed() { randomness[i] &+= 1; if randomness[i] != 0 { break } }
        }
        var bytes = [UInt8](repeating: 0, count: 16)
        for i in 0..<6 { bytes[5 - i] = UInt8((lastMilliseconds >> UInt64(i * 8)) & 0xff) }
        bytes.replaceSubrange(6..<16, with: randomness)
        var output = "", buffer: UInt32 = 0, bits = 2
        for byte in bytes {
            buffer = (buffer << 8) | UInt32(byte); bits += 8
            while bits >= 5 {
                bits -= 5; output.append(Self.alphabet[Int((buffer >> UInt32(bits)) & 31)])
                buffer &= bits == 0 ? 0 : (1 << UInt32(bits)) - 1
            }
        }
        return output
    }
}

public protocol HistorySink: Sendable { func append(_ entry: HistoryEntry) async }

struct HistoryRecord: Codable, Sendable {
    let id, ts, engine: String
    let ms, audio_duration_ms: Int?
    let raw, clean: String
    let enhanced: String?
    let delivered: Bool
    let delivery_method, delivery_error, app_name, app_bundle_id, audio: String?
    var audio_retained: Bool?
    let pre_dictionary: String?
}

public struct HistoryReconcileResult: Sendable, Equatable {
    public let month: String
    public let removedIDs: [String]
    public var removedCount: Int { removedIDs.count }
}

public struct HistoryListItem: Sendable, Equatable {
    public let id, timestamp, engine: String
    public let application: String?
    public var shortID: String { String(id.prefix(8)) }
    public var line: String {
        var fields = [String(timestamp.replacingOccurrences(of: "T", with: " ").prefix(16)), engine]
        if let application, !application.isEmpty { fields.append(application) }
        fields.append(shortID)
        return fields.joined(separator: " · ")
    }
}

public enum HistoryStoreError: Error, LocalizedError {
    case entryNotFound(String), ambiguousEntry(String)
    public var errorDescription: String? {
        switch self {
        case .entryNotFound(let value): return "history entry not found: \(value)"
        case .ambiguousEntry(let value): return "history entry is ambiguous: \(value)"
        }
    }
}

/// Result of a configured export: the months rendered and the `YYYY-MM.md` notes left untouched
/// because a same-named file exists that Rhemion didn't write (spec 4.5 — shown in the export status).
public struct ExportOutcome: Sendable, Equatable {
    public var months: [String] = []
    public var skipped: [String] = []
    public init(months: [String] = [], skipped: [String] = []) { self.months = months; self.skipped = skipped }
}

private actor HistoryRenderer {
    func append(_ record: HistoryRecord, month: String, stateDirectory: URL,
                historyDirectory: URL, calendar: Calendar) {
        // Re-adopt exact-match vault notes BEFORE the log changes (reconcile may drop records, the append
        // adds one): afterwards the current month's old note can't match a render and would stay foreign.
        if let directory = initializedVaultDirectory(stateDirectory: stateDirectory, historyDirectory: historyDirectory) {
            do { try ExportNote.readopt(directory: directory, state: stateDirectory,
                     registryURL: stateDirectory.appendingPathComponent(ExportRegistry.fileName), calendar: calendar) }
            catch { HistoryStore.log("export adoption failed: \(error)") }
        }
        do {
            _ = try HistoryStore.reconcileMonth(month, stateDirectory: stateDirectory,
                                                historyDirectory: historyDirectory, calendar: calendar,
                                                render: false)
            try HistoryStore.appendRecord(record, month: month, stateDirectory: stateDirectory)
            _ = try HistoryStore.renderMonth(month, stateDirectory: stateDirectory,
                                             historyDirectory: historyDirectory, calendar: calendar)
            do {
                _ = try exportConfigured(automatic: true, month: month, stateDirectory: stateDirectory,
                                         historyDirectory: historyDirectory, calendar: calendar)
            } catch { HistoryStore.log("transcript export failed: \(error)") }
        } catch { HistoryStore.log("history append failed: \(error)") }
    }

    func export(month: String?, exportDir: URL, stateDirectory: URL, historyDirectory: URL,
                calendar: Calendar) throws -> [String] {
        let directory = try TranscriptExport.directory(exportDir.path, state: stateDirectory, history: historyDirectory)
        return try TranscriptExport.write(month: month, directory: directory, state: stateDirectory, calendar: calendar)
    }

    func exportConfigured(automatic: Bool, month: String?, stateDirectory: URL,
                          historyDirectory: URL, calendar: Calendar) throws -> ExportOutcome {
        let settingsURL = stateDirectory.appendingPathComponent("active/settings.json")
        guard FileManager.default.fileExists(atPath: settingsURL.path) else {
            if automatic { return ExportOutcome() }
            throw TranscriptExport.Failure(message: "Export folder is not configured.")
        }
        let data = try Data(contentsOf: settingsURL)
        guard var settings = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw TranscriptExport.Failure(message: "Invalid settings file.")
        }
        if automatic && (settings["export_mode"] as? String ?? "auto") != "auto" { return ExportOutcome() }
        guard let path = settings["export_dir"] as? String, !path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            if automatic { return ExportOutcome() }
            throw TranscriptExport.Failure(message: "Export folder is not configured.")
        }
        let directory = try TranscriptExport.directory(path, state: stateDirectory, history: historyDirectory)
        let initialized = settings["export_initialized"] as? Bool == true
        // Prepare every month FIRST — bodies() strictly decodes each record, so an unreadable/corrupt
        // source log throws here, BEFORE anything in the export folder is touched.
        let bodies = try TranscriptExport.bodies(month: initialized ? month : nil, state: stateDirectory, calendar: calendar)
        if !initialized {
            // First export: just write our notes (the folder is never cleared — foreign files are
            // protected by the ownership registry). Flag kept for settings compatibility.
            let lock = open(settingsURL.path + ".lock", O_CREAT | O_RDWR, 0o600)
            guard lock >= 0 else { throw POSIXError(.EIO) }
            defer { close(lock) }
            guard flock(lock, LOCK_EX) == 0 else { throw POSIXError(.EIO) }
            defer { flock(lock, LOCK_UN) }
            settings = try JSONSerialization.jsonObject(with: Data(contentsOf: settingsURL)) as? [String: Any] ?? [:]
            if settings["export_dir"] as? String == path {
                settings["export_initialized"] = true
                try JSONSerialization.data(withJSONObject: settings, options: [.prettyPrinted, .sortedKeys])
                    .write(to: settingsURL, options: .atomic)
            }
        }
        let registryURL = stateDirectory.appendingPathComponent(ExportRegistry.fileName)
        try ExportNote.readopt(directory: directory, state: stateDirectory,
                                                   registryURL: registryURL, calendar: calendar)
        let skipped = try TranscriptExport.write(bodies, directory: directory, registryURL: registryURL)
        return ExportOutcome(months: bodies.map(\.0), skipped: skipped)
    }

    func reconcile(month: String, stateDirectory: URL, historyDirectory: URL,
                   calendar: Calendar) -> HistoryReconcileResult? {
        // sync CLI / startup / regenerate go through here -> also GC record-less orphan audio.
        do { return try HistoryStore.reconcileMonth(month, stateDirectory: stateDirectory,
                                                    historyDirectory: historyDirectory, calendar: calendar,
                                                    collectOrphanAudio: true) }
        catch { HistoryStore.log("history reconcile failed for \(month): \(error)"); return nil }
    }

    // Keep the complete batch on the same executor as append/reconcile, with no suspension
    // between reading a month and writing its survivors.
    func delete(ids: Set<String>, stateDirectory: URL, historyDirectory: URL,
                calendar: Calendar) -> [HistoryReconcileResult] {
        guard !ids.isEmpty else { return [] }
        // Re-adopt exact-match vault notes BEFORE the log changes: afterwards their bytes can no longer
        // match a render of the current log, and the note would stay foreign (never pruned).
        if let directory = initializedVaultDirectory(stateDirectory: stateDirectory, historyDirectory: historyDirectory) {
            do { try ExportNote.readopt(directory: directory, state: stateDirectory,
                     registryURL: stateDirectory.appendingPathComponent(ExportRegistry.fileName), calendar: calendar) }
            catch { HistoryStore.log("export adoption failed: \(error)") }
        }
        var results: [HistoryReconcileResult] = []
        for month in HistoryStore.availableMonths(stateDirectory: stateDirectory, historyDirectory: historyDirectory) {
            do {
                let records = try HistoryStore.readRecords(month: month, stateDirectory: stateDirectory)
                let dropped = try HistoryStore.removeRecords(ids: ids, allRecords: records, month: month,
                                                             stateDirectory: stateDirectory, historyDirectory: historyDirectory)
                guard !dropped.isEmpty else { continue }
                // Report the deletion BEFORE the (secondary) re-render so an export/render failure never
                // hides that the records + audio are already gone — a stale .md is fixed by reconcile.
                results.append(HistoryReconcileResult(month: month, removedIDs: dropped))
                do { _ = try HistoryStore.renderMonth(month, stateDirectory: stateDirectory,
                                                      historyDirectory: historyDirectory, calendar: calendar) }
                catch { HistoryStore.log("render after delete failed for \(month): \(error)") }
                // Keep the exported vault note consistent with the journal: prune this month's line(s),
                // or remove the month file when it is now empty. On-actor (no wipe, no mode gate).
                syncVaultAfterMutation(month: month, stateDirectory: stateDirectory,
                                       historyDirectory: historyDirectory, calendar: calendar)
            } catch { HistoryStore.log("history delete failed for \(month): \(error)") }
        }
        return results
    }

    /// Re-write (or remove, when empty) one month's exported transcript note to match the log after a
    /// deletion/expiry — but ONLY when the vault is already configured and initialized. Never wipes and
    /// never runs first-time initialization; a pre-init vault has nothing to keep in sync.
    private func syncVaultAfterMutation(month: String, stateDirectory: URL, historyDirectory: URL, calendar: Calendar) {
        guard let directory = initializedVaultDirectory(stateDirectory: stateDirectory, historyDirectory: historyDirectory)
        else { return }
        do {
            // Emptiness is judged from RAW log lines, not decoded records: readRecords drops undecodable
            // rows, so a month that still holds a corrupt/future-schema line would look empty and its
            // note would be wrongly deleted. When lines remain, TranscriptExport.write strictly decodes
            // and THROWS on a corrupt one — caught below — leaving the existing note untouched rather
            // than replacing a good export with a partial/empty one.
            if try HistoryStore.monthLogHasLines(month, stateDirectory: stateDirectory) {
                _ = try TranscriptExport.write(month: month, directory: directory, state: stateDirectory, calendar: calendar)
            } else {
                _ = try TranscriptExport.removeOwned(month: month, directory: directory,
                                                     registryURL: stateDirectory.appendingPathComponent(ExportRegistry.fileName))
            }
        } catch { HistoryStore.log("vault sync after mutation failed for \(month): \(error)") }
    }

    /// The configured export folder, only once export has been initialized (nil otherwise).
    private func initializedVaultDirectory(stateDirectory: URL, historyDirectory: URL) -> URL? {
        let settingsURL = stateDirectory.appendingPathComponent("active/settings.json")
        guard let data = try? Data(contentsOf: settingsURL),
              let settings = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              settings["export_initialized"] as? Bool == true,
              let path = settings["export_dir"] as? String else { return nil }
        return try? TranscriptExport.directory(path, state: stateDirectory, history: historyDirectory)
    }

    /// Delete expired local WAVs on the actor (serialized with append/delete/export). The file work
    /// lives in HistoryRetention (pure, testable); running it here keeps the JSONL rewrite it does out
    /// of any race with a live append.
    func expireAudio(before cutoff: Date, excludingIDs: Set<String>, stateDirectory: URL,
                     historyDirectory: URL, calendar: Calendar) -> Set<String> {
        // The exported vault note is transcript-only, so removing a WAV never changes it — no vault sync.
        do {
            return try HistoryRetention.runAudioExpiry(historyDirectory: historyDirectory, stateDirectory: stateDirectory,
                                                       before: cutoff, excludingIDs: excludingIDs, now: Date(), calendar: calendar)
        } catch { HistoryStore.log("audio expiry failed: \(error)"); return [] }
    }

    func delete(query: String, stateDirectory: URL, historyDirectory: URL,
                calendar: Calendar) throws -> HistoryReconcileResult {
        try HistoryStore.deleteEntry(query, stateDirectory: stateDirectory,
                                     historyDirectory: historyDirectory, calendar: calendar)
    }
}

public actor HistoryStore: HistorySink {
    private let resolveHistoryDirectory: @Sendable () -> URL
    private let resolveStateDirectory: @Sendable () -> URL
    private let calendar: Calendar
    private let renderer = HistoryRenderer()

    public init(historyDirectory: @escaping @Sendable () -> URL = { RuntimePaths.historyDirectory() },
                stateDirectory: @escaping @Sendable () -> URL = { RuntimePaths.stateDirectory() },
                calendar: Calendar = .current) {
        self.resolveHistoryDirectory = historyDirectory; self.resolveStateDirectory = stateDirectory
        self.calendar = calendar
    }
    public init(historyDirectory: URL, stateDirectory: URL, calendar: Calendar = .current) {
        self.resolveHistoryDirectory = { historyDirectory }; self.resolveStateDirectory = { stateDirectory }
        self.calendar = calendar
    }

    public func append(_ entry: HistoryEntry) async {
        await renderer.append(Self.record(entry), month: Self.month(entry.createdAt, calendar: calendar),
                              stateDirectory: resolveStateDirectory(), historyDirectory: resolveHistoryDirectory(),
                              calendar: calendar)
    }

    @discardableResult public func exportMonth(_ month: String, exportDir: URL) async throws -> [String] {
        try await renderer.export(month: month, exportDir: exportDir, stateDirectory: resolveStateDirectory(),
                                  historyDirectory: resolveHistoryDirectory(), calendar: calendar)
    }

    @discardableResult public func exportAll(exportDir: URL) async throws -> [String] {
        try await renderer.export(month: nil, exportDir: exportDir, stateDirectory: resolveStateDirectory(),
                                  historyDirectory: resolveHistoryDirectory(), calendar: calendar)
    }

    public func exportNow() async throws -> [String] { try await exportNowReporting().months }

    /// Manual/scheduled export with its status: the months exported and the notes skipped as foreign.
    public func exportNowReporting() async throws -> ExportOutcome {
        try await renderer.exportConfigured(automatic: false, month: nil, stateDirectory: resolveStateDirectory(),
                                            historyDirectory: resolveHistoryDirectory(), calendar: calendar)
    }

    @discardableResult public func regenerate(month: String) async -> Bool { await reconcile(month: month) != nil }

    @discardableResult public func reconcile(month: String) async -> HistoryReconcileResult? {
        await renderer.reconcile(month: month, stateDirectory: resolveStateDirectory(),
                                 historyDirectory: resolveHistoryDirectory(), calendar: calendar)
    }

    public func reconcileAll() async -> [HistoryReconcileResult] {
        let months = Self.availableMonths(stateDirectory: resolveStateDirectory(), historyDirectory: resolveHistoryDirectory())
        var results: [HistoryReconcileResult] = []
        for month in months { if let result = await reconcile(month: month) { results.append(result) } }
        return results
    }

    /// Exact, case-sensitive IDs only. Returns months whose record/audio/export deletion completed;
    /// failed months are logged and omitted so callers can report an incomplete batch.
    public func deleteEntries(ids: Set<String>) async -> [HistoryReconcileResult] {
        await renderer.delete(ids: ids, stateDirectory: resolveStateDirectory(),
                              historyDirectory: resolveHistoryDirectory(), calendar: calendar)
    }

    public func deleteEntry(matching query: String) async throws -> HistoryReconcileResult {
        try await renderer.delete(query: query, stateDirectory: resolveStateDirectory(),
                                  historyDirectory: resolveHistoryDirectory(), calendar: calendar)
    }

    /// Audio-only retention: delete WAVs older than `cutoff`, keeping the transcript. Runs on the same
    /// actor as append/delete so its JSONL rewrite can't race a live append. `excludingIDs` are entries
    /// transcript-expiry is deleting this pass (their audio belongs to that path). Returns the months changed.
    @discardableResult public func expireAudio(before cutoff: Date, excludingIDs: Set<String> = []) async -> Set<String> {
        await renderer.expireAudio(before: cutoff, excludingIDs: excludingIDs, stateDirectory: resolveStateDirectory(),
                                   historyDirectory: resolveHistoryDirectory(), calendar: calendar)
    }

    public func list(month: String? = nil, limit: Int = 20) -> [HistoryListItem] {
        let months = month.map { [$0] } ?? Self.availableMonths(stateDirectory: resolveStateDirectory(), historyDirectory: resolveHistoryDirectory())
        return months.flatMap { (try? Self.readRecords(month: $0, stateDirectory: resolveStateDirectory())) ?? [] }
            .sorted { $0.ts > $1.ts }.prefix(max(0, limit)).map {
                HistoryListItem(id: $0.id, timestamp: $0.ts, engine: $0.engine, application: $0.app_name)
            }
    }

    /// The newest non-empty `pre_dictionary` across the monthly logs, scanning months newest-first
    /// and, within a month, entries newest-first.
    public func lastPreDictionary() -> String? {
        let stateDirectory = resolveStateDirectory(), historyDirectory = resolveHistoryDirectory()
        for month in Self.availableMonths(stateDirectory: stateDirectory, historyDirectory: historyDirectory) {
            guard let records = try? Self.readRecords(month: month, stateDirectory: stateDirectory) else { continue }
            for record in records.reversed() {
                if let value = record.pre_dictionary, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    return value
                }
            }
        }
        return nil
    }

    public static func renderMonth(_ month: String, stateDirectory: URL, historyDirectory: URL,
                                   calendar: Calendar = .current, generatedAt: Date = Date()) throws -> Bool {
        let records = try readRecords(month: month, stateDirectory: stateDirectory)
        let monthDirectory = historyDirectory.appendingPathComponent(month, isDirectory: true)
        let target = monthDirectory.appendingPathComponent("\(month).md")
        let body = renderBody(records, month: month, monthDirectory: monthDirectory, calendar: calendar)
        try FileManager.default.createDirectory(at: historyDirectory, withIntermediateDirectories: true)
        let readme = historyDirectory.appendingPathComponent("README.md")
        if !FileManager.default.fileExists(atPath: readme.path) {
            try? Data("# Rhemion History\n\nMonthly dictation transcripts and retained audio.\n".utf8).write(to: readme, options: .withoutOverwriting)
        }
        try FileManager.default.createDirectory(at: monthDirectory, withIntermediateDirectories: true)
        let temporary = monthDirectory.appendingPathComponent(".\(month).\(UUID().uuidString).tmp")
        do {
            try Data(body.utf8).write(to: temporary)
            let handle = try FileHandle(forWritingTo: temporary); try handle.synchronize(); try handle.close()
            guard Darwin.rename(temporary.path, target.path) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        } catch { try? FileManager.default.removeItem(at: temporary); throw error }
        return true
    }

    /// One render for the runtime and the app (`HistoryNote.renderBody`, RhemionStorage).
    static func renderBody(_ records: [HistoryRecord], month: String, monthDirectory: URL,
                           calendar: Calendar = .current) -> String {
        HistoryNote.renderBody(records.map { HistoryNote.Entry(id: $0.id, ts: $0.ts, engine: $0.engine, text: $0.enhanced ?? $0.clean,
                                                               app: $0.app_name, audio: $0.audio, audioRetained: $0.audio_retained) },
                               month: month, monthDirectory: monthDirectory, calendar: calendar)
    }

    static func reconcileMonth(_ month: String, stateDirectory: URL, historyDirectory: URL,
                               calendar: Calendar = .current, render: Bool = true,
                               collectOrphanAudio: Bool = false) throws -> HistoryReconcileResult {
        let fm = FileManager.default, monthDirectory = historyDirectory.appendingPathComponent(month, isDirectory: true)
        let note = monthDirectory.appendingPathComponent("\(month).md"), noteExists = fm.fileExists(atPath: note.path)
        let noteIDs: Set<String> = noteExists ? idsInNote(try String(contentsOf: note, encoding: .utf8)) : []
        let audioDirectory = monthDirectory.appendingPathComponent("Audio", isDirectory: true)
        let audioNames = fm.fileExists(atPath: audioDirectory.path)
            ? try fm.contentsOfDirectory(atPath: audioDirectory.path) : []
        let audioIDs = Set(audioNames.compactMap(idInAudioName))
        let records = try readRecords(month: month, stateDirectory: stateDirectory)
        var removed: [HistoryRecord] = [], survivors: [HistoryRecord] = []
        for record in records {
            let missingFromNote = noteExists && !containsEntryID(noteIDs, id: record.id)
            let missingAudio = record.audio_retained != false && !audioIDs.contains(record.id.uppercased())
            if missingFromNote || missingAudio { removed.append(record) } else { survivors.append(record) }
        }
        if !removed.isEmpty {
            _ = try removeRecords(ids: Set(removed.map(\.id)), allRecords: records, month: month,
                                  stateDirectory: stateDirectory, historyDirectory: historyDirectory)
        }
        // Garbage-collect audio files with no source record at all (e.g. a wav finalized by a take
        // that never got journalled, or leftovers from schema churn). Only on safe, non-append
        // triggers (sync/startup) — the append path passes false, because the take's wav is on disk
        // before its record is appended. An age guard additionally spares any very recent (in-flight)
        // wav regardless of caller.
        if collectOrphanAudio {
            let keepIDs = Set(survivors.map { $0.id.uppercased() })
            for name in audioNames {
                guard let id = idInAudioName(name), !keepIDs.contains(id) else { continue }
                let url = audioDirectory.appendingPathComponent(name)
                if let mtime = (try? fm.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date,
                   Date().timeIntervalSince(mtime) < 30 { continue }
                if fm.fileExists(atPath: url.path) { try? fm.removeItem(at: url) }
            }
        }
        if render { _ = try renderMonth(month, stateDirectory: stateDirectory, historyDirectory: historyDirectory, calendar: calendar) }
        return HistoryReconcileResult(month: month, removedIDs: removed.map(\.id))
    }

    static func deleteEntry(_ query: String, stateDirectory: URL, historyDirectory: URL,
                            calendar: Calendar = .current) throws -> HistoryReconcileResult {
        let normalized = query.uppercased()
        var matches: [(String, HistoryRecord)] = []
        for month in availableMonths(stateDirectory: stateDirectory, historyDirectory: historyDirectory) {
            for record in try readRecords(month: month, stateDirectory: stateDirectory) {
                if record.id.uppercased().hasPrefix(normalized) || String(record.ts.prefix(16)) == query { matches.append((month, record)) }
            }
        }
        guard !matches.isEmpty else { throw HistoryStoreError.entryNotFound(query) }
        guard matches.count == 1, let match = matches.first else { throw HistoryStoreError.ambiguousEntry(query) }
        _ = try removeRecords(ids: [match.1.id], allRecords: readRecords(month: match.0, stateDirectory: stateDirectory),
                              month: match.0, stateDirectory: stateDirectory, historyDirectory: historyDirectory)
        _ = try renderMonth(match.0, stateDirectory: stateDirectory, historyDirectory: historyDirectory, calendar: calendar)
        return HistoryReconcileResult(month: match.0, removedIDs: [match.1.id])
    }

    /// Shared deletion primitive for reconciliation, CLI single deletion and IPC batches. Exact,
    /// case-sensitive IDs. Returns the IDs actually dropped from the log.
    ///
    /// Two data-safety guarantees:
    ///  - the log is rewritten line-by-line from the RAW bytes, dropping only exact-ID matches, so a
    ///    neighbouring undecodable / future-schema line (and unknown fields on kept records) survives
    ///    verbatim — decode-filter-reencode would have destroyed them;
    ///  - a WAV is deleted only when it is OWNED by a removed ID (its `…--<ID>.wav` name resolves to a
    ///    removed ID) and is NOT referenced by any surviving record — a stray `audio` field on a
    ///    removed record can never take out another entry's audio.
    @discardableResult
    static func removeRecords(ids requestedIDs: Set<String>, allRecords records: [HistoryRecord], month: String,
                              stateDirectory: URL, historyDirectory: URL) throws -> [String] {
        let removedUpper = Set(requestedIDs.map { $0.uppercased() })
        let survivors = records.filter { !requestedIDs.contains($0.id) }
        let survivorAudio = Set(survivors.compactMap { $0.audio.map { URL(fileURLWithPath: $0).lastPathComponent } })
        let audioDirectory = historyDirectory.appendingPathComponent("\(month)/Audio", isDirectory: true)
        let fm = FileManager.default
        let audioNames = fm.fileExists(atPath: audioDirectory.path)
            ? try fm.contentsOfDirectory(atPath: audioDirectory.path) : []
        var candidates = Set<String>()
        for name in audioNames where idInAudioName(name).map(removedUpper.contains) == true { candidates.insert(name) }
        for record in records where requestedIDs.contains(record.id) {
            guard let name = record.audio.map({ URL(fileURLWithPath: $0).lastPathComponent }) else { continue }
            if let owner = idInAudioName(name), !removedUpper.contains(owner) { continue }   // owned by another entry → never touch
            candidates.insert(name)
        }
        for name in candidates where !survivorAudio.contains(name) {
            let url = audioDirectory.appendingPathComponent(name)
            if fm.fileExists(atPath: url.path) { try fm.removeItem(at: url) }
        }
        return try rewriteLog(removingIDs: requestedIDs, month: month, stateDirectory: stateDirectory)
    }

    /// Rewrite the month's JSONL preserving every non-removed line's RAW bytes (undecodable lines and
    /// unknown fields survive). Drops only lines whose exact `id` is in `ids`; returns the dropped IDs.
    @discardableResult
    static func rewriteLog(removingIDs ids: Set<String>, month: String, stateDirectory: URL) throws -> [String] {
        let directory = stateDirectory.appendingPathComponent("log", isDirectory: true)
        let url = directory.appendingPathComponent("dictate-\(month).jsonl")
        guard let data = try? Data(contentsOf: url) else { return [] }
        var out = Data(); var dropped: [String] = []
        for line in data.split(separator: 0x0a, omittingEmptySubsequences: true) {
            let id = ((try? JSONSerialization.jsonObject(with: Data(line))) as? [String: Any])?["id"] as? String
            if let id, ids.contains(id) { dropped.append(id); continue }
            out.append(contentsOf: line); out.append(0x0a)   // keep verbatim
        }
        guard !dropped.isEmpty else { return [] }   // nothing matched → leave the file untouched
        let temporary = directory.appendingPathComponent(".dictate-\(month).\(UUID().uuidString).tmp")
        do {
            try out.write(to: temporary)
            let handle = try FileHandle(forWritingTo: temporary); try handle.synchronize(); try handle.close()
            guard Darwin.rename(temporary.path, url.path) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        } catch { try? FileManager.default.removeItem(at: temporary); throw error }
        return dropped
    }

    /// Flip `audio_retained` to false on the rows whose audio file is in `names` (raw-line rewrite;
    /// shared with the app's Clear Data › Recordings — `HistoryNote.markAudioNotRetained`).
    static func markAudioNotRetained(names: Set<String>, month: String, stateDirectory: URL) throws {
        try HistoryNote.markAudioNotRetained(names: names, month: month, state: stateDirectory)
    }

    static func appendRecord(_ record: HistoryRecord, month: String, stateDirectory: URL) throws {
        let directory = stateDirectory.appendingPathComponent("log", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("dictate-\(month).jsonl")
        var data = try JSONEncoder().encode(record); data.append(0x0a)
        // Owner-only (0600): this JSONL holds raw/clean/enhanced transcript text. Explicit as
        // defense-in-depth on top of the runtime's 0077 umask.
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil,
                                           attributes: [.posixPermissions: 0o600])
        }
        let handle = try FileHandle(forWritingTo: url); defer { try? handle.close() }
        try handle.seekToEnd(); try handle.write(contentsOf: data); try handle.synchronize()
    }

    private static func record(_ e: HistoryEntry) -> HistoryRecord {
        HistoryRecord(id: e.id, ts: timestamp(e.createdAt), engine: e.engine, ms: e.processingDurationMS,
                      audio_duration_ms: e.audioDurationMS, raw: e.raw, clean: e.clean, enhanced: e.enhanced,
                      delivered: e.delivered, delivery_method: e.deliveryMethod, delivery_error: e.deliveryError,
                      app_name: e.application?.name,
                      app_bundle_id: e.application?.bundleID, audio: e.audio.map { URL(fileURLWithPath: $0).lastPathComponent },
                      audio_retained: e.audioRetained, pre_dictionary: e.preDictionary)
    }

    static func readRecords(month: String, stateDirectory: URL) throws -> [HistoryRecord] {
        let url = stateDirectory.appendingPathComponent("log/dictate-\(month).jsonl")
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        return text.split(separator: "\n").compactMap { try? JSONDecoder().decode(HistoryRecord.self, from: Data($0.utf8)) }
    }

    /// Whether the month's log holds any non-empty line — a decode-free emptiness check so a month
    /// still carrying an undecodable row is never mistaken for empty (see syncVaultAfterMutation). A
    /// MISSING log means genuinely empty; a READ FAILURE throws (so the caller preserves the note
    /// instead of deleting it on a transient IO/permission error).
    static func monthLogHasLines(_ month: String, stateDirectory: URL) throws -> Bool {
        let url = stateDirectory.appendingPathComponent("log/dictate-\(month).jsonl")
        guard FileManager.default.fileExists(atPath: url.path) else { return false }
        let data = try Data(contentsOf: url)
        return !data.split(separator: 0x0a, omittingEmptySubsequences: true).isEmpty
    }

    static func writeRecords(_ records: [HistoryRecord], month: String, stateDirectory: URL) throws {
        let directory = stateDirectory.appendingPathComponent("log", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let target = directory.appendingPathComponent("dictate-\(month).jsonl")
        let temporary = directory.appendingPathComponent(".dictate-\(month).\(UUID().uuidString).tmp")
        var data = Data(); for record in records { data.append(try JSONEncoder().encode(record)); data.append(0x0a) }
        do {
            try data.write(to: temporary)
            let handle = try FileHandle(forWritingTo: temporary); try handle.synchronize(); try handle.close()
            guard Darwin.rename(temporary.path, target.path) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        } catch { try? FileManager.default.removeItem(at: temporary); throw error }
    }

    static func availableMonths(stateDirectory: URL, historyDirectory: URL) -> [String] {
        let log = stateDirectory.appendingPathComponent("log", isDirectory: true)
        let logMonths = ((try? FileManager.default.contentsOfDirectory(atPath: log.path)) ?? []).compactMap { name -> String? in
            guard name.hasPrefix("dictate-"), name.hasSuffix(".jsonl") else { return nil }
            return String(name.dropFirst(8).dropLast(6))
        }
        let vaultMonths = (try? FileManager.default.contentsOfDirectory(atPath: historyDirectory.path)) ?? []
        return Array(Set(logMonths + vaultMonths)).filter(isMonth).sorted(by: >)
    }

    private static func idsInNote(_ text: String) -> Set<String> {
        let pattern = #"(?:--([0-9A-HJKMNP-TV-Z]{26})\.wav\]\]|\^rh-([0-9A-HJKMNP-TV-Z]{8,26}))"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return [] }
        let ns = text as NSString; var values = Set<String>()
        for match in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            for index in 1..<match.numberOfRanges where match.range(at: index).location != NSNotFound {
                values.insert(ns.substring(with: match.range(at: index)).uppercased())
            }
        }
        return values
    }

    private static func containsEntryID(_ ids: Set<String>, id: String) -> Bool {
        let id = id.uppercased(); return ids.contains(id) || ids.contains { id.hasPrefix($0) }
    }
    private static func idInAudioName(_ name: String) -> String? {
        guard name.lowercased().hasSuffix(".wav"), let separator = name.range(of: "--", options: .backwards) else { return nil }
        let id = String(name[separator.upperBound...].dropLast(4)).uppercased(); return id.count == 26 ? id : nil
    }
    public static func timestamp(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter(); formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        formatter.timeZone = .current; return formatter.string(from: date)
    }
    public static func fileTimestamp(_ date: Date) -> String { timestamp(date).replacingOccurrences(of: ":", with: "-") }
    static func parseTimestamp(_ value: String) -> Date? {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.date(from: value) ?? ISO8601DateFormatter().date(from: value)
    }
    public static func month(_ date: Date, calendar: Calendar = .current) -> String {
        let c = calendar.dateComponents([.year, .month], from: date); return String(format: "%04d-%02d", c.year!, c.month!)
    }
    public static func isMonth(_ value: String) -> Bool { value.range(of: #"^\d{4}-(0[1-9]|1[0-2])$"#, options: .regularExpression) != nil }
    static func shortID(_ id: String) -> String { String(id.prefix(8)).lowercased() }
    static func log(_ message: String) { FileHandle.standardError.write(Data("rhemion-runtime: \(message)\n".utf8)) }
}
