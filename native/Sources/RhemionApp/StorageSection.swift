// The Storage section of Settings › Advanced (last section) — read-only sizes per category, each with a
// one-line hint (computed off the main thread, since walking the file tree can be slow), plus "Clear
// Data…" (the Clear Data window) and "Uninstall…" as setting rows in a second card.

import RhemionStorage
import SwiftUI

@MainActor
final class StorageModel: ObservableObject {
    struct Sizes: Equatable {
        var models, recordings, transcripts, appData, export: Int64
        var total: Int64 { models + recordings + transcripts + appData + export }
    }
    @Published var sizes: Sizes?
    /// Whether the "Exported transcripts" row exists — decided synchronously in `refresh` (a registry read),
    /// so it never pops in after the sizes; its size reads "Calculating…" until they arrive.
    @Published var showsExport = false
    /// Bumped on every `refresh`; a stale detached task (from a superseded settings snapshot) checks it
    /// before publishing so an in-flight-but-outrun scan can never clobber a newer one's result.
    private var generation = 0

    /// Snapshots the layout on the main actor (cheap — no disk access), then walks the file tree off it.
    func refresh(settings: AppSettings) {
        sizes = nil
        generation += 1
        showsExport = AppPaths.storageLayout(settings: settings).showsExportRow(exportMode: settings.exportMode)
        let gen = generation
        let layout = AppPaths.storageLayout(settings: settings)
        Task.detached(priority: .utility) {
            func sum(_ categories: [StorageCategory]) -> Int64 { StorageSizes.total(categories.flatMap(layout.items)) }
            let s = Sizes(models: sum([.models, .externalModels]), recordings: sum([.recordings]),
                          transcripts: sum([.transcripts, .dictionary, .legacyContent]),
                          appData: sum([.applicationData, .exportRegistry, .temporary]),
                          export: sum([.export]))
            await MainActor.run { if self.generation == gen { self.sizes = s } }
        }
    }
}

struct StorageSection: View {
    @ObservedObject var model: StorageModel
    /// The storage barrier: while an operation holds it, neither action can start.
    @ObservedObject var activity: DataOperations
    let dark: Bool
    let onClearData: () -> Void
    let onUninstall: () -> Void

    private func fmt(_ value: Int64?) -> String {
        guard let value else { return "Calculating…" }
        return ByteSize.string(value)
    }

    var body: some View {
        Section {
            row("Models", "Speech recognition models Rhemion uses. Some may be shared with other apps.", model.sizes?.models)
            row("Recordings", "Audio of your dictations, for playback in the Journal.", model.sizes?.recordings)
            row("Transcripts & Dictionary", "Your Journal text and word replacements.", model.sizes?.transcripts)
            row("Application Data", "Settings, logs and caches.", model.sizes?.appData)
            if model.showsExport {
                row("Exported transcripts", "Transcripts Rhemion exported to your export folder. They stay unless you delete them.", model.sizes?.export)
            }
            row("Total", "Everything Rhemion keeps on this Mac.", model.sizes?.total, bold: true)
        } header: {
            Text("Storage").font(RhemionStyle.font(13, .bold)).foregroundStyle(RhemionStyle.text(dark)).textCase(nil)
        }
        // A second card (its own Section): the two actions as setting rows, like "Application log".
        Section {
            actionRow("Clear data", "Free up space or erase your data. You choose what goes.") {
                RaisedButton(title: "Clear Data…", action: onClearData)
            }
            actionRow("Uninstall Rhemion", "Remove the app from this Mac and choose what goes with it.") {
                RaisedButton(title: "Uninstall…", danger: true, action: onUninstall)
            }
        }
    }

    /// The SettingRow pattern (title + hint left, control right in the field column) for an action button.
    private func actionRow<C: View>(_ title: String, _ hint: String, @ViewBuilder button: () -> C) -> some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(RhemionStyle.font(13)).foregroundStyle(RhemionStyle.text(dark))
                Text(hint).font(RhemionStyle.font(11)).foregroundStyle(RhemionStyle.secondary(dark))
            }
            Spacer(minLength: 12)
            button().frame(width: hubFieldColumn, alignment: .trailing)
        }
        .padding(.vertical, 3)
        .disabled(activity.inProgress)
    }

    private func row(_ title: String, _ note: String, _ value: Int64?, bold: Bool = false) -> some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(RhemionStyle.font(13, bold ? .semibold : .regular))
                Text(note).font(RhemionStyle.font(11)).foregroundStyle(RhemionStyle.secondary(dark))
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            Text(fmt(value)).font(RhemionStyle.font(13, bold ? .semibold : .regular)).monospacedDigit()
                .foregroundStyle(value == nil ? RhemionStyle.tertiary(dark) : RhemionStyle.text(dark))
        }
    }
}

/// Raised R1 button (DESIGN.md) — the exact treatment of the Journal's `JournalActionButton` (a raised
/// win pill + hairline border + a soft shadow, hover shifts the fill), but title-only (no leading icon).
/// `danger: true` keeps the neutral Raised R1 surface but swaps the label to the danger-red ink (the
/// destructive confirm action of a sheet, e.g. "Delete…") — no separate button type for this.
struct RaisedButton: View {
    let title: String
    var danger: Bool = false
    let action: () -> Void
    @Environment(\.colorScheme) private var scheme
    // `.disabled(...)` from a caller (e.g. the export-delete confirm's 0.5s guard) sets
    // this via the environment; Button already refuses the action when it's false, but `.plain` style
    // doesn't dim on its own, so this drives the visible "disabled" look too.
    @Environment(\.isEnabled) private var isEnabled
    @State private var hover = false
    private var dark: Bool { scheme == .dark }

    var body: some View {
        Button(action: action) {
            Text(title).font(RhemionStyle.font(12, .medium))
                .foregroundStyle(danger ? RhemionStyle.danger : RhemionStyle.text(dark))
                .padding(.horizontal, 12).padding(.vertical, 7)
                .background(hover && isEnabled ? RhemionStyle.hover(dark) : RhemionStyle.win(dark), in: RoundedRectangle(cornerRadius: 8))
                .overlay { RoundedRectangle(cornerRadius: 8).strokeBorder(RhemionStyle.line(dark), lineWidth: 0.5) }
                .shadow(color: .black.opacity(dark ? 0.22 : 0.06), radius: 1.5, y: 1)
                .opacity(isEnabled ? 1 : 0.45)
        }.buttonStyle(.plain).onHover { hover = $0 }
    }
}
