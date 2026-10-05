// Settings pane for the hub. The flat single-Form settings window is reorganized into a
// category sidebar (General / Shortcuts / Audio & Model / Recording / Journal) + a native grouped Form
// per category. Controls are native SwiftUI form rows, regrouped by category.
//
// Apply-on-change (System Settings style): every edit calls `model.apply`, which persists the snapshot
// and re-applies live. Labels are English (command-labels-English); the recognition LANGUAGE options
// name human languages and are content, not UI chrome.

import AppKit
import SwiftUI
import RhemionIPC
import RhemionStorage

/// The five settings categories, in sidebar order.
enum SettingsCategory: String, CaseIterable, Identifiable {
    case general = "General"
    case shortcuts = "Shortcuts"
    case audio = "Audio & Model"
    case recording = "Recording"
    case journal = "Journal"
    case advanced = "Advanced"
    var id: String { rawValue }
    var symbol: String {
        switch self {
        case .general: return "slider.horizontal.3"
        case .shortcuts: return "keyboard"
        case .audio: return "waveform"
        case .recording: return "mic"
        case .journal: return "book.closed"
        case .advanced: return "wrench.and.screwdriver"
        }
    }
}

struct HubSettingsPane: View {
    @ObservedObject var model: HubModel
    @State private var settings: AppSettings
    @StateObject private var storage = StorageModel()
    /// The export-deletion sheet (Journal › Export) — from the quiet action under the
    /// Export folder field, or from switching export Off while Rhemion still owns files there.
    @State private var exportSheet: ExportDeleteSheetModel?
    /// Whether the registry owns files in the current export folder (shows the delete action). Refreshed
    /// when the Journal category appears, when the folder changes and after a deletion — not per render.
    @State private var exportOwned = false
    @Environment(\.colorScheme) private var scheme
    private var dark: Bool { scheme == .dark }

    init(model: HubModel) {
        self.model = model
        _settings = State(initialValue: model.current())
    }

    var body: some View {
        HStack(spacing: 0) {
            categorySidebar
            Divider().overlay(RhemionStyle.line(dark))
            Form { sections }
                .formStyle(.grouped)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        // Settings is Equatable, so this fires once per edit; the app persists + live-applies it.
        .onChange(of: settings) { _, updated in model.apply(updated) }
        .sheet(item: $exportSheet) { sheetModel in
            ExportDeleteSheet(model: sheetModel, dark: dark,
                              onCancel: { exportSheet = nil },
                              onKeep: { settings.exportMode = "off"; exportSheet = nil },
                              onFinished: { exportSheet = nil })
        }
    }

    // A group title in the mockup's weight (bold, sentence case — not the default small-caps header).
    private func groupHeader(_ title: String) -> some View {
        Text(title).font(RhemionStyle.font(13, .bold)).foregroundStyle(RhemionStyle.text(dark)).textCase(nil)
    }

    // The footer under a section's card: an optional caption plus the dirty-only "Restore defaults" link
    // (a gold text link with the rotate icon, shown only when the category differs from its defaults).
    @ViewBuilder private func sectionFooter(_ caption: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            if let caption {
                Text(caption).font(RhemionStyle.font(11)).foregroundStyle(RhemionStyle.secondary(dark))
            }
            if isDirty(model.settingsCategory) {
                TextLink(title: "Restore defaults", systemImage: "arrow.counterclockwise") { restore(model.settingsCategory) }
            }
        }.textCase(nil).padding(.top, 2)
    }

    // MARK: category sidebar

    private var categorySidebar: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(SettingsCategory.allCases) { category in
                let on = model.settingsCategory == category
                Button { model.settingsCategory = category } label: {
                    HStack(spacing: 9) {
                        Image(systemName: category.symbol).frame(width: 18)
                        Text(category.rawValue)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 10).padding(.vertical, 7)
                    .contentShape(RoundedRectangle(cornerRadius: 7))
                }
                .buttonStyle(.plain)
                .font(RhemionStyle.font(13, on ? .semibold : .regular))
                .foregroundStyle(on ? RhemionStyle.text(dark) : RhemionStyle.secondary(dark))
                .background(on ? RhemionStyle.selected(dark) : .clear, in: RoundedRectangle(cornerRadius: 7))
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .frame(width: 190)
        .frame(maxHeight: .infinity)
        .background(RhemionStyle.rail(dark))
    }

    // MARK: category sections

    @ViewBuilder private var sections: some View {
        switch model.settingsCategory {
        case .general:    generalSection
        case .shortcuts:  shortcutsSection
        case .audio:      audioSection
        case .recording:  recordingSection
        case .journal:    journalSection
        case .advanced:   advancedSection
        }
    }

    @ViewBuilder private var generalSection: some View {
        Section {
            SettingRow(title: "Launch at login", description: "Start Rhemion when you sign in.") {
                Toggle("", isOn: $settings.launchAtLogin).labelsHidden()
            }
            pttBindings
            SettingRow(title: "Text insertion", description: "Direct types the text; Clipboard pastes it.") {
                BoxedPicker(selection: $settings.inputMethod,
                            options: AppSettings.inputMethodOptions.map { SettingsChoice(id: $0, label: Self.inputLabel($0)) })
            }
            SettingRow(title: "Recognition language", description: "Auto detects, or force one language.") {
                BoxedPicker(selection: $settings.language,
                            options: AppSettings.languageOptions.map { SettingsChoice(id: $0, label: Self.languageLabel($0)) })
            }
        } header: { groupHeader("Startup & input") }
        Section {
            SettingRow(title: "Theme", description: "Light, dark, or follow the system.") {
                ThemeSegmented(selection: $settings.theme)
            }
            SettingRow(title: "Recording indicator", description: "Where the orb appears while recording. Auto uses the notch on notched Macs, otherwise a floating pill.") {
                BoxedPicker(selection: $settings.indicatorStyle,
                            options: [SettingsChoice(id: "auto", label: "Auto"), SettingsChoice(id: "notch", label: "Notch"), SettingsChoice(id: "floating", label: "Floating")])
            }
        } header: { groupHeader("Appearance") } footer: { sectionFooter() }
    }

    private var shortcutsSection: some View {
        Section {
            hotkeyBindings("Recall", "Re-insert your last dictation.", $settings.recallHotkeys)
            hotkeyBindings("Dictionary add", "Add the selection as a replacement.", $settings.dictAddHotkeys)
            hotkeyBindings("Undo replacement", "Revert the last dictionary replacement.", $settings.undoHotkeys)
        } header: { groupHeader("Shortcuts") } footer: { sectionFooter() }
    }

    // MARK: multi-binding editors (the recorder — × inside the field, square "+" on the last
    // row; PTT is a stack of boxed pickers with the same add/remove model).

    // Push-to-talk — one or more device modifiers; any of them starts dictation.
    private var pttBindings: some View {
        SettingRow(title: "Push-to-talk key", description: "Hold to dictate; release to insert.", field: true) {
            PTTBindingStack(keys: $settings.pttKeys, label: Self.pttLabel)
        }
    }

    // A global chord action — one or more chords; any of them fires it.
    private func hotkeyBindings(_ title: String, _ description: String, _ specs: Binding<[String]>) -> some View {
        SettingRow(title: title, description: description, field: true) {
            HotkeyBindingStack(specs: specs, onBeginRecording: model.beginRecording, onEndRecording: model.endRecording)
        }
    }

    @ViewBuilder private var audioSection: some View {
        Section {
            SettingRow(title: "Recognition model", description: "The engine that turns speech into text.") {
                BoxedPicker(selection: $settings.model, options: modelChoices)
            }
            SettingRow(title: "Speech model (Parakeet)",
                       description: "Download the on-device recognition engine once (~\(model.modelDownload.approxSizeMB) MB). Works offline afterward; audio and transcripts stay on your Mac.",
                       wide: true) {
                SpeechModelSettingValue(model: model.modelDownload)
            }
            SettingRow(title: "Microphone", description: "Automatic picks the best available input.") {
                BoxedPicker(selection: $settings.audioMicrophone, options: micChoices)
            }
        } header: { groupHeader("Recognition") } footer: {
            Text("The model and microphone apply from your next dictation — no restart. The lists come from the runtime; a change takes effect immediately.")
                .font(RhemionStyle.font(11)).foregroundStyle(RhemionStyle.secondary(dark)).textCase(nil)
        }
        Section {
            SettingRow(title: "Whisper binary", description: "Used only for the Whisper engine.", field: true) {
                PathField(path: $settings.whisperBinary, placeholder: "Choose file…",
                          chooseDirectory: false, canRemove: false, clearOrRemove: { settings.whisperBinary = "" })
            }
            SettingRow(title: "Model folders", description: "Extra folders scanned for Whisper models.", field: true) {
                PathBindingStack(initial: modelDirList, placeholder: "Choose folder…") { list in
                    settings.modelDirs = list.filter { !$0.isEmpty }.joined(separator: ":")
                }
            }
        } header: { groupHeader("Whisper") } footer: {
            sectionFooter("Whisper only — Parakeet loads from its own cache, no path needed. Extra folders are scanned for whisper models; a newly found one appears in the picker, but using it takes effect after you restart Rhemion (switching between already-loaded models applies on your next dictation).")
        }
    }

    @ViewBuilder private var recordingSection: some View {
        Section {
            SettingRow(title: "Double-Esc window", description: "Max gap between the two Esc presses.") {
                StepperBox(value: $settings.escDoubleTapMS, range: 200...600, step: 50) { "\($0) ms" }
            }
            SettingRow(title: "Reversal window", description: "How long undo and the double-Esc erase stay available.") {
                StepperBox(value: $settings.undoTTLSecs, range: 1...120) { "\($0) s" }
            }
        } header: { groupHeader("Cancel (double-Esc)") } footer: {
            Text("Press Esc twice within this window to cancel a recording, or erase the just-inserted text.")
                .font(RhemionStyle.font(11)).foregroundStyle(RhemionStyle.secondary(dark)).textCase(nil)
        }
        Section {
            SettingRow(title: "Silence before countdown", description: "Silence this long starts the auto-stop countdown.") {
                StepperBox(value: $settings.handsfreeCountdownAfterSecs, range: 5...600, step: 5) { "\($0) s" }
            }
            SettingRow(title: "Countdown length", description: "Countdown before recording auto-stops.") {
                StepperBox(value: $settings.handsfreeCountdownSecs, range: 3...120) { "\($0) s" }
            }
        } header: { groupHeader("Hands-free") } footer: {
            sectionFooter("In hands-free mode a countdown starts after silence, then auto-stops. Speak again to keep going.")
        }
    }

    @ViewBuilder private var journalSection: some View {
        Section {
            SettingRow(title: "Export mode", description: "When transcripts are written to the folder. Off disables export entirely.") {
                BoxedPicker(selection: exportModeBinding,
                            options: [SettingsChoice(id: "auto", label: "Auto"), SettingsChoice(id: "manual", label: "Manual"), SettingsChoice(id: "scheduled", label: "Scheduled"), SettingsChoice(id: "off", label: "Off")])
            }
            if settings.exportMode == "scheduled" {
                SettingRow(title: "Interval", description: "How often scheduled exports run.") {
                    BoxedPicker(selection: $settings.exportSchedule,
                                options: [SettingsChoice(id: "hourly", label: "Hourly"), SettingsChoice(id: "daily", label: "Daily"), SettingsChoice(id: "weekly", label: "Weekly")])
                }
            }
            if settings.exportMode != "off" {
                SettingRow(title: "Export folder", description: "Where transcript notes are written.", field: true) {
                    VStack(alignment: .leading, spacing: 8) {
                        PathField(path: exportDirBinding, placeholder: "Choose folder…",
                                  chooseDirectory: true, canRemove: false, clearOrRemove: { exportDirBinding.wrappedValue = "" })
                        if exportOwned {
                            ExportDeleteLink(activity: model.storageActivity) { showExportDelete(turningOff: false) }
                                .padding(.leading, 2)
                        }
                    }
                }
            }
        } header: { groupHeader("Export") }
        .onAppear { refreshExportOwned() }
        .onChange(of: settings.exportDir) { _, _ in refreshExportOwned() }
        Section {
            retentionRow("Keep local audio", "Delete recordings older than this.", value: $settings.audioRetentionValue, unit: $settings.audioRetentionUnit)
            retentionRow("Keep transcripts", "Delete entries older than this.", value: $settings.transcriptRetentionValue, unit: $settings.transcriptRetentionUnit)
        } header: { groupHeader("Cleanup") } footer: {
            sectionFooter("Off = keep forever. Audio expiry removes only the local WAV (the transcript stays); transcript expiry removes the whole entry — record, its audio, and its line in the exported note.")
        }
    }

    // MARK: restore-defaults (per category, shown only when dirty)

    private func isDirty(_ category: SettingsCategory) -> Bool {
        let d = AppSettings()
        switch category {
        case .general:
            return settings.launchAtLogin != d.launchAtLogin || settings.pttKeys != d.pttKeys
                || settings.inputMethod != d.inputMethod || settings.language != d.language
                || settings.theme != d.theme || settings.indicatorStyle != d.indicatorStyle
        case .shortcuts:
            return settings.recallHotkeys != d.recallHotkeys || settings.dictAddHotkeys != d.dictAddHotkeys
                || settings.undoHotkeys != d.undoHotkeys
        case .audio:
            return settings.model != d.model || settings.audioMicrophone != d.audioMicrophone
                || settings.whisperBinary != d.whisperBinary || settings.modelDirs != d.modelDirs
        case .recording:
            return settings.escDoubleTapMS != d.escDoubleTapMS || settings.undoTTLSecs != d.undoTTLSecs
                || settings.handsfreeCountdownAfterSecs != d.handsfreeCountdownAfterSecs
                || settings.handsfreeCountdownSecs != d.handsfreeCountdownSecs
        case .journal:
            return settings.exportMode != d.exportMode
                || settings.exportSchedule != d.exportSchedule || settings.exportDir != d.exportDir
                || settings.audioRetentionValue != d.audioRetentionValue || settings.audioRetentionUnit != d.audioRetentionUnit
                || settings.transcriptRetentionValue != d.transcriptRetentionValue || settings.transcriptRetentionUnit != d.transcriptRetentionUnit
        case .advanced:
            return false   // Diagnostics + Storage: nothing to restore
        }
    }

    private func restore(_ category: SettingsCategory) {
        let d = AppSettings()
        switch category {
        case .general:
            settings.launchAtLogin = d.launchAtLogin; settings.pttKeys = d.pttKeys
            settings.inputMethod = d.inputMethod; settings.language = d.language; settings.theme = d.theme
            settings.indicatorStyle = d.indicatorStyle
        case .shortcuts:
            settings.recallHotkeys = d.recallHotkeys; settings.dictAddHotkeys = d.dictAddHotkeys
            settings.undoHotkeys = d.undoHotkeys
        case .audio:
            settings.model = d.model; settings.audioMicrophone = d.audioMicrophone
            settings.whisperBinary = d.whisperBinary; settings.modelDirs = d.modelDirs
        case .recording:
            settings.escDoubleTapMS = d.escDoubleTapMS; settings.undoTTLSecs = d.undoTTLSecs
            settings.handsfreeCountdownAfterSecs = d.handsfreeCountdownAfterSecs
            settings.handsfreeCountdownSecs = d.handsfreeCountdownSecs
        case .journal:
            settings.exportMode = d.exportMode
            settings.exportSchedule = d.exportSchedule; settings.exportDir = d.exportDir; settings.exportInitialized = false
            settings.audioRetentionValue = d.audioRetentionValue; settings.audioRetentionUnit = d.audioRetentionUnit
            settings.transcriptRetentionValue = d.transcriptRetentionValue; settings.transcriptRetentionUnit = d.transcriptRetentionUnit
        case .advanced:
            break
        }
    }

    @ViewBuilder private var advancedSection: some View {
        Section {
            SettingRow(title: "Application log", description: "Open the app's log file for troubleshooting.", wide: true) {
                Button { NSWorkspace.shared.open(AppPaths.logURL) } label: {
                    Label("Open app.log", systemImage: "doc.text").font(RhemionStyle.font(12, .medium))
                        .foregroundStyle(RhemionStyle.text(dark))
                        .padding(.horizontal, 11).padding(.vertical, 6)
                        .background(RhemionStyle.win(dark), in: RoundedRectangle(cornerRadius: 8))
                        .overlay { RoundedRectangle(cornerRadius: 8).strokeBorder(RhemionStyle.line(dark), lineWidth: 0.5) }
                        .shadow(color: .black.opacity(dark ? 0.22 : 0.06), radius: 1.5, y: 1)
                }.buttonStyle(.plain).fixedSize()
            }
        } header: { groupHeader("Diagnostics") }
        StorageSection(model: storage, activity: model.storageActivity, dark: dark,
                       onClearData: showClearData,
                       onUninstall: { model.showUninstall() })
            .onAppear { storage.refresh(settings: settings) }
    }

    // MARK: option lists + folder pickers (ported from the flat settings window)

    // Installed models the runtime can run, plus the current selection kept selectable even if the list
    // hasn't arrived yet or the saved model isn't present (so the Picker never blanks).
    private var modelChoices: [SettingsChoice] {
        var out: [SettingsChoice] = []
        var seen = Set<String>()
        for m in model.models where m.found && seen.insert(m.id).inserted {
            out.append(SettingsChoice(id: m.id, label: m.label))
        }
        if seen.insert(settings.model).inserted {
            out.append(SettingsChoice(id: settings.model, label: model.models.first { $0.id == settings.model }?.label ?? settings.model))
        }
        return out
    }

    // "Automatic" + every connected input device, plus the saved device if it isn't currently present
    // (marked unavailable) so the Picker keeps showing the user's choice.
    private var micChoices: [SettingsChoice] {
        var out: [SettingsChoice] = [SettingsChoice(id: "auto", label: "Automatic")]
        var seen: Set<String> = ["auto"]
        for d in model.mics where seen.insert(d.uid).inserted {
            out.append(SettingsChoice(id: d.uid, label: d.builtIn ? "\(d.name) (built-in)" : d.name))
        }
        if seen.insert(settings.audioMicrophone).inserted {
            out.append(SettingsChoice(id: settings.audioMicrophone, label: "\(settings.audioMicrophone) (unavailable)"))
        }
        return out
    }

    // model_dirs is one colon-separated string (wire format); the UI edits it as a list.
    private var modelDirList: [String] {
        settings.modelDirs.split(separator: ":").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    // Switching export Off while Rhemion owns files in the folder asks first (keep or delete them); with
    // nothing of Rhemion's there it switches silently. Cancel leaves the mode as it was.
    // Export starts off with no folder: turning it on without one asks for the folder first, and
    // cancelling the panel keeps export off.
    private var exportModeBinding: Binding<String> {
        Binding(get: { settings.exportMode },
                set: { mode in
                    if mode == "off", settings.exportMode != "off", showExportDelete(turningOff: true) { return }
                    if mode != "off", settings.exportDir.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        guard let folder = chooseExportFolder() else { return }
                        exportDirBinding.wrappedValue = folder
                    }
                    settings.exportMode = mode
                })
    }

    private func chooseExportFolder() -> String? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.prompt = "Choose"
        panel.message = "Choose the folder for exported transcripts."
        return panel.runModal() == .OK ? panel.url?.path : nil
    }

    /// Opens the Clear Data window for the current settings: the layout (with the selected model), the
    /// model names from the runtime's list (the window labels the EFFECTIVE model with them), and the
    /// dictionary's replacement count, as of now. An open window is only brought forward.
    private func showClearData() {
        let settings = self.settings, storage = self.storage, model = self.model
        let exportOwned = $exportOwned
        model.showClearData {
            let labels = Dictionary(model.models.map { ($0.id, $0.label) }, uniquingKeysWith: { first, _ in first })
            return ClearDataModel(layout: AppPaths.storageLayout(settings: settings), exportMode: settings.exportMode,
                                  modelLabels: labels, replacements: DictionaryStore.load().entries.count,
                                  isRecording: model.isRecording(), canStart: { model.canStartStorageOperation },
                                  run: model.runClearData,
                                  onRan: {
                                      // The pane may have been closed meanwhile; refresh what it shows anyway.
                                      storage.refresh(settings: model.current())
                                      exportOwned.wrappedValue = ExportOwnership.current(model.current()) != nil
                                  })
        }
    }

    private func refreshExportOwned() { exportOwned = ExportOwnership.current(settings) != nil }

    /// Opens the export-deletion sheet for what Rhemion owns in the current folder right now; false (no
    /// sheet) when it owns nothing there.
    @discardableResult private func showExportDelete(turningOff: Bool) -> Bool {
        guard let ownership = ExportOwnership.current(settings) else { exportOwned = false; return false }
        exportSheet = ExportDeleteSheetModel(
            ownership: ownership, turningOff: turningOff, canStart: { model.canStartStorageOperation },
            run: model.runDeleteExport,
            onRan: {
                // The controller already persisted export Off before resuming; mirror it here (the
                // resulting apply re-saves the same value) so the pane shows it at once.
                if turningOff { settings.exportMode = "off" }
                storage.refresh(settings: settings)
                refreshExportOwned()
            })
        return true
    }

    // Changing the export folder resets the runtime's one-time migration flag (a new folder starts fresh).
    private var exportDirBinding: Binding<String> {
        Binding(get: { settings.exportDir },
                set: { settings.exportDir = $0; settings.exportInitialized = false })
    }

    private func retentionRow(_ title: String, _ description: String, value: Binding<Int>, unit: Binding<String>) -> some View {
        SettingRow(title: title, description: description) {
            HStack(spacing: 8) {
                StepperBox(value: value, range: 0...3650) { $0 == 0 ? "Off" : "\($0)" }
                // The unit qualifies the number: while "Off" it's meaningless, so it's DISABLED and dimmed
                // (not hidden — keeps the row stable and the choice discoverable, macOS HIG). Fixed width so
                // days / weeks / months line up.
                BoxedPicker(selection: unit, options: AppSettings.retentionUnitOptions.map { SettingsChoice(id: $0, label: $0) }, width: 96)
                    .disabled(value.wrappedValue == 0)
                    .opacity(value.wrappedValue == 0 ? 0.5 : 1)
            }
        }
    }

    private static func pttLabel(_ key: String) -> String {
        switch key {
        case "right_option":  return "Right Option"
        case "left_option":   return "Left Option"
        case "right_cmd":     return "Right Command"
        case "left_cmd":      return "Left Command"
        case "right_control": return "Right Control"
        case "left_control":  return "Left Control"
        case "right_shift":   return "Right Shift"
        case "left_shift":    return "Left Shift"
        case "fn":            return "Fn (Globe)"
        default:              return key
        }
    }

    private static func inputLabel(_ method: String) -> String {
        switch method {
        case "direct":    return "Direct (type)"
        case "clipboard": return "Clipboard (paste)"
        default:          return method
        }
    }

    private static func languageLabel(_ language: String) -> String {
        switch language {
        case "auto": return "Auto"
        case "ru":   return "Russian"
        case "en":   return "English"
        default:     return language
        }
    }
}

private struct SettingsChoice: Identifiable, Hashable { let id: String; let label: String }

/// The trailing zone width for compact controls (pickers, toggle, steppers).
let hubZone: CGFloat = 190
/// THE field column: every path field and every shortcut field sits in one fixed,
/// right-aligned column, so left edges line up in every row and section. 340 pt holds the longest current
/// value in full (the export folder: "history" + "iCloud Drive › Notes › assets › rhemion" ≈ 336 pt
/// with icon, ×, padding) and still leaves ~270 pt for the title/description at the window's minimum width.
let hubFieldColumn: CGFloat = 340
let hubPlus: CGFloat = 30      // the square "+"
let hubStackGap: CGFloat = 6   // field ↔ "+" and row ↔ row in a stack
/// Every field of a multi-value stack (Model folders, every shortcut stack) has this one width, so the
/// "+" beside the LAST field ends exactly where a single field ends.
let hubStackField: CGFloat = hubFieldColumn - hubStackGap - hubPlus
let hubFieldHeight: CGFloat = 30

/// A settings row: title + one-line description on the left, a trailing control on the right (matches
/// the mockup's inset-grouped rows).
/// - `field`: the control sits in THE field column (`hubFieldColumn`, path + shortcut fields).
/// - `wide`: the control fills the available row width (the speech-model row, the log button).
/// - otherwise it sits in the compact `hubZone`-wide trailing zone, right-aligned.
private struct SettingRow<Control: View>: View {
    let title: String
    var description: String? = nil
    var wide: Bool = false
    var field: Bool = false
    @ViewBuilder let control: () -> Control
    @Environment(\.colorScheme) private var scheme
    private var dark: Bool { scheme == .dark }

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(RhemionStyle.font(13)).foregroundStyle(RhemionStyle.text(dark))
                if let description {
                    Text(description).font(RhemionStyle.font(11)).foregroundStyle(RhemionStyle.secondary(dark))
                }
            }
            Spacer(minLength: 12)
            if field {
                control().frame(width: hubFieldColumn, alignment: .leading)
            } else {
                control()
                    .layoutPriority(wide ? 1 : 0)
                    .frame(maxWidth: wide ? .infinity : hubZone, alignment: .trailing)
            }
        }
        .padding(.vertical, 3)
    }
}

/// A boxed pop-up (native menu on open; boxed value + a single up/down chevron closed) — the mockup's
/// picker. The box lives on the outer HStack (a menu label's own background is ignored under the
/// borderless style), and the native menu indicator is hidden so only our chevron shows.
private struct BoxedPicker: View {
    @Binding var selection: String
    let options: [SettingsChoice]
    var compact: Bool = false      // content-width; else fills the zone
    var width: CGFloat? = nil      // an explicit fixed width (e.g. equal-width day/week/month qualifiers)
    @Environment(\.colorScheme) private var scheme
    @State private var anchor: NSView?
    private var dark: Bool { scheme == .dark }
    private var currentLabel: String { options.first { $0.id == selection }?.label ?? selection }
    // The value fills the box unless it's purely content-sized (compact without a fixed width).
    private var valueFills: Bool { width != nil || !compact }

    var body: some View {
        // Our boxed look (value LEFT, chevron RIGHT); tapping opens OUR gold menu in its own panel.
        Button {
            if let anchor { HubMenuPanel.shared.show(anchor: anchor, options: options, selected: selection, dark: dark) { selection = $0 } }
        } label: {
            HStack(spacing: 7) {
                Text(currentLabel).font(RhemionStyle.font(12, .medium))
                    .foregroundStyle(RhemionStyle.text(dark)).lineLimit(1).truncationMode(.tail)
                    .frame(maxWidth: valueFills ? .infinity : nil, alignment: .leading)
                Image(systemName: "chevron.down").font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(RhemionStyle.secondary(dark))
            }
            .padding(.horizontal, 10).frame(maxWidth: valueFills ? .infinity : nil, minHeight: hubFieldHeight)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .modifier(BoxWidth(width: width, compact: compact))
        .background(RhemionStyle.win(dark), in: RoundedRectangle(cornerRadius: 7))
        .overlay { RoundedRectangle(cornerRadius: 7).strokeBorder(RhemionStyle.line(dark), lineWidth: 1) }
        .background(FieldAnchor { anchor = $0 })
    }
}

/// Sizes a boxed control: a fixed `width` if given, else content-width when compact, else fill.
private struct BoxWidth: ViewModifier {
    let width: CGFloat?
    let compact: Bool
    func body(content: Content) -> some View {
        if let width { content.frame(width: width) }
        else if compact { content.fixedSize(horizontal: true, vertical: false) }
        else { content.frame(maxWidth: .infinity) }
    }
}

/// Theme picker as a 3-icon segmented control (System / Light / Dark) — instantly readable. The selected
/// segment is a raised neutral surface (the app's "on" language), not an accent fill.
private struct ThemeSegmented: View {
    @Binding var selection: String     // "system" | "light" | "dark"
    @Environment(\.colorScheme) private var scheme
    private var dark: Bool { scheme == .dark }
    private let items: [(id: String, icon: String, help: String)] = [
        ("system", "display", "System"),
        ("light", "sun.max", "Light"),
        ("dark", "moon", "Dark"),
    ]

    var body: some View {
        HStack(spacing: 2) {
            ForEach(items, id: \.id) { item in
                let on = selection == item.id
                Button { selection = item.id } label: {
                    Image(systemName: item.icon).font(.system(size: 13, weight: .medium))
                        .foregroundStyle(on ? RhemionStyle.text(dark) : RhemionStyle.secondary(dark))
                        .frame(width: 36, height: 24)
                        .activeTile(on, dark: dark, radius: 6)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain).help(item.help).accessibilityLabel(item.help).accessibilityAddTraits(on ? [.isButton, .isSelected] : .isButton)
            }
        }
        .padding(2)
        .background(RhemionStyle.hover(dark), in: RoundedRectangle(cornerRadius: 8))
    }
}

/// A bordered "− value +" stepper box (the mockup's stepper) — the value + unit sits between the two
/// segment buttons, clamped to `range`.
private struct StepperBox: View {
    @Binding var value: Int
    let range: ClosedRange<Int>
    var step: Int = 1
    let format: (Int) -> String
    @Environment(\.colorScheme) private var scheme
    private var dark: Bool { scheme == .dark }

    var body: some View {
        HStack(spacing: 0) {
            segment("minus") { value = max(range.lowerBound, value - step) }
            Divider().frame(height: 18).overlay(RhemionStyle.line(dark))
            Text(format(value)).font(RhemionStyle.font(12, .medium)).monospacedDigit()
                .foregroundStyle(RhemionStyle.text(dark)).frame(minWidth: 52).padding(.horizontal, 4)
            Divider().frame(height: 18).overlay(RhemionStyle.line(dark))
            segment("plus") { value = min(range.upperBound, value + step) }
        }
        .frame(height: hubFieldHeight)
        .background(RhemionStyle.win(dark), in: RoundedRectangle(cornerRadius: 7))
        .overlay { RoundedRectangle(cornerRadius: 7).strokeBorder(RhemionStyle.line(dark), lineWidth: 1) }
    }

    private func segment(_ symbol: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 10, weight: .semibold))
                .foregroundStyle(RhemionStyle.secondary(dark)).frame(width: 28, height: hubFieldHeight).contentShape(Rectangle())
        }.buttonStyle(.plain)
    }
}

// MARK: - Multi-binding controls 
//
// One action can have several bindings. The × lives INSIDE the field: with one field it CLEARS the
// value, with several it REMOVES that row. A square "+" on the LAST row adds an alternative (its column
// is reserved on the other rows so the fields stay aligned).

/// A stack of chord recorder fields for one action.
private struct HotkeyBindingStack: View {
    @Binding var specs: [String]
    let onBeginRecording: () -> Void
    let onEndRecording: () -> Void
    @Environment(\.colorScheme) private var scheme
    private var dark: Bool { scheme == .dark }
    private let maxBindings = 8

    var body: some View {
        VStack(alignment: .leading, spacing: hubStackGap) {
            ForEach(specs.indices, id: \.self) { index in
                HStack(spacing: hubStackGap) {
                    HotkeyField(spec: binding(index), canRemove: specs.count > 1,
                                clearOrRemove: { clearOrRemove(index) },
                                onBeginRecording: onBeginRecording, onEndRecording: onEndRecording)
                        .frame(width: hubStackField)
                    if index == specs.count - 1 {
                        HubSquareAdd(dark: dark, active: specs.count < maxBindings) { specs.append("off") }
                    }
                }
            }
        }
    }

    private func clearOrRemove(_ i: Int) {
        if specs.count > 1 { specs.remove(at: i) } else if specs.indices.contains(i) { specs[i] = "off" }
    }
    private func binding(_ i: Int) -> Binding<String> {
        Binding(get: { specs.indices.contains(i) ? specs[i] : "off" },
                set: { if specs.indices.contains(i) { specs[i] = $0 } })
    }
}

/// One recorder field: click to record (Esc cancels, with a live modifier preview), key-caps when set,
/// an inline × that clears (lone) or removes (one of several). Writes only specs HotkeySpec can parse.
private struct HotkeyField: View {
    @Binding var spec: String
    let canRemove: Bool
    let clearOrRemove: () -> Void
    let onBeginRecording: () -> Void
    let onEndRecording: () -> Void
    @Environment(\.colorScheme) private var scheme
    @State private var recording = false
    @State private var monitor: Any?
    @State private var preview: [String] = []
    private var dark: Bool { scheme == .dark }
    private var caps: [String] { HotkeySpec.caps(spec) }
    private var hasValue: Bool { !HotkeySpec.isDisabled(spec) }
    // × acts only when it can: remove (several rows) or clear a lone field that holds a value.
    private var showClear: Bool { canRemove || hasValue }

    var body: some View {
        HStack(spacing: 6) {
            capsArea
            if showClear {
                Button(action: clearTapped) {
                    Image(systemName: "xmark").font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(RhemionStyle.tertiary(dark)).frame(width: 18, height: 18).contentShape(Circle())
                }
                .buttonStyle(.plain).help(canRemove ? "Remove" : "Clear")
            }
        }
        .padding(.horizontal, 9).frame(maxWidth: .infinity).frame(height: hubFieldHeight)
        .background(RhemionStyle.win(dark), in: RoundedRectangle(cornerRadius: 7))
        .overlay {
            RoundedRectangle(cornerRadius: 7)
                .strokeBorder(recording ? RhemionStyle.gold : RhemionStyle.line(dark), lineWidth: recording ? 2 : 1)
        }
        .onDisappear { stop() }
    }

    private var capsArea: some View {
        HStack(spacing: 4) {
            if recording {
                ForEach(preview.indices, id: \.self) { kbd(preview[$0]) }
                Text(preview.isEmpty ? "Type shortcut…" : "…")
                    .font(RhemionStyle.font(12)).foregroundStyle(RhemionStyle.tertiary(dark))
            } else if caps.isEmpty {
                Text("Record Shortcut").font(RhemionStyle.font(12)).foregroundStyle(RhemionStyle.tertiary(dark))
            } else {
                ForEach(caps.indices, id: \.self) { kbd(caps[$0]) }
            }
            Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
        .onTapGesture { recording ? stop() : start() }
    }

    private func kbd(_ symbol: String) -> some View {
        Text(symbol).font(RhemionStyle.font(11, .semibold)).foregroundStyle(RhemionStyle.text(dark))
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(RhemionStyle.hover(dark), in: RoundedRectangle(cornerRadius: 5))
            .overlay { RoundedRectangle(cornerRadius: 5).strokeBorder(RhemionStyle.line(dark), lineWidth: 1) }
    }

    private func clearTapped() { if recording { stop() }; clearOrRemove() }

    private func start() {
        onBeginRecording()   // suspend the global hotkey so the current chord can be re-recorded
        recording = true; preview = []
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { event in
            if event.type == .flagsChanged { preview = HotkeySpec.modifierCaps(event.modifierFlags); return nil }
            if event.keyCode == 53 { stop(); return nil }   // Esc cancels
            if let captured = HotkeySpec.spec(modifierFlags: event.modifierFlags, keyCode: event.keyCode) {
                spec = captured; stop()
            }
            return nil   // swallow the key so it never types into a field
        }
    }

    private func stop() {
        let wasRecording = recording
        recording = false; preview = []
        if let monitor { NSEvent.removeMonitor(monitor); self.monitor = nil }
        if wasRecording { onEndRecording() }   // restore the global hotkey (new or unchanged chord)
    }
}

/// A stack of boxed PTT pickers. A lone picker has no × (a picker always has a value); with several,
/// each carries an inline × (inside the box) to remove it. The square "+" adds another key.
private struct PTTBindingStack: View {
    @Binding var keys: [String]
    let label: (String) -> String
    @Environment(\.colorScheme) private var scheme
    private var dark: Bool { scheme == .dark }
    private var maxBindings: Int { AppSettings.pttKeyOptions.count }

    var body: some View {
        VStack(alignment: .leading, spacing: hubStackGap) {
            ForEach(keys.indices, id: \.self) { index in
                HStack(spacing: hubStackGap) {
                    PTTPickerBox(selection: binding(index), canRemove: keys.count > 1,
                                 remove: { keys.remove(at: index) }, label: label, dark: dark)
                        .frame(width: hubStackField)
                    if index == keys.count - 1 {
                        HubSquareAdd(dark: dark, active: keys.count < maxBindings) { keys.append(nextUnused()) }
                    }
                }
            }
        }
    }

    private func nextUnused() -> String { AppSettings.pttKeyOptions.first { !keys.contains($0) } ?? "right_cmd" }
    private func binding(_ i: Int) -> Binding<String> {
        Binding(get: { keys.indices.contains(i) ? keys[i] : "right_option" },
                set: { if keys.indices.contains(i) { keys[i] = $0 } })
    }
}

/// A boxed picker (native menu on open) with an inline × after the chevron when it's removable.
private struct PTTPickerBox: View {
    @Binding var selection: String
    let canRemove: Bool
    let remove: () -> Void
    let label: (String) -> String
    let dark: Bool
    @State private var anchor: NSView?
    private var options: [SettingsChoice] { AppSettings.pttKeyOptions.map { SettingsChoice(id: $0, label: label($0)) } }

    var body: some View {
        HStack(spacing: 6) {
            Button {
                if let anchor { HubMenuPanel.shared.show(anchor: anchor, options: options, selected: selection, dark: dark) { selection = $0 } }
            } label: {
                HStack(spacing: 7) {
                    Text(label(selection)).font(RhemionStyle.font(12, .medium))
                        .foregroundStyle(RhemionStyle.text(dark)).lineLimit(1).truncationMode(.tail)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Image(systemName: "chevron.down").font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(RhemionStyle.secondary(dark))
                }
                .frame(maxWidth: .infinity, minHeight: hubFieldHeight).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .frame(maxWidth: .infinity)
            .background(FieldAnchor { anchor = $0 })
            if canRemove {
                Button(action: remove) {
                    Image(systemName: "xmark").font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(RhemionStyle.tertiary(dark)).frame(width: 16, height: 16).contentShape(Circle())
                }
                .buttonStyle(.plain).help("Remove")
            }
        }
        .padding(.horizontal, 10).frame(maxWidth: .infinity).frame(height: hubFieldHeight)
        .background(RhemionStyle.win(dark), in: RoundedRectangle(cornerRadius: 7))
        .overlay { RoundedRectangle(cornerRadius: 7).strokeBorder(RhemionStyle.line(dark), lineWidth: 1) }
    }
}

/// The square "+" that adds a binding — only beside the LAST field of a stack (every field has the same
/// width, so the fields above stay aligned without reserving its slot). At the maximum it stays in place
/// but invisible and inert, so the row's right edge doesn't move.
private struct HubSquareAdd: View {
    let dark: Bool
    let active: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "plus").font(.system(size: 13, weight: .semibold))
                .foregroundStyle(RhemionStyle.secondary(dark)).frame(width: 30, height: 30)
                .background(RhemionStyle.win(dark), in: RoundedRectangle(cornerRadius: 7))
                .overlay { RoundedRectangle(cornerRadius: 7).strokeBorder(RhemionStyle.line(dark), lineWidth: 1) }
        }
        .buttonStyle(.plain)
        .opacity(active ? 1 : 0)
        .allowsHitTesting(active)
        .help("Add an alternative")
    }
}

/// A path/folder field: the field itself is the picker (click opens the native panel). It shows the app's
/// one folder motif (FolderLocation.swift): the icon (SF `folder`; SF `doc` for a FILE field), the name in
/// the text colour, then on the same line the humanized location in the secondary colour, truncated in
/// the middle; a muted placeholder when empty; the full path on hover. The inline × clears the value
/// (lone) or removes the row (one of several).
private struct PathField: View {
    @Binding var path: String
    let placeholder: String
    let chooseDirectory: Bool
    let canRemove: Bool
    let clearOrRemove: () -> Void
    @Environment(\.colorScheme) private var scheme
    private var dark: Bool { scheme == .dark }
    private var hasValue: Bool { !path.isEmpty }
    private var showClear: Bool { canRemove || hasValue }

    var body: some View {
        HStack(spacing: 6) {
            HStack(spacing: 8) {
                FolderIcon(file: !chooseDirectory, dark: dark)
                if hasValue {
                    let loc = FolderLocation(path: path)
                    HStack(spacing: 6) {
                        Text(loc.name).font(RhemionStyle.font(12)).foregroundStyle(RhemionStyle.text(dark))
                            .lineLimit(1).truncationMode(.middle).layoutPriority(1)
                        if !loc.location.isEmpty {
                            Text(loc.location).font(RhemionStyle.font(12)).foregroundStyle(RhemionStyle.secondary(dark))
                                .lineLimit(1).truncationMode(.middle)
                        }
                    }
                } else {
                    Text(placeholder).font(RhemionStyle.font(12)).foregroundStyle(RhemionStyle.tertiary(dark))
                        .lineLimit(1).truncationMode(.tail)
                }
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
            .onTapGesture { choose() }
            .help(hasValue ? path : "")
            if showClear {
                Button(action: clearOrRemove) {
                    Image(systemName: "xmark").font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(RhemionStyle.tertiary(dark)).frame(width: 18, height: 18).contentShape(Circle())
                }
                .buttonStyle(.plain).help(canRemove ? "Remove" : "Clear")
            }
        }
        .padding(.horizontal, 10).frame(maxWidth: .infinity).frame(height: hubFieldHeight)
        .background(RhemionStyle.win(dark), in: RoundedRectangle(cornerRadius: 7))
        .overlay { RoundedRectangle(cornerRadius: 7).strokeBorder(RhemionStyle.line(dark), lineWidth: 1) }
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = chooseDirectory
        panel.canChooseFiles = !chooseDirectory
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = chooseDirectory
        if !path.isEmpty { panel.directoryURL = URL(fileURLWithPath: path) }
        if panel.runModal() == .OK, let url = panel.url { path = url.path }
    }
}

/// A stack of folder fields (Model folders). Same add/remove model as the hotkey stack: a lone empty
/// field is clickable to choose; × clears it (lone) or removes the row (several); the square "+" adds
/// another. Edited as a local list and mirrored to the caller (empty rows dropped on persist).
private struct PathBindingStack: View {
    let placeholder: String
    let onChange: ([String]) -> Void
    @State private var paths: [String]
    @Environment(\.colorScheme) private var scheme
    private var dark: Bool { scheme == .dark }
    private let maxItems = 12

    init(initial: [String], placeholder: String, onChange: @escaping ([String]) -> Void) {
        self.placeholder = placeholder
        self.onChange = onChange
        _paths = State(initialValue: initial.isEmpty ? [""] : initial)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: hubStackGap) {
            ForEach(paths.indices, id: \.self) { index in
                HStack(spacing: hubStackGap) {
                    PathField(path: binding(index), placeholder: placeholder, chooseDirectory: true,
                              canRemove: paths.count > 1, clearOrRemove: { clearOrRemove(index) })
                        .frame(width: hubStackField)
                    if index == paths.count - 1 {
                        HubSquareAdd(dark: dark, active: paths.count < maxItems) { paths.append(""); commit() }
                    }
                }
            }
        }
    }

    private func clearOrRemove(_ i: Int) {
        if paths.count > 1 { paths.remove(at: i) } else if paths.indices.contains(i) { paths[i] = "" }
        commit()
    }
    private func binding(_ i: Int) -> Binding<String> {
        Binding(get: { paths.indices.contains(i) ? paths[i] : "" },
                set: { if paths.indices.contains(i) { paths[i] = $0; commit() } })
    }
    private func commit() { onChange(paths) }
}

// MARK: - Custom dropdown menu (Journal-style card, shown in its own panel so it can overflow the window)

/// Captures the field's backing NSView, so a picker can position its menu panel at the field's screen rect.
private struct FieldAnchor: NSViewRepresentable {
    let onView: (NSView) -> Void
    func makeNSView(context: Context) -> NSView { let v = NSView(); DispatchQueue.main.async { onView(v) }; return v }
    func updateNSView(_ nsView: NSView, context: Context) {}
}

/// Shows a settings dropdown in its OWN borderless panel — a real menu that can extend beyond the app
/// window (no clipping), arrowless, styled like the Journal card. One at a time; dismisses on a pick or
/// an outside click.
@MainActor
final class HubMenuPanel {
    static let shared = HubMenuPanel()
    private var panel: NSPanel?
    private var localMonitor: Any?
    private var globalMonitor: Any?
    private static let gap: CGFloat = 4

    fileprivate func show(anchor: NSView, options: [SettingsChoice], selected: String, dark: Bool, pick: @escaping (String) -> Void) {
        dismiss()
        guard let window = anchor.window else { return }
        let field = window.convertToScreen(anchor.convert(anchor.bounds, to: nil))

        let card = HubMenuCard(options: options, selected: selected, minWidth: field.width, maxWidth: 620, dark: dark) { [weak self] picked in
            pick(picked); self?.dismiss()
        }
        let hosting = NSHostingView(rootView: card)
        hosting.layout()
        let size = hosting.fittingSize

        let panel = NSPanel(contentRect: NSRect(origin: .zero, size: size),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true      // native window shadow traces the rounded (transparent-cornered) card
        panel.level = .popUpMenu
        panel.contentView = hosting
        // Screen coords are bottom-left origin; drop the card just under the field, its left aligned to it.
        panel.setFrameOrigin(NSPoint(x: field.minX, y: field.minY - Self.gap - size.height))
        panel.orderFront(nil)
        panel.invalidateShadow()
        self.panel = panel

        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            if event.window !== self?.panel { self?.dismiss() }   // click inside the panel is handled by its content
            return event
        }
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            self?.dismiss()
        }
    }

    func dismiss() {
        if let localMonitor { NSEvent.removeMonitor(localMonitor); self.localMonitor = nil }
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor); self.globalMonitor = nil }
        panel?.orderOut(nil)
        panel = nil
    }
}

/// The dropdown card — opaque, concentric radii (container 12 / row 6), soft shadow, no arrow — matching
/// the Journal menu. A selected row shows a leading checkmark; hover/selection highlight is solid gold.
private struct HubMenuCard: View {
    let options: [SettingsChoice]
    let selected: String
    let minWidth: CGFloat
    let maxWidth: CGFloat
    let dark: Bool
    let pick: (String) -> Void

    var body: some View {
        VStack(spacing: 2) {
            ForEach(options) { option in
                HubMenuRow(title: option.label, checked: option.id == selected, dark: dark) { pick(option.id) }
            }
        }
        .padding(6)
        .frame(minWidth: min(max(180, minWidth), maxWidth), maxWidth: maxWidth, alignment: .leading)
        .fixedSize()
        .background(RhemionStyle.win(dark), in: RoundedRectangle(cornerRadius: 12))
        .overlay { RoundedRectangle(cornerRadius: 12).strokeBorder(RhemionStyle.line(dark), lineWidth: 0.5) }
        // No SwiftUI shadow — the panel's native window shadow traces the rounded card (soft, no hard edge).
    }
}

private struct HubMenuRow: View {
    let title: String
    let checked: Bool
    let dark: Bool
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: "checkmark").font(.system(size: 11, weight: .semibold)).opacity(checked ? 1 : 0).frame(width: 20)
                Text(title).font(RhemionStyle.font(13)).lineLimit(1).truncationMode(.tail)
                Spacer(minLength: 8)
            }
            .padding(.vertical, 5).padding(.trailing, 8).frame(minHeight: 28).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(hover ? Color.white : RhemionStyle.text(dark))
        .background(hover ? RhemionStyle.gold : .clear, in: RoundedRectangle(cornerRadius: 6))
        .onHover { hover = $0 }
        .help(title)
    }
}
