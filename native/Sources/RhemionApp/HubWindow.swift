import AppKit
import SwiftUI
import RhemionIPC
import RhemionStorage

/// The three top-level destinations of the hub, in rail order.
enum HubDestination: Int, CaseIterable, Identifiable {
    case journal, dictionary, settings
    var id: Int { rawValue }
    var title: String {
        switch self {
        case .journal: return "Journal"
        case .dictionary: return "Dictionary"
        case .settings: return "Settings"
        }
    }
    /// SF Symbol shown in the rail.
    var symbol: String {
        switch self {
        case .journal: return "book.closed"
        case .dictionary: return "character.book.closed"
        case .settings: return "gearshape"
        }
    }
    /// ⌘-number that jumps to this destination (1-based, in rail order).
    var shortcut: Character { Character(String(rawValue + 1)) }
    /// Settings sits apart at the BOTTOM of the rail (the common macOS placement), away from the
    /// primary content destinations.
    var pinnedToBottom: Bool { self == .settings }
    static var topItems: [HubDestination] { allCases.filter { !$0.pinnedToBottom } }
    static var bottomItems: [HubDestination] { allCases.filter { $0.pinnedToBottom } }
}

/// The hub's observable state + settings dependencies. Kept in a model (not view @State) so the
/// controller can drive it — switch destination, push the runtime's device lists into the Settings
/// pickers — without rebuilding the view and resetting its selection.
@MainActor
final class HubModel: ObservableObject {
    @Published var dest: HubDestination = .journal
    @Published var settingsCategory: SettingsCategory = .general
    @Published var models: [ModelOption] = []
    @Published var mics: [MicOption] = []

    let current: () -> AppSettings
    let apply: (AppSettings) -> Void
    let beginRecording: () -> Void
    let endRecording: () -> Void
    /// Runtime socket for the embedded Journal (export-now / history-delete).
    let client: RuntimeClient
    /// The Journal's own model, owned here so it survives view rebuilds and the controller can reload it
    /// when the hub is shown / becomes key / switches to the Journal destination.
    let journal = JournalModel()
    /// The Dictionary's model, owned here for the same reason (reloaded on show / key / tab switch so a
    /// ⌘⌥W quick-add made while the hub is open is picked up).
    let dictionary = DictionaryModel()
    /// Speech-model provisioning state, shared with the onboarding Welcome (owned by AppController).
    let modelDownload: ModelDownloadModel
    /// Storage section actions (Settings › Advanced) — AppController points Uninstall at the farewell
    /// window and Clear Data at the Clear Data window. `showClearData` takes the model's builder: it is
    /// called only when the window isn't already open (an open one is just brought forward).
    var showUninstall: () -> Void = {}
    var showClearData: (() -> ClearDataModel) -> Void = { _ in }
    /// `AppController.runClearData(_:progress:)` — quiesce → delete the chosen categories → resume, or
    /// (with "Reset all settings") relaunch into Welcome. A closure (like `apply`) so the Settings pane
    /// can drive it without reaching back into AppController directly.
    let runClearData: ClearDataRun
    /// `AppController.runDeleteExport(turnOff:)` — quiesce → remove the registry-owned
    /// exported transcripts in the current export folder → (turn export Off) → resume.
    let runDeleteExport: (Bool) async -> OperationReport
    /// Snapshotted when a destructive sheet opens ("An active dictation will be discarded"), never
    /// subscribed to live.
    let isRecording: () -> Bool
    /// The storage barrier — the Storage section disables its buttons while it's up,
    /// and the sheets check it before starting (operations are mutually exclusive).
    let storageActivity: DataOperations
    var canStartStorageOperation: Bool { !storageActivity.inProgress }

    init(current: @escaping () -> AppSettings, apply: @escaping (AppSettings) -> Void,
         beginRecording: @escaping () -> Void, endRecording: @escaping () -> Void,
         client: RuntimeClient, modelDownload: ModelDownloadModel,
         runClearData: @escaping ClearDataRun,
         runDeleteExport: @escaping (Bool) async -> OperationReport,
         isRecording: @escaping () -> Bool,
         storageActivity: DataOperations) {
        self.current = current
        self.apply = apply
        self.beginRecording = beginRecording
        self.endRecording = endRecording
        self.client = client
        self.modelDownload = modelDownload
        self.runClearData = runClearData
        self.runDeleteExport = runDeleteExport
        self.isRecording = isRecording
        self.storageActivity = storageActivity
    }
}

/// Owns the single hub NSWindow. Mirrors the other window controllers: an NSHostingController root, a
/// Dock-icon flip while visible, and `isReleasedWhenClosed = false` so it is reused. The window title
/// tracks the current destination as "Rhemion — <Section>" (Settings also names the category).
@MainActor
final class HubWindowController: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    private let model: HubModel

    init(current: @escaping () -> AppSettings, apply: @escaping (AppSettings) -> Void,
         beginRecording: @escaping () -> Void, endRecording: @escaping () -> Void,
         client: RuntimeClient, modelDownload: ModelDownloadModel,
         runClearData: @escaping ClearDataRun,
         runDeleteExport: @escaping (Bool) async -> OperationReport,
         isRecording: @escaping () -> Bool,
         storageActivity: DataOperations) {
        model = HubModel(current: current, apply: apply, beginRecording: beginRecording,
                         endRecording: endRecording, client: client, modelDownload: modelDownload,
                         runClearData: runClearData,
                         runDeleteExport: runDeleteExport,
                         isRecording: isRecording,
                         storageActivity: storageActivity)
        super.init()
    }

    /// The Storage section's "Uninstall Rhemion…" — AppController points it at the farewell window.
    var showUninstall: () -> Void {
        get { model.showUninstall }
        set { model.showUninstall = newValue }
    }

    /// The Storage section's "Clear Data…" — AppController points it at the Clear Data window.
    var showClearData: (() -> ClearDataModel) -> Void {
        get { model.showClearData }
        set { model.showClearData = newValue }
    }

    /// Push the runtime's latest device lists into the Settings pickers; SwiftUI refreshes them in place
    /// (no view rebuild, so the open category/destination is preserved).
    func setDevices(models: [ModelOption], mics: [MicOption]) {
        model.models = models
        model.mics = mics
    }

    /// Show the hub, optionally jumping to a destination (e.g. Settings from the ⌘, menu item).
    func show(dest: HubDestination? = nil) {
        if let dest { model.dest = dest }
        if window == nil {
            let root = HubView(model: model, onTitle: { [weak self] title in self?.window?.title = title })
            let hosting = NSHostingController(rootView: root)
            hosting.sizingOptions = [.minSize]
            let window = NSWindow(contentViewController: hosting)
            window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
            window.setContentSize(NSSize(width: 1000, height: 660))
            // Wide enough that the embedded Journal keeps its ~860pt content beside the 52pt rail.
            window.minSize = NSSize(width: 924, height: 520)
            window.isReleasedWhenClosed = false
            window.delegate = self
            self.window = window
        }
        // Set the title here too: the view's initial onChange runs while the window is still being built
        // (window == nil), so on the first destination the title stayed "Untitled".
        window?.title = HubView.title(for: model)
        model.journal.reload()      // freshen the embedded Journal each time the hub is shown
        model.dictionary.reload()   // and the Dictionary (picks up ⌘⌥W quick-adds)
        AppController.shared?.setDockIconVisible(true)   // Dock icon + Cmd-Tab while the window is up
        NSApp.activate(ignoringOtherApps: true)
        window?.center()
        window?.makeKeyAndOrderFront(nil)
        log("hub window shown")
    }

    func windowDidBecomeKey(_ notification: Notification) { model.journal.reload(); model.dictionary.reload() }
    func windowWillClose(_ notification: Notification) { AppController.shared?.setDockIconVisible(false) }
}

/// The hub shell: a thin destination rail on the left and the destination body (Journal, Dictionary, or the
/// categorized Settings pane). No section-header band — the destination name lives in the native window
/// title, and each pane brings its own top-level chrome.
struct HubView: View {
    @ObservedObject var model: HubModel
    let onTitle: (String) -> Void
    @Environment(\.colorScheme) private var scheme
    private var dark: Bool { scheme == .dark }

    static func title(for model: HubModel) -> String {
        model.dest == .settings
            ? "Rhemion — Settings — \(model.settingsCategory.rawValue)"
            : "Rhemion — \(model.dest.title)"
    }
    private var titleText: String { Self.title(for: model) }

    /// Hover labels "warm up" like VS Code / macOS tooltips: the first one waits, then moving along the rail
    /// shows the next ones at once; leaving the rail cools them down again after a moment.
    @State private var labelsWarm = false
    @State private var coolTask: Task<Void, Never>?

    var body: some View {
        HStack(spacing: 0) {
            rail.zIndex(1)   // above the content, so the rail's hover labels can float over it
            Divider().overlay(RhemionStyle.line(dark))
            // No slim section header on any destination — the section name already lives in the native
            // window title, and each pane carries its own top-level chrome (Settings' category sidebar,
            // the Journal/Dictionary toolbars). The header band was just wasted vertical space.
            destinationBody
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(RhemionStyle.content(dark))
        }
        .frame(minWidth: 924, idealWidth: 1000, minHeight: 520, idealHeight: 660)
        .font(RhemionStyle.font(13))
        .foregroundStyle(RhemionStyle.text(dark))
        .tint(RhemionStyle.gold)
        .onChange(of: titleText, initial: true) { _, value in onTitle(value) }
        .onChange(of: model.dest) { _, value in
            if value == .journal { model.journal.reload() }
            if value == .dictionary { model.dictionary.reload() }
        }
    }

    private var rail: some View {
        VStack(spacing: 0) {
            ForEach(HubDestination.topItems) { railButton($0) }
            Spacer(minLength: 0)
            ForEach(HubDestination.bottomItems) { railButton($0) }   // Settings pinned to the bottom
        }
        .padding(.vertical, 4)
        .frame(width: 52)
        .onHover { inside in
            coolTask?.cancel()
            if !inside {
                coolTask = Task { @MainActor in
                    try? await Task.sleep(for: .seconds(1))
                    if !Task.isCancelled { labelsWarm = false }
                }
            }
        }
        .frame(maxHeight: .infinity)
        .background(RhemionStyle.rail(dark))
    }

    private func railButton(_ item: HubDestination) -> some View {
        RailButton(item: item, active: model.dest == item, dark: dark, warm: $labelsWarm) { model.dest = item }
            .keyboardShortcut(KeyEquivalent(item.shortcut), modifiers: .command)
    }

    @ViewBuilder private var destinationBody: some View {
        switch model.dest {
        case .settings:
            HubSettingsPane(model: model)
        case .journal:
            JournalView(model: model.journal, client: model.client)
        case .dictionary:
            HubDictionaryPane(model: model.dictionary)
        }
    }

    private var placeholder: some View {
        VStack(spacing: 10) {
            Image(systemName: model.dest.symbol)
                .font(.system(size: 30, weight: .regular))
                .foregroundStyle(RhemionStyle.tertiary(dark))
            Text("\(model.dest.title) appears here")
                .font(RhemionStyle.font(14, .semibold))
                .foregroundStyle(RhemionStyle.secondary(dark))
            Text("Shell preview — this pane fills in a later stage.")
                .font(RhemionStyle.font(12))
                .foregroundStyle(RhemionStyle.tertiary(dark))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(RhemionStyle.content(dark))
    }
}

/// One rail destination: an icon-only button in the exact style of the journal's segmented toggles — active =
/// a raised neutral tile with full-strength ink, idle = secondary ink, hover = the ink darkens (no fill).
/// The glyph weight never changes, so nothing jumps on switch. Hovering shows a label with the destination
/// and its ⌘-number, warming up like VS Code / macOS tooltips.
private struct RailButton: View {
    let item: HubDestination
    let active: Bool
    let dark: Bool
    @Binding var warm: Bool
    let action: () -> Void
    @State private var hover = false
    @State private var showLabel = false
    @State private var labelTask: Task<Void, Never>?

    var body: some View {
        Button(action: action) {
            Image(systemName: item.symbol)
                // The same recipe as the journal's segmented toggles (ViewModeToggle): idle = secondary ink,
                // active = full ink on a raised win tile with a 1 pt shadow, no hairline; hover only darkens the
                // icon (no fill). Light weight at 24 pt matches the stroke of the toolbar's 13 pt medium glyphs.
                .font(.system(size: 24, weight: .light))
                .frame(width: 40, height: 40)
                .foregroundStyle(active || hover ? RhemionStyle.text(dark) : RhemionStyle.secondary(dark))
                .animation(.easeOut(duration: 0.12), value: hover)
                .activeTile(active, dark: dark, radius: 10)
                .frame(width: 52, height: 48)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .overlay(alignment: .leading) {
            // starts just past the tile (tile spans 6…46 of the 52 pt row) and overlaps the rail's edge,
            // like Notes; centred on the icon
            if showLabel { label.offset(x: 49).allowsHitTesting(false).transition(.opacity) }
        }
        .onHover { inside in
            hover = inside
            labelTask?.cancel()
            if inside {
                if warm { showLabel = true; return }   // already warm: show at once while moving along the rail
                labelTask = Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(1500))
                    if !Task.isCancelled { withAnimation(.easeOut(duration: 0.12)) { showLabel = true }; warm = true }
                }
            } else {
                withAnimation(.easeOut(duration: 0.08)) { showLabel = false }
            }
        }
        .accessibilityLabel(item.title)
        .accessibilityHint("Command \(item.shortcut)")
        .accessibilityAddTraits(active ? [.isButton, .isSelected] : .isButton)
    }

    private var label: some View {
        HStack(spacing: 8) {
            Text(item.title).font(RhemionStyle.font(12, .semibold)).foregroundStyle(RhemionStyle.text(dark))
            Text("⌘\(item.shortcut)").font(RhemionStyle.font(12)).foregroundStyle(RhemionStyle.secondary(dark))
        }
        .padding(.horizontal, 10).padding(.vertical, 5)
        .background(RhemionStyle.win(dark), in: RoundedRectangle(cornerRadius: 7))
        .overlay { RoundedRectangle(cornerRadius: 7).strokeBorder(RhemionStyle.line(dark), lineWidth: 0.5) }
        .shadow(color: .black.opacity(dark ? 0.35 : 0.12), radius: 6, y: 2)
        .fixedSize()
    }
}
