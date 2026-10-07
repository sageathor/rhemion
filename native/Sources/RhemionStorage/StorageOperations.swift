import Foundation

public struct UninstallOptions: Sendable {
    public var models = true, externalModels = false, appData = true, userData = false, export = false
    public init() {}
}
public struct OperationReport: Sendable {
    public var removed: [String] = [], failures: [String] = [], unconfirmedExport: [String] = []
    /// The items behind `removed`, in the same order (the pop-up's report groups them by category).
    public var removedItems: [StorageItem] = []
    /// The run was a dry run (`DryRunEffects`): `removed` lists what WOULD have gone; nothing did.
    public var dryRun = false
    /// Clear Data: the pop-up rows that lost something in the plan that actually ran (`clearedRows`).
    public var clearedRows: Set<StorageOperations.ClearItem> = []
    /// Clear Data: the bytes of the removed items, each measured right before its removal (in a dry
    /// run: what would have been freed).
    public var freedBytes: Int64 = 0
    public var success: Bool { failures.isEmpty }
    public init() {}
}

/// Which items each action may touch (the category rules of the spec live HERE, tested) and how to run them.
public enum StorageOperations {
    // MARK: Clear Data

    /// Clear Data's categories (Settings › Advanced › Storage › Clear Data…).
    public enum ClearItem: String, CaseIterable, Sendable, Hashable {
        case recordings, unusedModels, modelInUse, logs, cache, journal, dictionary, exportedTranscripts, settings
        /// Gone for good (the operation pop-up's confirm step marks these): content, and the model in use (dictation
        /// stops until it's downloaded again). Logs aren't: new ones start on their own.
        public var irreversible: Bool { [.recordings, .modelInUse, .journal, .dictionary, .exportedTranscripts].contains(self) }
    }

    /// What one Clear Data category removes (the spec's category rules live HERE, tested):
    /// - Recordings = the audio only (month `Audio/` folders); transcripts stay.
    /// - Journal = the history: transcripts (logs, rendered notes) + recordings + history from the earlier location.
    /// - Dictionary = dictionary.json.
    /// - Exported transcripts = only the notes the registry (or an exact-match re-adoption) proves are Rhemion's.
    /// - Unused models / Model in use = `StorageLayout.modelItems()` (in use = the runtime's EFFECTIVE model).
    /// - Logs = Rhemion's diagnostic logs (app.log, runtime.log, rotated copies) — never the dictation logs.
    /// - Cache = temporary files + the app's cache + stray marker temps (never logs, never the compiled model,
    ///   which goes with Model in use).
    /// - Reset all settings = settings.json (+ lock), the defaults plist, the saved window state.
    public static func clearItems(_ c: ClearItem, _ l: StorageLayout) -> [StorageItem] {
        switch c {
        case .recordings: return l.items(.recordings)
        case .journal: return [.transcripts, .legacyContent].flatMap(l.items)
        case .dictionary: return l.items(.dictionary)
        case .exportedTranscripts: return l.items(.export)
        case .unusedModels: return l.modelItems().unused
        case .modelInUse: return l.modelItems().inUse + l.compiledModelItems()
        case .logs: return l.logItems()
        case .cache: return l.cacheItems()
        case .settings: return l.settingsItems()
        }
    }

    /// The whole plan for a selection, in category order, without duplicates (`deduplicated`). Journal
    /// always takes the recordings with it.
    public static func clearPlan(_ l: StorageLayout, _ selection: Set<ClearItem>) -> [StorageItem] {
        var chosen = selection
        if chosen.contains(.journal) { chosen.insert(.recordings) }
        return deduplicated(ClearItem.allCases.filter(chosen.contains).flatMap { clearItems($0, l) })
    }

    /// The same items as `clearPlan`, each with the category it is shown under — the Clear Data pop-up's
    /// row — and ordered row by row (category order), so the rows finish one after another. With the Journal,
    /// the recordings belong to the Journal's row (they aren't a row of their own).
    public static func clearSteps(_ l: StorageLayout, _ selection: Set<ClearItem>) -> [(category: ClearItem, item: StorageItem)] {
        var chosen = selection
        if chosen.contains(.journal) { chosen.insert(.recordings) }
        var owner: [StorageItem: ClearItem] = [:]
        for c in ClearItem.allCases where chosen.contains(c) {
            for item in clearItems(c, l) where owner[item] == nil {
                owner[item] = (c == .recordings && chosen.contains(.journal)) ? .journal : c
            }
        }
        let order = Dictionary(uniqueKeysWithValues: ClearItem.allCases.enumerated().map { ($1, $0) })
        let plan = clearPlan(l, selection).map { (category: owner[$0] ?? .cache, item: $0) }
        return plan.enumerated()
            .sorted { (order[$0.element.category]!, $0.offset) < (order[$1.element.category]!, $1.offset) }
            .map(\.element)
    }

    /// The result's ticked rows, from the steps that actually ran (`clearSteps` built behind the
    /// barrier) and what of them was removed: every row with at least one item gone. Settings is ticked only
    /// when it was chosen, every one of its items went and the fresh settings were written
    /// (`settingsWritten`; a dry run writes nothing and passes true) — never by the success of other rows.
    public static func clearedRows(_ steps: [(category: ClearItem, item: StorageItem)], removed: [StorageItem],
                                   settingsChosen: Bool, settingsWritten: Bool) -> Set<ClearItem> {
        let gone = Set(removed)
        var rows = Set(steps.filter { gone.contains($0.item) }.map(\.category))
        rows.remove(.settings)
        if settingsChosen, settingsWritten, steps.allSatisfy({ $0.category != .settings || gone.contains($0.item) }) {
            rows.insert(.settings)
        }
        return rows
    }

    /// Items without duplicates, first wins: one entry reached through two folder spellings
    /// (`StorageLayout.entryPath`) is kept once, and an entry that lies INSIDE another listed folder (by
    /// the same resolved location — e.g. a month's `Audio/` inside a history folder at the earlier location) is dropped, since
    /// removing — and counting — the folder covers it. The plan and the freed total both use this, so no
    /// byte is counted twice.
    public static func deduplicated(_ items: [StorageItem]) -> [StorageItem] {
        let unique = uniqueEntries(items)
        return unique.filter { u in !unique.contains { u.path.hasPrefix($0.path + "/") } }.map(\.item)
    }

    private static func uniqueEntries(_ items: [StorageItem]) -> [(item: StorageItem, path: String)] {
        var seen = Set<String>(), unique: [(item: StorageItem, path: String)] = []
        for item in items {
            let path = StorageLayout.entryPath(item.url)
            if seen.insert(path).inserted { unique.append((item, path)) }
        }
        return unique
    }

    /// The entries `deduplicated` dropped because they lie inside another listed folder, with that folder.
    public static func covered(_ items: [StorageItem]) -> [(inner: StorageItem, outer: StorageItem)] {
        let unique = uniqueEntries(items)
        return unique.compactMap { u in
            unique.first { u.path.hasPrefix($0.path + "/") }.map { (u.item, $0.item) }
        }
    }

    /// After a Clear Data run: a line for every selected entry that was left out of the plan because its
    /// outer folder covered it, when that outer folder could NOT be deleted and the entry is still there —
    /// so a failure never hides what stayed behind.
    public static func coveredFailures(_ l: StorageLayout, _ selection: Set<ClearItem>, removed: [String]) -> [String] {
        var chosen = selection
        if chosen.contains(.journal) { chosen.insert(.recordings) }
        let removedSet = Set(removed)
        return covered(ClearItem.allCases.filter(chosen.contains).flatMap { clearItems($0, l) }).compactMap { pair in
            guard !removedSet.contains(pair.outer.url.path), FileManager.default.fileExists(atPath: pair.inner.url.path) else { return nil }
            return "\(pair.inner.url.path): not deleted — it lies inside \(pair.outer.url.path), which couldn't be deleted"
        }
    }

    /// Counts the operation pop-up's confirm step names: journal entries (non-empty log lines), recording files,
    /// exported transcript files, diagnostic log files.
    public struct ClearCounts: Equatable, Sendable {
        public var entries = 0, recordings = 0, exported = 0, logs = 0
        public init() {}
    }

    public static func clearCounts(_ l: StorageLayout) -> ClearCounts {
        var c = ClearCounts()
        let fm = FileManager.default
        for item in l.items(.transcripts) where item.relative.first == "log" && item.relative.last?.hasPrefix("dictate-") == true {
            if let data = try? Data(contentsOf: item.url) {
                c.entries += data.split(separator: 0x0a, omittingEmptySubsequences: true).count
            }
        }
        for item in l.items(.recordings) {
            c.recordings += ((try? fm.contentsOfDirectory(atPath: item.url.path)) ?? []).filter { !$0.hasPrefix(".") }.count
        }
        c.exported = l.items(.export).count
        c.logs = l.logItems().count
        return c
    }

    /// Clear Data › Recordings WITHOUT the Journal: the transcripts stay, so none may keep pointing at a
    /// recording that's gone — the same bookkeeping as audio retention. Before any audio goes, every row of
    /// each month whose `Audio/` folder is in the plan is marked `audio_retained: false` (else the runtime's
    /// reconcile would drop the transcript). A month that can't be marked keeps its audio: its folder
    /// leaves the plan and a failure line says why. Returns the plan to run and the months to re-render
    /// (`rerenderHistory`) after it ran. Not for a dry run (it writes the logs).
    public struct RecordingsPrep: Sendable {
        public var plan: [StorageItem] = [], months: [String] = [], failures: [String] = []
    }

    public static func prepareRecordingsRemoval(_ plan: [StorageItem], _ l: StorageLayout) -> RecordingsPrep {
        var out = RecordingsPrep()
        let audioFolders = Set(l.items(.recordings).map { StorageLayout.entryPath($0.url) })
        for item in plan {
            guard audioFolders.contains(StorageLayout.entryPath(item.url)), let month = item.relative.first else {
                out.plan.append(item); continue
            }
            do {
                try HistoryNote.markAllAudioNotRetained(month: month, state: l.stateDir)
                out.plan.append(item); out.months.append(month)
            } catch {
                out.failures.append("\(item.url.path): kept — couldn't update the \(month) journal log (\(error.localizedDescription))")
            }
        }
        return out
    }

    /// After Recordings ran: re-render each month's history note from its (marked) log, so no note embeds
    /// a recording that's gone. Returns failure lines.
    public static func rerenderHistory(months: [String], _ l: StorageLayout) -> [String] {
        months.compactMap { month in
            do { try HistoryNote.rerender(month: month, state: l.stateDir, history: l.historyDir, calendar: l.calendar); return nil }
            catch { return "Couldn't update the \(month) journal note: \(error.localizedDescription)" }
        }
    }

    /// "Delete exported transcripts" (Settings › Journal › Export): ONLY the files the registry proves
    /// Rhemion wrote in the current export folder (content unchanged since). Never the folder itself,
    /// never a file Rhemion can't confirm, never the registry (it still names what's Rhemion's).
    public static func deleteExportPlan(_ l: StorageLayout) -> [StorageItem] {
        l.items(.export)
    }

    /// After an export deletion: drop the removed names from the registry, so it no longer claims files
    /// that are gone. Only names directly in the current export folder; no registry file → nothing to do
    /// (never creates one). `removeIfEmpty` (Clear Data with Exported transcripts): a registry that names
    /// no file any more is deleted.
    public static func forgetRemovedExports(_ removed: [String], layout l: StorageLayout, removeIfEmpty: Bool = false) throws {
        guard let dir = l.exportDir, FileManager.default.fileExists(atPath: l.registryURL.path) else { return }
        defer {
            if removeIfEmpty, ExportRegistry.load(from: l.registryURL).isEmpty {
                try? SafeRemover.remove([ExportRegistry.fileName], under: l.stateDir)
            }
        }
        let dirPath = dir.standardizedFileURL.path
        let names = removed.map { URL(fileURLWithPath: $0) }
            .filter { $0.deletingLastPathComponent().standardizedFileURL.path == dirPath }
            .map(\.lastPathComponent)
        guard !names.isEmpty else { return }
        var registry = ExportRegistry.load(from: l.registryURL)
        for name in names { registry.forget(name, in: dir) }
        try registry.save(to: l.registryURL)
    }

    public static func uninstallPlan(_ l: StorageLayout, _ o: UninstallOptions) -> [StorageItem] {
        var out = l.items(.temporary)
        if o.appData { out += l.items(.applicationData) }
        if o.models { out += l.items(.models) + (o.externalModels ? l.items(.externalModels) : []) }
        if o.userData { out += [.transcripts, .dictionary, .recordings, .legacyContent].flatMap(l.items) }
        if o.export { out += l.items(.export) }
        if o.appData && (o.export || l.exportDir == nil) { out += l.items(.exportRegistry) }
        return out
    }

    /// `willRemove` is called before each item is attempted, `didRemove` after it with whether it went
    /// (Clear Data's per-row progress and per-row outcome).
    public static func execute(_ items: [StorageItem], layout l: StorageLayout, effects: SystemEffects,
                               willRemove: (StorageItem) -> Void = { _ in },
                               didRemove: (StorageItem, Bool) -> Void = { _, _ in }) -> OperationReport {
        var report = OperationReport()
        report.dryRun = effects is DryRunEffects
        for item in items {
            willRemove(item)
            guard l.isSafe(item) else {
                report.failures.append("\(item.url.path): refused (outside allowed area)"); didRemove(item, false); continue
            }
            do { try effects.remove(item); report.removed.append(item.url.path); report.removedItems.append(item); didRemove(item, true) }
            catch { report.failures.append("\(error)"); didRemove(item, false) }
        }
        report.unconfirmedExport = l.unconfirmedExportFiles()
        if !(effects is DryRunEffects) {   // tidy up folders that are now empty (never the roots' parents)
            for dir in [l.historyDir, l.stateDir.appendingPathComponent("log"), l.stateDir.appendingPathComponent("active"),
                        l.stateDir, l.dataDir] { HistoryMigration.removeIfEmpty(dir) }
        }
        return report
    }
}
