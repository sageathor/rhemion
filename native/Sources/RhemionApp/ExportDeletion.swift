// Deleting exported transcripts lives with the export setting (Settings › Journal ›
// Export): a quiet "Delete exported transcripts…" action under the Export folder field, and a question
// when export is switched Off while Rhemion still owns files there. Both lead to one confirmation sheet
// that runs `AppController.runDeleteExport()` (quiesce barrier, mutual exclusion, busy/stuck handling).
// Only files the export registry proves Rhemion wrote are deleted — never the folder, never other files.

import AppKit
import RhemionStorage
import SwiftUI

/// What Rhemion owns in the current export folder right now, or nil when there's nothing of Rhemion's
/// there (no valid export folder, or the registry owns no file in it). Reads + hashes the owned notes, so
/// call it on demand (a click, a sheet opening), not on every render.
struct ExportOwnership: Equatable {
    let folder: URL
    let files: [String]
    let size: Int64

    static func current(_ settings: AppSettings) -> ExportOwnership? {
        let layout = AppPaths.storageLayout(settings: settings)
        guard let dir = layout.exportDir else { return nil }
        let items = StorageOperations.deleteExportPlan(layout)
        guard !items.isEmpty else { return nil }
        return ExportOwnership(folder: dir, files: items.map(\.url.lastPathComponent), size: StorageSizes.total(items))
    }
}

/// Drives one presentation of the export-deletion sheet.
@MainActor
final class ExportDeleteSheetModel: ObservableObject, Identifiable {
    enum Phase: Equatable {
        /// Export is being switched Off: keep the transcripts, or delete them?
        case askOff
        /// "Delete Exported Transcripts?" — the Delete button is live 0.5 s after this appears.
        case confirm
        case working
        case success
        /// Deleted, but some month notes in the folder can't be confirmed as Rhemion's — they were kept.
        case kept([String])
        case failure([String])
        case stuck(String)
    }

    let id = UUID()
    @Published private(set) var phase: Phase
    @Published private(set) var busy = false
    /// Mirrors "0.5 s have passed since `.confirm` was entered" for the button's look; the authoritative
    /// guard is the timestamp check in `delete()` (same pattern as the farewell data confirmation).
    @Published private(set) var deleteReady = false
    private var confirmEnteredAt: Date?

    let ownership: ExportOwnership
    /// Opened by switching export Off: after a deletion (or "Keep Transcripts") export goes Off.
    let turningOff: Bool
    private let canStart: () -> Bool
    /// Runs the deletion; its argument is `turningOff` (the controller turns export Off before resuming).
    private let run: (Bool) async -> OperationReport
    /// Called the moment the deletion has actually run (success, kept or per-item failure — never busy or
    /// stuck), before the user dismisses anything: the pane mirrors export Off and refreshes sizes.
    private let onRan: () -> Void

    init(ownership: ExportOwnership, turningOff: Bool, canStart: @escaping () -> Bool,
         run: @escaping (Bool) async -> OperationReport, onRan: @escaping () -> Void = {}) {
        self.ownership = ownership
        self.turningOff = turningOff
        self.canStart = canStart
        self.run = run
        self.onRan = onRan
        phase = turningOff ? .askOff : .confirm
        if !turningOff { armConfirm() }
    }

    var sizeText: String { ByteSize.string(ownership.size) }

    /// "1 exported transcript" / "3 exported transcripts", with the size.
    var deletesLine: String {
        let n = ownership.files.count
        return "\(n) exported \(n == 1 ? "transcript" : "transcripts") · \(sizeText)"
    }

    /// "Delete Transcripts…" on the Off question → the confirmation.
    func askDelete() {
        guard phase == .askOff else { return }
        phase = .confirm
        armConfirm()
    }

    /// Cancel on the confirmation: back to the Off question when that's where it came from.
    func back() {
        guard phase == .confirm, turningOff else { return }
        phase = .askOff
        confirmEnteredAt = nil
        deleteReady = false
        busy = false
    }

    private func armConfirm() {
        deleteReady = false
        let enteredAt = Date()
        confirmEnteredAt = enteredAt
        Task {
            try? await Task.sleep(for: .milliseconds(500))
            guard phase == .confirm, confirmEnteredAt == enteredAt else { return }
            deleteReady = true
        }
    }

    /// Valid only from `.confirm`, and only 0.5 s after it appeared (a double click can't land on Delete).
    func delete() {
        guard phase == .confirm else { return }
        guard let enteredAt = confirmEnteredAt, Date().timeIntervalSince(enteredAt) >= 0.5 else { return }
        guard canStart() else { busy = true; return }
        busy = false
        phase = .working
        let turningOff = self.turningOff
        Task {
            let report = await run(turningOff)
            defer { if ran { onRan() } }
            if report.failures == [AppController.busyMessage] {
                busy = true
                phase = .confirm
                armConfirm()
            } else if report.removed.isEmpty && report.failures == [AppController.quiesceStuckMessage] {
                phase = .stuck(report.failures[0])
            } else if !report.success {
                var lines = report.failures
                if !report.unconfirmedExport.isEmpty {
                    lines.append(KeptFiles.lead(report.unconfirmedExport.count))
                    lines += report.unconfirmedExport
                }
                phase = .failure(lines)
            } else if !report.unconfirmedExport.isEmpty {
                phase = .kept(report.unconfirmedExport)
            } else {
                phase = .success
            }
        }
    }

    /// Whether the deletion actually ran (success, kept or a per-item failure) — the caller refreshes
    /// sizes and, when turning export Off, switches it Off.
    var ran: Bool {
        switch phase {
        case .success, .kept, .failure: return true
        default: return false
        }
    }
}

/// The "Delete exported transcripts…" link under the Export folder field — its own view so it observes
/// the storage barrier and greys out live while any storage operation runs.
struct ExportDeleteLink: View {
    @ObservedObject var activity: DataOperations
    let action: () -> Void
    var body: some View {
        TextLink(title: "Delete exported transcripts…", danger: true, action: action)
            .disabled(activity.inProgress)
    }
}

/// The sheet. App controls only (DESIGN.md): Cancel / Keep are Raised R1, the destructive actions are
/// Raised R1 with danger-red text, the folder is the shared `FolderView`; both questions use the
/// "Deletes / Stays" columns (`ChangeColumns`).
struct ExportDeleteSheet: View {
    @ObservedObject var model: ExportDeleteSheetModel
    let dark: Bool
    /// Close without changing anything (export mode stays as it was).
    let onCancel: () -> Void
    /// "Keep Transcripts" on the Off question: close and switch export Off.
    let onKeep: () -> Void
    /// Close after a finished deletion (any terminal result the user dismisses, or an instant success).
    /// Mode/size updates already happened in the model's `onRan`.
    let onFinished: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            switch model.phase {
            case .askOff:                askOffContent
            case .confirm:               confirmContent
            case .working:               workingContent
            case .success:               EmptyView()   // dismissed the instant it lands, see onChange below
            case .kept(let files):       keptContent(files)
            case .failure(let lines):    failureContent(lines)
            case .stuck(let message):    StuckContent(message: message, dark: dark)
            }
        }
        .padding(WindowLayout.mainPadding)   // the standard main-column margins (DESIGN.md "Window layout")
        .frame(width: 440)
        .onExitCommand {
            switch model.phase {
            case .askOff: onCancel()
            case .confirm: if model.turningOff { model.back() } else { onCancel() }
            default: break
            }
        }
        .onChange(of: model.phase) { _, phase in if phase == .success { onFinished() } }
    }

    private func title(_ text: String) -> some View {
        Text(text).font(WindowLayout.stepTitleFont).foregroundStyle(RhemionStyle.text(dark))
    }

    private func para(_ text: String) -> some View {
        Text(text).font(RhemionStyle.font(12)).foregroundStyle(RhemionStyle.text(dark))
            .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: switching export Off

    private var askOffContent: some View {
        VStack(alignment: .leading, spacing: WindowLayout.stepGap) {
            title("Turn off export?")
            para("Rhemion stops writing transcripts to this folder. Keep the ones it already exported, or delete them?")
            FolderView(url: model.ownership.folder, dark: dark)
            ChangeColumns(goesTitle: "Turns off", goes: ["Export to this folder"],
                          stays: ["Your Journal", "Exported transcripts, unless you delete them"], dark: dark)
            // The macOS "Don't Save / Cancel / Save" arrangement: the destructive alternative on the left,
            // the default (keep) on the right.
            HStack(spacing: WindowLayout.buttonSpacing) {
                RaisedButton(title: "Delete Transcripts…", danger: true, action: model.askDelete)
                Spacer()
                RaisedButton(title: "Cancel", action: onCancel)
                RaisedButton(title: "Keep Transcripts", action: onKeep)
                    .keyboardShortcut(.defaultAction)
            }
        }
    }

    // MARK: confirmation

    private var confirmContent: some View {
        VStack(alignment: .leading, spacing: WindowLayout.stepGap) {
            title("Delete Exported Transcripts?")
            para("Deletes only the transcripts Rhemion exported to this folder.")
            FolderView(url: model.ownership.folder, dark: dark)
            ChangeColumns(goes: [model.deletesLine], stays: ["The folder", "Your other files in it", "Your Journal"], dark: dark)
            Text("This can't be undone.").font(RhemionStyle.font(12, .semibold)).foregroundStyle(RhemionStyle.danger)
            if model.busy { BusyNote(dark: dark) }
            WindowButtonRow {
                RaisedButton(title: "Cancel") { if model.turningOff { model.back() } else { onCancel() } }
                RaisedButton(title: "Delete", danger: true, action: model.delete)
                    .disabled(!model.deleteReady)
            }
        }
    }

    // MARK: working / results

    private var workingContent: some View {
        VStack(alignment: .leading, spacing: WindowLayout.stepGap) {
            title("Deleting Exported Transcripts…")
            HStack(spacing: 10) {
                ProgressView().controlSize(.small)
                Text("This may take a moment.").font(RhemionStyle.font(12)).foregroundStyle(RhemionStyle.secondary(dark))
            }
        }
    }

    private func keptContent(_ files: [String]) -> some View {
        VStack(alignment: .leading, spacing: WindowLayout.stepGap) {
            title("Some Transcripts Were Kept")
            FolderView(url: model.ownership.folder, dark: dark)
            para(KeptFiles.lead(files.count))
            FailureList(lines: files, dark: dark)
            WindowButtonRow { RaisedButton(title: "Done", action: onFinished) }
        }
    }

    private func failureContent(_ lines: [String]) -> some View {
        VStack(alignment: .leading, spacing: WindowLayout.stepGap) {
            title("Some Transcripts Couldn't Be Deleted")
            FailureList(lines: lines, dark: dark)
            WindowButtonRow { RaisedButton(title: "Done", action: onFinished) }
        }
    }
}
