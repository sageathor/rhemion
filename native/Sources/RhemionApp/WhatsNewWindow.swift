// What's New — shown once after an update, filled from the release notes bundled with the app (the same file
// that is published, so there is no second text to keep in sync). Never after a fresh install: there Welcome
// comes first and everything is new. Re-openable from the menu bar ("What's New…") and from About.
// Layout: the Welcome frame (800 pt, a 250 pt side column with the logo); the changes as a plain list.

import AppKit
import SwiftUI

/// One version's entry of RELEASE-NOTES.md: `## <version> — <YYYY-MM-DD>`, then `### <group>` with `- item` lines.
struct ReleaseNotesEntry: Equatable {
    struct Group: Equatable { let title: String; let items: [String] }
    let version: String
    let date: String
    let groups: [Group]

    /// Every entry in the file, newest first as written. The format comment at the top is skipped.
    static func parse(_ text: String) -> [ReleaseNotesEntry] {
        var body = text
        while let open = body.range(of: "<!--"), let close = body.range(of: "-->", range: open.upperBound..<body.endIndex) {
            body.removeSubrange(open.lowerBound..<close.upperBound)
        }
        var entries: [ReleaseNotesEntry] = []
        var version: String?, date = "", groups: [Group] = [], title: String?, items: [String] = []
        func closeGroup() { if let t = title, !items.isEmpty { groups.append(Group(title: t, items: items)) }; title = nil; items = [] }
        func closeEntry() { closeGroup(); if let v = version { entries.append(ReleaseNotesEntry(version: v, date: date, groups: groups)) }; groups = [] }
        for raw in body.components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("## ") {
                closeEntry()
                let head = line.dropFirst(3).components(separatedBy: " — ")
                version = head.first.map { $0.trimmingCharacters(in: .whitespaces) }
                date = head.count > 1 ? head[1].trimmingCharacters(in: .whitespaces) : ""
            } else if line.hasPrefix("### ") {
                closeGroup(); title = String(line.dropFirst(4))
            } else if line.hasPrefix("- "), title != nil {
                items.append(String(line.dropFirst(2)))
            }
        }
        closeEntry()
        return entries
    }

    /// The bundled notes' entry for `version`, if the app carries one.
    static func bundled(for version: String, bundle: Bundle = .main) -> ReleaseNotesEntry? {
        guard let url = bundle.url(forResource: "RELEASE-NOTES", withExtension: "md"),
              let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        return parse(text).first { $0.version == version }
    }

    /// "3.1" from "3.1.0": the release as people name it.
    var shortVersion: String { version.split(separator: ".").prefix(2).joined(separator: ".") }

    /// "11 October 2026" from "2026-10-11" (English, like the rest of the UI).
    var longDate: String {
        let parse = DateFormatter(); parse.locale = Locale(identifier: "en_US_POSIX"); parse.dateFormat = "yyyy-MM-dd"
        guard let d = parse.date(from: date) else { return date }
        let show = DateFormatter(); show.locale = Locale(identifier: "en_US_POSIX"); show.dateFormat = "d MMMM yyyy"
        return show.string(from: d)
    }
}

/// When What's New opens by itself: once per version, after an update only.
enum WhatsNewPolicy {
    static let seenKey = "rhemion.v3.whatsNewSeenVersion"

    /// `freshInstall`: Welcome had never been shown before this launch. Then nothing is "new": the current version
    /// is marked as seen and nothing opens. An update from a build without the mark (3.0.x) does open it.
    static func shouldShow(current: String, freshInstall: Bool, defaults: UserDefaults = .standard) -> Bool {
        let seen = defaults.string(forKey: seenKey)
        if seen == nil, freshInstall { defaults.set(current, forKey: seenKey); return false }
        return seen != current
    }

    static func markSeen(_ version: String, defaults: UserDefaults = .standard) { defaults.set(version, forKey: seenKey) }
}

@MainActor
final class WhatsNewWindowController: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    private let logoClock = WelcomeLogoClock()
    private let version: String

    init(version: String) { self.version = version; super.init() }

    /// Whether the bundled notes have an entry for this version (no entry: nothing to show).
    var hasNotes: Bool { ReleaseNotesEntry.bundled(for: version) != nil }

    func show() {
        guard let entry = ReleaseNotesEntry.bundled(for: version) else { log("whats-new: no notes for \(version)"); return }
        WhatsNewPolicy.markSeen(version)
        if window == nil {
            let tag = AboutInfo.repository.appendingPathComponent("releases/tag/v\(version)")
            let root = WhatsNewView(entry: entry, logoClock: logoClock,
                                    onGitHub: { NSWorkspace.shared.open(tag) },
                                    onContinue: { [weak self] in self?.window?.close() })
            let hosting = NSHostingController(rootView: root)
            hosting.sizingOptions = [.preferredContentSize]
            let window = NSWindow(contentViewController: hosting)
            window.title = "What's New in Rhemion"
            window.styleMask = [.titled, .closable]
            window.isReleasedWhenClosed = false
            window.delegate = self
            self.window = window
        }
        logoClock.restart()
        AppController.shared?.setDockIconVisible(true)
        NSApp.activate(ignoringOtherApps: true)
        if let window, !window.isVisible { centerOnPointerScreen(window) }
        window?.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) { AppController.shared?.setDockIconVisible(false) }
}

struct WhatsNewView: View {
    let entry: ReleaseNotesEntry
    @ObservedObject var logoClock: WelcomeLogoClock
    let onGitHub: () -> Void
    let onContinue: () -> Void
    @Environment(\.colorScheme) private var scheme
    private var dark: Bool { scheme == .dark }
    private static let sideWidth: CGFloat = 250

    var body: some View {
        HStack(spacing: 0) {
            side.frame(width: Self.sideWidth)
            VStack(spacing: 0) {
                ScrollView { list.padding(EdgeInsets(top: 26, leading: 28, bottom: 14, trailing: 28)) }
                Rectangle().fill(RhemionStyle.line(dark)).frame(height: 1)
                footer
            }
        }
        .frame(width: 800, height: 560)
        .background(RhemionStyle.content(dark))
        .foregroundStyle(RhemionStyle.text(dark))
    }

    // The release, said once: the mark, the version as people name it, the slogan, the full version and the date
    // on lines of their own (a version never splits from its label).
    private var side: some View {
        VStack(alignment: .leading, spacing: 14) {
            WelcomeLogo(clock: logoClock, size: 128).padding(.leading, -6).padding(.bottom, 6)
            Text("Rhemion \(entry.shortVersion)").font(RhemionStyle.font(22, .heavy))
            VStack(alignment: .leading, spacing: 4) {
                Text("Thought, uninterrupted.").font(RhemionStyle.font(13, .semibold)).foregroundStyle(RhemionStyle.text(dark))
                Text("Version\u{00A0}\(entry.version)").font(RhemionStyle.font(12)).foregroundStyle(RhemionStyle.secondary(dark))
                    .monospacedDigit()
                if !entry.date.isEmpty {
                    Text(entry.longDate).font(RhemionStyle.font(12)).foregroundStyle(RhemionStyle.secondary(dark))
                }
            }
            Spacer(minLength: 16)
            Text("Reopen this any time: menu bar › What's New.")
                .font(RhemionStyle.font(11)).foregroundStyle(RhemionStyle.tertiary(dark))
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(EdgeInsets(top: 34, leading: 26, bottom: 22, trailing: 26))
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(RhemionStyle.rail(dark))
        .overlay(alignment: .trailing) { Rectangle().fill(RhemionStyle.line(dark)).frame(width: 1) }
    }

    // A list of news, not settings: group labels in small capitals, plain items with a dot, no cards.
    private var list: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(entry.groups.indices, id: \.self) { g in
                Text(entry.groups[g].title.uppercased())
                    .font(RhemionStyle.font(11, .semibold)).tracking(0.66)
                    .foregroundStyle(RhemionStyle.secondary(dark))
                    .padding(.top, g == 0 ? 0 : 22).padding(.bottom, 8)
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(entry.groups[g].items.indices, id: \.self) { i in item(entry.groups[g].items[i]) }
                }
            }
        }
        .frame(maxWidth: 480 + 16, alignment: .leading)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func item(_ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Circle().fill(RhemionStyle.tertiary(dark)).frame(width: 4, height: 4).alignmentGuide(.firstTextBaseline) { $0[.bottom] + 4 }
            Text(Self.styled(text)).font(RhemionStyle.font(13)).lineSpacing(3)   // about 1.5 leading for 13 pt Mulish
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }

    /// A lead-in in bold only where the note already has one before a colon ("Journal only: …"); nothing invented.
    static func styled(_ text: String) -> AttributedString {
        if let colon = text.firstIndex(of: ":"), text.distance(from: text.startIndex, to: colon) <= 40,
           text.index(after: colon) < text.endIndex, text[text.index(after: colon)] == " " {
            var lead = AttributedString(String(text[...colon]))
            lead.font = RhemionStyle.font(13, .bold)
            return lead + AttributedString(String(text[text.index(after: colon)...]))
        }
        return AttributedString(text)
    }

    private var footer: some View {
        HStack(spacing: 10) {
            TextLink(title: "Release Notes on GitHub", action: onGitHub)
            Spacer(minLength: 8)
            Button(action: onContinue) {
                Text("Continue").font(RhemionStyle.font(13, .semibold))
                    .foregroundStyle(dark ? Color(rhemionHex: 0xE8D9A8) : Color(rhemionHex: 0x5A4410))
                    .padding(.horizontal, 18).padding(.vertical, 9)
                    .background(RhemionStyle.selected(dark), in: RoundedRectangle(cornerRadius: 9))
                    .overlay { RoundedRectangle(cornerRadius: 9).strokeBorder(RhemionStyle.gold.opacity(dark ? 0.42 : 0.35), lineWidth: 1) }
                    .shadow(color: .black.opacity(dark ? 0.20 : 0.05), radius: 1.5, y: 1)
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.defaultAction)
        }
        .padding(EdgeInsets(top: 14, leading: 28, bottom: 22, trailing: 28))
    }
}
