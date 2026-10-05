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
    var onArmUndo: (@Sendable (_ deliveredN: Int, _ pid: Int, _ undoRaw: String?) -> Void)?
    /// Clear any armed reversal — called at the start of every delivery so only the most recent take
    /// is ever reversible (undo-replace or double-Esc delete).
    var onDisarmUndo: (@Sendable () -> Void)?

    func onDeliver(
        text: String,
        original: String?,
        session: String,
        targetPid: Int?,
        inputMethod: String,
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

        let classification = AXInsert.classify(targetPid: item.targetPid, text: item.text)
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

        switch AXInsert.insert(payload, targetPid: item.targetPid) {
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

    private func paste(_ payload: String, item: Item) {
        ClipboardPaste.paste(payload, targetPid: item.targetPid) { [weak self, item] status in
            guard let self else { return }
            self.queue.async { self.finish(item, status: Self.statusString(status)) }
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
            onArmUndo?(n, pid, item.undoRaw)
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
