// UndoStore — the armed state describing the LAST delivered dictation, so the two in-place reversal
// gestures can act on it: undo-replace (Cmd+Option+Shift+L, revert a dictionary substitution back to
// the spoken original) and double-Esc delete (erase the whole delivered take). Delivery arms it on
// every landed delivery and disarms it at the start of every new one, so only the MOST RECENT
// dictation is ever reversible. Shared across the Delivery queue (arm/disarm) and the main run loop
// (the hotkey/Esc readers), so lock-guarded.
//
// One record backs both gestures: `deliveredN` (how many Backspaces erase the delivered text) is
// always present; `undoRaw` (the boundary-spaced pre-dictionary text to paste back) is present only
// when a real dictionary substitution occurred. Consuming for either gesture clears the record, so
// the two can never both fire on one dictation.

import QuartzCore

final class UndoStore: @unchecked Sendable {
    private let lock = NSLock()
    private struct Armed {
        let deliveredN: Int      // grapheme-cluster count of the delivered text (Backspaces to erase it)
        let pid: Int             // where it landed
        let at: CFTimeInterval
        let undoRaw: String?     // boundary-spaced pre-dictionary text to restore (nil = no substitution)
    }
    private var armed: Armed?
    private var ttl: CFTimeInterval = 8   // a reversal older than this is no longer "the last thing typed"

    /// Configure how long an armed record stays valid (governs both gestures). Main run loop — guarded.
    func setTTL(_ seconds: Double) { lock.lock(); ttl = max(1, seconds); lock.unlock() }

    /// Arm from a confirmed delivery. `deliveredN` is the grapheme count of the delivered text; `pid`
    /// is where it landed; `undoRaw` is the boundary-spaced original to paste back on undo-replace, or
    /// nil when this delivery was not a dictionary substitution (still deletable via double-Esc).
    func arm(deliveredN: Int, pid: Int, undoRaw: String?) {
        guard deliveredN > 0 else { disarm(); return }
        lock.lock()
        armed = Armed(deliveredN: deliveredN, pid: pid, at: CACurrentMediaTime(), undoRaw: undoRaw)
        lock.unlock()
    }

    func disarm() { lock.lock(); armed = nil; lock.unlock() }

    /// Whether a valid (non-expired) record is armed. Used by the Esc gesture to decide whether a
    /// double-Esc should engage (and swallow the second Esc) at all. Does not consume or mutate.
    func isArmed() -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard let a = armed else { return false }
        return CACurrentMediaTime() - a.at <= ttl
    }

    /// Atomically consume the record for a WHOLE-TAKE DELETE (double-Esc) IF it is still valid AND
    /// landed in `pid`. Returns the delivered grapheme count (how many Backspaces erase it), cleared
    /// one-shot on a match; clears and returns nil if expired; on a pid mismatch leaves it armed (so
    /// the user can refocus the original app and retry within the TTL) and returns nil.
    func takeDelete(matchingPid pid: Int) -> Int? {
        lock.lock(); defer { lock.unlock() }
        guard let a = armed else { return nil }
        if CACurrentMediaTime() - a.at > ttl { armed = nil; return nil }
        guard a.pid == pid else { return nil }
        armed = nil
        return a.deliveredN
    }

    /// Atomically consume the record for an UNDO-REPLACE (revert a substitution) IF it is still valid,
    /// landed in `pid`, AND actually carried a substitution (`undoRaw` present). Returns the original
    /// text to paste back plus the delivered grapheme count. On expiry clears and returns nil; on a pid
    /// mismatch leaves it armed and returns nil; when the record is valid but carried no substitution
    /// it returns nil WITHOUT consuming, so a following double-Esc can still delete the take.
    /// Read-check-consume is a single locked transaction, so a delivery arming a NEW record can't be
    /// mixed with an old count.
    func takeUndo(matchingPid pid: Int) -> (rawPayload: String, n: Int)? {
        lock.lock(); defer { lock.unlock() }
        guard let a = armed else { return nil }
        if CACurrentMediaTime() - a.at > ttl { armed = nil; return nil }
        guard a.pid == pid else { return nil }
        guard let raw = a.undoRaw else { return nil }   // valid take, but nothing to revert — leave armed
        armed = nil
        return (raw, a.deliveredN)
    }
}
