// AppController's storage operations: Clear Data, deleting exported transcripts, Uninstall and the restart
// after a settings reset (moved out of main.swift unchanged).

import AppKit
import Foundation
import RhemionStorage

extension AppController {
    /// "Clear Data" — quiesce (block input, drop an in-flight take/download, stop the
    /// runtime and WAIT), delete the chosen categories (`StorageOperations.clearPlan`, off the main
    /// actor), then resume and stay. The layout is collected AFTER the barrier, so nothing racing in during
    /// quiesce can stale it — and the result's ticks and freed size come from that plan (
    /// `OperationReport.clearedRows` / `freedBytes`, each item measured right before it goes). With Exported
    /// transcripts: exact-match notes are re-adopted first, removed names are forgotten and an emptied
    /// registry goes. Recordings without the Journal mark the months' log rows `audio_retained: false` first
    /// and re-render their notes after (`prepareRecordingsRemoval`). With "Reset all settings":
    /// `settingsWriteSuppressed` flips the instant the barrier clears the defaults domain goes
    /// and fresh settings are written (export settings carried over unless Exported transcripts is chosen
    /// too); the barrier then stays up and the pop-up shows the result — its "Restart Rhemion" performs the
    /// restart (`restartAfterClear()`: no quit mid-progress). A dry run logs "would …" lines and
    /// resumes instead. `progress` names the pop-up row being deleted now: the plan runs row by row
    /// (`StorageOperations.clearSteps`), and a settings reset reports its row before it starts.
    func runClearData(_ selection: Set<ClearItem>,
                      progress: @escaping @MainActor @Sendable (ClearItem, Set<ClearItem>) -> Void = { _, _ in }) async -> OperationReport {
        guard !dataOps.inProgress else { return Self.busyReport() }
        guard await dataOps.quiesce() == .ready else { return Self.stuckReport() }
        destructiveOpRunning = true
        defer { destructiveOpRunning = false }
        let effects = AppPaths.makeEffects()
        let dryRun = effects is DryRunEffects
        let resetSettings = selection.contains(.settings), clearExport = selection.contains(.exportedTranscripts)
        if resetSettings && !dryRun { settingsWriteSuppressed = true }
        let keep = settings
        let layout = AppPaths.storageLayout(settings: keep)
        if clearExport && !dryRun { readoptExports(layout) }
        let steps = StorageOperations.clearSteps(layout, selection)
        let plan = steps.map(\.item)
        let rowOf = Dictionary(steps.map { ($0.item, $0.category) }, uniquingKeysWith: { first, _ in first })
        // Each row as it starts, once, with the rows that have failed so far (hopped to the main queue in order).
        let announce: @Sendable (ClearItem, Set<ClearItem>) -> Void = { c, failed in
            DispatchQueue.main.async { MainActor.assumeIsolated { progress(c, failed) } }
        }
        // Recordings without the Journal: mark the transcripts first, re-render their notes after (no dead
        // audio references, nothing for the runtime's reconcile to drop) — as audio retention does.
        let recordingsOnly = selection.contains(.recordings) && !selection.contains(.journal) && !dryRun
        var report = await Task.detached(priority: .userInitiated) {
            var current: ClearItem?
            var failedRows: Set<ClearItem> = []
            var sizes: [StorageItem: Int64] = [:]
            let willRemove: (StorageItem) -> Void = { item in
                sizes[item] = StorageSizes.size(of: item)   // what this item frees, just before it goes
                guard let c = rowOf[item], c != current else { return }
                current = c; announce(c, failedRows)
            }
            let didRemove: (StorageItem, Bool) -> Void = { item, ok in
                if !ok, let c = rowOf[item] { failedRows.insert(c) }
            }
            var r: OperationReport
            if recordingsOnly {
                let prep = StorageOperations.prepareRecordingsRemoval(plan, layout)
                r = StorageOperations.execute(prep.plan, layout: layout, effects: effects, willRemove: willRemove, didRemove: didRemove)
                r.failures = prep.failures + r.failures + StorageOperations.rerenderHistory(months: prep.months, layout)
            } else {
                r = StorageOperations.execute(plan, layout: layout, effects: effects, willRemove: willRemove, didRemove: didRemove)
            }
            r.freedBytes = r.removedItems.reduce(Int64(0)) { $0 + (sizes[$1] ?? 0) }
            return r
        }.value
        let removed = report.removed   // anything left behind under a folder that couldn't go is named
        report.failures += await Task.detached(priority: .userInitiated) {
            StorageOperations.coveredFailures(layout, selection, removed: removed)
        }.value
        if clearExport && !dryRun {
            do { try StorageOperations.forgetRemovedExports(report.removed, layout: layout, removeIfEmpty: true) }
            catch { report.failures.append("Couldn't update the export record: \(error.localizedDescription)") }
        }
        if !clearExport { report.unconfirmedExport = [] }
        defer {
            Self.logDryRun(effects, "clear data")   // after relaunch() below too, which a dry run only notes
            log("clear data [\(selection.map(\.rawValue).sorted().joined(separator: ","))]: removed \(report.removed.count), failures \(report.failures.count)")
        }
        var settingsWritten = true
        if resetSettings {
            let removedItems = Set(report.removedItems)
            progress(.settings, Set(steps.filter { !removedItems.contains($0.item) }.map(\.category)))
            effects.removeDefaults(domain: "com.sageathor.rhemion.app")
            var fresh = AppSettings()
            if !clearExport {
                fresh.exportDir = keep.exportDir; fresh.exportMode = keep.exportMode
                fresh.exportSchedule = keep.exportSchedule; fresh.exportInitialized = keep.exportInitialized
            }
            if !dryRun && !SettingsStore.save(fresh) {
                settingsWritten = false
                report.failures.append("Couldn't write fresh settings.")
            }
        }
        report.clearedRows = StorageOperations.clearedRows(steps, removed: report.removedItems,
                                                           settingsChosen: resetSettings, settingsWritten: settingsWritten)
        guard resetSettings, !dryRun else {
            // A dry run of a settings reset only notes the relaunch (as before), and every dry run resumes.
            if resetSettings && report.success {
                do { try effects.relaunch(app: Bundle.main.bundleURL, afterPID: getpid()) }
                catch { report.failures.append("Couldn't schedule relaunch: \(error.localizedDescription)") }
            }
            dataOps.resume()
            return report
        }
        // A real settings reset: the barrier stays up (settings are half-way to Welcome); the pop-up shows the
        // result and its "Restart Rhemion" performs the restart (restartAfterClear()).
        return report
    }

    /// Before an export deletion: (re)record every note in the export folder that exactly matches the
    /// current render, so the registry names what is removed. Runs behind the barrier only.
    private func readoptExports(_ layout: StorageLayout) {
        guard let dir = layout.exportDir else { return }
        do { try ExportNote.readopt(directory: dir, state: layout.stateDir, registryURL: layout.registryURL, calendar: layout.calendar) }
        catch { log("export re-adoption failed: \(error)") }
    }

    /// A dry run (`RHEMION_UNINSTALL_DRYRUN=1`) writes every "would …" line it collected to app.log, so a
    /// live dry run of any storage operation can be checked afterwards.
    private static func logDryRun(_ effects: SystemEffects, _ operation: String) {
        guard let dry = effects as? DryRunEffects else { return }
        for line in dry.log { log("\(operation) dry run: \(line)") }
    }

    /// "Delete exported transcripts" (Settings › Journal › Export, and switching export
    /// Off) — the same quiesce barrier, mutual exclusion and busy/stuck handling as the other operations;
    /// removes ONLY the registry-owned files in the current export folder (never the folder), then
    /// resumes. Files Rhemion can't confirm as its own come back in `unconfirmedExport` for the sheet.
    /// `turnOff` (the "Turn off export?" → Delete path): export_mode becomes "off" and is persisted BEFORE
    /// the runtime resumes, so a resumed runtime never exports into the folder that was just cleaned.
    /// The removed names are dropped from the registry (not in a dry run, which removed nothing).
    func runDeleteExport(turnOff: Bool) async -> OperationReport {
        guard !dataOps.inProgress else { return Self.busyReport() }
        guard await dataOps.quiesce() == .ready else { return Self.stuckReport() }
        destructiveOpRunning = true
        defer { destructiveOpRunning = false }
        let layout = AppPaths.storageLayout(settings: settings)
        let effects = AppPaths.makeEffects()
        if !(effects is DryRunEffects) { readoptExports(layout) }
        var report = StorageOperations.execute(StorageOperations.deleteExportPlan(layout), layout: layout, effects: effects)
        if !(effects is DryRunEffects) {
            do { try StorageOperations.forgetRemovedExports(report.removed, layout: layout) }
            catch { report.failures.append("Couldn't update the export record: \(error.localizedDescription)") }
        }
        if turnOff {
            settings.exportMode = "off"
            if !settingsWriteSuppressed, !SettingsStore.save(settings) { log("settings: WARN save failed (export off)") }
        }
        Self.logDryRun(effects, "delete export")
        log("delete export: removed \(report.removed.count), failures \(report.failures.count), unconfirmed \(report.unconfirmedExport.count)")
        dataOps.resume()
        return report
    }

    /// The barrier never returning `.ready` (the runtime survived SIGKILL) is reported through the same
    /// `OperationReport` shape as an ordinary failure — `Self.quiesceStuckMessage` is the exact text the
    /// sheet matches on to show the dedicated "Quit Rhemion" state instead of a failure list.
    private static func stuckReport() -> OperationReport {
        var report = OperationReport()
        report.failures = [quiesceStuckMessage]
        return report
    }

    /// Storage operations are mutually exclusive — a second one refused while the
    /// barrier is up (another operation running, or a real failed settings reset/Uninstall waiting for restart).
    static func busyReport() -> OperationReport {
        var report = OperationReport()
        report.failures = [busyMessage]
        return report
    }

    /// Whether a new storage operation may start now — the sheets and the farewell window check this
    /// before leaving their confirm step.
    var canStartStorageOperation: Bool { !dataOps.inProgress }

    /// The Clear Data pop-up's "Restart Rhemion" after a settings reset (whether it succeeded or not —
    /// the reset never quits by itself, the result is shown first). `settingsWriteSuppressed` is already
    /// `true` and the runtime is left down in the real (non-dry-run) case — this schedules the relaunch
    /// (into Welcome) and quits.
    func restartAfterClear() {
        let effects = AppPaths.makeEffects()
        guard !(effects is DryRunEffects) else {   // a dry run never actually terminates
            log("clear data dry run: would restart Rhemion")
            return
        }
        do { try effects.relaunch(app: Bundle.main.bundleURL, afterPID: getpid()) }
        catch { log("restart after clear data: couldn't schedule relaunch: \(error)") }
        destructiveOpRunning = false   // runClearData has returned (already down); explicit for the exit path
        NSApp.terminate(nil)
    }

    /// "Uninstall Rhemion" — quiesce, unregister the login item, reset the privacy
    /// permissions, remove the chosen data (off the main actor), clear the defaults domain with app data,
    /// then move the app to the Trash. `progress(step)` ticks the farewell window's five steps. Every
    /// effect's failure is collected, never thrown: the window lists them honestly (a failed,
    /// partial uninstall never resumes — the app may already be half-removed; Done quits).
    /// `settingsWriteSuppressed` flips right after the barrier when app data is going —
    /// settings.json is about to be deleted and must not be resurrected by an in-memory save.
    func runUninstall(_ o: UninstallOptions, progress: @escaping @MainActor (Int) -> Void) async -> OperationReport {
        guard !dataOps.inProgress else { return Self.busyReport() }
        progress(0)
        guard await dataOps.quiesce() == .ready else { return Self.stuckReport() }
        destructiveOpRunning = true
        defer { destructiveOpRunning = false }
        let effects = AppPaths.makeEffects()
        let dryRun = effects is DryRunEffects
        if o.appData && !dryRun { settingsWriteSuppressed = true }
        var report = OperationReport()
        report.dryRun = dryRun
        progress(1); do { try await effects.unregisterLoginItem() } catch { report.failures.append("Login item: \(error.localizedDescription)") }
        progress(2); do { try await effects.resetPrivacy() } catch { report.failures.append("Permissions: \(error.localizedDescription)") }
        progress(3)
        let layout = AppPaths.storageLayout(settings: settings)
        if o.export && !dryRun { readoptExports(layout) }
        let plan = StorageOperations.uninstallPlan(layout, o)
        // App data (incl. app.log) is about to go: from here on log() writes to stderr only, so nothing
        // recreates the state folder after the uninstall. A dry run keeps logging to the file.
        if o.appData && !dryRun { AppLog.fileDisabled.value = true }
        // Off the main actor: a large recordings folder must not freeze the window (the steps and logo).
        let data = await Task.detached(priority: .userInitiated) {
            StorageOperations.execute(plan, layout: layout, effects: effects)
        }.value
        report.removed += data.removed; report.removedItems += data.removedItems
        report.failures += data.failures; report.unconfirmedExport = data.unconfirmedExport
        if o.appData { effects.removeDefaults(domain: "com.sageathor.rhemion.app") }
        progress(4)
        do { try await effects.moveAppToTrash(Bundle.main.bundleURL) }
        catch { report.failures.append("Move Rhemion to the Trash yourself: \(error.localizedDescription)") }
        if !dryRun { uninstallEnded = true }   // from here on a quit goes through finishUninstall()
        Self.logDryRun(effects, "uninstall")
        log("uninstall: removed \(report.removed.count), failures \(report.failures.count), unconfirmed export \(report.unconfirmedExport.count)")
        return report
    }

    /// The farewell window's way out once `runUninstall` has returned: quit — except in a dry run, which
    /// never quits and brings the runtime back instead (nothing was actually removed).
    func finishUninstall() {
        destructiveOpRunning = false   // already down (runUninstall has returned); explicit for the exit path
        if AppPaths.makeEffects() is DryRunEffects { dataOps.resume(); return }
        // Real uninstall: leave nothing behind. NSApp.terminate would run applicationWillTerminate (a
        // log line → app.log) and let AppKit persist state into the defaults domain we just cleared, so
        // stop the inputs and the runtime ourselves and exit directly.
        stopInputs()
        supervisor.stop()
        exit(0)
    }
}
