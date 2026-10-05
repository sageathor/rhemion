// UndoReplace — revert the last dictation's dictionary replacement in place, via a global hotkey.
// Delivery arms UndoStore after a confirmed delivery that carried a dictionary
// substitution; on the hotkey this deletes the corrected text with Backspace×N and pastes the
// pre-dictionary original back over the caret.
//
// Global CarbonHotkey (fires under Secure Keyboard Entry). Default Cmd+Option+Shift+L. Like recall, the chord's release isn't reliably observable under
// Secure Input, so it fires a short fixed settle after the PRESS. Backspace (not Shift+Left) deletes,
// because Electron drops the Shift modifier on synthetic arrows.

import AppKit

final class UndoReplace: @unchecked Sendable {
    /// Called (off the main thread, from the paste completion) when the undo could not be applied.
    var onError: (@Sendable () -> Void)?

    private static let settleSeconds = 0.25
    private let hotkeys = CarbonHotkeyGroup(baseID: 30)   // undo: ids 30..37
    private let store: UndoStore
    private var pending: DispatchWorkItem?

    init(store: UndoStore) {
        self.store = store
        hotkeys.onPress = { [weak self] in self?.fired() }
    }

    /// (Re)bind the undo chords (any of them undoes; "off"/"none"/"" entries disable). Main run loop only.
    func setHotkeys(_ specs: [String]) {
        log("undo: bound \(hotkeys.setHotkeys(specs)) of \(specs.count) binding(s)")
    }

    /// Temporarily unbind so a settings recorder can capture keystrokes (including the current chords).
    func suspend() { pending?.cancel(); pending = nil; hotkeys.suspend() }

    func stop() { pending?.cancel(); pending = nil; hotkeys.stop() }

    private func fired() {   // main run loop
        log("undo: pressed")
        pending?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.doUndo() }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.settleSeconds, execute: work)
    }

    private func doUndo() {   // main run loop
        let frontPid = MainActor.assumeIsolated { NSWorkspace.shared.frontmostApplication?.processIdentifier }
        guard let front = frontPid else { log("undo: no frontmost app"); return }
        // Atomically consume the armed record for undo-replace IF it matches the frontmost app AND
        // carried a substitution to revert (leaves it for a retry on a pid mismatch, clears it on
        // expiry, leaves it for a possible double-Esc when there is nothing to revert) — one lock, so
        // a concurrent delivery can't swap the record.
        guard let armed = store.takeUndo(matchingPid: Int(front)) else { log("undo: nothing to undo here"); return }
        perform(rawPayload: armed.rawPayload, n: armed.n, pid: Int(front))
    }

    private func perform(rawPayload: String, n: Int, pid: Int) {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            // Erase the delivered text (Backspace×n, posted directly to the armed pid, after the chord's
            // modifiers clear). Abort the whole undo if that fails, so we never paste the original on top
            // of un-deleted corrected text.
            guard KeyboardEdit.deleteBackward(n: n, pid: pid) else {
                log("undo: modifiers still held / no source, aborting"); self.onError?(); return
            }
            ClipboardPaste.paste(rawPayload, targetPid: pid) { [weak self] status in
                switch status {
                case .pasteSubmitted, .pasteAmbiguous:
                    log("undo: \(status)")          // success is silent — the restored text is the confirmation
                default:
                    log("undo: failed (\(status))")
                    self?.onError?()
                }
            }
        }
    }
}
