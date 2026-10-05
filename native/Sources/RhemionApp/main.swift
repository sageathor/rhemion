// Rhemion — native menu-bar app. This file is the app shell; the dictation
// pieces plug into AppController as they land: RuntimeSupervisor, RuntimeClient,
// HotkeyTap, Delivery, NotchIndicator, full wiring.
//
// Isolated from any earlier install: own bundle id (com.sageathor.rhemion.app), own state under
// RHEMION_RUNTIME_DIR=~/.local/state/rhemion-v3. It must never touch an earlier version's data.

import AppKit
import AVFoundation
import Foundation
import RhemionIPC
import RhemionStorage

/// A compact, PRIVACY-SAFE label for an event — never the transcript/deliver TEXT (only byte counts),
/// matching the no-content-in-logs rule.
func eventLabel(_ event: Event) -> String {
    switch event {
    case .started(let s): return "started(\(s))"
    case .stopped(let s): return "stopped(\(s))"
    case .transcript(let engine, let ms, let text): return "transcript[\(engine) \(Int(ms))ms \(text.utf8.count)b]"
    case .deliver(let s, let text, _, let pid): return "deliver(\(s) \(text.utf8.count)b pid=\(pid.map(String.init) ?? "-"))"
    case .error(let m): return "error(\(m))"
    case .canceled(let s): return "canceled(\(s))"
    case .exportCompleted(let months, _, let skipped): return "export-completed(\(months.count) skipped=\(skipped.count))"
    case .historyDeleted(_, let removed, _): return "history-deleted(\(removed.count))"
    case .pong: return "pong"
    case .level(let rms): return "level(\(String(format: "%.2f", rms)))"
    case .devices(let models, let mics): return "devices(models=\(models.count) mics=\(mics.count))"
    case .modelDownload(let id, let state, let fraction, _):
        return "model-download(\(id) \(state)\(fraction.map { " \(Int($0 * 100))%" } ?? ""))"
    }
}

/// Delivery statuses that mean the text landed (paste-ambiguous is
/// treated as landed so the indicator doesn't flash an error when the text almost certainly arrived).
func isDeliverySuccess(_ status: String) -> Bool {
    switch status {
    case "inserted-verified", "submitted-unverified", "typed-submitted", "paste-submitted", "paste-ambiguous":
        return true
    default:
        return false
    }
}

/// A tiny lock-guarded value: the delivery closure runs on the socket-read queue and must read the
/// current input method, while the main actor updates it when settings change.
final class Locked<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value
    init(_ value: Value) { stored = value }
    var value: Value {
        get { lock.lock(); defer { lock.unlock() }; return stored }
        set { lock.lock(); stored = newValue; lock.unlock() }
    }
}


/// Where `log()` may write. A real Uninstall that removes app data turns file logging off right before
/// deleting the state folder, so no later line (from any thread) recreates app.log after it is gone.
/// Log hygiene (`LogRotation`, 7 days / 15 MB): enforced at launch, whenever app.log passes its size cap
/// while writing, and at most once a minute from the write path (which also covers runtime.log, written
/// by the runtime through an O_APPEND descriptor — rotated by copy + truncate).
enum AppLog {
    static let fileDisabled = Locked(false)
    /// Mirrors `DataOperations.inProgress`, readable from the hygiene timer's utility queue: while a
    /// storage operation holds the barrier, log hygiene doesn't run — it never races Clear Data's Logs.
    static let hygienePaused = Locked(false)
    static let policy = LogRotation.Policy()
    private static let lock = NSLock()
    private nonisolated(unsafe) static var lastEnforced = Date.distantPast

    /// The whole policy on the state folder's diagnostic logs, now. Nothing once file logging is off (a
    /// real Uninstall is removing the state folder) or while a storage operation holds the barrier.
    static func enforceHygiene() {
        guard !fileDisabled.value, !hygienePaused.value else { return }
        lock.lock(); defer { lock.unlock() }
        enforceLocked(now: Date())
    }

    private nonisolated(unsafe) static var timer: DispatchSourceTimer?

    /// Every 60 s, off the main thread: runtime.log grows without the app writing a line (the runtime
    /// writes it directly), so its cap can't wait for the next app.log line.
    static func startHygieneTimer() {
        lock.lock(); defer { lock.unlock() }
        guard timer == nil else { return }
        let t = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        t.schedule(deadline: .now() + 60, repeating: 60, leeway: .seconds(5))
        t.setEventHandler { enforceHygiene() }
        t.resume()
        timer = t
    }

    private static func enforceLocked(now: Date) {
        guard !hygienePaused.value else { return }   // a storage operation holds the barrier
        lastEnforced = now
        LogRotation.enforce(in: AppPaths.stateDir, policy: policy, copyTruncate: ["runtime.log"], now: now)
    }

    /// Appends one line to app.log (created owner-only), rotating when it's due (`hygiene`). `create: false`
    /// writes only into an app.log that already exists — never creates the state folder or the file: the
    /// open itself has no O_CREAT, so there is no check-then-act window. A failed open is said on
    /// stderr (a missing app.log under `create: false` is the expected case and stays quiet).
    static func append(_ line: String, hygiene: Bool = true, create: Bool = true) {
        lock.lock(); defer { lock.unlock() }
        let path = AppPaths.logURL.path
        if create {
            try? FileManager.default.createDirectory(at: AppPaths.stateDir, withIntermediateDirectories: true,
                                                     attributes: [.posixPermissions: 0o700])
        }
        let fd = create ? open(path, O_WRONLY | O_APPEND | O_CREAT | O_CLOEXEC, 0o600) : open(path, O_WRONLY | O_APPEND | O_CLOEXEC)
        guard fd >= 0 else {
            let err = errno
            if create || err != ENOENT {
                FileHandle.standardError.write(Data("app.log: couldn't open (\(String(cString: strerror(err))))\n".utf8))
            }
            return
        }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        handle.write(Data(line.utf8))
        let size = (try? handle.seekToEnd()) ?? 0
        try? handle.close()
        let now = Date()
        if hygiene, size > UInt64(policy.maxFileBytes) || now.timeIntervalSince(lastEnforced) > 60 { enforceLocked(now: now) }
    }
}

func log(_ message: String) {
    let stamp = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium)
    let line = stamp + "  " + message + "\n"
    FileHandle.standardError.write(Data(line.utf8))
    guard !AppLog.fileDisabled.value else { return }   // stderr only
    AppLog.append(line)
}

@MainActor
final class AppController: NSObject, NSApplicationDelegate {
    static var shared: AppController?
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    let supervisor = RuntimeSupervisor()
    var client: RuntimeClient?
    private var delivery: Delivery?
    var hotkey: HotkeyTap?
    private var indicator: NotchIndicator?
    private var recall: RecallHotkey?
    private var dictAdd: DictAdd?
    private var dictAddPanel: DictAddPanelController?
    private let undoStore = UndoStore()
    private var undoReplace: UndoReplace?
    private var escGesture: EscapeGesture?
    // "The user is actively dictating" — driven by the LOCAL PTT intent (onStart/onStop/abort), NOT by
    // runtime session events, so it can't be clobbered by a late terminal event from an EARLIER,
    // already-processing session, and it flips to false the instant the key is released (before the
    // runtime's `.stopped` round-trips). Read (lock-guarded) from the Esc tap to decide cancel vs erase.
    private let recordingFlag = Locked<Bool>(false)
    /// Mirrors `recordingFlag` for DataOperations' "An active dictation will be discarded" copy.
    var isDictatingNow: Bool { recordingFlag.value }
    /// Clear the "actively dictating" flag without sending a stray `.stop` — `abortRecording()` alone
    /// resets HotkeyTap's own state but never fires `onStop`, so this flag would otherwise stay stuck
    /// `true` forever after a take is discarded. Same pairing as the double-Esc cancel path
    /// (`handleEscapeGesture`). Used by `DataOperations.quiesce()`.
    func clearRecordingFlag() { recordingFlag.value = false }
    /// The quiesce barrier: every destructive storage action (Clear Data, export deletion,
    /// uninstall) starts by calling `dataOps.quiesce()`.
    lazy var dataOps = DataOperations(app: self)
    /// The exact failure text `stuckReport()` reports when `quiesce()` comes back `.stuck` — a shared
    /// constant so a storage sheet (Clear Data, export deletion, farewell) can recognize this specific failure and show
    /// the dedicated "Quit Rhemion" state instead of an ordinary failure list, without widening
    /// `OperationReport` itself with a new case.
    static let quiesceStuckMessage = "Rhemion couldn't stop its engine. Quit and reopen Rhemion to continue."
    /// The exact text `busyReport()` returns when another storage operation already
    /// holds the barrier — the sheets/window match it and stay on their confirm step (never a failure).
    static let busyMessage = "Another storage operation is in progress."
    /// Up from the moment a destructive run* function's barrier comes back `.ready` until it returns —
    /// `applicationShouldTerminate` refuses to quit in between (a half-done removal). Every legitimate
    /// exit that happens INSIDE a run* function (Clear Data's settings-reset relaunch) clears it first; the others (restart,
    /// Done, Quit on stuck) run after the function has returned, when it is already down.
    private var destructiveOpRunning = false
    /// A real (non-dry-run) Uninstall has run — set once `runUninstall` returns from anything but
    /// busy/stuck. From then on every way out goes through `finishUninstall()` (it exits by itself), never
    /// `NSApp.terminate`, which would let AppKit write the just-cleared defaults and saved state back.
    private var uninstallEnded = false
    private var settings = AppSettings()
    /// Flips to `true` the instant a settings reset's barrier clears (Clear Data with "Reset
    /// all settings", before settings.json is touched) and never back — it always ends in either a
    /// relaunch or a "Restart Rhemion"-only
    /// failure state, never a return to normal operation. Every site that saves `settings` FROM MEMORY
    /// (the hub's apply-on-change, the two onboarding writers) checks this first, so a save racing in
    /// during/after the reset can't resurrect the old settings.json over the fresh one Reset just wrote.
    private var settingsWriteSuppressed = false
    // The runtime's latest answer to `.listDevices` — what the Settings model/mic pickers offer.
    private var availableModels: [ModelOption] = []
    private var availableMics: [MicOption] = []
    private var hubWindow: HubWindowController?
    private var onboardingWindow: OnboardingWindowController?
    private let aboutWindow = AboutWindowController()
    private var farewellWindow: FarewellWindowController?
    private var clearDataWindow: ClearDataWindowController?
    let modelDownload = ModelDownloadModel()   // speech-model provisioning state (onboarding + settings)
    // Thread-safe mirror of "the speech model is present" for the PTT hot path: HotkeyTap's onStart can run
    // off the main actor, so it reads this instead of the @MainActor ModelDownloadModel to decide, without a
    // hop, whether to start a take or show the not-ready cue. Kept in sync on the main actor (syncModelState).
    private let modelReady = Locked<Bool>(false)
    /// Whether microphone access was already granted when the runtime started. The runtime does not touch
    /// the microphone without it, so a grant made later needs a runtime restart to take effect.
    private let micAuthorizedAtRuntimeStart = Locked<Bool>(false)
    private var devicesPollScheduled = false
    /// Microphone granted while a download runs: the download's own runtime restart picks it up.
    private var micRestartPending = false
    /// Watches for a microphone grant made in System Settings while Welcome is closed (stops once granted).
    private var micWatchTimer: Timer?
    private var setupIncompleteItem: NSMenuItem?   // "Setup incomplete — download model", shown only when missing
    private let inputMethod = Locked<String>("direct")

    override init() {
        super.init()
        AppController.shared = self
        // Menu-bar glyph: a MONOCHROME version of the app icon (orb + rings), so the tray matches the
        // logo. Loaded as a template image (macOS tints it to the light/dark menu bar).
        if let button = statusItem.button {
            if let url = Bundle.main.url(forResource: "MenuBarGlyph", withExtension: "png"),
               let img = NSImage(contentsOf: url) {
                img.isTemplate = true
                img.size = NSSize(width: 18, height: 18)
                button.image = img
            } else {
                button.title = "R3"   // fallback if the asset is missing
            }
        }
        // Clean menu-bar menu: no title line, separators between groups, Settings near the
        // bottom, Quit last. Diagnostics (indicator style, app.log) moved to Settings › Advanced; the dev
        // ping test was removed.
        let menu = NSMenu()
        let hubItem = NSMenuItem(title: "Open Rhemion…", action: #selector(openHub), keyEquivalent: "0")
        hubItem.target = self
        // Shown only while the speech model is missing (setup incomplete) — the one gentle nudge, no red badge.
        // Opens Welcome, where the Download button lives. Hidden by default; toggled in updateSetupMenuItem().
        let setupItem = NSMenuItem(title: "Setup incomplete — download model", action: #selector(openWelcome), keyEquivalent: "")
        setupItem.target = self
        setupItem.isHidden = true
        setupIncompleteItem = setupItem
        let journalItem = NSMenuItem(title: "Journal", action: #selector(openJournal), keyEquivalent: "j")
        journalItem.target = self
        let dictionaryItem = NSMenuItem(title: "Dictionary", action: #selector(openDictionary), keyEquivalent: "d")
        dictionaryItem.target = self
        let settingsItem = NSMenuItem(title: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
        settingsItem.target = self
        let welcomeItem = NSMenuItem(title: "Welcome…", action: #selector(openWelcome), keyEquivalent: "")
        welcomeItem.target = self
        let quitItem = NSMenuItem(title: "Quit Rhemion", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        quitItem.keyEquivalentModifierMask = [.command, .option]   // same as the app menu: ⌘Q only closes windows
        quitItem.target = NSApp   // terminate: is handled by NSApp, not this controller
        menu.addItem(hubItem)
        menu.addItem(setupItem)
        menu.addItem(.separator())
        menu.addItem(journalItem); menu.addItem(dictionaryItem); menu.addItem(.separator())
        menu.addItem(settingsItem); menu.addItem(welcomeItem); menu.addItem(.separator())
        let aboutItem = NSMenuItem(title: "About Rhemion", action: #selector(openAbout), keyEquivalent: "")
        aboutItem.target = self
        menu.addItem(aboutItem)
        menu.addItem(quitItem)
        Self.withoutItemIcons(menu)
        statusItem.menu = menu
    }

    func setStatus(_ message: String) { statusItem.button?.toolTip = message }

    // While a real window is open the app must have a Dock icon + Cmd-Tab entry, otherwise the
    // window vanishes behind other apps with no way back (an .accessory app has neither). We flip to
    // .regular while a window is open and back to .accessory when it closes.

    func setDockIconVisible(_ visible: Bool) {
        if visible {
            guard NSApp.activationPolicy() != .regular else { return }
            NSApp.setActivationPolicy(.regular)   // the Dock shows the bundle's AppIcon.icns (one icon, no choice)
        } else {
            // Called from a window's windowWillClose, while that window is still on screen: look again on the
            // next turn of the run loop, and only drop the Dock icon when no other app window is still open.
            // Flipping to .accessory with another window up (e.g. closing Welcome while the Journal is open)
            // pulls that window away too — each window must close on its own.
            DispatchQueue.main.async {
                let anyOpen = NSApp.windows.contains { $0.isVisible && $0.styleMask.contains(.titled) }
                guard !anyOpen, NSApp.activationPolicy() != .accessory else { return }
                NSApp.setActivationPolicy(.accessory)
            }
        }
    }

    /// Apply the saved recording-indicator preference; "auto" keeps NotchIndicator's own hardware default.
    private func applyIndicatorStyle(_ style: String, to indicator: NotchIndicator) {
        switch style {
        case "notch":    indicator.setStyle(.notch)
        case "floating": indicator.setStyle(.floating)
        default:         break
        }
    }

    @objc private func openSettings() {
        client?.send(.listDevices)   // refresh the model/mic pickers from the runtime on every open
        hubWindow?.show(dest: .settings)   // Settings lives in the hub; ⌘, opens it there
    }

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
                      progress: @escaping @MainActor @Sendable (ClearItem) -> Void = { _ in }) async -> OperationReport {
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
        // Each row as it starts, once (hopped to the main queue in order).
        let announce: @Sendable (ClearItem) -> Void = { c in DispatchQueue.main.async { MainActor.assumeIsolated { progress(c) } } }
        // Recordings without the Journal: mark the transcripts first, re-render their notes after (no dead
        // audio references, nothing for the runtime's reconcile to drop) — as audio retention does.
        let recordingsOnly = selection.contains(.recordings) && !selection.contains(.journal) && !dryRun
        var report = await Task.detached(priority: .userInitiated) {
            var current: ClearItem?
            var sizes: [StorageItem: Int64] = [:]
            let willRemove: (StorageItem) -> Void = { item in
                sizes[item] = StorageSizes.size(of: item)   // what this item frees, just before it goes
                guard let c = rowOf[item], c != current else { return }
                current = c; announce(c)
            }
            var r: OperationReport
            if recordingsOnly {
                let prep = StorageOperations.prepareRecordingsRemoval(plan, layout)
                r = StorageOperations.execute(prep.plan, layout: layout, effects: effects, willRemove: willRemove)
                r.failures = prep.failures + r.failures + StorageOperations.rerenderHistory(months: prep.months, layout)
            } else {
                r = StorageOperations.execute(plan, layout: layout, effects: effects, willRemove: willRemove)
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
            progress(.settings)
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

    /// No quitting in the middle of a destructive operation
    /// A click on the Dock icon (the app is pinned there, or a window put the icon up): Rhemion is a
    /// menu-bar app with no window of its own at rest, so AppKit's default does nothing visible. Bring
    /// Welcome forward while it is open, otherwise open the hub (or bring a minimized/hidden one back).
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if let welcome = onboardingWindow, welcome.isShowing { welcome.bringToFront() } else { hubWindow?.show() }
        return true
    }

    /// What a quit request (Cmd-Q, Dock Quit, logout) does now: refused mid-operation; after a real
    /// Uninstall routed to `finishUninstall()` (it exits by itself, so AppKit's own quit is cancelled — it
    /// would write the cleared defaults and saved state back); otherwise an ordinary quit.
    enum QuitDecision: Equatable { case quit, refuse, finishUninstall }

    nonisolated static func quitDecision(destructiveOpRunning: Bool, uninstallEnded: Bool) -> QuitDecision {
        if destructiveOpRunning { return .refuse }
        return uninstallEnded ? .finishUninstall : .quit
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        switch Self.quitDecision(destructiveOpRunning: destructiveOpRunning, uninstallEnded: uninstallEnded) {
        case .quit:
            return .terminateNow
        case .refuse:
            log("quit refused: a storage operation is running")
            return .terminateCancel
        case .finishUninstall:
            finishUninstall()   // exits; never returns in a real uninstall
            return .terminateCancel
        }
    }

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

    /// Store the runtime's latest device enumeration and push it into the hub's Settings pickers (a
    /// refresh while the window is open updates the option lists in place).
    @MainActor private func updateDevices(models: [ModelOption], mics: [MicOption]) {
        availableModels = models
        availableMics = mics
        hubWindow?.setDevices(models: models, mics: mics)
        modelDownload.devicesUpdated(models)   // drives the Speech-model row (present / preparing / ready)
        syncModelState()
        // While the runtime prepares the model, ask again shortly; the report flips to warm when it is done.
        if modelDownload.phase == .preparing, !devicesPollScheduled {
            devicesPollScheduled = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                guard let self else { return }
                self.devicesPollScheduled = false
                self.client?.send(.listDevices)
            }
        }
    }

    /// Push the current model phase into the hot-path readiness mirror and the menu. Call on the main actor
    /// after any change to `modelDownload.phase` (a `.devices` report or a `.modelDownload` event).
    @MainActor private func syncModelState() {
        modelReady.value = modelDownload.isReady
        updateSetupMenuItem()
        // Model just became ready: end any download/not-ready orb cue (leaves a live recording alone) and
        // clear the menu-bar "downloading…" tooltip.
        if modelDownload.isReady { indicator?.endModelCue(); setStatus("") }
    }

    /// Show the "Setup incomplete — download model" menu line only when the model is actionable-missing
    /// (absent or a failed download), never while it's downloading/preparing/ready. No persistent red badge.
    @MainActor private func updateSetupMenuItem() {
        let show: Bool
        switch modelDownload.phase {
        case .missing, .failed: show = true
        default:                show = false
        }
        setupIncompleteItem?.isHidden = !show
    }

    /// A gated push-to-talk press (model not ready): don't start a take. Reset the hotkey state so a
    /// hands-free latch/countdown can't engage on the gated press, and show a graphical, non-error cue at the
    /// notch (progress ring if a download is running, else a brief down-arrow) with an English hover tooltip.
    @MainActor private func handleGatedPTT() {
        hotkey?.abortRecording()
        switch modelDownload.phase {
        case .downloading(let f):
            indicator?.downloadProgress(f)
            setStatus("Downloading speech model — \(Int(f * 100))%")
            showWelcomeForSetup()
        case .preparing:
            // Usually under a second (a first-time compile can take a minute): the spinner only; Welcome comes
            // forward only if it is already open, so a press right after login doesn't pop a window.
            indicator?.preparing()
            setStatus("Preparing speech model…")
            if let welcome = onboardingWindow, welcome.isShowing { welcome.bringToFront() }
        default:
            indicator?.downloadHint()
            setStatus("Download the speech model to use dictation (Welcome / Settings › Audio & Model)")
            showWelcomeForSetup()
        }
    }

    /// A dictation press without usable microphone access. Not granted: bring Welcome forward (its Microphone
    /// row asks). Granted since the runtime started: restart the runtime so it can prepare the microphone.
    @MainActor private func handleMicrophoneGate(granted: Bool) {
        hotkey?.abortRecording()
        if granted {
            // The runtime restarts to open the microphone; the spinner ends when it reports ready. During a
            // download the restart waits for it, and the download ring stays.
            if case .downloading = modelDownload.phase {} else { indicator?.preparing() }
            restartRuntimeForMicrophone()
        } else {
            indicator?.downloadHint()
            showWelcomeForSetup()
        }
    }

    @MainActor private func restartRuntimeForMicrophone() {
        guard !micAuthorizedAtRuntimeStart.value else { return }
        micWatchTimer?.invalidate(); micWatchTimer = nil
        // A restart now would cut a running download; its own restart (on "done") covers the microphone too.
        if case .downloading = modelDownload.phase { micRestartPending = true; return }
        micAuthorizedAtRuntimeStart.value = true
        micRestartPending = false
        log("microphone access granted; restarting the runtime so it can use the microphone")
        supervisor.restart()
    }

    /// Until microphone access is granted, check every 2 s (reading the status never prompts), so a grant
    /// made in System Settings with Welcome closed takes effect without spending a dictation press on it.
    @MainActor private func watchForMicrophoneGrant() {
        guard !micAuthorizedAtRuntimeStart.value, micWatchTimer == nil else { return }
        micWatchTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                if AVCaptureDevice.authorizationStatus(for: .audio) == .authorized { self.restartRuntimeForMicrophone() }
            }
        }
    }

    /// The words and the progress live in Welcome; the notch indicator stays wordless.
    @MainActor private func showWelcomeForSetup() {
        guard let welcome = onboardingWindow else { return }
        if welcome.isShowing { welcome.bringToFront() } else { welcome.show() }
    }

    @objc private func openHub() { hubWindow?.show() }

    // The Dictionary and Journal now live as hub destinations; these menu items just jump the
    // hub to the right tab. The old standalone windows are gone.
    @objc private func openDictionary() { hubWindow?.show(dest: .dictionary) }

    @objc private func openJournal() { hubWindow?.show(dest: .journal) }

    @objc private func openWelcome() { onboardingWindow?.show() }
    @objc private func openAbout() { aboutWindow.show() }

    // Global hotkeys are suspended while ANY settings recorder captures a chord; a depth counter keeps
    // them suspended until the last active recorder finishes (two rows can record at once).
    private var recordingDepth = 0
    private func beginHotkeyRecording() {
        if recordingDepth == 0 {
            recall?.suspend(); dictAdd?.suspend(); undoReplace?.suspend()
            escGesture?.suspend()   // let the recorder's monitor see Esc; don't act on it as a gesture
        }
        recordingDepth += 1
    }
    private func endHotkeyRecording() {
        recordingDepth = max(0, recordingDepth - 1)
        if recordingDepth == 0 {
            recall?.setHotkeys(settings.recallHotkeys)
            dictAdd?.setHotkeys(settings.dictAddHotkeys)
            undoReplace?.setHotkeys(settings.undoHotkeys)
            escGesture?.resume()
        }
    }

    /// The double-Esc gesture: cancel the recording in progress, or (nothing recording) erase the
    /// just-delivered take at the frontmost app. Same stroke, stage-dependent meaning. Returns whether
    /// it CLAIMED an action, so the Esc tap swallows the second Esc only when it did.
    @MainActor
    private func handleEscapeGesture() -> Bool {
        if recordingFlag.value {
            log("double-Esc: cancel recording")
            recordingFlag.value = false
            hotkey?.abortRecording()   // so the eventual PTT release doesn't send a stray .stop
            client?.send(.cancel)      // runtime discards the take: no transcript, no history, no recall
            indicator?.hide()
            return true
        }
        return deleteLastTake()
    }

    /// Erase the most recently delivered take with Backspace×n, but only if it is still armed AND
    /// landed in the app that is frontmost now (the same TTL + pid-match heuristic as undo-replace, so
    /// we never delete into a different app; the caret-moved-since-delivery edge is the same accepted
    /// limitation both gestures share). Returns whether a take was claimed. Success is silent — the
    /// vanished text is the confirmation.
    @MainActor
    private func deleteLastTake() -> Bool {
        guard let front = NSWorkspace.shared.frontmostApplication?.processIdentifier,
              let n = undoStore.takeDelete(matchingPid: Int(front)) else {
            log("double-Esc: nothing to erase here"); return false
        }
        let pid = Int(front)
        let indicator = self.indicator
        DispatchQueue.global(qos: .userInitiated).async {
            if KeyboardEdit.deleteBackward(n: n, pid: pid) {
                log("double-Esc: erased last take (\(n))")
            } else {
                log("double-Esc: erase aborted (modifiers held)")
                Task { @MainActor in indicator?.error() }
            }
        }
        return true
    }

    /// Deliver a recalled transcript into the current focus through the normal delivery path, so it
    /// gets the SAME boundary spacing and AX/paste routing as a fresh dictation (recall used to paste
    /// raw, with no leading/trailing space). targetPid nil = universal (wherever focus is now);
    /// success is silent, a failure flashes the indicator.
    @MainActor
    private func deliverRecall(_ text: String) {
        guard let delivery else { return }
        let indicator = self.indicator
        delivery.onDeliver(
            text: text, original: nil, session: "recall-\(UUID().uuidString)", targetPid: nil,
            inputMethod: inputMethod.value,
            sendAck: { _, _ in },
            onResult: { status in
                log("recall delivery: \(status)")
                if !isDeliverySuccess(status) { Task { @MainActor in indicator?.error() } }
            }
        )
    }

    // MARK: - NSApplicationDelegate lifecycle

    /// ⌘Q: close every Rhemion window the normal way (performClose — a window mid-operation refuses, as it should);
    /// Rhemion itself keeps running in the menu bar.
    @objc private func closeAllWindows() {
        for window in NSApp.windows where window.isVisible && window.styleMask.contains(.titled) {
            window.performClose(nil)
        }
    }

    /// The app's main menu. Rhemion is a menu-bar app, but its windows (Journal, Settings, Clear Data, Uninstall,
    /// Welcome) put up a Dock icon and the menu bar — without a main menu, ⌘Q / ⌘W / ⌘C / ⌘V do nothing there.
    /// Quit goes through NSApp.terminate, so applicationShouldTerminate still refuses mid-operation.
    private func installMainMenu() {
        let main = NSMenu()
        let appItem = NSMenuItem(); main.addItem(appItem)
        let app = NSMenu(title: "Rhemion")
        let about = NSMenuItem(title: "About Rhemion", action: #selector(openAbout), keyEquivalent: ""); about.target = self
        app.addItem(about)
        app.addItem(.separator())
        let settings = NSMenuItem(title: "Settings…", action: #selector(openSettings), keyEquivalent: ","); settings.target = self
        app.addItem(settings)
        app.addItem(.separator())
        app.addItem(NSMenuItem(title: "Hide Rhemion", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h"))
        app.addItem(.separator())
        // ⌘Q only closes Rhemion's windows — Rhemion lives in the menu bar, and an accidental ⌘Q must not silently
        // stop dictation. Quitting for real is ⌥⌘Q here, or "Quit Rhemion" in the menu-bar menu (owner decision).
        let closeAll = NSMenuItem(title: "Close Rhemion Windows", action: #selector(closeAllWindows), keyEquivalent: "q")
        closeAll.target = self
        app.addItem(closeAll)
        let quit = NSMenuItem(title: "Quit Rhemion", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        quit.keyEquivalentModifierMask = [.command, .option]
        app.addItem(quit)
        appItem.submenu = app
        app.delegate = self   // re-strips icons right before it opens (macOS 26 decorates "About" late)
        let editItem = NSMenuItem(); main.addItem(editItem)
        let edit = NSMenu(title: "Edit")
        edit.addItem(NSMenuItem(title: "Undo", action: Selector(("undo:")), keyEquivalent: "z"))
        let redo = NSMenuItem(title: "Redo", action: Selector(("redo:")), keyEquivalent: "z"); redo.keyEquivalentModifierMask = [.command, .shift]
        edit.addItem(redo)
        edit.addItem(.separator())
        edit.addItem(NSMenuItem(title: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x"))
        edit.addItem(NSMenuItem(title: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c"))
        edit.addItem(NSMenuItem(title: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v"))
        edit.addItem(NSMenuItem(title: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a"))
        editItem.submenu = edit
        let windowItem = NSMenuItem(); main.addItem(windowItem)
        let window = NSMenu(title: "Window")
        window.addItem(NSMenuItem(title: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m"))
        window.addItem(NSMenuItem(title: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w"))
        windowItem.submenu = window
        Self.withoutItemIcons(main)
        NSApp.mainMenu = main
        NSApp.windowsMenu = window
        Self.withoutItemIcons(main)   // again: setting the main menu can re-decorate the app menu
    }

    /// Menus without item icons (owner decision, 05.10.2026): short menus scan faster without them, and the app
    /// looks the same on macOS 15, 26 and 27. macOS 26 adds its own icons to recognised commands (Settings,
    /// Quit, Close…); assigning an image and then nil opts an item out (AppKit engineer, Apple Developer
    /// Forums thread 800414). Recurses into submenus.
    static func withoutItemIcons(_ menu: NSMenu) {
        for item in menu.items {
            if !item.isSeparatorItem {
                item.image = NSImage(size: NSSize(width: 1, height: 1))
                item.image = nil
            }
            if let submenu = item.submenu { withoutItemIcons(submenu) }
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        installMainMenu()
        AppLog.enforceHygiene()   // 7 days / 15 MB of diagnostic logs, before the first line of this run
        AppLog.startHygieneTimer()
        log("Rhemion 3.0 launched. stateDir=\(AppPaths.stateDir.path)")

        // 0) Settings — the app owns active/settings.json (no source note). Materialize it so
        //    the runtime always has a complete snapshot, then load our view of it.
        SettingsStore.ensureExists()
        settings = SettingsStore.load()
        settings.applyAppearance()
        inputMethod.value = settings.inputMethod
        // Reconcile the login-item registration to the saved preference (default on). Non-fatal: a
        // failure is logged and retried on the next launch/toggle, never crashes startup.
        LoginItem.reconcile(enabled: settings.launchAtLogin)
        log("settings: ptt=[\(settings.pttKeys.joined(separator: ","))], input=\(settings.inputMethod), language=\(settings.language)")

        // 1) Own isolated runtime. Migrate any history from the earlier location into the Application Support
        //    dataDir FIRST — before the runtime starts — so its startup reconcile finds the audio
        //    instead of treating every take's WAV as missing and purging the month's records.
        AppPaths.migrateDataDirIfNeeded()
        micAuthorizedAtRuntimeStart.value = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        supervisor.start()

        // 2) Delivery + socket client. The client routes `deliver` events into Delivery,
        //    which inserts natively and reports the outcome back as a delivery-result ack.
        let indicator = NotchIndicator()
        applyIndicatorStyle(settings.indicatorStyle, to: indicator)   // honor the saved Advanced preference
        let delivery = Delivery()
        // Arm/disarm the in-place undo from the delivery outcome (disarm at every delivery start, arm on
        // a landed dictionary substitution).
        delivery.onArmUndo = { [undoStore] deliveredN, pid, undoRaw in
            undoStore.arm(deliveredN: deliveredN, pid: pid, undoRaw: undoRaw)
        }
        delivery.onDisarmUndo = { [undoStore] in undoStore.disarm() }
        let client = RuntimeClient(socketPath: supervisor.socketPath)
        client.onConnect = { [weak client, weak self] in
            log("runtime connected")
            // A reconnect while a download was still in flight means the runtime restarted under it — no
            // "failed" event will arrive, so surface it as interrupted (Retry appears; the `.devices` report
            // below then resolves ready/missing). This also unsticks a Download whose command was dropped
            // because the socket was down. `.preparing` is the intended post-"done" restart and is left to
            // resolve to `.ready` via devicesUpdated, so it is deliberately NOT treated as interrupted.
            Task { @MainActor in
                guard let self else { return }
                if case .downloading = self.modelDownload.phase {
                    self.modelDownload.phase = .failed("Download interrupted")
                    self.syncModelState()
                    self.indicator?.downloadHint()
                    self.setStatus("Speech model download interrupted — retry in Setup")
                }
            }
            client?.send(.listDevices)   // pre-warm the Settings model/mic lists + resolve model readiness
        }
        // Speech-model provisioning: the Download/Retry button asks the runtime to fetch the model (it owns
        // FluidAudio); Cancel aborts it. Progress + terminal state come back as `.modelDownload` events.
        modelDownload.onDownload = { [weak client, weak self] in
            guard let self, !self.dataOps.inProgress else { return }
            self.modelDownload.phase = .downloading(0)   // immediate feedback before the first progress event
            self.syncModelState()
            self.indicator?.downloadProgress(0)          // show the orb the instant Download is pressed (links the two)
            self.setStatus("Downloading speech model…")
            client?.send(.downloadModel(id: self.modelDownload.modelID))
        }
        modelDownload.onCancel = { [weak client] in client?.send(.cancelModelDownload) }
        client.onEvent = { [weak client, weak self, inputMethod] event in
            // Per-tick microphone levels aren't logged (dozens a second while dictating); state changes are.
            if case .level = event {} else { log("event: \(eventLabel(event))") }
            switch event {
            case .started:        Task { @MainActor in indicator.recording() }
            case .level(let rms): Task { @MainActor in indicator.onLevel(rms); self?.hotkey?.onLevel(rms) }
            case .stopped:        Task { @MainActor in indicator.processing() }
            case .canceled:       Task { @MainActor in indicator.hide() }
            case .error:          Task { @MainActor in indicator.error() }
            case let .devices(models, mics): Task { @MainActor in self?.updateDevices(models: models, mics: mics) }
            case let .modelDownload(_, state, fraction, error):
                Task { @MainActor in
                    guard let self else { return }
                    // Always fold the event into the phase model — quiesce()'s own ~3s cancel-download
                    // poll (DataOperations.swift) reads `modelDownload.phase` as its only signal that the
                    // runtime's "canceled" reply landed, and this call is the only thing that flips phase
                    // away from `.downloading`. It has no side effect of its own (no UI, no supervisor
                    // call), so leaving it live during quiesce is safe.
                    self.modelDownload.downloadEvent(state: state, fraction: fraction, error: error)
                    guard !self.dataOps.inProgress else {
                        log("model-download event dropped: data operation in progress")
                        return
                    }
                    self.syncModelState()
                    switch state {
                    case "downloading":
                        let f = fraction ?? 0
                        self.indicator?.downloadProgress(f)
                        self.setStatus("Downloading speech model — \(Int(f * 100))%")
                    case "done":
                        // A finished download isn't usable until a fresh runtime discovers + registers it;
                        // restart so it does (and prewarms). Readiness then arrives via the next `.devices`.
                        self.setStatus("Preparing speech model…")
                        self.indicator?.preparing()   // spinner until the restarted runtime reports the model warm
                        // This restart also opens the microphone if access was granted during the download.
                        self.micAuthorizedAtRuntimeStart.value = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
                        self.micRestartPending = false
                        self.supervisor.restart()
                    case "failed":
                        self.indicator?.downloadHint()
                        self.setStatus("Speech model download interrupted — retry in Setup")
                        if self.micRestartPending { self.restartRuntimeForMicrophone() }
                    case "canceled":
                        self.indicator?.hide()
                        self.setStatus("")
                        if self.micRestartPending { self.restartRuntimeForMicrophone() }
                    default: break
                    }
                }
            case let .deliver(session, text, original, targetPid):
                // Hop to the main actor to check the barrier (dataOps is @MainActor-isolated; this
                // closure runs on RuntimeClient's internal queue), same pattern as every other case here.
                Task { @MainActor in
                    guard self?.dataOps.inProgress != true else {
                        log("deliver dropped: data operation in progress")
                        return
                    }
                    delivery.onDeliver(
                        text: text, original: original, session: session, targetPid: targetPid,
                        inputMethod: inputMethod.value,
                        sendAck: { s, status in client?.send(.deliverResult(session: s, status: status)) },
                        onResult: { status in
                            log("delivery: \(status)")
                            let ok = isDeliverySuccess(status)
                            Task { @MainActor in if ok { indicator.done() } else { indicator.error() } }
                        }
                    )
                }
            default: break
            }
        }
        client.connect()

        // 3) Push-to-talk hotkey: a bare modifier (from settings, default Right Option) drives
        //    start/stop over the socket, carrying the frontmost pid so the runtime binds delivery to
        //    the app that was focused at press.
        let hotkey = HotkeyTap()
        hotkey.onStart = { [weak client, weak self, recordingFlag, modelReady, micAuthorizedAtRuntimeStart] pid in
            // Hot-path gate: don't start a take until the speech model is ready and the microphone may be used
            // — otherwise the runtime has nothing to record or nothing to recognise with. Read thread-safe
            // state (onStart can run off the main actor); show a cue and the Welcome window instead.
            let micGranted = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
            guard micGranted, micAuthorizedAtRuntimeStart.value else {
                Task { @MainActor in self?.handleMicrophoneGate(granted: micGranted) }
                return
            }
            guard modelReady.value else {
                Task { @MainActor in self?.handleGatedPTT() }
                return
            }
            // Barrier gate: this closure runs on the main run loop (HotkeyTap's tap source is added
            // there), so a synchronous MainActor read is safe here, matching escGesture.onDoubleTap below.
            // A quiesce in progress must not start a new take: reset the tap's latch state instead (no
            // recordingFlag, no `.start`) so the eventual release is a no-op too.
            let blocked = MainActor.assumeIsolated { self?.dataOps.inProgress ?? false }
            guard !blocked else {
                log("PTT ignored: data operation in progress")
                MainActor.assumeIsolated { self?.hotkey?.abortRecording() }
                return
            }
            log("PTT down -> start (pid \(pid))")
            recordingFlag.value = true
            client?.send(.start(pressedAt: nil, targetPid: Int(pid)))
        }
        hotkey.onStop = { [weak client, weak self, recordingFlag] in
            guard recordingFlag.value else { return }   // a gated press never started — send no stray .stop
            recordingFlag.value = false
            let blocked = MainActor.assumeIsolated { self?.dataOps.inProgress ?? false }
            guard !blocked else { log("PTT ignored: data operation in progress"); return }
            log("PTT up -> stop")
            client?.send(.stop)
        }
        hotkey.onCountdown = { remaining in Task { @MainActor in indicator.countdown(remaining) } }
        hotkey.onCountdownCancel = { Task { @MainActor in indicator.cancelCountdown() } }
        hotkey.setPTTKeys(settings.pttKeys)
        hotkey.setHandsFreeTimings(ringAfter: Double(settings.handsfreeCountdownAfterSecs),
                                   countdown: Double(settings.handsfreeCountdownSecs))
        hotkey.start()

        // 3b) Recall hotkey (global Carbon chord, works under Secure Input): re-inserts the last
        //     dictation into the current focus. Default Cmd+Option+R. Success is silent; only a failure flashes the indicator.
        let recall = RecallHotkey()
        recall.onRecall = { [weak self] text in
            Task { @MainActor in
                guard let self, !self.dataOps.inProgress else { return }
                self.deliverRecall(text)
            }
        }
        recall.setHotkeys(settings.recallHotkeys)

        // 3c) Dict-add hotkey (global Carbon chord, default Cmd+Option+W): reads the current selection
        //     then opens the "as heard → correct" panel, which writes the replacement into the
        //     dictionary the runtime hot-reloads.
        let dictAddPanel = DictAddPanelController()
        let dictAdd = DictAdd()
        dictAdd.onTrigger = { [weak self] selection in
            Task { @MainActor in
                guard let self, !self.dataOps.inProgress else { return }
                self.dictAddPanel?.show(heard: selection)
            }
        }
        dictAdd.setHotkeys(settings.dictAddHotkeys)

        // 3d) Undo-replace hotkey (global Carbon, default Cmd+Option+Shift+L): reverts
        //     the last dictation's dictionary replacement in place (Backspace×N + paste the original).
        let undoReplace = UndoReplace(store: undoStore)
        undoReplace.onError = { Task { @MainActor in indicator.error() } }
        undoReplace.setHotkeys(settings.undoHotkeys)
        undoStore.setTTL(Double(settings.undoTTLSecs))

        // 3e) Double-Esc gesture (active CGEventTap; a lone Esc passes through, only the second Esc of
        //     an engaged double-tap is swallowed): cancels a recording in progress, or erases the
        //     just-delivered take. Engages only while a take is recording or an armed take is fresh.
        let escGesture = EscapeGesture()
        escGesture.isEligible = { [recordingFlag, undoStore] in recordingFlag.value || undoStore.isArmed() }
        // Synchronous on the tap's main-run-loop callback (assumeIsolated is safe — we ARE on main), so
        // the swallow decision reflects whether the gesture actually claimed an action THIS press.
        escGesture.onDoubleTap = { [weak self] in
            MainActor.assumeIsolated { self?.handleEscapeGesture() ?? false }
        }
        escGesture.setWindowMS(settings.escDoubleTapMS)
        escGesture.start()

        // 4) Hub window (it owns Settings, reached via "Open Rhemion…" or ⌘,). Apply-on-
        //    change: persist the snapshot, then re-apply live — rebind the PTT modifier and swap the
        //    delivery input method. `language`/`model` live in the same snapshot and the runtime
        //    re-reads them on the next take, no restart.
        hubWindow = HubWindowController(
            current: { [weak self] in self?.settings ?? AppSettings() },
            apply: { [weak self] updated in
                guard let self else { return }
                // A model-folder change alters what the runtime's whisper scan finds, so re-query the
                // device list afterward to refresh the model picker in place.
                let modelDirsChanged = self.settings.modelDirs != updated.modelDirs
                self.settings = updated
                updated.applyAppearance()
                if let ind = self.indicator { self.applyIndicatorStyle(updated.indicatorStyle, to: ind) }
                if !self.settingsWriteSuppressed, !SettingsStore.save(updated) {
                    log("settings: WARN save failed — live change applied but not persisted")
                }
                self.inputMethod.value = updated.inputMethod
                self.hotkey?.setPTTKeys(updated.pttKeys)
                self.hotkey?.setHandsFreeTimings(ringAfter: Double(updated.handsfreeCountdownAfterSecs),
                                                 countdown: Double(updated.handsfreeCountdownSecs))
                // Don't re-arm the global chords while a recorder is capturing (a settings change during
                // capture would re-register them mid-capture); endHotkeyRecording restores them from
                // self.settings when the last active recorder ends.
                if self.recordingDepth == 0 {
                    self.recall?.setHotkeys(updated.recallHotkeys)
                    self.dictAdd?.setHotkeys(updated.dictAddHotkeys)
                    self.undoReplace?.setHotkeys(updated.undoHotkeys)
                }
                self.undoStore.setTTL(Double(updated.undoTTLSecs))
                self.escGesture?.setWindowMS(updated.escDoubleTapMS)
                LoginItem.reconcile(enabled: updated.launchAtLogin)
                if modelDirsChanged { self.client?.send(.listDevices) }
                log("settings changed: ptt=[\(updated.pttKeys.joined(separator: ","))], input=\(updated.inputMethod), language=\(updated.language)")
            },
            // While the recorder captures a chord, drop the global registrations so the current chord
            // reaches the local monitor (and no global hotkey fires mid-capture); restore afterward.
            // Ref-counted so two recorder rows recording at once don't restore while one is still open.
            beginRecording: { [weak self] in self?.beginHotkeyRecording() },
            endRecording: { [weak self] in self?.endHotkeyRecording() },
            client: client, modelDownload: modelDownload,
            runClearData: { [weak self] selection, progress in await self?.runClearData(selection, progress: progress) ?? OperationReport() },
            runDeleteExport: { [weak self] turnOff in await self?.runDeleteExport(turnOff: turnOff) ?? OperationReport() },
            isRecording: { [weak self] in self?.dataOps.isRecording ?? false },
            storageActivity: dataOps
        )

        // 4b) Uninstall: the farewell window, opened from Settings › Advanced › Storage.
        farewellWindow = FarewellWindowController(
            current: { [weak self] in self?.settings ?? AppSettings() },
            isRecording: { [weak self] in self?.dataOps.isRecording ?? false },
            canStart: { [weak self] in self?.canStartStorageOperation ?? false },
            run: { [weak self] options, progress in await self?.runUninstall(options, progress: progress) ?? OperationReport() },
            finish: { [weak self] in self?.finishUninstall() })
        hubWindow?.showUninstall = { [weak self] in self?.farewellWindow?.show() }
        // Clear Data is its own window in the farewell's format.
        clearDataWindow = ClearDataWindowController(restart: { [weak self] in self?.restartAfterClear() })
        hubWindow?.showClearData = { [weak self] make in self?.clearDataWindow?.show(make) }

        // The Dictionary and Journal are hub destinations now (Stages 4/5); no standalone windows to build.

        // 5) Welcome & Setup: first-run permissions + how-to. Shown once, re-openable from the menu.
        //    The PTT chooser writes the key live (persist + rebind the tap), same as a Settings change.
        onboardingWindow = OnboardingWindowController(
            current: { [weak self] in self?.settings ?? AppSettings() },
            setPTTKey: { [weak self] key in
                guard let self else { return }
                self.settings.pttKeys = [key]
                if !self.settingsWriteSuppressed, !SettingsStore.save(self.settings) { log("settings: WARN save failed (ptt from onboarding)") }
                self.hotkey?.setPTTKeys(self.settings.pttKeys)
                log("onboarding set ptt=\(key)")
            },
            setLaunchAtLogin: { [weak self] on in
                guard let self else { return }
                self.settings.launchAtLogin = on
                if !self.settingsWriteSuppressed, !SettingsStore.save(self.settings) { log("settings: WARN save failed (launch-at-login from onboarding)") }
                LoginItem.reconcile(enabled: on)
                log("onboarding set launch-at-login=\(on)")
            },
            modelDownload: modelDownload,
            onMicrophoneGranted: { [weak self] in self?.restartRuntimeForMicrophone() }
        )
        onboardingWindow?.showIfNeeded()
        watchForMicrophoneGrant()

        // Testing hook: RHEMION_OPEN_HUB=1 pops the hub on launch so it can be shown without clicking the
        // menu-bar item (no permanent behaviour change — the menu item is the real entry point).
        if let openHub = ProcessInfo.processInfo.environment["RHEMION_OPEN_HUB"], !openHub.isEmpty {
            hubWindow?.show(dest: openHub == "settings" ? .settings : nil)
        }

        self.indicator = indicator
        self.delivery = delivery
        self.client = client
        self.hotkey = hotkey
        self.recall = recall
        self.dictAdd = dictAdd
        self.dictAddPanel = dictAddPanel
        self.undoReplace = undoReplace
        self.escGesture = escGesture
    }

    /// Stop every global hotkey/event tap (quit and the uninstall exit path).
    private func stopInputs() {
        hotkey?.stop()
        recall?.stop()
        dictAdd?.stop()
        undoReplace?.stop()
        escGesture?.stop()
    }

    func applicationWillTerminate(_ notification: Notification) {
        stopInputs()
        supervisor.stop()
        log("Rhemion 3.0 terminating.")
    }
}

// Owner-only files by default.
umask(0o077)
// Writing to a socket whose peer (the runtime) has gone raises SIGPIPE, whose default action kills the
// process; ignore it so the client reconnects instead of crashing.
signal(SIGPIPE, SIG_IGN)

// One Rhemion at a time: a second launch brings the running one forward and quits here — before
// the runtime starts or any state is touched.
if SingleInstance.handOverIfAlreadyRunning() { exit(0) }

let app = NSApplication.shared
app.setActivationPolicy(.accessory)   // menu-bar only; no Dock icon (also declared LSUIElement)
let controller = AppController()
app.delegate = controller             // drives applicationDidFinishLaunching / WillTerminate
app.run()

// The app menu strips its icons again each time it is about to open (see withoutItemIcons).
extension AppController: NSMenuDelegate {
    func menuNeedsUpdate(_ menu: NSMenu) { Self.withoutItemIcons(menu) }
}
