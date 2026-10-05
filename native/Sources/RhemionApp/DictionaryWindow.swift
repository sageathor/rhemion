// Dictionary — the personal word-replacement editor. It is a destination inside the hub:
// HubModel owns a DictionaryModel and the hub renders HubDictionaryPane. There is no standalone window.
//
// One row = one result: comma-separated spoken variants -> a single replacement (like
// `Canonical = variant1, variant2`). New rows are inserted at the TOP and scrolled into view. Editing
// writes active/dictionary.json, which the runtime hot-reloads and applies to the next dictation;
// apply-on-change persists (incomplete rows are dropped). English UI chrome; the replacement text itself
// is user content (typically Russian).

import AppKit
import SwiftUI

/// The Dictionary's model, owned by HubModel so it survives view rebuilds and the controller can reload
/// it from disk when the hub is shown / becomes key (the ⌘⌥W quick-add writes dictionary.json while the
/// hub may be open — without reloading, the next in-place edit would save a stale snapshot back).
@MainActor
final class DictionaryModel: ObservableObject {
    @Published var doc = DictionaryStore.load()
    func reload() { doc = DictionaryStore.load() }
}

/// The Dictionary pane inside the hub, styled to the shared design system
/// (`RhemionStyle`): a subtitle + gold "Add replacement" action, a bordered table card (Spoken as → Replace
/// with) with in-place editable rows, and the quick-add hint. Edits
/// persist to active/dictionary.json on change, incomplete rows dropped, runtime hot-reloads.
struct HubDictionaryPane: View {
    @ObservedObject var model: DictionaryModel
    @Environment(\.colorScheme) private var scheme
    @FocusState private var focused: UUID?
    @State private var scrollTarget: UUID?
    @State private var hovered: UUID?
    @State private var addHover = false
    private var dark: Bool { scheme == .dark }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    headerRow
                    tableCard
                    note
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(EdgeInsets(top: 30, leading: 34, bottom: 40, trailing: 34))
            }
            .onChange(of: scrollTarget) { _, target in
                guard let target else { return }
                withAnimation { proxy.scrollTo(target, anchor: .top) }
                scrollTarget = nil
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(RhemionStyle.content(dark))
        // Persist on any change; DictionaryStore drops incomplete rows and the runtime hot-reloads.
        .onChange(of: model.doc) { _, updated in DictionaryStore.save(updated) }
    }

    private var headerRow: some View {
        HStack(alignment: .firstTextBaseline, spacing: 14) {
            Text("Your words, spelled your way — applied automatically after every dictation.")
                .font(RhemionStyle.font(12)).lineSpacing(3)
                .foregroundStyle(RhemionStyle.secondary(dark))
                .frame(maxWidth: .infinity, alignment: .leading)
            // Raised NEUTRAL pill (the app's "active = neutral-raised" language, matching the Copy/Delete
            // buttons) — priority comes from placement + the plus glyph + medium text, not from the gold
            // accent (gold is reserved for selection). Hover shifts the fill; a hairline shadow lifts it.
            Button { addEntry() } label: {
                HStack(spacing: 6) {
                    Image(systemName: "plus").font(.system(size: 11, weight: .semibold))
                    Text("Add replacement").font(RhemionStyle.font(12, .medium))
                }
                .foregroundStyle(RhemionStyle.text(dark))
                .padding(.horizontal, 12).padding(.vertical, 7)
                .background(addHover ? RhemionStyle.hover(dark) : RhemionStyle.win(dark),
                            in: RoundedRectangle(cornerRadius: 8))
                .overlay { RoundedRectangle(cornerRadius: 8).strokeBorder(RhemionStyle.line(dark), lineWidth: 0.5) }
                .shadow(color: .black.opacity(dark ? 0.22 : 0.06), radius: 1.5, y: 1)
            }
            .buttonStyle(.plain).fixedSize().help("Add a replacement")
            .onHover { addHover = $0 }
        }
        .padding(.bottom, 18)
    }

    private var tableCard: some View {
        VStack(spacing: 0) {
            headCells
            if model.doc.entries.isEmpty {
                Divider().overlay(RhemionStyle.line(dark))
                emptyRow
            } else {
                ForEach(model.doc.entries) { entry in
                    Divider().overlay(RhemionStyle.line(dark))
                    editRow(entry)
                }
            }
        }
        .background(RhemionStyle.win(dark))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay { RoundedRectangle(cornerRadius: 12).strokeBorder(RhemionStyle.line(dark), lineWidth: 1) }
    }

    private var headCells: some View {
        HStack(spacing: 12) {
            Text("Spoken as").frame(maxWidth: .infinity, alignment: .leading)
            Color.clear.frame(width: 26)
            Text("Replace with").frame(maxWidth: .infinity, alignment: .leading)
            Color.clear.frame(width: 18)   // aligns with the row's delete column
        }
        .font(RhemionStyle.font(10, .semibold)).textCase(.uppercase).tracking(0.8)
        .foregroundStyle(RhemionStyle.tertiary(dark))
        .padding(.horizontal, 18).padding(.vertical, 11)
    }

    private func editRow(_ entry: ReplacementEntry) -> some View {
        HStack(spacing: 12) {
            field("what you say", binding(for: entry.id).variants)
                .frame(maxWidth: .infinity)
                .focused($focused, equals: entry.id)
            Image(systemName: "arrow.right").font(.system(size: 12))
                .foregroundStyle(RhemionStyle.tertiary(dark)).frame(width: 26)
            field("what it becomes", binding(for: entry.id).canonical)
                .frame(maxWidth: .infinity)
            Button {
                if focused == entry.id { focused = nil }
                model.doc.entries.removeAll { $0.id == entry.id }
            } label: {
                Image(systemName: "trash").font(.system(size: 12))
                    .foregroundStyle(RhemionStyle.tertiary(dark)).frame(width: 18, height: 18)
            }
            .buttonStyle(.plain)
            .opacity(hovered == entry.id ? 1 : 0).allowsHitTesting(hovered == entry.id)
            .help("Delete this replacement")
        }
        .padding(.horizontal, 18).padding(.vertical, 12)
        .id(entry.id)
        .onHover { inside in hovered = inside ? entry.id : (hovered == entry.id ? nil : hovered) }
    }

    private func field(_ placeholder: String, _ text: Binding<String>) -> some View {
        TextField(placeholder, text: text)
            .textFieldStyle(.plain).font(RhemionStyle.font(13))
            .padding(.horizontal, 9).padding(.vertical, 6)
            .background(RhemionStyle.hover(dark), in: RoundedRectangle(cornerRadius: 7))
            .overlay { RoundedRectangle(cornerRadius: 7).strokeBorder(RhemionStyle.line(dark), lineWidth: 0.5) }
    }

    private var emptyRow: some View {
        VStack(spacing: 6) {
            Text("No replacements yet").font(RhemionStyle.font(14, .semibold)).foregroundStyle(RhemionStyle.secondary(dark))
            Text("Add one: what you say → what it becomes.").font(RhemionStyle.font(12)).foregroundStyle(RhemionStyle.tertiary(dark))
        }
        .frame(maxWidth: .infinity).padding(.vertical, 44)
    }

    private var note: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("Add names, technical terms, or phrases you use often.")
            HStack(spacing: 5) {
                Text("Quick-add from any app with")
                kbd("⌘"); kbd("⌥"); kbd("W")
            }
        }
        .font(RhemionStyle.font(11)).lineSpacing(3)
        .foregroundStyle(RhemionStyle.secondary(dark))
        .padding(.top, 16).padding(.horizontal, 2)
    }

    private func kbd(_ label: String) -> some View {
        Text(label).font(RhemionStyle.font(10, .semibold)).foregroundStyle(RhemionStyle.text(dark))
            .padding(.horizontal, 5).padding(.vertical, 1)
            .background(RhemionStyle.hover(dark), in: RoundedRectangle(cornerRadius: 4))
            .overlay { RoundedRectangle(cornerRadius: 4).strokeBorder(RhemionStyle.line(dark), lineWidth: 0.5) }
    }

    /// Insert a new row at the TOP, focus it, and scroll it into view — adding never requires scrolling.
    private func addEntry() {
        let entry = ReplacementEntry()
        model.doc.entries.insert(entry, at: 0)
        focused = entry.id
        scrollTarget = entry.id
    }

    /// A binding to one entry looked up by id, safe against the row being removed mid-edit (get returns a
    /// throwaway placeholder if the id is gone, set no-ops). Never subscripts by a stale index.
    private func binding(for id: UUID) -> Binding<ReplacementEntry> {
        Binding(
            get: { model.doc.entries.first { $0.id == id } ?? ReplacementEntry() },
            set: { newValue in
                if let index = model.doc.entries.firstIndex(where: { $0.id == id }) { model.doc.entries[index] = newValue }
            }
        )
    }
}
