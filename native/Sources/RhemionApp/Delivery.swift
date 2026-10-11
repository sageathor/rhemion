// Serial text-delivery router. Exactly one item may be in flight, and an item's completion is
// idempotent so a late watchdog/callback can never advance the FIFO twice.

import Foundation

final class Delivery: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.sageathor.rhemion.app.delivery")
    private var items: [Item] = []
    private var active = false

    /// Arm the last-delivery reversal record on a landed delivery: `deliveredN` = grapheme-cluster
    /// count of the delivered text (Backspaces to erase it), `pid` = where it landed, `undoRaw` =
    /// boundary-spaced pre-dictionary text to restore on undo-replace (nil when this delivery was not
    /// a dictionary substitution — still deletable via double-Esc).
    var onArmUndo: (@Sendable (_ deliveredN: Int, _ pid: Int, _ undoRaw: String?, _ session: String) -> Void)?
    /// Clear any armed reversal — called at the start of every delivery so only the most recent take
    /// is ever reversible (undo-replace or double-Esc delete).
    var onDisarmUndo: (@Sendable () -> Void)?
    /// Compares the press-time target with the current focus for this session, right before inserting;
    /// false = the focus left the target, so the text stays in the Journal (status `target-lost`).
    var targetCheck: (@Sendable (_ session: String) -> Bool)?
    /// Re-checks the press-time target right before ⌘V (true = still the target, or nothing to check).
    var targetRecheck: (@Sendable (_ session: String) -> Bool)?
    /// The text reached the field (AX write returned, or ⌘V posted) at this uptime: for the `felt` latency.
    var onVisible: (@Sendable (_ session: String, _ at: UInt64) -> Void)?

    func onDeliver(
        text: String,
        original: String?,
        session: String,
        targetPid: Int?,
        inputMethod: String,
        checkTarget: Bool = true,
        sendAck: @escaping (String, String) -> Void,
        onResult: @escaping (String) -> Void
    ) {
        let item = Item(
            text: text,
            original: original,
            session: session,
            targetPid: targetPid,
            inputMethod: inputMethod,
            sendAck: sendAck,
            onResult: onResult
        )
        item.checkTarget = checkTarget
        queue.async {
            self.items.append(item)
            self.pump()
        }
    }

    private final class Item: @unchecked Sendable {
        let text: String
        let original: String?
        let session: String
        let targetPid: Int?
        let inputMethod: String
        let sendAck: (String, String) -> Void
        let onResult: (String) -> Void
        var finished = false
        var checkTarget = true   // false: the caller already put the focus where the text goes (a pinned window)
        var undoRaw: String?   // boundary-spaced pre-dictionary text to restore on undo (nil = not undoable)
        var undoN: Int?        // scalar count of the delivered text (Backspaces to select it)

        init(
            text: String,
            original: String?,
            session: String,
            targetPid: Int?,
            inputMethod: String,
            sendAck: @escaping (String, String) -> Void,
            onResult: @escaping (String) -> Void
        ) {
            self.text = text
            self.original = original
            self.session = session
            self.targetPid = targetPid
            self.inputMethod = inputMethod
            self.sendAck = sendAck
            self.onResult = onResult
        }
    }

    private func pump() {
        guard !active, !items.isEmpty else { return }
        active = true
        process(items.removeFirst())
    }

    private func process(_ item: Item) {
        // Only the most recent dictation is ever undoable: clear any armed undo as each delivery starts.
        onDisarmUndo?()
        guard !item.text.isEmpty else { finish(item, status: "empty-delivery"); return }
        if item.checkTarget, let targetCheck, !targetCheck(item.session) { finish(item, status: "target-lost"); return }

        AXInsert.timing = [:]; AXInsert.writtenAt = nil
        let tc = DispatchTime.now().uptimeNanoseconds
        let classification = AXInsert.classify(targetPid: item.targetPid, text: item.text)
        AXInsert.tick("classify", since: tc)
        switch classification.boundary {
        case .blockedSecure:
            finish(item, status: "blocked-secure")
            return
        case .targetChanged:
            finish(item, status: "target-changed")
            return
        case .noSpace, .needsSpace, .unknown:
            break
        }

        let payload = withBoundarySpaces(item.text, classification.boundary)
        // Prepare the last-delivery reversal record. `undoN` (delivered GRAPHEME-CLUSTER count) is set
        // for EVERY delivery that has a known target pid, so double-Esc can erase the whole take;
        // Backspace×undoN deletes exactly the delivered text (one Backspace = one grapheme, even for
        // multi-scalar clusters; never over-deletes into the user's preceding text). `undoRaw` (the
        // boundary-spaced original to paste back) is set ONLY when this delivery was a dictionary
        // substitution (original present), which is what undo-replace restores.
        if item.targetPid != nil {
            item.undoN = payload.count
            if let original = item.original, !original.isEmpty {
                item.undoRaw = withBoundarySpaces(original, classification.boundary)
            }
        }

        if item.inputMethod == "clipboard" || classification.isWeb {
            paste(payload, item: item)
            return
        }

        let ti = DispatchTime.now().uptimeNanoseconds
        let axResult = AXInsert.insert(payload, targetPid: item.targetPid)
        if let at = AXInsert.writtenAt, axResult == .insertedVerified || axResult == .submittedUnverified { onVisible?(item.session, at) }
        AXInsert.tick("insert", since: ti)
        log("ax: " + ["classify", "web", "insert", "read", "set", "verify"].compactMap { k in AXInsert.timing[k].map { "\(k) \($0)" } }.joined(separator: " · "))
        switch axResult {
        case .insertedVerified:
            finish(item, status: "inserted-verified")
        case .submittedUnverified:
            finish(item, status: "submitted-unverified")
        case .unsupported:
            // This is the only result proving no AX edit landed, and therefore the only safe fallback.
            paste(payload, item: item)
        case .blockedSecure:
            finish(item, status: "blocked-secure")
        case .targetChanged:
            finish(item, status: "target-changed")
        }
    }

    private let verifyQueue = DispatchQueue(label: "com.sageathor.rhemion.app.paste-verify", qos: .utility)

    private func paste(_ payload: String, item: Item) {
        let verifier = PasteVerifier.before()
        let session = item.session
        var stillTarget: (@Sendable () -> Bool)? = nil
        if item.checkTarget, let recheck = targetRecheck { stillTarget = { recheck(session) } }
        ClipboardPaste.paste(payload, targetPid: item.targetPid, stillTarget: stillTarget) { [weak self, item] status in
            guard let self else { return }
            let token = ClipboardPaste.lastPostedToken.value
            guard case .pasteSubmitted = status else { self.queue.async { self.finish(item, status: Self.statusString(status)) }; return }
            self.onVisible?(item.session, DispatchTime.now().uptimeNanoseconds)
            // ⌘V only says the shortcut was sent: the status waits for the field to change (about 50 ms). A miss
            // (the field stayed as it was, for the whole window or while the focus moved on) is Not inserted.
            guard let verifier else { log("verify: paste unreadable"); self.queue.async { self.finish(item, status: "paste-submitted") }; return }
            self.verifyQueue.async {
                let outcome = verifier.after(inserted: payload.utf16.count) { miss in
                    let status = miss == .elsewhere ? "paste-elsewhere" : miss == .unchanged ? "paste-unchanged" : "paste-submitted"
                    self.queue.async { self.finish(item, status: status) }
                }
                // Seen in the field: the app has read the clipboard, the user's own goes back now (else the
                // fallback restore, ClipboardPaste.fallbackRestoreMS).
                if case .landed = outcome, let token { ClipboardPaste.restoreNow(token: token) }
                log("verify: paste \(outcome.label) (\(verifier.label))")
            }
        }
    }

    private static func statusString(_ status: ClipboardPaste.PasteStatus) -> String {
        switch status {
        case .pasteSubmitted: return "paste-submitted"
        case .targetChanged: return "target-changed"
        case .pasteNotPosted: return "paste-not-posted"
        case .pasteAmbiguous: return "paste-ambiguous"
        case .error: return "error"
        }
    }

    private func finish(_ item: Item, status: String) {
        guard !item.finished else { return }
        item.finished = true
        // Arm the last-delivery reversal only when the text actually landed at the caret. Every landed
        // delivery with a known pid is deletable via double-Esc (undoN); undoRaw (a substitution's
        // original) rides along when present so undo-replace can also revert it.
        if status == "inserted-verified" || status == "paste-submitted",
           let n = item.undoN, let pid = item.targetPid {
            onArmUndo?(n, pid, item.undoRaw, item.session)
        }
        item.onResult(status)
        item.sendAck(item.session, status)
        active = false
        // Drain iteratively. Synchronous AX successes must not recursively grow the stack.
        queue.async { self.pump() }
    }

    private func withBoundarySpaces(_ text: String, _ boundary: AXInsert.Boundary) -> String {
        var result = boundary == .needsSpace ? " " + text : text
        if !(result.unicodeScalars.last.map(AXInsertBoundaryWhitespace.isWhitespace) ?? false) {
            result.append(" ")
        }
        return result
    }
}

/// Lua's `%s` is an ASCII-oriented separator test. Keep the trailing-boundary rule identical rather
/// than using Character.isWhitespace, which recognizes additional Unicode separators.
private enum AXInsertBoundaryWhitespace {
    static func isWhitespace(_ scalar: Unicode.Scalar) -> Bool {
        scalar == " " || scalar == "\t" || scalar == "\n" || scalar == "\r"
            || scalar.value == 0x0B || scalar.value == 0x0C
    }
}
