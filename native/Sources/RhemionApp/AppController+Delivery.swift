// AppController's delivery paths outside a fresh dictation: the double-Esc gesture (cancel or erase), the pinned
// window's "insert there, come back", Insert again from the Journal, Recall, and the purge of expired canceled
// entries (moved out of main.swift unchanged).

import AppKit
import Foundation
import RhemionIPC

extension AppController {
    /// The double-Esc gesture: cancel the recording in progress, or (nothing recording) erase the
    /// just-delivered take at the frontmost app. Same stroke, stage-dependent meaning. Returns whether
    /// it CLAIMED an action, so the Esc tap swallows the second Esc only when it did.
    @MainActor
    func handleEscapeGesture() -> Bool {
        let policy = escPolicy.value
        if let front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier, policy.except.contains(front) { return false }
        if recordingFlag.value {
            guard policy.cancel else { return false }   // Settings › Shortcuts: Cancel is off
            log("double-Esc: cancel recording")
            recordingFlag.value = false
            hotkey?.abortRecording()   // so the eventual PTT release doesn't send a stray .stop
            // Kept (3.1, default on): the runtime journals it as Canceled for Recall / Insert again; else discarded.
            client?.send(settings.keepCanceled ? .cancelKeeping : .cancel)
            indicator?.hide()
            return true
        }
        return policy.erase ? deleteLastTake() : false
    }

    /// Erase the most recently delivered take with Backspace×n, but only if it is still armed AND
    /// landed in the app that is frontmost now (the same TTL + pid-match heuristic as undo-replace, so
    /// we never delete into a different app; the caret-moved-since-delivery edge is the same accepted
    /// limitation both gestures share). Returns whether a take was claimed. Success is silent — the
    /// vanished text is the confirmation.
    @MainActor
    private func deleteLastTake() -> Bool {
        guard let front = NSWorkspace.shared.frontmostApplication?.processIdentifier,
              let (n, session) = undoStore.takeDeleteWithSession(matchingPid: Int(front)) else {
            log("double-Esc: nothing to erase here"); return false
        }
        let pid = Int(front)
        // Only in the field the take went into: another field of the same app must never lose text.
        if let session, let snap = recentTargets.value[session]?.snap {
            let (match, _) = snap.matchNow()
            guard match == .sameElement || match == .sameField else {
                log("double-Esc: not erased, the focus is in another field (\(match.rawValue))"); return true
            }
        }
        let indicator = self.indicator
        DispatchQueue.global(qos: .userInitiated).async {
            if KeyboardEdit.deleteBackward(n: n, pid: pid) {
                log("double-Esc: erased last take (\(n))")
                if let session { JournalMarks.add(session: session, mark: "erased") }   // the Journal shows it as Erased
            } else {
                log("double-Esc: erase aborted (modifiers held)")
                Task { @MainActor in indicator?.error() }
            }
        }
        return true
    }

    /// Pinned, "insert there, come back" (3.1): wait for a pause in typing (so no keystroke lands in the wrong
    /// window), bring the pinned field forward, insert through the normal path (no target check: the focus is
    /// where the text goes), then put the user back where they were, caret included. The pinned window gone:
    /// unpin, keep the text (Journal), the notch shows kept.
    @MainActor
    func deliverToPinned(text: String, original: String?, session: String,
                                 ack: @escaping (String, String) -> Void, finished: @escaping (String) -> Void) {
        let start = CACurrentMediaTime()
        func attempt() {
            let idle = CACurrentMediaTime() - (hotkey?.lastKeyDownAt ?? 0)
            if idle < 0.3 && CACurrentMediaTime() - start < 1.5 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { MainActor.assumeIsolated { attempt() } }
                return
            }
            guard let delivery, let front = NSWorkspace.shared.frontmostApplication else { ack(session, "target-lost"); finished("target-lost"); return }
            let back = TargetSnapshot.capture(pid: Int(front.processIdentifier))
            guard pin.bringForward(), let target = pin.target else { ack(session, "target-lost"); finished("target-lost"); return }
            let verifier = PasteVerifier.before()   // ⌘V is asynchronous: come back only once the text is in
            delivery.onDeliver(
                text: text, original: original, session: session, targetPid: target.pid,
                inputMethod: inputMethod.value, checkTarget: false, sendAck: ack,
                onResult: { [weak self] status in
                    finished(status)
                    DispatchQueue.global(qos: .userInitiated).async {
                        if status.hasPrefix("paste") {
                            let outcome = verifier?.after(inserted: text.utf16.count + 1, budgetMS: 400) ?? .unreadable
                            if case .landed = outcome {} else { usleep(250_000) }   // unreadable field: a safe pause
                        }
                        DispatchQueue.main.async {
                            MainActor.assumeIsolated {
                                self?.pin.refresh()
                                let (match, _) = back.restoreFocus()
                                log("pin: back to the previous window \(match.rawValue)")
                            }
                        }
                    }
                }
            )
        }
        attempt()
    }

    /// Delete Canceled Journal entries older than "Keep them for" (3.1). Through the runtime, like a Journal delete.
    @MainActor
    func purgeExpiredCanceled() {
        guard let client else { return }
        let hours = Double(max(1, settings.keepCanceledHours))
        Task { @MainActor in
            let doc = await Task.detached(priority: .utility) { JournalDoc.load() }.value
            let cutoff = Date().addingTimeInterval(-hours * 3600)
            let ids = doc.entries.filter { $0.status == .canceled && $0.ts < cutoff }.map(\.id)
            guard !ids.isEmpty else { return }
            do {
                let removed = try await client.historyDelete(ids: ids)
                log("journal: purged \(removed.count) expired canceled entr\(removed.count == 1 ? "y" : "ies")")
                self.hubWindow?.journal.reload()
            } catch { log("journal: canceled purge failed: \(error.localizedDescription)") }
        }
    }

    /// Insert again (3.1): bring the press-time target back (app, window, field, caret) and deliver the entry's
    /// text there through the normal path, checking the focus first. Never guesses: no target, or the field
    /// cannot be confirmed, reports `.fieldGone` and inserts nothing.
    @MainActor
    func insertAgain(_ entry: JournalEntry, _ done: @escaping @MainActor (JournalModel.InsertAgainOutcome) -> Void) {
        guard let delivery, let session = entry.session, let snap = recentTargets.value[session]?.snap else { done(.fieldGone); return }
        let (match, detail) = snap.restoreFocus()
        log("insert again: refocus \(match.rawValue) (\(detail))")
        guard match == .sameElement || match == .sameField else { done(.fieldGone); return }
        let indicator = self.indicator
        let againSession = "again-\(UUID().uuidString)", again = againTargets
        again.value = { var m = again.value; m[againSession] = snap; return m }()   // checked strictly at delivery
        delivery.onDeliver(
            text: entry.transcript, original: nil, session: againSession, targetPid: snap.pid,
            inputMethod: inputMethod.value, sendAck: { _, _ in },
            onResult: { status in
                again.value = { var m = again.value; m[againSession] = nil; return m }()
                log("insert again: \(status)")
                let ok = isDeliverySuccess(status)
                Task { @MainActor in
                    if ok { indicator?.done() } else { indicator?.kept() }
                    done(ok ? .inserted : .failed)
                }
            }
        )
    }

    /// Deliver a recalled transcript into the current focus through the normal delivery path, so it
    /// gets the SAME boundary spacing and AX/paste routing as a fresh dictation (recall used to paste
    /// raw, with no leading/trailing space). targetPid nil = universal (wherever focus is now);
    /// success is silent, a failure flashes the indicator.
    @MainActor
    func deliverRecall(_ text: String) {
        guard let delivery else { return }
        let indicator = self.indicator
        delivery.onDeliver(
            text: text, original: nil, session: "recall-\(UUID().uuidString)", targetPid: nil,
            inputMethod: inputMethod.value,
            sendAck: { _, _ in },
            onResult: { status in
                log("recall delivery: \(status)")
                if !isDeliverySuccess(status) { Task { @MainActor in indicator?.kept() } }
            }
        )
    }
}
