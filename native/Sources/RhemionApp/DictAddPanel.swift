// Dict-add panel — the quick-add surface for the dict-add hotkey. A small native window matching
// the rest of the app (Settings / Dictionary): system colors, theme-adaptive, rounded-border
// fields, a prominent Add button. Two fields, "As heard" (seeded from the selection) → "Correct". On
// submit it writes the replacement via DictionaryStore.add and shows a brief confirmation, then closes.
// Esc = cancel, Return = add.

import AppKit
import SwiftUI

@MainActor
final class DictAddPanelController: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    private var openToken = 0

    /// Open the panel seeded with `heard` (empty when nothing was selected). Only one at a time. Each
    /// open bumps a token; a view's deferred auto-close is tagged with its token, so reopening within
    /// the auto-close delay does not let the previous submission hide the fresh form.
    func show(heard: String) {
        openToken += 1
        let token = openToken
        let view = DictAddPanelView(
            heard: heard,
            add: { spoken, correct in DictionaryStore.add(variant: spoken, canonical: correct) },
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

    private func close(token: Int) { guard token == openToken else { return }; window?.orderOut(nil) }
}

private struct DictAddPanelView: View {
    let heard: String
    let add: (String, String) -> DictionaryStore.AddOutcome
    let onClose: () -> Void

    @State private var heardText: String
    @State private var correctText = ""
    @State private var help: String
    @State private var isWarning = false
    @State private var done = false
    @FocusState private var focus: Field?
    private enum Field { case heard, correct }

    private let hadSelection: Bool

    init(heard: String, add: @escaping (String, String) -> DictionaryStore.AddOutcome, onClose: @escaping () -> Void) {
        self.heard = heard
        self.add = add
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
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)

            HStack(alignment: .bottom, spacing: 10) {
                field(label: "As heard", text: $heardText, placeholder: "e.g. youtube", field: .heard)
                Image(systemName: "arrow.right").foregroundStyle(.secondary).padding(.bottom, 6)
                field(label: "Correct", text: $correctText, placeholder: "e.g. YouTube", field: .correct)
            }

            Text(help).font(.caption).foregroundStyle(isWarning ? RhemionStyle.danger : Color.secondary)
                .fixedSize(horizontal: false, vertical: true).frame(minHeight: 15, alignment: .leading)

            HStack {
                Spacer()
                Button("Cancel") { onClose() }.keyboardShortcut(.cancelAction)
                Button("Add") { submit() }.keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent).disabled(done)
            }
        }
        .padding(20)
        .frame(width: 400, alignment: .leading)
        .onAppear { focus = hadSelection ? .correct : .heard }
    }

    private func field(label: String, text: Binding<String>, placeholder: String, field: Field) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            TextField(placeholder, text: text)
                .textFieldStyle(.roundedBorder).focused($focus, equals: field).disabled(done)
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
        switch add(spoken, correct) {
        case .added:          log("dict-add: added"); finish("Added: \(spoken) → \(correct)")
        case .alreadyPresent: log("dict-add: already present"); finish("Already in dictionary: \(spoken) → \(correct)")
        case .failed:         log("dict-add: save failed"); warn("Couldn't save. Check permissions and try again.", focus: .correct)
        }
    }

    /// Show the outcome and auto-close. Never log the entry TEXT (user dictionary content) — the panel
    /// shows it in the moment; the persistent log gets only the outcome word (in submit()).
    private func finish(_ message: String) {
        done = true; isWarning = false; help = message
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.1) { onClose() }
    }

    private func warn(_ message: String, focus target: Field) {
        help = message; isWarning = true; focus = target
    }
}
