import AppKit
import AVFoundation
import SwiftUI

// The Journal lives inside the hub: HubModel owns a JournalModel and the hub renders JournalView.
// There is no standalone Journal window anymore — the model, view, and its subviews below are what the hub
// uses.

@MainActor
final class JournalModel: ObservableObject {
    @Published var doc = JournalDoc(entries: [], skippedLines: 0, unreadableFiles: 0)
    @Published var loading = false
    private var refresh: Task<Void, Never>?
    private var reloadPending = false
    func reload() {
        guard refresh == nil else { reloadPending = true; return }
        loading = true
        refresh = Task {
            doc = await Task.detached(priority: .userInitiated) { JournalDoc.load() }.value
            loading = false
            refresh = nil
            if reloadPending { reloadPending = false; reload() }
        }
    }
}

private extension Color {
    init(journalHex hex: UInt32) {
        self.init(red: Double((hex >> 16) & 255) / 255, green: Double((hex >> 8) & 255) / 255, blue: Double(hex & 255) / 255)
    }
}
private enum JournalStyle {
    static let gold = Color(journalHex: 0xE0A42E)
    static func text(_ dark: Bool) -> Color { Color(journalHex: dark ? 0xE8E8EC : 0x1D1D1F) }
    static func secondary(_ dark: Bool) -> Color { Color(journalHex: dark ? 0xA8A8AE : 0x5F5F66) }
    static func tertiary(_ dark: Bool) -> Color { Color(journalHex: dark ? 0x909098 : 0x9A9AA1) }
    static func sidebar(_ dark: Bool) -> Color { Color(journalHex: dark ? 0x242426 : 0xF5F5F7) }
    static func content(_ dark: Bool) -> Color { Color(journalHex: dark ? 0x1E1E20 : 0xFFFFFF) }
    static func win(_ dark: Bool) -> Color { Color(journalHex: dark ? 0x232326 : 0xFFFFFF) }        // raised surface (--win)
    static func line(_ dark: Bool) -> Color { Color(journalHex: dark ? 0x37373B : 0xE5E5E9) }
    static func line2(_ dark: Bool) -> Color { Color(journalHex: dark ? 0x2C2C30 : 0xEFEFF2) }       // hover fill (--line2)
    static func selected(_ dark: Bool) -> Color { dark ? gold.opacity(0.20) : Color(journalHex: 0xF6DD84) }
    static func cbBorder(_ dark: Bool) -> Color { dark ? Color.white.opacity(0.28) : Color.black.opacity(0.24) }   // --cb-border from the mockup
    static func font(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        // Use the EXACT bundled Mulish face for each weight (no SwiftUI weight synthesis, which rendered
        // heavier than the design). Falls back to the native macOS font if the face isn't registered.
        let face: String
        switch weight {
        case .heavy, .black: face = "Mulish-ExtraBold"
        case .bold: face = "Mulish-Bold"
        case .semibold: face = "Mulish-SemiBold"
        case .medium: face = "Mulish-Medium"
        case .light, .ultraLight, .thin: face = "Mulish-Light"
        default: face = "Mulish-Regular"
        }
        return NSFont(name: face, size: size) == nil ? .system(size: size, weight: weight) : .custom(face, size: size)
    }
}

struct JournalView: View {
    @ObservedObject var model: JournalModel
    let client: RuntimeClient
    @Environment(\.colorScheme) private var scheme
    @State private var query = ""
    @State private var grouping = JournalGrouping.monthWeekDay
    @State private var compact = false
    @State private var details = true
    @State private var groupMenu = false
    @State private var opened: String?
    @State private var checked = Set<String>()
    @State private var pendingDelete = Set<String>()
    @State private var confirmDelete = false
    @State private var deleting = false
    @State private var collapsed = Set<String>()
    @State private var hovered: String?
    @State private var listWidth: CGFloat = 348
    @State private var dragWidth: CGFloat?
    @State private var toast: String?
    @State private var toastTask: Task<Void, Never>?
    @State private var exportMode = SettingsStore.load().exportMode
    @State private var exporting = false
    @State private var groupAnchor: CGRect = .zero
    private var dark: Bool { scheme == .dark }
    private var search: String { query.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var entries: [JournalEntry] {
        guard !search.isEmpty else { return model.doc.entries }
        return model.doc.entries.filter { entry in
            [entry.transcript, entry.clean, entry.raw, entry.appName ?? ""].contains { $0.localizedStandardContains(search) }
        }
    }
    private var selected: JournalEntry? { entries.first { $0.id == opened } }
    // Flatten the tree: only day sections pin, while month/week headers scroll away.
    private func visibleGroups(_ groups: [JournalGroup]) -> [JournalGroup] {
        groups.flatMap { [$0] + (collapsed.contains($0.id) ? [] : visibleGroups($0.children)) }
    }
    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            if !checked.isEmpty { selectionBar; Divider() }
            GeometryReader { geometry in
                HStack(spacing: 0) {
                    list.frame(width: details ? min(listWidth, max(280, geometry.size.width - 385)) : nil).frame(maxWidth: details ? nil : .infinity, maxHeight: .infinity)
                    if details {
                        Rectangle().fill(JournalStyle.line(dark)).frame(width: 5)
                            .onHover { if $0 { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() } }
                            .gesture(DragGesture().onChanged { value in
                                if dragWidth == nil { dragWidth = listWidth }
                                // clamp with the SAME bound the render uses, so there is no invisible slack on drag-back
                                listWidth = max(280, min(geometry.size.width - 385, (dragWidth ?? listWidth) + value.translation.width))
                            }.onEnded { _ in dragWidth = nil })
                        Group {
                            if let selected { JournalDetail(entry: selected, notify: notify, delete: { requestDelete([selected.id]) }, deleting: deleting).id(selected.id) }
                            else { Text("Select an entry").foregroundStyle(JournalStyle.secondary(dark)).frame(maxWidth: .infinity, maxHeight: .infinity) }
                        }.frame(minWidth: 290, maxWidth: .infinity, maxHeight: .infinity).background(JournalStyle.content(dark))
                    }
                }
            }
            if model.doc.skippedLines > 0 || model.doc.unreadableFiles > 0 {
                Text("Skipped malformed lines: \(model.doc.skippedLines) · Unreadable files: \(model.doc.unreadableFiles)")
                    .font(.caption).foregroundStyle(JournalStyle.secondary(dark)).padding(6)
            }
        }.frame(minWidth: 860, idealWidth: 1000, minHeight: 440, idealHeight: 640)
            .font(JournalStyle.font(13)).foregroundStyle(JournalStyle.text(dark))
            .background(JournalStyle.sidebar(dark)).tint(JournalStyle.gold).buttonStyle(.plain)
            .coordinateSpace(name: "journalRoot")
            .onPreferenceChange(MenuAnchorKey.self) { groupAnchor = $0 }
            .overlay { groupingMenu }
            .onReceive(NotificationCenter.default.publisher(for: SettingsStore.didChange)) { _ in
                exportMode = SettingsStore.load().exportMode
            }
            .overlay(alignment: .bottom) {
                if let toast {
                    Text(toast).font(JournalStyle.font(12)).padding(12)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 9)).padding(20).allowsHitTesting(false)
                }
            }
            .alert("Delete \(pendingDelete.count) entries and their audio permanently?", isPresented: $confirmDelete) {
                Button("Cancel", role: .cancel) { pendingDelete.removeAll() }
                Button("Delete permanently", role: .destructive) { performDelete() }
            } message: {
                Text("This also removes them from the exported note.")
            }
            .onChange(of: entries, initial: true) { _, values in
                if !values.contains(where: { $0.id == opened }) { opened = values.first?.id }
                checked.formIntersection(Set(values.map(\.id)))
            }
    }
    // Custom dropdown drawn at the window root: no popover arrow, hangs directly under the trigger.
    // A full-window catcher dismisses on any outside click; the card sits above it.
    @ViewBuilder private var groupingMenu: some View {
        if groupMenu {
            ZStack(alignment: .topLeading) {
                Color.clear.contentShape(Rectangle()).onTapGesture { groupMenu = false }
                JournalMenuCard {
                    ForEach(JournalGrouping.allCases, id: \.self) { option in
                        JournalMenuRow(title: option.rawValue, checked: grouping == option) { grouping = option; groupMenu = false }
                    }
                }
                .fixedSize()
                .offset(x: groupAnchor.minX, y: groupAnchor.maxY + 5)
            }
        }
    }
    private var toolbar: some View {
        HStack(spacing: 10) {
            HStack(spacing: 7) {
                Image(systemName: "magnifyingglass").foregroundStyle(JournalStyle.secondary(dark))
                TextField("Search the journal", text: $query).textFieldStyle(.plain)
                if !query.isEmpty { Button { query = "" } label: { Image(systemName: "xmark.circle.fill") }.help("Clear search") }
            }.padding(7).frame(minWidth: 130, maxWidth: 250).background(JournalStyle.content(dark), in: RoundedRectangle(cornerRadius: 7))
            Button { groupMenu.toggle() } label: {
                HStack { Text(grouping.rawValue); Image(systemName: "chevron.down").font(.caption2) }.padding(7)
            }.background(JournalStyle.content(dark), in: RoundedRectangle(cornerRadius: 7))
                // Capture the trigger's frame so the custom dropdown (no arrow, drawn at the window root) hangs under it.
                .background(GeometryReader { g in Color.clear.preference(key: MenuAnchorKey.self, value: g.frame(in: .named("journalRoot"))) })
            ViewModeToggle(compact: $compact)   // choose one of two views (comfortable / compact), not on/off
            Text("\(entries.count) \(search.isEmpty ? "entries" : "found")").font(JournalStyle.font(11)).foregroundStyle(JournalStyle.tertiary(dark)).fixedSize()
            Spacer(minLength: 0)
            // The export chip + "Export now" action vanish entirely when export is turned Off in settings.
            if exportMode != "off" {
                HStack(spacing: 5) {
                    Circle().fill(Color(journalHex: 0x2E9E5B)).frame(width: 6, height: 6)
                    Text("Export: \(exportMode)")
                }.font(JournalStyle.font(11)).padding(7).background(JournalStyle.content(dark), in: RoundedRectangle(cornerRadius: 7))
                    .help("Current export mode")
                JournalToolbarAction(systemImage: "arrow.up.to.line", help: "Export now to the vault note", busy: exporting) {
                    exporting = true
                    Task { @MainActor in
                        defer { exporting = false }
                        do {
                            reportExport(try await client.exportNow())
                        } catch { notify(error.localizedDescription) }
                    }
                }
            }
            JournalToolbarToggle(systemImage: details ? "sidebar.right" : "rectangle", on: details,
                                 help: details ? "Hide details" : "Show details") { details.toggle() }
        }.font(JournalStyle.font(12, .semibold)).padding(10)
    }
    private var selectionBar: some View {
        HStack(spacing: 12) {
            Text("\(checked.count) selected")
            Button("Select all") { checked = Set(entries.map(\.id)) }
            Button("Clear") { checked.removeAll() }
            Spacer()
            Button("Delete") { requestDelete(checked) }.foregroundStyle(RhemionStyle.danger).disabled(deleting)
        }.font(JournalStyle.font(12, .semibold)).padding(10).background(JournalStyle.gold.opacity(0.12))
    }
    private var list: some View {
        ScrollView {
            LazyVStack(spacing: 0, pinnedViews: [.sectionHeaders]) {
                if entries.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: "text.book.closed").font(.title)
                        Text(model.loading ? "Loading…" : search.isEmpty ? "No entries yet" : "No matches")
                    }.foregroundStyle(JournalStyle.secondary(dark)).padding(.vertical, 70).frame(maxWidth: .infinity)
                } else if !search.isEmpty || grouping == .flat { rows(entries) }
                else {
                    ForEach(visibleGroups(JournalDoc.groups(entries, by: grouping))) { group in
                        if group.level == .day {
                            Section { if !collapsed.contains(group.id) { rows(group.entries) } } header: { groupHeader(group) }
                        } else { groupHeader(group) }
                    }
                }
            }.padding(.bottom, 14)
        }.background(JournalStyle.sidebar(dark))
    }
    private func groupHeader(_ group: JournalGroup) -> some View {
        HStack(spacing: 8) {
            if !checked.isEmpty {   // group checkboxes appear only once at least one entry is selected
                let ids = Set(group.entries.map(\.id))
                let count = checked.intersection(ids).count
                JournalCheckbox(on: count == ids.count, mixed: count > 0 && count < ids.count)
                    .frame(width: 22, height: 22).contentShape(Rectangle())
                    .onTapGesture { if count == ids.count { checked.subtract(ids) } else { checked.formUnion(ids) } }
            }
            Button {
                if !collapsed.insert(group.id).inserted { collapsed.remove(group.id) }
            } label: {
                HStack(spacing: 6) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(group.title).font(JournalStyle.font(group.level == .month ? 15 : group.level == .week ? 10 : 12.5, group.level == .month ? .heavy : .semibold))
                        if group.level == .day { Text("\(group.entries.count)").font(JournalStyle.font(11)).foregroundStyle(JournalStyle.tertiary(dark)) }
                    }
                    Spacer(minLength: 4)
                    Image(systemName: collapsed.contains(group.id) ? "chevron.right" : "chevron.down").font(.system(size: 10)).foregroundStyle(JournalStyle.tertiary(dark))
                }.contentShape(Rectangle())
            }
        }.foregroundStyle(group.level == .week ? JournalStyle.secondary(dark) : JournalStyle.text(dark))
            .padding(.horizontal, 12).padding(.top, group.level == .month ? 15 : 9).padding(.bottom, 5)
            .background(JournalStyle.sidebar(dark)).overlay(alignment: .top) { if group.level == .month { Divider() } }
    }
    private func rows(_ values: [JournalEntry]) -> some View {
        ForEach(Array(values.enumerated()), id: \.element.id) { index, entry in
            JournalRow(entry: entry, compact: compact && search.isEmpty, query: search,
                       selected: opened == entry.id, checked: checked.contains(entry.id), selecting: !checked.isEmpty, hovered: hovered == entry.id,
                       separator: index + 1 < values.count && opened != values[index + 1].id && hovered != values[index + 1].id,
                       open: { opened = entry.id }, toggle: { if !checked.insert(entry.id).inserted { checked.remove(entry.id) } }, copy: {
                           NSPasteboard.general.clearContents()
                           NSPasteboard.general.setString(entry.transcript, forType: .string)
                           notify("Copied (Final)")
                       }).onHover { inside in hovered = inside ? entry.id : (hovered == entry.id ? nil : hovered) }
        }
    }
    private func requestDelete(_ ids: Set<String>) {
        guard !deleting, !ids.isEmpty else { return }
        pendingDelete = ids
        confirmDelete = true
    }

    private func performDelete() {
        let ids = pendingDelete.sorted()
        guard !deleting, !ids.isEmpty else { return }
        pendingDelete.removeAll()
        deleting = true
        // If the open entry is among those being deleted, focus its nearest survivor (the next entry
        // below in the flat list, else the one above) instead of jumping to the top of the journal.
        let idSet = Set(ids)
        let flat = entries
        let focus: String? = {
            guard let openedID = opened, idSet.contains(openedID),
                  let i = flat.firstIndex(where: { $0.id == openedID }) else { return opened }
            if let below = flat[(i + 1)...].first(where: { !idSet.contains($0.id) }) { return below.id }
            return flat[..<i].last(where: { !idSet.contains($0.id) })?.id
        }()
        Task { @MainActor in
            do {
                let removed = try await client.historyDelete(ids: ids)
                notify("Deleted \(removed.count) \(removed.count == 1 ? "entry" : "entries") permanently.")
            } catch {
                notify(error.localizedDescription)
            }
            opened = focus
            checked.removeAll()
            model.reload()
            deleting = false
        }
    }

    /// Export status line. Skipped notes (spec 4.5) are named — the user must learn which months
    /// were not written and why.
    static func exportStatus(_ result: RuntimeClient.ExportResult) -> String {
        let done = "Export complete: \(max(0, result.months.count - result.skipped.count)) month(s)"
        guard !result.skipped.isEmpty else { return done }
        return done + ". Not written — file exists and wasn't written by Rhemion: "
            + result.skipped.joined(separator: ", ")
    }

    private func reportExport(_ result: RuntimeClient.ExportResult) {
        notify(Self.exportStatus(result), seconds: result.skipped.isEmpty ? 3 : 8)
    }

    private func notify(_ message: String) { notify(message, seconds: 3) }

    private func notify(_ message: String, seconds: Int) {
        toastTask?.cancel(); toast = message
        toastTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(seconds))
            if !Task.isCancelled { toast = nil }
        }
    }
}

/// A 30×30 toolbar icon toggle matching the mockup's `.icon-toggle`: neutral gray chip when active,
/// gray (`--line2`) on hover — never an accent tint (it sits quietly next to the window chrome).
private struct JournalToolbarToggle: View {
    let systemImage: String
    let on: Bool
    let help: String
    let action: () -> Void
    @Environment(\.colorScheme) private var scheme
    @State private var hover = false
    private var dark: Bool { scheme == .dark }
    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage).frame(width: 30, height: 30)
                .foregroundStyle(on || hover ? JournalStyle.text(dark) : JournalStyle.secondary(dark))
                .contentShape(Rectangle())
        }.buttonStyle(.plain)
            // Active = raised LIGHT surface (--win), the app's "on = neutral-raised" language (same as the
            // Final/Clean/Raw and Theme pills) — not a gray chip. These float on a near-white toolbar (no
            // segmented track), so ON also carries a hairline border for a continuous edge + a restrained
            // shadow for elevation; the border+shadow are reserved for ON so hover can't masquerade as it.
            .background(!on && hover ? JournalStyle.line2(dark) : .clear, in: RoundedRectangle(cornerRadius: 8))
            .activeTile(on, dark: dark, radius: 8)
            .onHover { hover = $0 }.help(help).accessibilityLabel(help).accessibilityValue(on ? "On" : "Off")
    }
}
/// A two-position VIEW switcher (comfortable / compact) — a choice between two layouts, not an on/off, so
/// it reads as a segmented control: both icons always visible on a track, the current view a raised light
/// pill (the app's selection language, matching the Final/Clean/Raw and Theme segments).
private struct ViewModeToggle: View {
    @Binding var compact: Bool
    @Environment(\.colorScheme) private var scheme
    private var dark: Bool { scheme == .dark }
    var body: some View {
        HStack(spacing: 2) {
            segment(icon: "rectangle.grid.1x2", isCompact: false, help: "Comfortable view")
            segment(icon: "list.bullet", isCompact: true, help: "Compact view")
        }
        .padding(2)
        .background(JournalStyle.sidebar(dark), in: RoundedRectangle(cornerRadius: 8))
        .overlay { RoundedRectangle(cornerRadius: 8).strokeBorder(JournalStyle.line(dark), lineWidth: 0.5) }
    }
    private func segment(icon: String, isCompact: Bool, help: String) -> some View {
        let on = compact == isCompact
        return Button { compact = isCompact } label: {
            Image(systemName: icon).font(.system(size: 13, weight: .medium))
                .foregroundStyle(on ? JournalStyle.text(dark) : JournalStyle.secondary(dark))
                .frame(width: 30, height: 24)
                .activeTile(on, dark: dark, radius: 6)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain).help(help).accessibilityLabel(help)
        .accessibilityAddTraits(on ? [.isButton, .isSelected] : .isButton)
    }
}
/// A momentary toolbar ACTION icon (vs `JournalToolbarToggle`, which persists an on/off chip): no sticky
/// fill, just a neutral hover wash, and it swaps to a small spinner while `busy`. Reused by future toolbar
/// actions (e.g. a Share button) so they stay visually consistent.
private struct JournalToolbarAction: View {
    let systemImage: String
    let help: String
    var busy = false
    let action: () -> Void
    @Environment(\.colorScheme) private var scheme
    @State private var hover = false
    private var dark: Bool { scheme == .dark }
    var body: some View {
        Button(action: action) {
            Group {
                if busy { ProgressView().controlSize(.small).scaleEffect(0.7) }
                else { Image(systemName: systemImage) }
            }
            .frame(width: 30, height: 30)
            .foregroundStyle(hover ? JournalStyle.text(dark) : JournalStyle.secondary(dark))
            .contentShape(Rectangle())
        }.buttonStyle(.plain)
            .background(hover ? JournalStyle.line2(dark) : .clear, in: RoundedRectangle(cornerRadius: 8))
            .onHover { hover = $0 }.help(help).accessibilityLabel(help)
            .disabled(busy)
    }
}
/// Captures a trigger's frame (in the "journalRoot" space) so a root-level dropdown can hang under it.
private struct MenuAnchorKey: PreferenceKey {
    static let defaultValue = CGRect.zero
    static func reduce(value: inout CGRect, nextValue: () -> CGRect) { let next = nextValue(); if next != .zero { value = next } }
}
/// Separate key for the detail's ⓘ panel — a shared key would bubble up to JournalView and clobber the
/// grouping anchor (the detail is a descendant of the view that reads MenuAnchorKey).
private struct InfoAnchorKey: PreferenceKey {
    static let defaultValue = CGRect.zero
    static func reduce(value: inout CGRect, nextValue: () -> CGRect) { let next = nextValue(); if next != .zero { value = next } }
}

/// The shared menu/popover surface: opaque (not glass), concentric radii —
/// container radius 12, inner inset 6, so a row-highlight radius of 6 nests perfectly (12 − 6 = 6).
private struct JournalMenuCard<Content: View>: View {
    @ViewBuilder let content: Content
    @Environment(\.colorScheme) private var scheme
    private var dark: Bool { scheme == .dark }
    var body: some View {
        VStack(spacing: 2) { content }
            .padding(6)
            .frame(width: 232)
            .background(JournalStyle.win(dark), in: RoundedRectangle(cornerRadius: 12))
            .overlay { RoundedRectangle(cornerRadius: 12).strokeBorder(JournalStyle.line(dark), lineWidth: 0.5) }
            .shadow(color: .black.opacity(dark ? 0.44 : 0.22), radius: 17, y: 12)
    }
}

/// A menu row in the native-menu layout: a leading 20px accessory column holding a checkmark for the
/// selected item, then the label. Highlight = solid gold with WHITE text (both themes), radius 6.
private struct JournalMenuRow: View {
    let title: String
    let checked: Bool
    let action: () -> Void
    @Environment(\.colorScheme) private var scheme
    @State private var hover = false
    private var dark: Bool { scheme == .dark }
    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: "checkmark").font(.system(size: 11, weight: .semibold)).opacity(checked ? 1 : 0).frame(width: 20)
                Text(title).font(JournalStyle.font(13))
                Spacer(minLength: 0)
            }.padding(.vertical, 5).padding(.trailing, 8).frame(minHeight: 28).contentShape(Rectangle())
        }.buttonStyle(.plain)
            .foregroundStyle(hover ? Color.white : JournalStyle.text(dark))
            .background(hover ? JournalStyle.gold : .clear, in: RoundedRectangle(cornerRadius: 6))
            .onHover { hover = $0 }
    }
}
/// Raised R1 button (DESIGN.md) — the exact treatment of the Dictionary's "Add replacement": a raised
/// win pill + hairline border + a soft shadow, hover shifts the fill.
private struct JournalActionButton: View {
    let title: String
    let systemImage: String
    let action: () -> Void
    @Environment(\.colorScheme) private var scheme
    @State private var hover = false
    private var dark: Bool { scheme == .dark }
    var body: some View {
        Button(action: action) {
            Label(title, systemImage: systemImage).font(JournalStyle.font(12, .medium))
                .foregroundStyle(JournalStyle.text(dark))
                .padding(.horizontal, 12).padding(.vertical, 7)
                .background(hover ? JournalStyle.line2(dark) : JournalStyle.win(dark), in: RoundedRectangle(cornerRadius: 8))
                .overlay { RoundedRectangle(cornerRadius: 8).strokeBorder(JournalStyle.line(dark), lineWidth: 0.5) }
                .shadow(color: .black.opacity(dark ? 0.22 : 0.06), radius: 1.5, y: 1)
        }.buttonStyle(.plain).onHover { hover = $0 }
    }
}
/// A Quiet-tier action (DESIGN.md): an icon + text link with no border or fill — same treatment as the
/// settings "Restore defaults". `color` sets the accent (e.g. red for a destructive Delete); hover dims it.
private struct JournalQuietAction: View {
    let title: String
    let systemImage: String
    var color: Color? = nil
    let action: () -> Void
    @Environment(\.colorScheme) private var scheme
    @State private var hover = false
    private var dark: Bool { scheme == .dark }
    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: systemImage).font(.system(size: 11, weight: .regular))
                Text(title).font(JournalStyle.font(12.5, .regular))
            }
            .foregroundStyle(color ?? JournalStyle.text(dark))
            .opacity(hover ? 0.7 : 1)
            .contentShape(Rectangle())
        }.buttonStyle(.plain).onHover { hover = $0 }
    }
}
/// Gold checkbox (DESIGN.md): solid gold fill + white check when on, hairline border when off. Kept
/// internal (not private) so the Clear Data window (ClearData.swift) and the Uninstall window
/// (FarewellWindow.swift) reuse the exact same control rather than a second implementation.
struct JournalCheckbox: View {
    let on: Bool
    var mixed = false
    // Pure visual — the tap is handled by the caller's .onTapGesture so it can't be swallowed by a
    // sibling row Button (the previous nested-Button setup never registered clicks).
    @Environment(\.colorScheme) private var scheme
    private var dark: Bool { scheme == .dark }
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 3.5).fill(on || mixed ? JournalStyle.gold : .clear)   // unchecked = no fill (mockup)
            RoundedRectangle(cornerRadius: 3.5).strokeBorder(on || mixed ? JournalStyle.gold : JournalStyle.cbBorder(dark), lineWidth: 1)
            if on || mixed { Image(systemName: mixed ? "minus" : "checkmark").font(.system(size: 9, weight: .bold)).foregroundStyle(.white) }
        }.frame(width: 15, height: 15)
            .accessibilityLabel("Select").accessibilityValue(mixed ? "Mixed" : on ? "Yes" : "No").accessibilityAddTraits(.isButton)
    }
}
private struct JournalRow: View {
    let entry: JournalEntry
    let compact: Bool
    let query: String
    let selected: Bool
    let checked: Bool
    let selecting: Bool
    let hovered: Bool
    let separator: Bool
    let open: () -> Void
    let toggle: () -> Void
    let copy: () -> Void
    @Environment(\.colorScheme) private var scheme
    private var dark: Bool { scheme == .dark }
    private var preview: AttributedString {
        // A search hit in Clean/Raw should be visible even when the final text differs.
        let source = query.isEmpty ? entry.transcript : [entry.transcript, entry.clean, entry.raw].first { $0.localizedStandardContains(query) } ?? entry.transcript
        var value = AttributedString(source)
        if !query.isEmpty {
            var remaining = source.startIndex..<source.endIndex
            while let range = source.range(of: query, options: [.caseInsensitive, .diacriticInsensitive], range: remaining) {
                if let converted = Range(range, in: value) { value[converted].backgroundColor = JournalStyle.gold.opacity(0.35) }
                remaining = range.upperBound..<source.endIndex
            }
        }
        return value
    }
    var body: some View {
        HStack(alignment: compact ? .center : .top, spacing: 8) {
            JournalCheckbox(on: checked)
                .frame(width: 20, height: 18, alignment: compact ? .center : .top).contentShape(Rectangle())
                .opacity(hovered || selecting || checked ? 1 : 0)   // reveal on hover / in selection; the tap zone stays live so the first click always lands
                .onTapGesture { open(); toggle() }   // also open the ticked entry so the detail (and its Delete) act on THIS record
            Button(action: open) {
                Group {
                    if compact {
                        HStack(spacing: 8) {
                            Text(JournalDoc.label(entry.ts, "HH:mm")).font(JournalStyle.font(11.5, .medium)).foregroundStyle(JournalStyle.secondary(dark))
                            Text(preview).font(JournalStyle.font(13, .light)).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
                            Text(entry.duration).font(JournalStyle.font(11)).foregroundStyle(JournalStyle.tertiary(dark))
                        }
                    } else {
                        VStack(alignment: .leading, spacing: 5) {
                            Text(preview).font(JournalStyle.font(13, .light)).lineLimit(2).multilineTextAlignment(.leading).frame(maxWidth: .infinity, alignment: .leading)
                            HStack(spacing: 5) {
                                Text(JournalDoc.label(entry.ts, query.isEmpty ? "HH:mm" : "dd.MM.yyyy · HH:mm"))
                                Text("·")
                                Text(entry.appName ?? "Unknown app").lineLimit(1)
                                Spacer(minLength: 0)
                                Text(entry.duration)
                            }.font(JournalStyle.font(11)).foregroundStyle(JournalStyle.tertiary(dark))
                        }
                    }
                }.contentShape(Rectangle())
            }.buttonStyle(.plain)
            Button(action: copy) { Image(systemName: "doc.on.doc").font(.system(size: 12, weight: .regular)).foregroundStyle(JournalStyle.tertiary(dark)).frame(width: 18, height: 18) }
                .opacity(hovered ? 1 : 0).allowsHitTesting(hovered).help("Copy (Final)")
        }.monospacedDigit().padding(.horizontal, 8).padding(.vertical, compact ? 6 : 8)
            .background(selected ? JournalStyle.selected(dark) : hovered ? JournalStyle.line(dark).opacity(0.6) : .clear, in: RoundedRectangle(cornerRadius: 6))
            .overlay { if !compact && !selected { RoundedRectangle(cornerRadius: 6).strokeBorder(JournalStyle.line(dark), lineWidth: 0.5).allowsHitTesting(false) } }
            .overlay(alignment: .bottom) {
                if compact && separator && !selected && !hovered { JournalStyle.line(dark).frame(height: 0.5).padding(.leading, 24) }
            }.padding(.horizontal, compact ? 8 : 10).padding(.vertical, compact ? 0 : 4)
    }
}

private struct JournalDetail: View {
    let entry: JournalEntry
    let notify: (String) -> Void
    let delete: () -> Void
    let deleting: Bool
    @Environment(\.colorScheme) private var scheme
    @State private var mode = "Final"
    @State private var info = false
    @State private var infoAnchor: CGRect = .zero
    @State private var textHeight: CGFloat = 0
    private var dark: Bool { scheme == .dark }
    private var transcript: String { mode == "Raw" ? entry.raw : mode == "Clean" ? entry.clean : entry.transcript }
    var body: some View {
        VStack(spacing: 0) {
            // PINNED header — stays put while the transcript scrolls, so Copy is always reachable (a long
            // transcript no longer pushes it off the bottom). Order: mode switcher · app · ⓘ · Copy.
            VStack(alignment: .leading, spacing: 12) {
                Text(JournalDoc.label(entry.ts, "d MMMM yyyy · HH:mm")).font(JournalStyle.font(18, .bold))
                HStack(spacing: 8) {
                    modeSwitcher
                    Spacer(minLength: 8)
                    Text(entry.appName ?? "—").font(JournalStyle.font(11)).lineLimit(1).foregroundStyle(JournalStyle.tertiary(dark))
                    Button { info.toggle() } label: { Image(systemName: "info.circle") }.help("How it was recognized")
                        .background(GeometryReader { g in Color.clear.preference(key: InfoAnchorKey.self, value: g.frame(in: .named("detailRoot"))) })
                    JournalActionButton(title: "Copy", systemImage: "doc.on.doc") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(transcript, forType: .string)
                        notify("Copied (\(mode))")
                    }
                }
            }
            .padding(EdgeInsets(top: 22, leading: 24, bottom: 14, trailing: 24))
            Divider().overlay(JournalStyle.line(dark))
            // SCROLL body — transcript, player, and the (deliberate, destructive) Delete at the bottom.
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    // Selectable transcript in a read-only NSTextView so the selection highlight is OUR gold,
                    // not the system blue accent (SwiftUI's .textSelection can't recolor its highlight).
                    GeometryReader { geo in
                        SelectableText(text: transcript.isEmpty ? "No text" : transcript, width: geo.size.width,
                                       dark: dark, height: $textHeight)
                    }
                    .frame(height: max(textHeight, 1)).frame(maxWidth: .infinity, alignment: .leading)
                    JournalPlayer(url: entry.audioURL, durationMS: entry.audioDurationMS, notify: notify)
                    HStack {
                        Spacer()
                        JournalQuietAction(title: "Delete", systemImage: "trash", color: RhemionStyle.danger, action: delete).disabled(deleting)
                    }
                }.padding(24)
            }
        }
        .coordinateSpace(name: "detailRoot")
        .onPreferenceChange(InfoAnchorKey.self) { infoAnchor = $0 }
        .overlay { infoPanel }
    }

    // Final / Clean / Raw — a segmented control (active = raised win pill + soft shadow, thin text).
    private var modeSwitcher: some View {
        HStack(spacing: 2) {
            ForEach(["Final", "Clean", "Raw"], id: \.self) { value in
                let on = mode == value
                Button { mode = value } label: {
                    Text(value).font(JournalStyle.font(12, .regular))
                        .foregroundStyle(on ? JournalStyle.text(dark) : JournalStyle.secondary(dark))
                        .padding(.horizontal, 13).padding(.vertical, 4)
                        .contentShape(Rectangle())
                }
                .activeTile(on, dark: dark, radius: 6)
            }
        }.padding(2).background(JournalStyle.sidebar(dark), in: RoundedRectangle(cornerRadius: 8))
            .overlay { RoundedRectangle(cornerRadius: 8).strokeBorder(JournalStyle.line(dark), lineWidth: 0.5) }
    }
    // Same surface as the grouping menu (opaque card, radius 12, soft shadow, no arrow), hung under the
    // ⓘ button and right-aligned to it so it stays inside the detail pane. Click-away dismisses.
    @ViewBuilder private var infoPanel: some View {
        if info {
            ZStack(alignment: .topLeading) {
                Color.clear.contentShape(Rectangle()).onTapGesture { info = false }
                VStack(alignment: .leading, spacing: 10) {
                    Text("How it was recognized").font(JournalStyle.font(13, .semibold)).foregroundStyle(JournalStyle.text(dark))
                    infoRow("Engine", entry.engine)
                    infoRow("Insertion method", entry.deliveryMethod ?? "—")
                    infoRow("Processing", entry.ms.map { "\($0) ms" } ?? "—")
                    infoRow("Duration", entry.duration)
                }
                .padding(14)
                .frame(width: 264, alignment: .leading)
                .background(JournalStyle.win(dark), in: RoundedRectangle(cornerRadius: 12))
                .overlay { RoundedRectangle(cornerRadius: 12).strokeBorder(JournalStyle.line(dark), lineWidth: 0.5) }
                .shadow(color: .black.opacity(dark ? 0.44 : 0.22), radius: 17, y: 12)
                .fixedSize()
                .offset(x: max(8, infoAnchor.maxX - 264), y: infoAnchor.maxY + 5)
            }
        }
    }
    private func infoRow(_ title: String, _ value: String) -> some View {
        HStack { Text(title).foregroundStyle(JournalStyle.secondary(dark)); Spacer(); Text(value).foregroundStyle(JournalStyle.text(dark)) }.font(JournalStyle.font(12))
    }
}

/// Real local-WAV transport: AVAudioPlayer play/pause + drag-to-seek on the "thread" progress, and
/// Reveal-in-Finder. When the entry has no audio (never retained / pruned) play + folder are disabled.
private struct JournalPlayer: View {
    let url: URL?
    let durationMS: Int?
    let notify: (String) -> Void
    @Environment(\.colorScheme) private var scheme
    @State private var player: AVAudioPlayer?
    @State private var playing = false
    @State private var position = 0.0
    @State private var scrubbing = false
    @State private var rate = 1.0
    private let ticker = Timer.publish(every: 0.03, on: .main, in: .common).autoconnect()
    private var dark: Bool { scheme == .dark }
    private var available: Bool { url != nil }        // the WAV exists on disk (Reveal-in-Finder)
    private var playable: Bool { player != nil }       // AVAudioPlayer actually loaded it (play / seek / speed)
    private var total: Double { let d = player?.duration ?? 0; return d > 0 ? d : Double(max(0, durationMS ?? 0)) / 1000 }
    var body: some View {
        HStack(spacing: 12) {
            Button { toggle() } label: {
                Image(systemName: playing ? "pause.fill" : "play.fill").font(.system(size: 14, weight: .semibold)).offset(x: playing ? 0 : 1)
                    .foregroundStyle(JournalStyle.text(dark)).frame(width: 30, height: 30)
            }.buttonStyle(JournalPlayStyle()).disabled(!playable)
                .help(playable ? (playing ? "Pause" : "Play") : available ? "Audio couldn't be loaded" : "No audio for this entry").accessibilityLabel(playing ? "Pause" : "Play")
            GeometryReader { geometry in
                let width = max(1, geometry.size.width - 12)
                ZStack(alignment: .leading) {
                    Capsule().fill(JournalStyle.tertiary(dark).opacity(0.55)).frame(height: 2)
                    // Played portion — monochrome INK (text color): near-black on light / near-white on
                    // dark, so it clearly contrasts the grey track (white-on-light barely showed).
                    Capsule().fill(JournalStyle.text(dark)).frame(width: width * position, height: 2)
                    // Thumb matches the Copy/Play raised style: a raised neutral badge (win + hairline +
                    // shadow) with a contrasting inner dot (dark on light, light on dark).
                    ZStack {
                        Circle().fill(JournalStyle.win(dark)).frame(width: 13, height: 13)
                            .overlay { Circle().strokeBorder(JournalStyle.line(dark), lineWidth: 0.5) }
                            .shadow(color: .black.opacity(dark ? 0.30 : 0.14), radius: 1.5, y: 1)
                        Circle().fill(dark ? Color(journalHex: 0xE8E8EC) : Color(journalHex: 0x1D1D1F)).frame(width: 5, height: 5)
                    }.offset(x: width * position - 6.5)
                }.padding(.horizontal, 6).frame(height: 28).contentShape(Rectangle())
                    .gesture(DragGesture(minimumDistance: 0)
                        .onChanged { if playable { scrubbing = true; position = min(1, max(0, ($0.location.x - 6) / width)) } }
                        .onEnded { _ in if playable { seek(position); scrubbing = false } })
            }.frame(minWidth: 35).frame(height: 28).opacity(playable ? 1 : 0.5)
                .accessibilityLabel("Playback position").accessibilityValue(JournalDoc.duration(position * total))
            Text("\(JournalDoc.duration(position * total)) / \(available || durationMS != nil ? JournalDoc.duration(total) : "—")").font(JournalStyle.font(11)).monospacedDigit().fixedSize()
            Button { cycleRate() } label: { Text(rateLabel).font(JournalStyle.font(12, .medium)).fixedSize() }
                .buttonStyle(.plain).disabled(!playable).help("Playback speed")
            Button { if let url { NSWorkspace.shared.activateFileViewerSelecting([url]) } else { notify("No audio file for this entry.") } } label: { Image(systemName: "folder") }
                .disabled(!available).help("Reveal in Finder").accessibilityLabel("Reveal in Finder")
        }.foregroundStyle(JournalStyle.secondary(dark)).padding(13)
            .background(JournalStyle.sidebar(dark), in: RoundedRectangle(cornerRadius: 10))
            .overlay { RoundedRectangle(cornerRadius: 10).strokeBorder(JournalStyle.line(dark), lineWidth: 0.5) }
            .onAppear { if let url { let p = try? AVAudioPlayer(contentsOf: url); p?.enableRate = true; p?.prepareToPlay(); player = p } }
            .onDisappear { player?.stop(); player = nil }
            .onReceive(ticker) { _ in
                guard playing, !scrubbing, let p = player else { return }
                if p.isPlaying { position = p.duration > 0 ? p.currentTime / p.duration : 0 }
                else { playing = false; position = 0 }   // reached the end
            }
    }
    private func toggle() {
        guard let p = player else { return }
        if p.isPlaying { p.pause(); playing = false }
        else { if position >= 1 { p.currentTime = 0; position = 0 }; p.play(); p.rate = Float(rate); playing = true }
    }
    private func seek(_ fraction: Double) {
        guard let p = player else { return }
        p.currentTime = max(0, min(p.duration, fraction * p.duration))
    }
    private var rateLabel: String { rate == rate.rounded() ? "\(Int(rate))×" : String(format: "%g×", rate) }
    private func cycleRate() {
        let rates = [1.0, 1.25, 1.5, 2.0]
        rate = rates[((rates.firstIndex(of: rate) ?? 0) + 1) % rates.count]
        player?.rate = Float(rate)   // live while playing; re-applied after the next play()
    }
}
/// The Play/Pause face — a raised NEUTRAL circle matching the Copy button (Raised R1): win fill + a
/// hairline border + a soft shadow, hover shifts the fill. Monochrome (no gold, no breathing glow).
private struct JournalPlayStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        JournalPlayFace(label: configuration.label, pressed: configuration.isPressed)
    }
}
private struct JournalPlayFace<Label: View>: View {
    let label: Label
    let pressed: Bool
    @Environment(\.colorScheme) private var scheme
    @State private var hover = false
    private var dark: Bool { scheme == .dark }
    var body: some View {
        label
            .background(hover ? JournalStyle.line2(dark) : JournalStyle.win(dark), in: Circle())
            .overlay { Circle().strokeBorder(JournalStyle.line(dark), lineWidth: 0.5) }
            .shadow(color: .black.opacity(dark ? 0.22 : 0.10), radius: 1.5, y: 1)
            .scaleEffect(pressed ? 0.95 : 1)
            .onHover { hover = $0 }
    }
}

private extension NSColor {
    convenience init(journalHex hex: UInt32) {
        self.init(srgbRed: CGFloat((hex >> 16) & 255) / 255, green: CGFloat((hex >> 8) & 255) / 255,
                  blue: CGFloat(hex & 255) / 255, alpha: 1)
    }
}

/// A read-only, selectable transcript rendered with AppKit so the selection highlight is OUR gold instead
/// of the system-accent blue (SwiftUI's `.textSelection` exposes no way to recolor the highlight). Non-
/// scrolling — the parent ScrollView scrolls; it self-sizes by reporting the wrapped height for the given
/// width back through `height`. Native Cmd+C copies the selection.
private struct SelectableText: NSViewRepresentable {
    let text: String
    let width: CGFloat
    let dark: Bool
    @Binding var height: CGFloat

    private var font: NSFont { NSFont(name: "Mulish-Regular", size: 15) ?? .systemFont(ofSize: 15) }
    private var textColor: NSColor { NSColor(journalHex: dark ? 0xE8E8EC : 0x1D1D1F) }
    // Same warm-yellow hue as the journal list's selected row (#F6DD84), just slightly translucent so the
    // text keeps breathing through it (the solid fill read too dense). Base hue matches the selected row —
    // the amber gold #E0A42E turned peachy on white.
    private var selectionColor: NSColor {
        NSColor(journalHex: 0xF6DD84).withAlphaComponent(dark ? 0.32 : 0.70)
    }

    private func attributed() -> NSAttributedString {
        let para = NSMutableParagraphStyle(); para.lineSpacing = 7
        return NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: textColor, .paragraphStyle: para])
    }

    func makeNSView(context: Context) -> NSTextView {
        let tv = NSTextView()
        tv.isEditable = false
        tv.isSelectable = true
        tv.drawsBackground = false
        tv.textContainerInset = .zero
        tv.textContainer?.lineFragmentPadding = 0
        tv.isVerticallyResizable = true
        tv.isHorizontallyResizable = false
        return tv
    }

    func updateNSView(_ tv: NSTextView, context: Context) {
        tv.selectedTextAttributes = [.backgroundColor: selectionColor]
        tv.textStorage?.setAttributedString(attributed())
        guard width > 0 else { return }
        let bounds = attributed().boundingRect(with: NSSize(width: width, height: .greatestFiniteMagnitude),
                                               options: [.usesLineFragmentOrigin, .usesFontLeading])
        let measured = ceil(bounds.height) + 2   // small buffer so the last line never clips
        if abs(measured - height) > 0.5 {
            DispatchQueue.main.async { height = measured }
        }
    }
}
