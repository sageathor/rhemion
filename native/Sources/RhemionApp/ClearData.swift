// Clear Data — one window that
// replaces "Remove Downloaded Models" and "Reset Rhemion" (Settings › Advanced › Storage › Clear Data…), laid
// out on the standard of the Uninstall window (`WindowLayout`): a side column (the calm Welcome logo, the
// title, the "what stays" line, how much is freed and how many items, a quiet hint at the bottom) and a main
// column: preset selections and ONE list of categories grouped Free up space / Personal data / Settings,
// each row a gold checkbox, name, tag, size and a hint; Cancel / Delete…. The window only ever shows this
// selection, so its height never changes. Delete… opens the operation pop-up (DESIGN.md, "Operation
// pop-up"): a small borderless panel centred over the window — the "receipt" of what goes (confirm, 0.5 s
// guard), then each row's progress, then what was freed. `AppController.runClearData` does the work behind
// the quiesce barrier; only "Reset all settings" restarts the app.

import AppKit
import Combine
import RhemionStorage
import SwiftUI

typealias ClearItem = StorageOperations.ClearItem
/// `AppController.runClearData(_:progress:)`: deletes the selection; `progress` names the row being deleted.
typealias ClearDataRun = (Set<ClearItem>, @escaping @MainActor @Sendable (ClearItem) -> Void) async -> OperationReport

/// Drives one showing of the Clear Data window and its pop-up: choose → confirm → working → done.
@MainActor
final class ClearDataModel: ObservableObject, Identifiable {
    enum Phase: Equatable {
        /// The window's selection; no pop-up.
        case choose
        /// The pop-up's receipt with Cancel / Delete (0.5 s guard).
        case confirm
        case working
        case done(Outcome)
        case stuck(String)
    }

    struct Outcome: Equatable {
        /// What the run actually freed (`OperationReport.freedBytes`: measured right before each removal).
        var freed: Int64 = 0
        /// The pop-up rows that actually lost something in the plan that ran (or the settings, once reset) —
        /// ticked in the result (`OperationReport.clearedRows`).
        var deleted: Set<ClearItem> = []
        var failures: [String] = []
        /// Exported notes Rhemion couldn't confirm as its own (only when Exported transcripts was chosen).
        var kept: [String] = []
        /// Settings were being reset and it didn't finish: "only partly reset" (the button restarts anyway).
        var mustRestart = false
        /// "Reset all settings" was chosen: the result's button is "Restart Rhemion" instead of Done — it
        /// performs the restart (a real reset no longer quits mid-progress).
        var restart = false
        /// Every path removed (in a dry run: that would have been) — "Show all N items".
        var removed: [String] = []
        /// A dry run: the result says "Dry run — nothing was removed".
        var dryRun = false
    }

    /// One line of the pop-up's receipt: name · detail (secondary) · size (right, tabular).
    struct ReceiptRow: Equatable, Identifiable {
        let item: ClearItem
        let name: String
        let detail: String?
        let size: String
        /// "Can't be recovered" on the confirmation (Journal, Recordings, Dictionary, Exported transcripts).
        let permanent: Bool
        var id: ClearItem { item }
    }

    /// A receipt row's mark (the shared operation pop-up's): `notDone` is a row that lost nothing.
    typealias RowStatus = OperationRowStatus

    struct Group {
        let title: String
        let items: [ClearItem]
    }

    static let groups = [
        Group(title: "Free up space", items: [.recordings, .unusedModels, .modelInUse, .logs, .cache]),
        Group(title: "Personal data", items: [.journal, .dictionary, .exportedTranscripts]),
        Group(title: "Settings", items: [.settings]),
    ]

    enum Preset: String, CaseIterable {
        case freeUpSpace = "Free Up Space", erasePersonalData = "Erase Personal Data", startOver = "Start Over"
        var items: Set<ClearItem> {
            switch self {
            case .freeUpSpace: return [.unusedModels, .logs, .cache]
            case .erasePersonalData: return [.recordings, .journal, .dictionary, .exportedTranscripts, .logs]
            case .startOver: return Set(ClearItem.allCases).subtracting([.exportedTranscripts])
            }
        }
    }

    let id = UUID()
    @Published private(set) var phase: Phase = .choose
    @Published private(set) var selection: Set<ClearItem> = [] { didSet { updateFreed() } }
    /// What the selection deletes, each byte once (`updateFreed`); nil while sizes are calculating.
    /// Stored, so a render reads it instead of walking the items.
    @Published private(set) var freedBytes: Int64?
    /// Recordings were ticked BY the Journal (not by hand) — unticking the Journal releases them.
    private var recordingsAuto = false
    /// Per-category sizes; nil while calculating.
    @Published private(set) var sizes: [ClearItem: Int64]? { didSet { updateFreed() } }
    /// Categories that have anything on disk (an empty one is disabled and reads "None").
    @Published private(set) var present: Set<ClearItem> = []
    @Published private(set) var counts = StorageOperations.ClearCounts()
    @Published private(set) var unusedNames: [String] = []
    @Published private(set) var busy = false
    @Published private(set) var confirmReady = false
    private var confirmEnteredAt: Date?
    private var itemSizes: [StorageItem: Int64] = [:]
    /// Each category's items as of the last `load()` — the freed total dedupes across them.
    private var categoryItems: [ClearItem: [StorageItem]] = [:]
    private var generation = 0

    let layout: StorageLayout
    /// Exported transcripts is offered only when export is configured or the registry owns files there.
    /// Decided synchronously at init (`StorageLayout.showsExportRow`: a registry read, no rendering), so the
    /// row never pops in after the sizes.
    let showsExport: Bool
    /// The display name of the model dictation actually runs on (`StorageLayout.effectiveModel`); the
    /// setting's name until `load()` has looked at the disk.
    @Published private(set) var modelName: String
    private let modelLabels: [String: String]
    let replacements: Int
    let isRecording: Bool
    private let canStart: () -> Bool
    private let run: ClearDataRun
    private let pacingClock: any PacingClock
    /// Called once the deletion actually ran (any result but busy/stuck): the pane refreshes its sizes.
    private let onRan: () -> Void

    /// `modelLabels`: model id → display name (the runtime's list); an unknown id shows as itself.
    init(layout: StorageLayout, exportMode: String, modelLabels: [String: String], replacements: Int, isRecording: Bool,
         canStart: @escaping () -> Bool, run: @escaping ClearDataRun,
         onRan: @escaping () -> Void = {}, pacingClock: any PacingClock = SystemPacingClock()) {
        self.layout = layout
        self.pacingClock = pacingClock
        self.modelLabels = modelLabels
        let selected = layout.selectedModel.trimmingCharacters(in: .whitespacesAndNewlines)
        modelName = modelLabels[selected] ?? selected
        showsExport = layout.showsExportRow(exportMode: exportMode)
        self.replacements = replacements
        self.isRecording = isRecording
        self.canStart = canStart
        self.run = run
        self.onRan = onRan
    }

    var visible: [ClearItem] { ClearItem.allCases.filter { $0 != .exportedTranscripts || showsExport } }

    // MARK: sizes

    /// Walks every category off the main actor; a newer call supersedes an older one (generation guard).
    func load() {
        sizes = nil
        generation += 1
        let gen = generation
        let layout = self.layout, labels = self.modelLabels
        Task.detached(priority: .utility) {
            var per: [ClearItem: Int64] = [:], present = Set<ClearItem>(), itemSizes: [StorageItem: Int64] = [:]
            var categoryItems: [ClearItem: [StorageItem]] = [:]
            for c in ClearItem.allCases {
                let items = StorageOperations.clearItems(c, layout)
                categoryItems[c] = items
                if !items.isEmpty { present.insert(c) }
                per[c] = items.reduce(Int64(0)) { total, item in
                    let s = itemSizes[item] ?? StorageSizes.size(of: item)
                    itemSizes[item] = s
                    return total + s
                }
            }
            let counts = StorageOperations.clearCounts(layout)
            let unused = ClearDataModel.modelNames(layout.modelItems().unused)
            let effective = layout.effectiveModel
            await MainActor.run {
                guard self.generation == gen else { return }
                self.itemSizes = itemSizes; self.categoryItems = categoryItems
                self.present = present; self.counts = counts
                self.unusedNames = unused; self.modelName = labels[effective] ?? effective
                self.sizes = per
                // A preset picked while calculating: keep only what exists and is shown.
                self.selection.formIntersection(present.union([.settings]))
                if !self.selection.contains(.recordings) { self.recordingsAuto = false }
            }
        }
    }

    /// Humanized names of model artifacts: "Parakeet v2", "Whisper large-v3-turbo", "Whisper silence
    /// model" (a Core ML encoder goes with its model and isn't named).
    nonisolated static func modelNames(_ items: [StorageItem]) -> [String] {
        var out: [String] = []
        for item in items {
            let name = item.relative.last ?? ""
            let label: String?
            if name.hasPrefix("parakeet-") { label = "Parakeet " + (name.split(separator: "-").last.map(String.init) ?? name) }
            else if name.hasSuffix(".mlmodelc") { label = nil }
            else if StorageLayout.isSilenceModel(name) { label = "Whisper silence model" }
            else { label = "Whisper " + StorageLayout.whisperID(forFile: name).dropFirst("whisper-".count) }
            if let label, !out.contains(label) { out.append(label) }
        }
        return out
    }

    // MARK: selection

    func isEnabled(_ c: ClearItem) -> Bool { c == .settings || sizes == nil || present.contains(c) }
    func isLocked(_ c: ClearItem) -> Bool { c == .recordings && selection.contains(.journal) }
    func isOn(_ c: ClearItem) -> Bool { selection.contains(c) }

    func toggle(_ c: ClearItem) {
        guard phase == .choose, isEnabled(c), !isLocked(c) else { return }
        if selection.contains(c) {
            selection.remove(c)
            if c == .journal && recordingsAuto { selection.remove(.recordings); recordingsAuto = false }
        } else {
            selection.insert(c)
            if c == .journal && !selection.contains(.recordings) && isEnabled(.recordings) {
                selection.insert(.recordings); recordingsAuto = true
            }
        }
    }

    /// A preset REPLACES the selection (the checkboxes show the result); it never acts by itself. While
    /// sizes are still calculating Exported transcripts may not be shown yet — it's kept, and `load()`
    /// drops it if it turns out to be hidden or empty.
    func apply(_ preset: Preset) {
        guard phase == .choose else { return }
        selection = preset.items.filter { (sizes == nil || visible.contains($0)) && isEnabled($0) }
        recordingsAuto = false
    }

    func deselectAll() {
        guard phase == .choose else { return }
        selection = []
        recordingsAuto = false
    }

    // MARK: words

    func sizeText(_ c: ClearItem) -> String {
        if c == .settings { return "" }
        guard let sizes else { return "Calculating…" }
        guard present.contains(c) else { return "None" }
        return ByteSize.string(sizes[c] ?? 0)
    }

    static func title(_ c: ClearItem) -> String {
        switch c {
        case .recordings: return "Recordings"
        case .unusedModels: return "Unused models"
        case .modelInUse: return "Model in use"
        case .logs: return "Logs"
        case .cache: return "Cache"
        case .journal: return "Journal"
        case .dictionary: return "Dictionary"
        case .exportedTranscripts: return "Exported transcripts"
        case .settings: return "Reset all settings"
        }
    }

    /// The small tag after a row's name: tertiary, danger once ticked.
    static func tag(_ c: ClearItem) -> String? {
        switch c {
        case .recordings, .journal, .dictionary, .exportedTranscripts: return "Permanent"
        case .modelInUse: return "Stops dictation"
        default: return nil
        }
    }

    /// The permanent one-line hint under a row's name.
    func hint(_ c: ClearItem) -> String {
        switch c {
        case .recordings: return "Audio of your dictations. Transcripts stay."
        case .unusedModels:
            let names = unusedNames.count > 2 ? unusedNames.prefix(2).joined(separator: ", ") + " and more"
                                              : unusedNames.joined(separator: " and ")
            return names.isEmpty ? "Models dictation doesn't use. Dictation keeps working." : "\(names). Dictation keeps working."
        case .modelInUse: return "Downloaded again when needed."
        case .logs: return "Diagnostic records. New ones start automatically."
        case .cache: return "Temporary files. Safe to delete."
        case .journal: return "Every transcript and its recording."
        case .dictionary: return "Your word replacements."
        case .exportedTranscripts: return "Only files Rhemion wrote in your export folder."
        case .settings: return "Back to defaults. Rhemion restarts into Welcome."
        }
    }

    /// Recomputes `freedBytes` when the selection or the sizes change: the chosen categories' items
    /// (Journal with its recordings), deduplicated by location (`StorageOperations.deduplicated`) — so
    /// Journal and Recordings, or anything reached twice, never count the same bytes twice.
    private func updateFreed() {
        guard sizes != nil else { if freedBytes != nil { freedBytes = nil }; return }
        var chosen = selection
        if chosen.contains(.journal) { chosen.insert(.recordings) }
        let items = StorageOperations.deduplicated(ClearItem.allCases.filter(chosen.contains).flatMap { categoryItems[$0] ?? [] })
        let total = items.reduce(Int64(0)) { $0 + (itemSizes[$1] ?? 0) }
        if freedBytes != total { freedBytes = total }
    }

    /// The side column's big number: "0 KB" with nothing selected, "Calculating…" while sizes load.
    var freedText: String {
        guard !selection.isEmpty else { return ByteSize.string(0) }
        return freedBytes.map(ByteSize.string) ?? "Calculating…"
    }

    /// "will be freed · N of M items" — M is every category shown.
    var countText: String { "will be freed · \(selection.count) of \(visible.count) items" }

    /// The selection a preset gives right now (what `apply` would select).
    func presetSelection(_ p: Preset) -> Set<ClearItem> {
        p.items.filter { (sizes == nil || visible.contains($0)) && isEnabled($0) }
    }

    /// The one "what stays" line under the numbers (concept 3 of clear-data-kind).
    var message: String {
        if selection.isEmpty { return "What stays is up to you." }
        if selection == presetSelection(.freeUpSpace) { return "Your words stay. The extras go." }
        if selection == presetSelection(.erasePersonalData) { return "The model stays. Your saved words go." }
        if selection == presetSelection(.startOver) { return "Only your exported transcripts stay." }
        if selection.contains(.modelInUse) { return "Your current model goes too. You can download it again." }
        return "Everything you don't tick stays."
    }

    private static func count(_ n: Int, _ one: String, _ many: String) -> String { "\(n) \(n == 1 ? one : many)" }

    // MARK: the pop-up's receipt

    /// "Delete the cache?" for the cache alone, otherwise "Delete selected data?".
    var confirmTitle: String { selection == [.cache] ? "Delete the cache?" : "Delete selected data?" }

    /// The pop-up's rows: each chosen category in list order (Recordings chosen with the Journal are part of
    /// the Journal's row, not a row of their own), with what it holds and its size.
    var receiptRows: [ReceiptRow] {
        ClearItem.allCases.filter(selection.contains).compactMap { c in
            if c == .recordings && selection.contains(.journal) { return nil }
            return ReceiptRow(item: c, name: c == .settings ? "Settings" : Self.title(c), detail: detail(c),
                              size: rowSize(c), permanent: c.irreversible && c != .modelInUse)
        }
    }

    private func detail(_ c: ClearItem) -> String? {
        switch c {
        case .recordings: return Self.count(counts.recordings, "file", "files")
        case .journal:
            return Self.count(counts.entries, "entry", "entries")
                + (counts.recordings > 0 ? ", " + Self.count(counts.recordings, "recording", "recordings") : "")
        case .dictionary: return Self.count(replacements, "replacement", "replacements")
        case .exportedTranscripts: return Self.count(counts.exported, "file", "files")
        case .modelInUse: return modelName
        case .unusedModels: return unusedNames.isEmpty ? nil : unusedNames.joined(separator: ", ")
        case .logs: return Self.count(counts.logs, "file", "files")
        case .cache: return nil
        case .settings: return "back to defaults"
        }
    }

    /// A row's size; the Journal's includes its recordings (each byte once).
    private func rowSize(_ c: ClearItem) -> String {
        guard c == .journal, selection.contains(.recordings), sizes != nil else { return sizeText(c) }
        let items = StorageOperations.deduplicated((categoryItems[.journal] ?? []) + (categoryItems[.recordings] ?? []))
        return ByteSize.string(items.reduce(Int64(0)) { $0 + (itemSizes[$1] ?? 0) })
    }

    /// Under the rows when Model in use goes: what that means for dictation.
    var modelInUseNote: String? {
        selection.contains(.modelInUse) ? "Dictation stops until \(modelName) is downloaded again." : nil
    }

    /// What the rows show while deleting: `run`'s progress, paced so each row is seen running and done.
    /// The first row is under way from the start (while the engine is being stopped).
    @Published private(set) var shown = PacedStep(index: 0, done: false)

    func status(_ row: ClearItem) -> RowStatus {
        switch phase {
        case .working:
            guard let index = receiptRows.firstIndex(where: { $0.item == row }) else { return .waiting }
            return shown.status(index)
        case .done(let o): return o.deleted.contains(row) ? .done : .notDone
        default: return .dot
        }
    }

    // MARK: flow

    /// "Delete…": opens the pop-up's confirmation (always — even the cache alone is confirmed there). When
    /// another storage operation is running, the confirmation says so and Delete waits for it.
    func delete() {
        guard phase == .choose, !selection.isEmpty else { return }
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

    /// Valid only from `.confirm`, and only 0.5 s after it appeared — a double click on Delete… can't land here.
    func confirmDelete() {
        guard phase == .confirm else { return }
        guard let enteredAt = confirmEnteredAt, Date().timeIntervalSince(enteredAt) >= 0.5 else { return }
        guard canStart() else { busy = true; return }
        busy = false
        start()
    }

    /// Cancel on the confirmation closes the pop-up, keeping the choice.
    func back() {
        guard phase == .confirm else { return }
        phase = .choose
        busy = false
        confirmEnteredAt = nil
        confirmReady = false
    }

    /// The pop-up is up for every step after the choice.
    var showsPopup: Bool { phase != .choose }

    /// Whether the window's close button may close it now: only on the choice — while the pop-up is up it
    /// is the only way on (Cancel, Done, Restart Rhemion, Quit Rhemion).
    var canCloseWindow: Bool { phase == .choose }

    private func start() {
        phase = .working
        let chosen = selection
        let rows = receiptRows.map(\.item)
        let pacer = ProgressPacer(count: rows.count, clock: pacingClock) { [weak self] in self?.shown = $0 }
        pacer.start()
        Task {
            let report = await run(chosen) { [weak self] row in
                guard let self, self.phase == .working, let index = rows.firstIndex(of: row) else { return }
                pacer.advance(to: index)
            }
            if report.failures == [AppController.busyMessage] {
                pacer.stop()
                busy = true
                phase = .confirm   // the pop-up stays on its confirmation, saying why
            } else if report.removed.isEmpty && report.failures == [AppController.quiesceStuckMessage] {
                pacer.stop()
                phase = .stuck(report.failures[0])
            } else {
                // The ticks and the freed size come from the plan that actually ran (built behind the
                // barrier), not the lists of when the window opened; a row that lost nothing is never ticked
                // on the way (the rows catch up at a pace the eye can follow).
                let cleared = report.clearedRows.intersection(rows)
                await pacer.finish(notDone: Set(rows.indices.filter { !cleared.contains(rows[$0]) }))
                phase = .done(Outcome(freed: report.freedBytes,
                                      deleted: cleared,
                                      failures: report.failures,
                                      kept: chosen.contains(.exportedTranscripts) ? report.unconfirmedExport : [],
                                      mustRestart: chosen.contains(.settings) && !cleared.contains(.settings),
                                      restart: chosen.contains(.settings),
                                      removed: report.removed, dryRun: report.dryRun))
                onRan()
            }
        }
    }
}

/// Owns the single Clear Data window and its operation pop-up. The window: titled "Clear Data",
/// sized to its content, centred on the screen under the pointer, the Dock icon on while it's up; opened
/// from Settings › Advanced › Storage; a second "Clear Data…" while it's open only brings it forward. It
/// can be closed only on the choice. The pop-up: a borderless panel (our 12 pt radius, the window shadow),
/// a child of the window centred over it and re-centred as its height follows the content; while it is up
/// the window takes no input and hands the key focus back to the pop-up.
@MainActor
final class ClearDataWindowController: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    private let popup = OperationPopupHost()
    private var model: ClearDataModel?
    private var phaseWatch: AnyCancellable?
    private let restart: () -> Void

    init(restart: @escaping () -> Void) {
        self.restart = restart
        super.init()
    }

    var isShowing: Bool { window?.isVisible == true }

    /// Shows `make()`'s model — built only when the window isn't already up (then it's brought forward).
    func show(_ make: () -> ClearDataModel) {
        if let window, window.isVisible {
            NSApp.activate(ignoringOtherApps: true)
            if !popup.refocus() { window.makeKeyAndOrderFront(nil) }
            return
        }
        let model = make()
        self.model = model
        let root = ClearDataView(model: model, onCancel: { [weak self] in self?.cancelChoice() })
        let hosting = NSHostingController(rootView: root)
        hosting.sizingOptions = [.preferredContentSize]
        let window = self.window ?? NSWindow(contentViewController: hosting)
        window.contentViewController = hosting
        window.title = "Clear Data"
        window.styleMask = [.titled, .closable]
        window.isReleasedWhenClosed = false
        window.delegate = self
        self.window = window
        // The pop-up follows the phase; the close button reads disabled while it is up.
        phaseWatch = model.$phase.receive(on: RunLoop.main).sink { [weak self, weak model] _ in
            guard let self, let model else { return }
            self.window?.standardWindowButton(.closeButton)?.isEnabled = model.canCloseWindow
            if model.showsPopup { self.showPopup(model) } else { self.closePopup() }
        }
        model.load()
        AppController.shared?.setDockIconVisible(true)
        NSApp.activate(ignoringOtherApps: true)
        centerOnPointerScreen(window)
        window.makeKeyAndOrderFront(nil)
    }

    private func showPopup(_ model: ClearDataModel) {
        guard !popup.isShowing, let window else { return }
        let view = ClearDataPopupView(model: model,
                                      onDone: { [weak self] in self?.closeWindow() },
                                      onRestart: { [weak self] in self?.restart(); self?.closeWindow() })
        popup.show(view, over: window, onCancel: { [weak model] in model?.back() })
    }

    private func closePopup() { popup.close() }

    /// Cancel (or Esc) on the choice: only while the choice is all there is (`canCloseWindow`) — never the
    /// window behind a running pop-up — and through `performClose`, so `windowShouldClose` has the last word.
    private func cancelChoice() {
        guard model?.canCloseWindow == true else { return }
        window?.performClose(nil)
    }

    /// Done / Restart Rhemion on the result: the pop-up and the window go together.
    private func closeWindow() {
        closePopup()
        window?.close()
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool { model?.canCloseWindow ?? true }

    /// A click on the window while the pop-up is up gives the key focus straight back to the pop-up.
    func windowDidBecomeKey(_ notification: Notification) {
        popup.refocus()
    }

    func windowWillClose(_ notification: Notification) {
        closePopup()
        phaseWatch = nil
        model = nil
        AppController.shared?.setDockIconVisible(false)
    }
}

/// The window's content — the selection only. App controls only (DESIGN.md): presets and Cancel are Raised
/// R1, Delete… is Raised R1 with danger ink, Deselect All is the text link, the rows are the gold
/// `JournalCheckbox`. Red marks only the destructive button and the ticked rows' tags. Margins and fonts:
/// `WindowLayout`. While the pop-up is up it takes no input.
struct ClearDataView: View {
    @ObservedObject var model: ClearDataModel
    let onCancel: () -> Void
    @StateObject private var clock = WelcomeLogoClock()
    @StateObject private var focusVisibility = KeyboardFocusVisibility()
    @Environment(\.colorScheme) private var scheme
    private var dark: Bool { scheme == .dark }

    private static let width: CGFloat = 820
    /// The rows' hover fill reaches this far past the column's margins, so the checkboxes and names sit on
    /// the standard edge while the fill still has room around them.
    private static let rowInset: CGFloat = 6
    static let hint = "Old recordings and transcripts can be cleaned up automatically in Settings › Journal."

    var body: some View {
        StandardWindow(width: Self.width) { sideColumn } main: { chooseContent }
            .environmentObject(focusVisibility)
            .allowsHitTesting(model.phase == .choose)
            .disabled(model.phase != .choose)   // also no Return / keyboard / VoiceOver press behind the pop-up
            .onExitCommand { if model.phase == .choose { onCancel() } }
            .onAppear { clock.restart(); focusVisibility.start() }
            .onDisappear { focusVisibility.stop() }
    }

    /// The "what stays" line, then the freed size and the count.
    private var sideColumn: some View {
        WindowSideColumn(clock: clock, title: "Clear Rhemion Data", subtitle: model.message, hint: Self.hint) {
            VStack(alignment: .leading, spacing: 2) {
                Text(model.freedText).font(RhemionStyle.font(26, .heavy)).monospacedDigit()
                    .foregroundStyle(model.selection.isEmpty || model.freedBytes == nil ? RhemionStyle.tertiary(dark) : RhemionStyle.text(dark))
                    .lineLimit(1).minimumScaleFactor(0.6)
                Text(model.countText).font(RhemionStyle.font(12)).monospacedDigit()
                    .foregroundStyle(RhemionStyle.secondary(dark))
            }
            .accessibilityElement(children: .combine)
        }
    }

    private var chooseContent: some View {
        VStack(alignment: .leading, spacing: WindowLayout.blockGap) {
            presetRow
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(ClearDataModel.groups.enumerated()), id: \.offset) { index, group in
                    let items = group.items.filter(model.visible.contains)
                    if !items.isEmpty {
                        GroupLabel(title: group.title, dark: dark)
                            .padding(EdgeInsets(top: index == 0 ? 0 : 12, leading: Self.rowInset, bottom: 2, trailing: Self.rowInset))
                        ForEach(items, id: \.self) { item in ClearRow(item: item, model: model, dark: dark) }
                    }
                }
            }
            .padding(.horizontal, -Self.rowInset)
            buttonRow
        }
    }

    private var presetRow: some View {
        HStack(spacing: 6) {
            Text("Select:").font(RhemionStyle.font(11.5)).foregroundStyle(RhemionStyle.tertiary(dark)).padding(.trailing, 2)
            ForEach(ClearDataModel.Preset.allCases, id: \.self) { preset in
                RaisedButton(title: preset.rawValue) { model.apply(preset) }
            }
            Spacer(minLength: 8)
            TextLink(title: "Deselect All", action: model.deselectAll)
                .disabled(model.selection.isEmpty)
        }
    }

    /// Cancel (the default: Return / Esc) and Delete… — no summary. The left side holds only the at-open
    /// "active dictation" note.
    private var buttonRow: some View {
        WindowButtonRow {
            if model.isRecording {
                Text("An active dictation will be discarded")
                    .font(RhemionStyle.font(11.5, .semibold)).foregroundStyle(RhemionStyle.danger)
            }
        } buttons: {
            // Cancel is the default button (Return / Esc); Return never deletes.
            RaisedButton(title: "Cancel", action: onCancel).keyboardShortcut(.defaultAction)
            RaisedButton(title: "Delete…", danger: true, action: model.delete)
                .disabled(model.selection.isEmpty)
        }
    }
}

/// The operation pop-up's content, variant "Receipt" (operation-popup.html): a title, the receipt rows,
/// then per step — confirm: the model line (danger), "Everything else stays.", Cancel (default) · Delete
/// (danger, 0.5 s guard); deleting: a status mark on every row, no buttons; done: "<size> freed", rows
/// ticked, kept files / failures only when there are any, Done (or Restart Rhemion). Stuck: the shared
/// stuck state (Quit Rhemion).
struct ClearDataPopupView: View {
    @ObservedObject var model: ClearDataModel
    let onDone: () -> Void
    let onRestart: () -> Void
    @Environment(\.colorScheme) private var scheme
    private var dark: Bool { scheme == .dark }

    var body: some View {
        OperationPopupCard { content }
    }

    @ViewBuilder private var content: some View {
        switch model.phase {
        case .choose: EmptyView()
        case .confirm:
            title(model.confirmTitle)
            rows(showPermanent: true)
            if let note = model.modelInUseNote {
                Text(note).font(RhemionStyle.font(12.5)).foregroundStyle(RhemionStyle.danger)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text("Everything else stays.").font(RhemionStyle.font(13)).foregroundStyle(RhemionStyle.secondary(dark))
            if model.isRecording {
                Text("An active dictation will be discarded")
                    .font(RhemionStyle.font(11.5, .semibold)).foregroundStyle(RhemionStyle.danger)
            }
            WindowButtonRow {
                if model.busy { BusyNote(dark: dark) }
            } buttons: {
                // Cancel is the default button (Return); Esc cancels too (OperationPanel). Return never deletes.
                RaisedButton(title: "Cancel", action: model.back).keyboardShortcut(.defaultAction)
                RaisedButton(title: "Delete", danger: true, action: model.confirmDelete)
                    .disabled(!model.confirmReady)
            }
        case .working:
            title("Deleting selected data…")
            rows(showPermanent: false)
        case .done(let o):
            OperationResultTitle(text: "\(ByteSize.string(o.freed)) freed", dryRun: o.dryRun)
            rows(showPermanent: false)
            RemovedItemsDisclosure(paths: o.removed, dark: dark)
            if !o.kept.isEmpty {
                Text(KeptFiles.lead(o.kept.count)).font(RhemionStyle.font(12)).fixedSize(horizontal: false, vertical: true)
                if let dir = model.layout.exportDir { FolderView(url: dir, dark: dark) }
                FailureList(lines: o.kept, dark: dark)
            }
            if !o.failures.isEmpty {
                GroupLabel(title: "Not deleted", dark: dark)
                FailureList(lines: o.failures, dark: dark)
            }
            if o.mustRestart {
                Text("Settings were only partly reset. Restart Rhemion to continue.")
                    .font(RhemionStyle.font(12)).foregroundStyle(RhemionStyle.secondary(dark))
                    .fixedSize(horizontal: false, vertical: true)
            }
            WindowButtonRow {
                if o.restart { RaisedButton(title: "Restart Rhemion", action: onRestart).keyboardShortcut(.defaultAction) }
                else { RaisedButton(title: "Done", action: onDone).keyboardShortcut(.defaultAction) }
            }
        case .stuck(let message):
            StuckContent(message: message, dark: dark)
        }
    }

    private func title(_ text: String) -> some View { OperationPopupTitle(text: text) }

    private func rows(showPermanent: Bool) -> some View {
        OperationReceipt(lines: model.receiptRows.map { row in
            OperationReceiptLine(id: row.item.rawValue, name: row.name, detail: row.detail, size: row.size,
                                 permanent: row.permanent, status: model.status(row.item))
        }, showPermanent: showPermanent)
    }
}

/// `:focus-visible` for the window: keyboard focus is shown (the gold outline) only after the user moved
/// with the keyboard (Tab, Shift-Tab, arrows) — never on open, and never after a click until the keyboard
/// moves again.
@MainActor
final class KeyboardFocusVisibility: ObservableObject {
    @Published private(set) var visible = false
    private var monitor: Any?

    func start() {
        guard monitor == nil else { return }
        visible = false
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .leftMouseDown]) { [weak self] event in
            // Tab, arrows (left/right/down/up) — the keys that move focus.
            let navigation: Set<UInt16> = [48, 123, 124, 125, 126]
            let show = event.type == .keyDown ? (navigation.contains(event.keyCode) ? true : nil) : false
            if let show { MainActor.assumeIsolated { self?.visible = show } }
            return event
        }
    }

    func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }
}

/// One category: a real toggle for keyboard and VoiceOver (checkbox value, Space toggles, focus stays on
/// the row because its identity is stable) drawn as the gold checkbox, the name (+ the model, or "with
/// Journal"), a small tag (tertiary; danger once ticked), the size, and a permanent one-line hint. Not a
/// Button: a plain-style Button takes keyboard focus only with Full Keyboard Access on, so the row is its
/// own focusable view (Tab reaches it) and handles click and Space itself. The system focus ring is off;
/// a gold outline marks keyboard focus only (`KeyboardFocusVisibility`).
private struct ClearRow: View {
    let item: ClearItem
    @ObservedObject var model: ClearDataModel
    let dark: Bool
    @EnvironmentObject private var focusVisibility: KeyboardFocusVisibility
    @State private var hover = false
    @FocusState private var focused: Bool

    var body: some View {
        let on = model.isOn(item), locked = model.isLocked(item), enabled = model.isEnabled(item)
        let active = enabled && !locked
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            JournalCheckbox(on: on).frame(width: 18, alignment: .leading).opacity(enabled ? (locked ? 0.55 : 1) : 0.5)
                .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 4 }
            VStack(alignment: .leading, spacing: 1) {
                HStack(alignment: .firstTextBaseline, spacing: 0) {
                    Text(ClearDataModel.title(item)).font(RhemionStyle.font(13, .semibold))
                        .foregroundStyle(enabled ? RhemionStyle.text(dark) : RhemionStyle.tertiary(dark))
                    if item == .modelInUse {
                        Text(" · \(model.modelName)").font(RhemionStyle.font(11.5)).foregroundStyle(RhemionStyle.secondary(dark))
                    }
                    if locked {
                        Text(" with Journal").font(RhemionStyle.font(11.5)).foregroundStyle(RhemionStyle.secondary(dark))
                    }
                    if let tag = ClearDataModel.tag(item) {
                        Text(tag).font(RhemionStyle.font(10.5, .semibold)).tracking(0.2)
                            .foregroundStyle(on ? RhemionStyle.danger : RhemionStyle.tertiary(dark))
                            .padding(.leading, 6)
                    }
                }
                .lineLimit(1)
                // Hints wrap to a second line rather than truncate (e.g. a long list of unused models).
                Text(model.hint(item)).font(RhemionStyle.font(11.5)).foregroundStyle(RhemionStyle.secondary(dark))
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 6)
            Text(model.sizeText(item)).font(RhemionStyle.font(12.5)).monospacedDigit()
                .foregroundStyle(model.sizes == nil || !enabled ? RhemionStyle.tertiary(dark) : RhemionStyle.secondary(dark))
        }
        .padding(6)
        .background(hover && active ? RhemionStyle.hover(dark) : .clear, in: RoundedRectangle(cornerRadius: 7))
        .contentShape(Rectangle())
        .overlay {
            if focused && focusVisibility.visible {
                RoundedRectangle(cornerRadius: 7).strokeBorder(RhemionStyle.gold, lineWidth: 1.75)
            }
        }
        .onTapGesture { if active { model.toggle(item) } }
        .focusable(active)
        .focusEffectDisabled()
        .focused($focused)
        .onKeyPress(.space) {
            guard active else { return .ignored }
            model.toggle(item); return .handled
        }
        .onHover { hover = $0 }
        .disabled(!active)   // VoiceOver reads it dimmed, as the Button did
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(ClearDataModel.title(item) + (item == .modelInUse ? ", \(model.modelName)" : ""))
        .accessibilityValue(on ? "checked" : "unchecked")
        .accessibilityHint(locked ? "Included with the Journal" : model.hint(item) + " " + model.sizeText(item))
        .accessibilityAddTraits(.isToggle)
        .accessibilityAction { if active { model.toggle(item) } }
    }
}
