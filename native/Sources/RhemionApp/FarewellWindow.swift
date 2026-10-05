// The Uninstall farewell window —
// the window is ONLY the choice: the logo in its calmer farewell rhythm in the side column while the user
// chooses what leaves with Rhemion, then Cancel / Uninstall. Its height never changes while ticking (every
// hint is constant). "Uninstall" opens the shared operation pop-up (DESIGN.md "Operation pop-up",
// `OperationPopupHost`) over it: the one confirmation (a receipt of what goes, 0.5 s guard), then the five
// uninstall steps, ticked as `AppController.runUninstall` reports progress — paced so each step is seen
// running and done. On success the pop-up shows an itemised report of what went (grouped by option, every
// path behind "Show all N items"); "Goodbye" closes it, the mark collapses into its core and the app quits (a
// dry run closes the window and resumes instead). Kept export files, failures, busy and stuck are said in the
// pop-up.

import AppKit
import Combine
import RhemionStorage
import SwiftUI

/// Drives one showing of the farewell window: choice → (pop-up) confirm → steps → a terminal state.
@MainActor
final class FarewellModel: ObservableObject {
    enum Phase: Equatable {
        /// The window's choice; no pop-up.
        case choose
        /// The pop-up's receipt with Cancel / Uninstall (0.5 s guard) — the one confirmation.
        case confirm
        /// The five steps, paced (`shown`) behind the run's progress.
        case working
        /// Success: the pop-up's itemised report of what went; "Goodbye" moves on to `collapsing`.
        case report(Report)
        /// Success: the pop-up is gone, the mark collapsing; the window closes a beat later.
        case collapsing
        /// Success, but export deletion was chosen and some files couldn't be confirmed as Rhemion's.
        case kept([String])
        /// Lines to list (failures, then kept export files); `failedSteps` marks the steps that didn't finish.
        case failure([String])
        case stuck(String)
    }

    /// What a successful uninstall removed (or, in a dry run, would have): one row per ticked option plus
    /// System, every path behind "Show all N items", and the dry-run flag — all from the run's report.
    struct Report: Equatable {
        var lines: [OperationReceiptLine]
        var removed: [String]
        var dryRun: Bool
    }

    static let steps = ["Stopping Rhemion", "Removing login item", "Resetting permissions",
                        "Removing data", "Moving Rhemion to the Trash"]

    @Published private(set) var phase: Phase = .choose
    @Published var options = UninstallOptions()
    /// What the pop-up shows: the step `runUninstall` is on, paced so each step is seen running and then
    /// done (a failed step ends on "not done").
    @Published private(set) var shown = PacedStep(index: 0, done: false)
    /// The steps a failed uninstall didn't finish (`failedSteps(_:)`).
    @Published private(set) var failedSteps: Set<Int> = []
    /// Byte size of every item the uninstall could touch (all options on), nil while calculating.
    @Published private(set) var sizes: [StorageItem: Int64]?
    /// Journal entries / recordings on disk when the window opened — the report's "N entries, N recordings".
    @Published private(set) var counts: StorageOperations.ClearCounts?
    /// Mirrors "0.5 s have passed since `.confirm` was entered" for the button's look; the authoritative
    /// guard is the timestamp check in `confirmUninstall()` (same as Clear Data's confirmation).
    @Published private(set) var confirmReady = false
    /// Another storage operation holds the barrier — the pop-up's confirmation says so and Uninstall waits.
    @Published private(set) var busy = false
    private var confirmEnteredAt: Date?

    let clock = WelcomeLogoClock()
    let layout: StorageLayout
    /// Extra model folders configured, or external model files present.
    let hasExternal: Bool
    /// The export folder — only when export is configured (exportMode != "off") or the registry owns
    /// files there; nil hides the export option and its notes.
    let exportDir: URL?
    /// Snapshotted when the window opens, like the sheets.
    let isRecording: Bool

    private var generation = 0
    private let canStart: () -> Bool
    private let run: (UninstallOptions, @escaping @MainActor (Int) -> Void) async -> OperationReport
    private let pacingClock: any PacingClock
    /// Closes the window and ends the app (a dry run resumes instead).
    private let finish: () -> Void

    init(layout: StorageLayout, exportMode: String, isRecording: Bool, canStart: @escaping () -> Bool,
         run: @escaping (UninstallOptions, @escaping @MainActor (Int) -> Void) async -> OperationReport,
         finish: @escaping () -> Void, pacingClock: any PacingClock = SystemPacingClock()) {
        self.layout = layout
        self.pacingClock = pacingClock
        self.canStart = canStart
        hasExternal = !layout.extraModelDirs.isEmpty || !layout.items(.externalModels).isEmpty
        if let dir = layout.exportDir,
           exportMode != "off" || !layout.items(.export).isEmpty {
            exportDir = dir
        } else {
            exportDir = nil
        }
        self.isRecording = isRecording
        self.run = run
        self.finish = finish
    }

    // MARK: sizes

    /// Walks every item the uninstall could remove off the main actor; a newer call supersedes an older one.
    func loadSizes() {
        sizes = nil
        generation += 1
        let gen = generation
        let layout = self.layout
        Task.detached(priority: .utility) {
            var all = UninstallOptions()
            all.models = true; all.externalModels = true; all.appData = true; all.userData = true; all.export = true
            var out: [StorageItem: Int64] = [:]
            for item in StorageOperations.uninstallPlan(layout, all) { out[item] = StorageSizes.size(of: item) }
            let counts = StorageOperations.clearCounts(layout)
            await MainActor.run { if self.generation == gen { self.sizes = out; self.counts = counts } }
        }
    }

    /// What checking `option` adds to the plan, given the other current choices — derived from
    /// `uninstallPlan` itself (plan with it on minus plan with it off), so the sizes can never drift from
    /// what is actually removed. "Models" is counted without the external folders (they have their own
    /// row); "external" is counted as if models were on (it's nested under it).
    nonisolated static func items(for option: WritableKeyPath<UninstallOptions, Bool>, base: UninstallOptions,
                      layout: StorageLayout) -> [StorageItem] {
        var on = base, off = base
        on[keyPath: option] = true; off[keyPath: option] = false
        if option == \UninstallOptions.models { on.externalModels = false; off.externalModels = false }
        if option == \UninstallOptions.externalModels { on.models = true; off.models = true }
        let without = Set(StorageOperations.uninstallPlan(layout, off))
        var seen = Set<StorageItem>()
        return StorageOperations.uninstallPlan(layout, on).filter {
            // The export registry is Rhemion's own bookkeeping — counted under app data only,
            // never as "exported transcripts" (it goes with export only when app data goes too).
            !without.contains($0) && seen.insert($0).inserted
                && !(option == \UninstallOptions.export && $0.category == .exportRegistry)
        }
    }

    func sizeText(_ option: WritableKeyPath<UninstallOptions, Bool>) -> String {
        guard let sizes else { return "Calculating…" }
        let total = Self.items(for: option, base: options, layout: layout).reduce(Int64(0)) { $0 + (sizes[$1] ?? 0) }
        return ByteSize.string(total)
    }

    // MARK: the pop-up's receipt

    /// The confirmation's rows: every ticked option, in the options' order, with its size; what can't be
    /// recovered (recordings/transcripts/dictionary, exported transcripts) is marked.
    var receiptLines: [OperationReceiptLine] {
        var out: [OperationReceiptLine] = []
        let o = options
        if o.models { out.append(.init(id: "models", name: "Downloaded models", size: sizeText(\.models))) }
        if o.models && o.externalModels && hasExternal {
            out.append(.init(id: "external", name: "Models from folders you added", size: sizeText(\.externalModels)))
        }
        if o.appData { out.append(.init(id: "appData", name: "Settings and application data", size: sizeText(\.appData))) }
        if o.userData {
            out.append(.init(id: "userData", name: "Recordings, transcripts and dictionary", size: sizeText(\.userData),
                             permanent: true))
        }
        if o.export, exportDir != nil {
            out.append(.init(id: "export", name: "Exported transcripts", size: sizeText(\.export), permanent: true))
        }
        return out
    }

    /// The export option's hint: one constant line whether it is ticked or not (the window never
    /// changes height while ticking).
    var exportHint: String { Self.exportHint }
    static let exportHint = "Only transcripts Rhemion exported. The folder and your other files stay."

    /// Anything ticked that can't be recovered.
    var irreversibleChosen: Bool { options.userData || (exportDir != nil && options.export) }

    /// The confirmation's plain line under the rows.
    var confirmNote: String {
        irreversibleChosen ? "Rhemion moves itself to the Trash."
                           : "Rhemion moves itself to the Trash. Your recordings, transcripts and dictionary stay."
    }

    /// The five steps as receipt rows with their marks: while working done / current / waiting; on success
    /// all done; after a failure the steps that didn't finish keep an empty ring.
    var stepLines: [OperationReceiptLine] {
        Self.steps.enumerated().map { i, name in OperationReceiptLine(id: name, name: name, status: stepStatus(i)) }
    }

    func stepStatus(_ i: Int) -> OperationRowStatus {
        switch phase {
        case .working: return shown.status(i)
        case .report, .collapsing, .kept: return .done
        case .failure: return failedSteps.contains(i) ? .notDone : .done
        default: return .dot
        }
    }

    // MARK: the report

    /// The success report's rows, grouped by the ticked option from what the run ACTUALLY removed (in a dry
    /// run: would have) — a group with nothing removed isn't shown; System closes the list. Sizes are the
    /// sizes measured when the window opened, summed over the removed items.
    nonisolated static func reportLines(removed: [StorageItem], options: UninstallOptions, sizes: [StorageItem: Int64]?,
                                        counts: StorageOperations.ClearCounts?, exportDir: URL?) -> [OperationReceiptLine] {
        func of(_ cats: Set<StorageCategory>) -> [StorageItem] { removed.filter { cats.contains($0.category) } }
        func size(_ items: [StorageItem]) -> String {
            guard let sizes else { return "" }
            return ByteSize.string(items.reduce(Int64(0)) { $0 + (sizes[$1] ?? 0) })
        }
        func count(_ n: Int, _ one: String, _ many: String) -> String { "\(n) \(n == 1 ? one : many)" }
        var out: [OperationReceiptLine] = []
        func add(_ id: String, _ name: String, _ detail: String?, _ items: [StorageItem]) {
            guard !items.isEmpty else { return }
            out.append(OperationReceiptLine(id: id, name: name, detail: detail, size: size(items), status: .done))
        }
        let models = of([.models]), external = of([.externalModels])
        add("models", "Downloaded models", modelDetail(models), models)
        add("external", "Models from folders you added", modelDetail(external), external)
        // Temporary files always go; with app data they are part of it, otherwise a row of their own.
        let app = of(options.appData ? [.applicationData, .exportRegistry, .temporary] : [.applicationData, .exportRegistry])
        add("appData", "Settings and application data", "Settings, logs, caches, preferences", app)
        if !options.appData { add("temporary", "Temporary files", "Cache", of([.temporary])) }
        let user = of([.transcripts, .dictionary, .recordings, .legacyContent])
        var parts: [String] = []
        if let counts {
            if counts.entries > 0, user.contains(where: { $0.category == .transcripts || $0.category == .legacyContent }) {
                parts.append(count(counts.entries, "entry", "entries"))
            }
            if counts.recordings > 0, user.contains(where: { $0.category == .recordings }) {
                parts.append(count(counts.recordings, "recording", "recordings"))
            }
        }
        if user.contains(where: { $0.category == .dictionary }) { parts.append("dictionary") }
        add("userData", "Recordings, transcripts and dictionary", parts.isEmpty ? nil : parts.joined(separator: ", "), user)
        let export = of([.export])
        let folder = exportDir.map { FolderLocation(path: $0.path).name }
        add("export", "Exported transcripts",
            count(export.count, "file", "files") + (folder.map { " in \($0)" } ?? ""), export)
        out.append(OperationReceiptLine(id: "system", name: "System",
                                        detail: "Login item removed · Permissions reset · Moved to the Trash", status: .done))
        return out
    }

    /// The models removed, by name ("Parakeet v3, Whisper large-v3-turbo"); whatever isn't a model of its own
    /// (a Core ML encoder, the silence helper, anything unrecognised) is counted as "(+N files)".
    nonisolated static func modelDetail(_ items: [StorageItem]) -> String? {
        var names: [String] = [], extra = 0
        for item in items {
            let file = item.relative.last ?? ""
            let label: String?
            if file.hasPrefix("parakeet-") {
                label = "Parakeet " + (file.split(separator: "-").last.map(String.init) ?? file)
            } else if file.lowercased().hasSuffix(".bin") && !StorageLayout.isSilenceModel(file) {
                label = "Whisper " + StorageLayout.whisperID(forFile: file).dropFirst("whisper-".count)
            } else {
                label = nil
            }
            if let label { if !names.contains(label) { names.append(label) } } else { extra += 1 }
        }
        let files = "\(extra) \(extra == 1 ? "file" : "files")"
        if names.isEmpty { return extra == 0 ? nil : files }
        return names.joined(separator: ", ") + (extra == 0 ? "" : " (+\(files))")
    }

    /// Which steps a failure line belongs to (`runUninstall`'s prefixes): the login item (1), the
    /// permissions (2), the Trash (4); anything else is the data (3).
    nonisolated static func failedSteps(_ failures: [String]) -> Set<Int> {
        Set(failures.map { line in
            if line.hasPrefix("Login item:") { return 1 }
            if line.hasPrefix("Permissions:") { return 2 }
            if line.hasPrefix("Move Rhemion to the Trash yourself:") { return 4 }
            return 3
        })
    }

    // MARK: flow

    /// "Uninstall": opens the pop-up's confirmation (always — it is the one confirmation). When another
    /// storage operation is running, the confirmation says so and Uninstall waits for it.
    func uninstall() {
        guard phase == .choose else { return }
        if exportDir == nil { options.export = false }
        busy = !canStart()
        phase = .confirm
        confirmReady = false
        let enteredAt = Date()
        confirmEnteredAt = enteredAt
        Task {
            try? await Task.sleep(for: .milliseconds(500))
            guard phase == .confirm, confirmEnteredAt == enteredAt else { return }
            confirmReady = true
        }
    }

    /// Valid only from `.confirm`, and only 0.5 s after it appeared — a double click on the window's
    /// Uninstall must not land on the pop-up's Uninstall before it has been read.
    func confirmUninstall() {
        guard phase == .confirm else { return }
        guard let enteredAt = confirmEnteredAt, Date().timeIntervalSince(enteredAt) >= 0.5 else { return }
        guard canStart() else { busy = true; return }
        busy = false
        start()
    }

    /// Cancel on the confirmation closes the pop-up, keeping the checkboxes.
    func back() {
        guard phase == .confirm else { return }
        phase = .choose
        busy = false
        confirmEnteredAt = nil
        confirmReady = false
    }

    /// The pop-up is up for every step after the choice — except the collapse, which the window plays.
    var showsPopup: Bool { phase != .choose && phase != .collapsing }

    /// Only the choice can be closed; once uninstall has started the window stays until its own button (or
    /// the success close) ends it — the app may already be half-removed.
    var canClose: Bool { phase == .choose }

    private func start() {
        phase = .working
        failedSteps = []
        let chosen = options
        let pacer = ProgressPacer(count: Self.steps.count, clock: pacingClock) { [weak self] in self?.shown = $0 }
        pacer.start()
        Task {
            let report = await run(chosen) { @MainActor s in pacer.advance(to: s) }
            if report.failures == [AppController.busyMessage] {
                // Lost a race to another operation: nothing was touched — the confirmation says why.
                pacer.stop()
                busy = true
                phase = .confirm
                return
            } else if report.removed.isEmpty && report.failures == [AppController.quiesceStuckMessage] {
                pacer.stop()
                phase = .stuck(report.failures[0])
                return
            }
            // The steps catch up at a pace the eye can follow before the result; the outcome is
            // known first, so a step that failed is never ticked on the way.
            let failed = report.success ? [] : Self.failedSteps(report.failures)
            await pacer.finish(notDone: failed)
            if report.success {
                if chosen.export, !report.unconfirmedExport.isEmpty {
                    phase = .kept(report.unconfirmedExport)
                } else {
                    phase = .report(Report(lines: Self.reportLines(removed: report.removedItems, options: chosen, sizes: sizes,
                                                                   counts: counts, exportDir: exportDir),
                                           removed: report.removed, dryRun: report.dryRun))
                }
            } else {
                failedSteps = failed
                var lines = report.failures
                if chosen.export, !report.unconfirmedExport.isEmpty {
                    lines.append(KeptFiles.lead(report.unconfirmedExport.count))
                    lines += report.unconfirmedExport
                }
                phase = .failure(lines)
            }
        }
    }

    func done() { finish() }

    /// "Goodbye" on the report: the pop-up closes, the mark collapses into its core, then the app quits (a
    /// dry run resumes instead).
    func goodbye() {
        guard case .report = phase else { return }
        phase = .collapsing
        clock.collapse()
        Task {
            let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
            if !reduceMotion { try? await Task.sleep(for: .seconds(1)) }
            finish()
        }
    }

    /// "Show in Finder" on the failure screen: the folder of the first failure that names a path (the
    /// nearest part of it that still exists), else the app itself.
    nonisolated static func revealTarget(failures: [String], app: URL) -> URL {
        let fm = FileManager.default
        for line in failures where line.hasPrefix("/") {
            // The path is everything before the LAST ": " (a path may itself contain ": ").
            let path = line.range(of: ": ", options: .backwards).map { String(line[..<$0.lowerBound]) } ?? line
            var url = URL(fileURLWithPath: path)
            while url.path != "/" {
                if fm.fileExists(atPath: url.path) { return url }
                url.deleteLastPathComponent()
            }
        }
        return app
    }
}

/// Owns the single farewell window and its operation pop-up. Modeled on `OnboardingWindowController`: sized
/// to its content, centred on the screen under the pointer, the Dock icon on while it's up, closing on its
/// own. A fresh model is built each time the window opens, so options, sizes and the "active dictation" note
/// reflect that moment. The pop-up (`OperationPopupHost`, shared with Clear Data) follows the phase; while it
/// is up the window takes no input, can't be closed and hands the key focus back to the pop-up.
@MainActor
final class FarewellWindowController: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    private var model: FarewellModel?
    private let popup = OperationPopupHost()
    private var phaseWatch: AnyCancellable?
    private let current: () -> AppSettings
    private let isRecording: () -> Bool
    private let canStart: () -> Bool
    private let run: (UninstallOptions, @escaping @MainActor (Int) -> Void) async -> OperationReport
    private let finish: () -> Void

    init(current: @escaping () -> AppSettings, isRecording: @escaping () -> Bool, canStart: @escaping () -> Bool,
         run: @escaping (UninstallOptions, @escaping @MainActor (Int) -> Void) async -> OperationReport,
         finish: @escaping () -> Void) {
        self.current = current; self.isRecording = isRecording; self.canStart = canStart; self.run = run; self.finish = finish
        super.init()
    }

    func show() {
        if let window, window.isVisible {
            NSApp.activate(ignoringOtherApps: true)
            if !popup.refocus() { window.makeKeyAndOrderFront(nil) }
            return
        }
        let settings = current()
        let model = FarewellModel(layout: AppPaths.storageLayout(settings: settings), exportMode: settings.exportMode,
                                  isRecording: isRecording(), canStart: canStart, run: run,
                                  finish: { [weak self] in self?.close(); self?.finish() })
        self.model = model
        let root = FarewellView(model: model, onCancel: { [weak self] in self?.cancelChoice() })
        let hosting = NSHostingController(rootView: root)
        hosting.sizingOptions = [.preferredContentSize]
        let window = self.window ?? NSWindow(contentViewController: hosting)
        window.contentViewController = hosting
        window.title = "Uninstall Rhemion"
        window.styleMask = [.titled, .closable]
        window.isReleasedWhenClosed = false
        window.delegate = self
        self.window = window
        // The pop-up follows the phase; the close button reads disabled while it is up (and on the way out).
        phaseWatch = model.$phase.receive(on: RunLoop.main).sink { [weak self, weak model] _ in
            guard let self, let model else { return }
            self.window?.standardWindowButton(.closeButton)?.isEnabled = model.canClose
            if model.showsPopup { self.showPopup(model) } else { self.popup.close() }
        }
        model.clock.restart()   // the farewell intro plays each time the window opens
        model.loadSizes()
        AppController.shared?.setDockIconVisible(true)
        NSApp.activate(ignoringOtherApps: true)
        centerOnPointerScreen(window)
        window.makeKeyAndOrderFront(nil)
    }

    private func showPopup(_ model: FarewellModel) {
        guard !popup.isShowing, let window else { return }
        popup.show(FarewellPopupView(model: model), over: window, onCancel: { [weak model] in model?.back() })
    }

    /// Cancel (or Esc) on the choice: only while the choice is all there is (`canClose`) — never the window
    /// behind a running pop-up — and through `performClose`, so `windowShouldClose` has the last word.
    private func cancelChoice() {
        guard model?.canClose == true else { return }
        window?.performClose(nil)
    }

    private func close() {
        popup.close()
        phaseWatch = nil
        model = nil
        window?.close()
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool { model?.canClose ?? true }

    /// A click on the window while the pop-up is up gives the key focus straight back to the pop-up.
    func windowDidBecomeKey(_ notification: Notification) { popup.refocus() }

    func windowWillClose(_ notification: Notification) {
        popup.close()
        phaseWatch = nil
        model = nil
        AppController.shared?.setDockIconVisible(false)
    }
}

/// The window's content — layout A: a recessed side column like Welcome layout C
/// (logo in its farewell rhythm, the question, the pitch, a quiet footer) and a main column with the
/// options — hello and goodbye read as a pair. Only the choice: every hint is constant, so ticking
/// never changes the height. App controls only (DESIGN.md): Cancel is a Raised R1 button,
/// Uninstall is Raised R1 with danger-red text, checkboxes are the gold `JournalCheckbox`, folders are the
/// shared `FolderView`. While the pop-up is up (or the mark collapses) it takes no input.
struct FarewellView: View {
    @ObservedObject var model: FarewellModel
    let onCancel: () -> Void
    @Environment(\.colorScheme) private var scheme
    private var dark: Bool { scheme == .dark }

    private static let width: CGFloat = 760
    private static let checkboxColumn: CGFloat = 18
    private static let checkboxGap: CGFloat = 10

    var body: some View {
        StandardWindow(width: Self.width) { sideColumn } main: { chooseContent }
            .allowsHitTesting(model.phase == .choose)
            .disabled(model.phase != .choose)   // also no keyboard / VoiceOver press behind the pop-up
            .onExitCommand { if model.phase == .choose { onCancel() } }
    }

    // MARK: side column

    /// The question while choosing; on success, the goodbye while the mark collapses into its core.
    private var sideColumn: some View {
        let leaving = model.phase == .collapsing
        return WindowSideColumn(clock: model.clock, farewell: true, title: leaving ? "Goodbye." : "Uninstall Rhemion?",
                                subtitle: leaving ? "Your double has left this Mac."
                                                  : "Your double will leave this Mac. Choose what goes with it.",
                                hint: "Rhemion moves itself to the Trash when it's done.")
    }

    // MARK: main column — the choice

    private var chooseContent: some View {
        VStack(alignment: .leading, spacing: WindowLayout.blockGap) {
            VStack(alignment: .leading, spacing: 14) {
                option(\.models, "Remove downloaded models",
                       hint: "Speech recognition models. Some may be shared with other apps, which would download them again.") {
                    model.options.models.toggle()
                    if !model.options.models { model.options.externalModels = false }
                }
                if model.hasExternal {
                    option(\.externalModels, "Also models from folders you added", enabled: model.options.models) {
                        if model.options.models { model.options.externalModels.toggle() }
                    }
                    .padding(.leading, Self.checkboxColumn + Self.checkboxGap)
                }
                option(\.appData, "Remove settings and application data", hint: "Settings, logs and caches.") {
                    model.options.appData.toggle()
                }
                option(\.userData, "Delete recordings, transcripts and dictionary",
                       hint: "Permanently deletes your Journal, recordings and dictionary.", hintDanger: true) {
                    model.options.userData.toggle()
                }
                if let dir = model.exportDir { exportOption(dir) }
            }
            WindowButtonRow {
                if model.isRecording {
                    Text("An active dictation will be discarded")
                        .font(RhemionStyle.font(11.5, .semibold)).foregroundStyle(RhemionStyle.danger)
                }
            } buttons: {
                RaisedButton(title: "Cancel", action: onCancel)
                RaisedButton(title: "Uninstall", danger: true, action: model.uninstall)
            }
        }
    }

    /// One option: the gold checkbox, the title, its size in a right-aligned tabular column, and one
    /// constant hint line under the title. The whole row is the hit target.
    private func option(_ key: WritableKeyPath<UninstallOptions, Bool>, _ title: String, hint: String? = nil,
                        hintDanger: Bool = false, enabled: Bool = true, toggle: @escaping () -> Void) -> some View {
        optionRow(key, title, enabled: enabled, toggle: toggle) {
            if let hint {
                Text(hint)
                    .font(RhemionStyle.font(11.5, hintDanger ? .semibold : .regular))
                    .foregroundStyle(hintDanger ? RhemionStyle.danger : RhemionStyle.secondary(dark))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func optionRow<Detail: View>(_ key: WritableKeyPath<UninstallOptions, Bool>, _ title: String, enabled: Bool = true,
                                         toggle: @escaping () -> Void, @ViewBuilder detail: () -> Detail) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Self.checkboxGap) {
            JournalCheckbox(on: model.options[keyPath: key])
                .frame(width: Self.checkboxColumn, alignment: .leading)
                .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 4 }
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Text(title).font(RhemionStyle.font(13, .semibold))
                        .foregroundStyle(enabled ? RhemionStyle.text(dark) : RhemionStyle.tertiary(dark))
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                    Text(model.sizeText(key)).font(RhemionStyle.font(13)).monospacedDigit()
                        .foregroundStyle(RhemionStyle.secondary(dark))
                }
                detail()
            }
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: toggle)
        .accessibilityAddTraits(.isButton)
    }

    /// The export option: one constant hint (ticked or not) and the folder always under it (with Show in
    /// Finder). The folder sits OUTSIDE the row's tap area, so "Show in Finder" never toggles the checkbox.
    private func exportOption(_ dir: URL) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            optionRow(\.export, "Delete exported transcripts", toggle: { model.options.export.toggle() }) {
                Text(model.exportHint)
                    .font(RhemionStyle.font(11.5)).foregroundStyle(RhemionStyle.secondary(dark))
                    .fixedSize(horizontal: false, vertical: true)
            }
            FolderView(url: dir, dark: dark).padding(.leading, Self.checkboxColumn + Self.checkboxGap)
        }
    }
}

/// The Uninstall operation pop-up's content, variant "Receipt" (shared with Clear Data): confirm — "Uninstall
/// Rhemion?", a receipt row per ticked option with its size ("Can't be recovered" on what can't), the plain
/// line, Cancel (default) · Uninstall (danger, 0.5 s guard); working — "Uninstalling…" and the five steps
/// with their marks (paced), no buttons; report — "Rhemion is uninstalled", a row per ticked option and
/// System, "Show all N items", Goodbye; kept / failure — the steps, what stayed (named, Show in Finder), Done;
/// stuck — the shared stuck state (Quit Rhemion). Goodbye closes the pop-up; the window plays the goodbye.
struct FarewellPopupView: View {
    @ObservedObject var model: FarewellModel
    @Environment(\.colorScheme) private var scheme
    private var dark: Bool { scheme == .dark }

    var body: some View {
        OperationPopupCard { content }
    }

    @ViewBuilder private var content: some View {
        switch model.phase {
        case .choose, .collapsing: EmptyView()
        case .confirm:
            OperationPopupTitle(text: "Uninstall Rhemion?")
            let lines = model.receiptLines
            if !lines.isEmpty { OperationReceipt(lines: lines, showPermanent: true) }
            Text(model.confirmNote).font(RhemionStyle.font(13)).foregroundStyle(RhemionStyle.secondary(dark))
                .fixedSize(horizontal: false, vertical: true)
            if model.isRecording {
                Text("An active dictation will be discarded")
                    .font(RhemionStyle.font(11.5, .semibold)).foregroundStyle(RhemionStyle.danger)
            }
            WindowButtonRow {
                if model.busy { BusyNote(dark: dark) }
            } buttons: {
                // Cancel is the default button (Return); Esc cancels too (OperationPanel). Return never uninstalls.
                RaisedButton(title: "Cancel", action: model.back).keyboardShortcut(.defaultAction)
                RaisedButton(title: "Uninstall", danger: true, action: model.confirmUninstall)
                    .disabled(!model.confirmReady)
            }
        case .working:
            OperationPopupTitle(text: "Uninstalling…")
            OperationReceipt(lines: model.stepLines, showPermanent: false)
        case .report(let report):
            OperationResultTitle(text: "Rhemion is uninstalled", dryRun: report.dryRun)
            OperationReceipt(lines: report.lines, showPermanent: false)
            RemovedItemsDisclosure(paths: report.removed, dark: dark)
            WindowButtonRow {
                RaisedButton(title: "Goodbye", action: model.goodbye).keyboardShortcut(.defaultAction)
            }
        case .kept(let files):
            OperationPopupTitle(text: "Some exported files were kept")
            OperationReceipt(lines: model.stepLines, showPermanent: false)
            Text(KeptFiles.lead(files.count)).font(RhemionStyle.font(12)).fixedSize(horizontal: false, vertical: true)
            if let dir = model.exportDir { FolderView(url: dir, dark: dark) }
            FailureList(lines: files, dark: dark)
            WindowButtonRow { RaisedButton(title: "Done", action: model.done).keyboardShortcut(.defaultAction) }
        case .failure(let lines):
            // The app may be half-removed, so Done quits.
            OperationPopupTitle(text: "Rhemion couldn't remove all data")
            OperationReceipt(lines: model.stepLines, showPermanent: false)
            FailureList(lines: lines, dark: dark)
            WindowButtonRow {
                RaisedButton(title: "Show in Finder") {
                    let target = FarewellModel.revealTarget(failures: lines, app: Bundle.main.bundleURL)
                    NSWorkspace.shared.activateFileViewerSelecting([target])
                }
                RaisedButton(title: "Done", action: model.done).keyboardShortcut(.defaultAction)
            }
        case .stuck(let message):
            StuckContent(message: message, dark: dark)
        }
    }
}
