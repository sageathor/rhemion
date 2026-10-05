// KeyboardEdit — the shared low-level "erase the last delivered text" primitive behind both in-place
// reversal gestures: undo-replace (deletes, then pastes the original back) and double-Esc delete
// (deletes and stops). Backspace events are posted DIRECTLY to a pid (never the global HID tap), so
// if the frontmost app changed after the caller's pid check, the deletes still can't land in a
// different app's field. Backspace (kVK_Delete), not Shift+Left, because Electron drops the Shift
// modifier on synthetic arrows.

import AppKit
import Carbon.HIToolbox

enum KeyboardEdit {
    /// Wait (up to 500ms) for any still-held gesture-chord modifiers to clear — so a Backspace isn't
    /// Cmd/Opt+Backspace, which would delete a whole word/line — then post Backspace×n to `pid`.
    /// SYNCHRONOUS; call on a background queue, never the main run loop. Returns false (posting
    /// nothing) if the modifiers never clear or the event source can't be created; true otherwise
    /// (including n == 0, a no-op).
    static func deleteBackward(n: Int, pid: Int) -> Bool {
        guard n > 0 else { return true }
        let relevant: CGEventFlags = [.maskCommand, .maskControl, .maskAlternate, .maskShift]
        var waitedMS = 0
        while !CGEventSource.flagsState(.combinedSessionState).intersection(relevant).isEmpty, waitedMS < 500 {
            usleep(10_000); waitedMS += 10
        }
        guard CGEventSource.flagsState(.combinedSessionState).intersection(relevant).isEmpty else { return false }
        guard let source = CGEventSource(stateID: .privateState) else { return false }
        let target = pid_t(pid)
        for _ in 0..<n {   // kVK_Delete = Backspace
            CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_Delete), keyDown: true)?.postToPid(target)
            CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_Delete), keyDown: false)?.postToPid(target)
            usleep(3_000)
        }
        return true
    }
}
