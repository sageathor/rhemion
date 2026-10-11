// Did a paste land? ⌘V only says "the shortcut was sent". Before it, read the focused field's character count
// and selection (cheap: no full value); after it, poll until the count grew by the expected amount and the caret
// sits right after the inserted text. A field that cannot be read stays "unverified": that is not a failure
// and never a reason to paste again. A missed paste is `unchanged` (a readable field that held text and stayed
// exactly as it was for the whole window) or `elsewhere` (the field stayed as it was and the focus moved on): editors that rewrite the field on paste (a list
// continued, a trailing newline) report `changedOtherwise`, and the text is there.

import ApplicationServices
import Foundation

struct PasteVerifier: @unchecked Sendable {
    enum Outcome: Sendable, Equatable {
        case landed(ms: Int)
        case unchanged          // readable before and after, nothing changed within the window
        case unreadable         // the field does not report its length or selection
        case changedOtherwise   // something changed, but not the way this insertion would
        case elsewhere          // the field stayed as it was while the focus moved to another one
    }

    private let element: AXUIElement
    private let count0: Int
    private let range0: CFRange

    /// Reads the focused field now; nil when it cannot be read (the outcome is then `.unreadable`).
    static func before() -> PasteVerifier? {
        guard let element = focused(), let count = characterCount(element), let range = selectedRange(element) else { return nil }
        return PasteVerifier(element: element, count0: count, range0: range)
    }

    /// Polls for up to `budgetMS`, blocking the calling (non-main) queue. `inserted` is the UTF-16 length pasted.
    /// Landings take about 50 ms (p99 under 150, the slowest seen near 400), so a second leaves room before a
    /// paste is called missed. `decided` fires once, as early as the answer is known: nil (not missed) the moment
    /// the field changes or cannot be read; `.elsewhere` when the focus left the field before the text reached
    /// it (seen twice running, the field unchanged); `.unchanged` only at the end of the window. A field that read
    /// empty (often a proxy, see below) cannot prove a miss by staying empty, so it is let go after 100 ms unless
    /// the focus moved. The polling goes on after `decided` for the logged outcome.
    func after(inserted: Int, budgetMS: Int = 1000, decided: ((_ miss: Outcome?) -> Void)? = nil) -> Outcome {
        var pending = decided
        func decide(_ miss: Outcome?) { pending?(miss); pending = nil }
        defer { decide(nil) }
        let t0 = DispatchTime.now().uptimeNanoseconds
        let grow = inserted - range0.length
        let caret = range0.location + inserted
        var changed = false
        var away = 0
        for wait in [10, 10, 10, 10, 10, 10, 20, 20, 50, 50, 100, 100, 200, 200, 200] {
            usleep(useconds_t(wait * 1000))
            let ms = Int((DispatchTime.now().uptimeNanoseconds - t0) / 1_000_000)
            let focusAway = Self.focused().map { !CFEqual($0, element) } ?? false
            if let count = Self.characterCount(element), let range = Self.selectedRange(element) {
                if count - count0 == grow && range.location == caret && range.length == 0 { return .landed(ms: ms) }
                // A caret that moved only because the field lost focus (Safari's contenteditable) is no change.
                if count != count0 || (range.location != range0.location && !focusAway) { changed = true; decide(nil) }
            } else {
                return .unreadable
            }
            // The field is as it was and the focus is in another one: the ⌘V went there (a click that slipped in
            // between the last target check and the app handling the paste).
            if !changed && focusAway {
                away += 1
                if away >= 2 { decide(.elsewhere); return .elsewhere }
            } else { away = 0 }
            if count0 == 0 && ms >= 100 { decide(nil) }
            if ms >= budgetMS { break }
        }
        // A field that reads empty before and after is usually a proxy (a terminal's hidden input, an editor's
        // off-screen textarea: VSCodium logged 56 of these in one session), so "unchanged" proves nothing there.
        if !changed && count0 == 0 { return .unreadable }
        if !changed { decide(.unchanged) }
        return changed ? .changedOtherwise : .unchanged
    }

    private static func focused() -> AXUIElement? {
        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, 0.05)
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &v) == .success,
              let v, CFGetTypeID(v) == AXUIElementGetTypeID() else { return nil }
        return unsafeDowncast(v, to: AXUIElement.self)
    }

    var label: String { "count \(count0) sel \(range0.location)+\(range0.length)" }

    private static func characterCount(_ e: AXUIElement) -> Int? {
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(e, kAXNumberOfCharactersAttribute as CFString, &v) == .success else { return nil }
        return (v as? NSNumber)?.intValue
    }

    private static func selectedRange(_ e: AXUIElement) -> CFRange? {
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(e, kAXSelectedTextRangeAttribute as CFString, &v) == .success,
              let v, CFGetTypeID(v) == AXValueGetTypeID() else { return nil }
        var r = CFRange()
        return AXValueGetValue(unsafeDowncast(v, to: AXValue.self), .cfRange, &r) ? r : nil
    }
}

extension PasteVerifier.Outcome {
    var label: String {
        switch self {
        case .landed(let ms): return "landed \(ms) ms"
        case .unchanged: return "unchanged"
        case .unreadable: return "unreadable"
        case .changedOtherwise: return "changed-otherwise"
        case .elsewhere: return "elsewhere"
        }
    }
}
