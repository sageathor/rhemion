// RecallHotkey — a global hotkey that re-inserts the last dictation into whatever is focused
// now.
//
// The global registration is a CarbonHotkey (RegisterEventHotKey keeps firing under macOS Secure
// Keyboard Entry, where the PTT CGEventTap never sees letter key-downs). Neither Carbon's key-up nor a modifier poll reliably reports the chord's
// release under Secure Input, so we paste a short fixed delay after the PRESS (the one dependable
// signal), long enough for a quick tap's modifiers to lift before the synthetic Cmd+V (the clipboard
// paste aborts if a modifier is still held at its own +100ms recheck).
//
// Universal: no target guard (pastes into the current focus), clipboard preserved by the paste path.
// Default is Cmd+Option+R.

import Foundation

final class RecallHotkey: @unchecked Sendable {
    /// Called on the main run loop with the text to re-insert. The app routes it through the normal
    /// delivery path (boundary spaces, AX/paste routing, input method), so recall inserts identically
    /// to a fresh dictation. Not called when there is nothing to recall.
    var onRecall: (@Sendable (String) -> Void)?

    private static let settleSeconds = 0.25
    private let hotkeys = CarbonHotkeyGroup(baseID: 10)   // recall: ids 10..17
    private var pending: DispatchWorkItem?

    init() { hotkeys.onPress = { [weak self] in self?.fired() } }

    /// (Re)bind the recall chords (any of them recalls; "off"/"none"/"" entries disable). Main run loop only.
    func setHotkeys(_ specs: [String]) {
        log("recall: bound \(hotkeys.setHotkeys(specs)) of \(specs.count) binding(s)")
    }

    /// Temporarily unbind so a settings recorder can capture keystrokes (including the current chords).
    func suspend() { pending?.cancel(); pending = nil; hotkeys.suspend() }

    func stop() { pending?.cancel(); pending = nil; hotkeys.stop() }

    /// On the main run loop when the chord is pressed: wait a fixed settle for the modifiers to lift,
    /// then paste — cancelling any still-pending recall so a double-press collapses to one.
    private func fired() {
        log("recall: pressed")
        pending?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.doRecall() }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.settleSeconds, execute: work)
    }

    private func doRecall() {
        guard let text = RecallStore.lastTranscript() else { log("recall: nothing to recall"); return }
        onRecall?(text)
    }
}
