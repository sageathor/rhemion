import Foundation
import Darwin
import RhemionStorage

/// Independent of the audio/anchor based history renderer and reconciliation.
enum TranscriptExport {
    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    static func directory(_ path: String, state: URL, history: URL) throws -> URL {
        do { return try ExportFolder.validate(path, state: state, history: history) }
        catch let invalid as ExportFolder.Invalid { throw Failure(message: invalid.message) }
    }

    static func bodies(month: String?, state: URL, calendar: Calendar) throws -> [(String, String)] {
        let log = state.appendingPathComponent("log", isDirectory: true)
        let months: [String]
        if let month {
            guard HistoryStore.isMonth(month) else { throw Failure(message: "Invalid export month.") }
            months = [month]
        } else if FileManager.default.fileExists(atPath: log.path) {
            months = try FileManager.default.contentsOfDirectory(atPath: log.path).compactMap { name in
                guard name.hasPrefix("dictate-"), name.hasSuffix(".jsonl") else { return nil }
                let value = String(name.dropFirst(8).dropLast(6))
                return HistoryStore.isMonth(value) ? value : nil
            }.sorted()
        } else { months = [] }
        let decoder = JSONDecoder()
        return try months.map { month in
            let file = log.appendingPathComponent("dictate-\(month).jsonl")
            let text = FileManager.default.fileExists(atPath: file.path) ? try String(contentsOf: file, encoding: .utf8) : ""
            // STRICT: every non-empty line must decode. A corrupt source log throws here (before any
            // clear/write), so a wipe can never replace a good export with an empty one.
            var records: [HistoryRecord] = []
            for (index, line) in text.split(separator: "\n", omittingEmptySubsequences: true).enumerated() {
                do { records.append(try decoder.decode(HistoryRecord.self, from: Data(line.utf8))) }
                catch { throw Failure(message: "Export aborted — unreadable record in dictate-\(month).jsonl (line \(index + 1)). Nothing was changed.") }
            }
            return (month, render(records, month: month, calendar: calendar))
        }
    }

    /// Write month notes atomically, only over files Rhemion owns (ExportRegistry). A same-named file
    /// that isn't ours (user's own, or an edited export) is left untouched and returned as skipped.
    @discardableResult
    static func write(_ bodies: [(String, String)], directory: URL, registryURL: URL) throws -> [String] {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var registry = ExportRegistry.load(from: registryURL)
        var skipped: [String] = []
        for (month, body) in bodies {
            let name = "\(month).md"
            let target = directory.appendingPathComponent(name)
            if let existing = try? Data(contentsOf: target), !registry.owns(name, in: directory, data: existing) {
                skipped.append(name); continue
            }
            let data = Data(body.utf8)
            let temporary = directory.appendingPathComponent(".\(month).\(UUID().uuidString).tmp")
            do {
                try data.write(to: temporary, options: .withoutOverwriting)
                let handle = try FileHandle(forWritingTo: temporary)
                try handle.synchronize(); try handle.close()
                guard Darwin.rename(temporary.path, target.path) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            } catch { try? FileManager.default.removeItem(at: temporary); throw error }
            // Persist ownership immediately, not after the whole loop: if a LATER month's write
            // throws, this month's rename already landed on disk and must not be forgotten — an
            // unsaved record would make it look foreign (and be skipped) on the next export.
            registry.record(name, in: directory, data: data)
            try registry.save(to: registryURL)
        }
        if !skipped.isEmpty { HistoryStore.log("export: skipped \(skipped) — exists and wasn't written by Rhemion") }
        return skipped
    }

    static func write(month: String?, directory: URL, state: URL, calendar: Calendar) throws -> [String] {
        try writeReporting(month: month, directory: directory, state: state, calendar: calendar).months
    }

    /// Like `write(month:…)`, also returning the month notes skipped as foreign (spec 4.5 status).
    static func writeReporting(month: String?, directory: URL, state: URL,
                               calendar: Calendar) throws -> (months: [String], skipped: [String]) {
        let bodies = try bodies(month: month, state: state, calendar: calendar)
        let registryURL = state.appendingPathComponent(ExportRegistry.fileName)
        try ExportNote.readopt(directory: directory, state: state, registryURL: registryURL, calendar: calendar)
        let skipped = try write(bodies, directory: directory, registryURL: registryURL)
        return (bodies.map(\.0), skipped)
    }

    /// Delete one month note only if it is still exactly what Rhemion wrote. Returns whether it was removed.
    static func removeOwned(month: String, directory: URL, registryURL: URL) throws -> Bool {
        let name = "\(month).md"
        var registry = ExportRegistry.load(from: registryURL)
        guard let data = try? Data(contentsOf: directory.appendingPathComponent(name)),
              registry.owns(name, in: directory, data: data) else { return false }
        try SafeRemover.remove([name], under: directory)
        registry.forget(name, in: directory); try registry.save(to: registryURL)
        return true
    }

    /// The note text — one render for the runtime and the app (`ExportNote.render`).
    static func render(_ records: [HistoryRecord], month: String, calendar: Calendar) -> String {
        ExportNote.render(records.map { ExportNote.Line(ts: $0.ts, text: $0.enhanced ?? $0.clean, app: $0.app_name) },
                          month: month, calendar: calendar)
    }
}
