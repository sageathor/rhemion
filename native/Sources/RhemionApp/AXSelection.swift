// AXSelection — best-effort read of the focused field's current text selection, for dict-add's
// "as heard" seed. A ladder of strategies (each rung cheap, side-effect-free,
// tried in order), and it must run BEFORE the panel opens, because the panel becomes frontmost and the
// original field loses focus.
//
//   1. AXSelectedText on the focused element — native text fields.
//   2. AXSelectedTextRange + AXStringForRange on the same element — fields that expose only a range.
//   3. ascend to the enclosing AXWebArea and try AXSelectedText, then the text-marker range
//      (AXSelectedTextMarkerRange + AXStringForTextMarkerRange) — web-rendered content.
//
// Secure fields are never read. Never throws; returns a trimmed non-empty string or nil.

import AppKit
import ApplicationServices
import Foundation

enum AXSelection {
    /// The current selection, trimmed and non-empty, or nil.
    static func currentSelection() -> String? {
        guard let element = focusedElement(), !isSecure(element) else { return nil }

        // 1. Direct selected text on the focused element.
        if let text = nonBlank(stringAttribute(element, kAXSelectedTextAttribute)) { return text }

        // 2. Selected range -> string on the same element.
        if let range = selectedRange(element), range.length > 0,
           let text = nonBlank(stringForRange(element, range)) { return text }

        // 3. Ascend to the web area and try there.
        if let web = webAreaAncestor(element) {
            if let text = nonBlank(stringAttribute(web, kAXSelectedTextAttribute)) { return text }
            if let text = nonBlank(stringForSelectedTextMarkerRange(web)) { return text }
        }
        return nil
    }

    /// Where a dict-add selection lives, so the fix can be written back over it after the panel closes.
    /// Captured only for fields that expose the selection on the focused element itself (rungs 1 and 2);
    /// web-area selections are read-only here and fall back to the clipboard.
    struct Target: @unchecked Sendable {   // AXUIElement is an immutable CF handle
        let pid: pid_t
        let element: AXUIElement
        let selected: String   // the raw selection, whitespace included
    }

    static func currentTarget() -> Target? {
        guard let app = NSWorkspace.shared.frontmostApplication,
              let element = focusedElement(), !isSecure(element) else { return nil }
        var selected = stringAttribute(element, kAXSelectedTextAttribute)
        if nonBlank(selected) == nil, let range = selectedRange(element), range.length > 0 {
            selected = stringForRange(element, range)
        }
        guard let selected, nonBlank(selected) != nil else { return nil }
        return Target(pid: app.processIdentifier, element: element, selected: selected)
    }

    enum FixResult: Sendable {
        case fixed                // the selection now reads the corrected text
        case notFound             // the selection does not contain the spoken form (the user edited it)
        case unavailable(String)  // could not write it; the argument is the corrected selection to paste
    }

    /// Replace `spoken` with `correct` inside the still-selected text of `target`. Writes only when the
    /// field still holds the exact selection captured at the hotkey press, so it never edits the wrong
    /// place. Case-insensitive like the dictionary itself.
    static func fix(_ target: Target, spoken: String, correct: String) -> FixResult {
        let fixed = target.selected.replacingOccurrences(of: spoken, with: correct, options: .caseInsensitive)
        guard fixed != target.selected else { return .notFound }
        guard stringAttribute(target.element, kAXSelectedTextAttribute) == target.selected else {
            return .unavailable(fixed)   // selection moved or unreadable: do not guess
        }
        var settable = DarwinBoolean(false)
        guard AXUIElementIsAttributeSettable(target.element, kAXSelectedTextAttribute as CFString, &settable) == .success,
              settable.boolValue else { return .unavailable(fixed) }
        let before = stringAttribute(target.element, kAXValueAttribute)
        guard AXUIElementSetAttributeValue(
            target.element, kAXSelectedTextAttribute as CFString, fixed as CFTypeRef) == .success
        else { return .unavailable(fixed) }
        usleep(15_000)
        // A value that did not change proves the write was ignored (some web and Electron fields).
        if let before, let after = stringAttribute(target.element, kAXValueAttribute),
           after.utf8.elementsEqual(before.utf8) { return .unavailable(fixed) }
        return .fixed
    }

    // MARK: - AX helpers

    private static func focusedElement() -> AXUIElement? {
        var value: CFTypeRef?
        let system = AXUIElementCreateSystemWide()
        guard AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return unsafeDowncast(value, to: AXUIElement.self)
    }

    private static func isSecure(_ element: AXUIElement) -> Bool {
        stringAttribute(element, kAXRoleAttribute) == kAXSecureTextFieldSubrole
            || stringAttribute(element, kAXSubroleAttribute) == kAXSecureTextFieldSubrole
    }

    private static func webAreaAncestor(_ element: AXUIElement) -> AXUIElement? {
        var current: AXUIElement? = element
        for _ in 0..<12 {
            guard let candidate = current else { return nil }
            if stringAttribute(candidate, kAXRoleAttribute) == "AXWebArea" { return candidate }
            current = elementAttribute(candidate, kAXParentAttribute)
        }
        return nil
    }

    private static func stringForRange(_ element: AXUIElement, _ range: CFRange) -> String? {
        var requested = range
        guard let rangeValue = AXValueCreate(.cfRange, &requested) else { return nil }
        var result: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(
            element, kAXStringForRangeParameterizedAttribute as CFString, rangeValue, &result) == .success
        else { return nil }
        return result as? String
    }

    /// Web/browser content sometimes exposes the selection only as a text-marker range. The marker range
    /// value is opaque (AXTextMarkerRange) — copy it, then ask for its string. Attribute names are the
    /// documented AX strings.
    private static func stringForSelectedTextMarkerRange(_ web: AXUIElement) -> String? {
        var markerRange: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            web, "AXSelectedTextMarkerRange" as CFString, &markerRange) == .success, let markerRange
        else { return nil }
        var result: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(
            web, "AXStringForTextMarkerRange" as CFString, markerRange, &result) == .success
        else { return nil }
        return result as? String
    }

    private static func stringAttribute(_ element: AXUIElement, _ name: String) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value as? String
    }

    private static func elementAttribute(_ element: AXUIElement, _ name: String) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return unsafeDowncast(value, to: AXUIElement.self)
    }

    private static func selectedRange(_ element: AXUIElement) -> CFRange? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        let axValue = unsafeDowncast(value, to: AXValue.self)
        guard AXValueGetType(axValue) == .cfRange else { return nil }
        var range = CFRange()
        guard AXValueGetValue(axValue, .cfRange, &range) else { return nil }
        return range
    }

    private static func nonBlank(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else { return nil }
        return trimmed
    }
}
