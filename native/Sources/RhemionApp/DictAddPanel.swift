// Dict-add panel — the quick-add surface for the dict-add hotkey. A small native window matching
// the rest of the app (Settings / Dictionary): system colors, theme-adaptive, rounded-border
// fields, a prominent Add button. Two fields, "As heard" (seeded from the selection) → "Correct". On
// submit it writes the replacement via DictionaryStore.add, fixes the selected word in place when the
// field allows it (otherwise copies the fix), shows a brief confirmation, then closes and hands focus back
// to the app the word came from. Esc = cancel, Return = add.

import AppKit
import SwiftUI

@MainActor
final class DictAddPanelController: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    private var openToken = 0
    private var returnTo: NSRunningApplication?

    /// Open the panel seeded with `heard` (empty when nothing was selected). Only one at a time. Each
    /// open bumps a token; a view's deferred auto-close is tagged with its token, so reopening within
    /// the auto-close delay does not let the previous submission hide the fresh form.
    func show(heard: String, target: AXSelection.Target?) {
        openToken += 1
        let token = openToken
        // Still the user's app: the panel has not activated Rhemion yet.
        let front = NSWorkspace.shared.frontmostApplication
        returnTo = front?.processIdentifier == ProcessInfo.processInfo.processIdentifier ? nil : front
        let view = DictAddPanelView(
            heard: heard,
            add: { spoken, correct in DictionaryStore.add(variant: spoken, canonical: correct) },
            fix: { spoken, correct in target.map { AXSelection.fix($0, spoken: spoken, correct: correct) } },
            onClose: { [weak self] in self?.close(token: token) }
        )
        let hosting = NSHostingController(rootView: view)
        if let window {
            window.contentViewController = hosting
        } else {
            let window = NSWindow(contentViewController: hosting)
            window.title = "Add to Dictionary"
            window.styleMask = [.titled, .closable]
            window.isReleasedWhenClosed = false
            window.delegate = self
            self.window = window
        }
        window?.center()
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    private func close(token: Int) {
        guard token == openToken else { return }
        window?.orderOut(nil)
        returnTo?.activate(); returnTo = nil
    }

    func windowWillClose(_ notification: Notification) { returnTo?.activate(); returnTo = nil }
}

private struct DictAddPanelView: View {
    @Environment(\.colorScheme) private var scheme
    private var dark: Bool { scheme == .dark }
    let heard: String
    let add: (String, String) -> DictionaryStore.AddOutcome
    let fix: (String, String) -> AXSelection.FixResult?
    let onClose: () -> Void

    @State private var heardText: String
    @State private var correctText = ""
    @State private var help: String
    @State private var isWarning = false
    @State private var done = false
    @FocusState private var focus: Field?
    private enum Field { case heard, correct }

    private let hadSelection: Bool

    init(heard: String, add: @escaping (String, String) -> DictionaryStore.AddOutcome,
         fix: @escaping (String, String) -> AXSelection.FixResult?, onClose: @escaping () -> Void) {
        self.heard = heard
        self.add = add
        self.fix = fix
        self.onClose = onClose
        let seeded = heard.trimmingCharacters(in: .whitespacesAndNewlines)
        self.hadSelection = !seeded.isEmpty
        _heardText = State(initialValue: seeded)
        _help = State(initialValue: "The replacement triggers when you dictate the word on the left.")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(hadSelection
                 ? "Dictation misheard this. Type how it should be spelled."
                 : "Type how the word sounds to dictation, and how it should be spelled.")
                .font(RhemionStyle.font(13)).foregroundStyle(RhemionStyle.secondary(dark))
                .fixedSize(horizontal: false, vertical: true)

            HStack(alignment: .bottom, spacing: 10) {
                field(label: "As heard", text: $heardText, placeholder: "e.g. youtube", field: .heard)
                Image(systemName: "arrow.right").font(.system(size: 12))
                    .foregroundStyle(RhemionStyle.tertiary(dark)).padding(.bottom, 8)
                field(label: "Correct", text: $correctText, placeholder: "e.g. YouTube", field: .correct)
            }

            Text(help).font(RhemionStyle.font(11.5))
                .foregroundStyle(isWarning ? RhemionStyle.danger : RhemionStyle.tertiary(dark))
                .fixedSize(horizontal: false, vertical: true).frame(minHeight: 15, alignment: .leading)

            WindowButtonRow {
                RaisedButton(title: "Cancel") { onClose() }.keyboardShortcut(.cancelAction)
                RaisedButton(title: "Add") { submit() }.keyboardShortcut(.defaultAction).disabled(done)
            }
        }
        .padding(20)
        .frame(width: 400, alignment: .leading)
        .background(RhemionStyle.content(dark))
        .onAppear { focus = hadSelection ? .correct : .heard }
    }

    private func field(label: String, text: Binding<String>, placeholder: String, field: Field) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(label).font(RhemionStyle.font(11.5)).foregroundStyle(RhemionStyle.secondary(dark))
            // The Dictionary window's field: plain, no system focus ring (blue is not ours).
            TextField(placeholder, text: text)
                .textFieldStyle(.plain).font(RhemionStyle.font(13))
                .padding(.horizontal, 9).padding(.vertical, 6)
                .background(RhemionStyle.hover(dark), in: RoundedRectangle(cornerRadius: 7))
                .overlay { RoundedRectangle(cornerRadius: 7).strokeBorder(RhemionStyle.line(dark), lineWidth: 0.5) }
                .focused($focus, equals: field).disabled(done)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func submit() {
        let spoken = heardText.trimmingCharacters(in: .whitespacesAndNewlines)
        let correct = correctText.trimmingCharacters(in: .whitespacesAndNewlines)
        if spoken.isEmpty { warn("Type how the word sounds.", focus: .heard); return }
        if correct.isEmpty { warn("Type the correct spelling.", focus: .correct); return }
        // Case-SENSITIVE: "youtube → YouTube" is a valid capitalization fix, not a no-op.
        if spoken == correct { warn("Same as heard, nothing to replace.", focus: .correct); return }
        let saved: String
        switch add(spoken, correct) {
        case .added:          log("dict-add: added"); saved = "Added"
        case .alreadyPresent: log("dict-add: already present"); saved = "Already in dictionary"
        case .failed:
            log("dict-add: save failed"); warn("Couldn't save. Check permissions and try again.", focus: .correct)
            return
        }
        // Then fix the word the user selected, so they do not have to retype or re-dictate it.
        switch fix(spoken, correct) {
        case .fixed?:
            log("dict-add: fixed in place"); finish("\(saved) and fixed in the text: \(spoken) → \(correct)")
        case .unavailable(let text)?:
            log("dict-add: fix copied (field not editable)")
            NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string)
            finish("\(saved): \(spoken) → \(correct). This field can't be edited directly, so the fix is copied. Press ⌘V.",
                   hold: 3.0)
        case .notFound?, nil:
            finish("\(saved): \(spoken) → \(correct)")
        }
    }

    /// Show the outcome and auto-close. Never log the entry TEXT (user dictionary content) — the panel
    /// shows it in the moment; the persistent log gets only the outcome word (in submit()).
    private func finish(_ message: String, hold: Double = 1.1) {
        done = true; isWarning = false; help = message
        DispatchQueue.main.asyncAfter(deadline: .now() + hold) { onClose() }
    }

    private func warn(_ message: String, focus target: Field) {
        help = message; isWarning = true; focus = target
    }
}
