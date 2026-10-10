// Did a paste land? ⌘V only says "the shortcut was sent". Before it, read the focused field's character count
// and selection (cheap: no full value); after it, poll until the count grew by the expected amount and the caret
// sits right after the inserted text. A field that cannot be read stays "unverified": that is not a failure
// and never a reason to paste again.

import ApplicationServices
import Foundation

struct PasteVerifier: @unchecked Sendable {
    enum Outcome: Sendable, Equatable {
        case landed(ms: Int)
        case unchanged          // readable before and after, nothing changed within the window
        case unreadable         // the field does not report its length or selection
        case changedOtherwise   // something changed, but not the way this insertion would
    }

    private let element: AXUIElement
    private let count0: Int
    private let range0: CFRange

    /// Reads the focused field now; nil when it cannot be read (the outcome is then `.unreadable`).
    static func before() -> PasteVerifier? {
        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, 0.05)
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &v) == .success,
              let v, CFGetTypeID(v) == AXUIElementGetTypeID() else { return nil }
        let element = unsafeDowncast(v, to: AXUIElement.self)
        guard let count = characterCount(element), let range = selectedRange(element) else { return nil }
        return PasteVerifier(element: element, count0: count, range0: range)
    }

    /// Polls for up to `budgetMS`, blocking the calling (non-main) queue. `inserted` is the UTF-16 length pasted.
    func after(inserted: Int, budgetMS: Int = 400) -> Outcome {
        let t0 = DispatchTime.now().uptimeNanoseconds
        let grow = inserted - range0.length
        let caret = range0.location + inserted
        var changed = false
        for wait in [10, 20, 30, 40, 50, 100, 150] {
            usleep(useconds_t(wait * 1000))
            let ms = Int((DispatchTime.now().uptimeNanoseconds - t0) / 1_000_000)
            if let count = Self.characterCount(element), let range = Self.selectedRange(element) {
                if count - count0 == grow && range.location == caret && range.length == 0 { return .landed(ms: ms) }
                if count != count0 || range.location != range0.location { changed = true }
            } else {
                return .unreadable
            }
            if ms >= budgetMS { break }
        }
        // A field that reads empty before and after is usually a proxy (a terminal's hidden input, an editor's
        // off-screen textarea: VSCodium logged 56 of these in one session), so "unchanged" proves nothing there.
        if !changed && count0 == 0 { return .unreadable }
        return changed ? .changedOtherwise : .unchanged
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
        }
    }
}
