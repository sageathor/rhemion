// Native Accessibility delivery.  The status split is deliberately conservative: after the
// AXSelectedText setter is called, every ambiguous outcome is "submitted-unverified" so a caller
// can never paste the same text a second time.

@preconcurrency import AppKit
import ApplicationServices
import Foundation

enum AXInsert {
    enum Boundary: Sendable {
        case noSpace, needsSpace, blockedSecure, targetChanged, unknown
    }

    struct Classification: Sendable {
        let boundary: Boundary
        let isWeb: Bool
    }

    enum InsertResult: Sendable {
        case insertedVerified, submittedUnverified, unsupported, blockedSecure, targetChanged
    }

    /// Read-only classification API. Delivery uses the text-aware overload below because the
    /// boundary rule also checks the first scalar of the incoming text.
    static func classify(targetPid: Int?) -> Classification {
        classify(targetPid: targetPid, text: nil)
    }

    static func classify(targetPid: Int?, text: String) -> Classification {
        classify(targetPid: targetPid, text: Optional(text))
    }

    static func insert(_ text: String, targetPid: Int?) -> InsertResult {
        guard !text.isEmpty else { return .unsupported }
        guard let frontmostPid = frontmostPid() else { return .unsupported }
        if let targetPid, frontmostPid != targetPid { return .targetChanged }
        guard let element = focusedElement() else { return .unsupported }
        guard !isSecure(element) else { return .blockedSecure }

        var settable = DarwinBoolean(false)
        guard AXUIElementIsAttributeSettable(
            element, kAXSelectedTextAttribute as CFString, &settable
        ) == .success, settable.boolValue else { return .unsupported }
        guard let range0 = selectedRange(element) else { return .unsupported }

        let value0 = stringAttribute(element, kAXValueAttribute)
        let length0 = value0?.utf16.count

        // Set before making the call: even an error return can mean the target accepted the edit.
        let wrote = true
        let setError = AXUIElementSetAttributeValue(
            element, kAXSelectedTextAttribute as CFString, text as CFTypeRef
        )
        guard setError == .success else {
            return wrote ? .submittedUnverified : .unsupported
        }

        usleep(15_000)
        let element2 = focusedElement() ?? element
        let value1 = stringAttribute(element2, kAXValueAttribute)
        let range1 = selectedRange(element2)

        if let value1, let length0 {
            let grew = value1.utf16.count - length0
            let present = Data(value1.utf8).range(of: Data(text.utf8)) != nil
            if present && grew == text.utf16.count { return .insertedVerified }
            if !present && grew == 0 {
                // Only byte-for-byte unchanged proves the setter did nothing. Equal-length
                // replacement, normalization, and smart punctuation are possibly-posted writes.
                if let value0, value1.utf8.elementsEqual(value0.utf8) { return .unsupported }
                return .submittedUnverified
            }
            return .submittedUnverified
        }

        if let range1, range1.location == range0.location + text.utf16.count {
            return .submittedUnverified
        }
        return .submittedUnverified
    }

    // MARK: - classification

    private static func classify(targetPid: Int?, text: String?) -> Classification {
        guard let frontmostPid = frontmostPid() else {
            return Classification(boundary: .unknown, isWeb: false)
        }
        if let targetPid, frontmostPid != targetPid {
            return Classification(boundary: .targetChanged, isWeb: false)
        }
        guard let element = focusedElement() else {
            return Classification(boundary: .unknown, isWeb: false)
        }
        guard !isSecure(element) else {
            return Classification(boundary: .blockedSecure, isWeb: false)
        }

        let web = hasWebAreaAncestor(element)
        switch characterLeftOfCaret(element) {
        case .readable(let left):
            // With no incoming text, expose whether the left edge itself abuts a word. The delivery
            // path always supplies text and therefore applies the complete production rule.
            let needs = text.map { needsBoundarySpace(left: left, text: $0) }
                ?? leftRequiresSeparator(left)
            return Classification(boundary: needs ? .needsSpace : .noSpace, isWeb: web)
        case .none:
            return Classification(boundary: .noSpace, isWeb: web)
        case .unknown:
            return Classification(boundary: .unknown, isWeb: web)
        }
    }

    private enum CaretLeft {
        case readable(String), none, unknown
    }

    private static let openers: Set<Unicode.Scalar> = [
        "(", "[", "{", "<", "«", "“", "‘", "\"", "'", "/", "\\", "@", "#", "_", "-",
    ]

    private static func needsBoundarySpace(left: String, text: String) -> Bool {
        guard let first = text.unicodeScalars.first, isWordScalar(first) else { return false }
        return leftRequiresSeparator(left)
    }

    private static func leftRequiresSeparator(_ left: String) -> Bool {
        guard let last = left.unicodeScalars.last else { return false }
        if isLuaWhitespace(last) || openers.contains(last) { return false }
        return true
    }

    private static func isWordScalar(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x30...0x39, 0x41...0x5A, 0x61...0x7A, 0x0410...0x044F, 0x0401, 0x0451:
            return true
        default:
            return false
        }
    }

    private static func isLuaWhitespace(_ scalar: Unicode.Scalar) -> Bool {
        scalar == " " || scalar == "\t" || scalar == "\n" || scalar == "\r"
            || scalar.value == 0x0B || scalar.value == 0x0C
    }

    private static func characterLeftOfCaret(_ element: AXUIElement) -> CaretLeft {
        guard let range = selectedRange(element) else { return .unknown }
        if range.length != 0 || range.location <= 0 { return .none }

        var requested = CFRange(location: range.location - 1, length: 1)
        guard let rangeValue = AXValueCreate(.cfRange, &requested) else { return .unknown }
        var result: CFTypeRef?
        let error = AXUIElementCopyParameterizedAttributeValue(
            element,
            kAXStringForRangeParameterizedAttribute as CFString,
            rangeValue,
            &result
        )
        guard error == .success, let string = result as? String, !string.isEmpty else {
            return .unknown
        }
        return .readable(string)
    }

    private static func hasWebAreaAncestor(_ element: AXUIElement) -> Bool {
        var current: AXUIElement? = element
        for _ in 0..<12 {
            guard let candidate = current else { return false }
            if stringAttribute(candidate, kAXRoleAttribute) == "AXWebArea" { return true }
            current = elementAttribute(candidate, kAXParentAttribute)
        }
        return false
    }

    private static func isSecure(_ element: AXUIElement) -> Bool {
        stringAttribute(element, kAXRoleAttribute) == kAXSecureTextFieldSubrole
            || stringAttribute(element, kAXSubroleAttribute) == kAXSecureTextFieldSubrole
    }

    private static func frontmostPid() -> Int? {
        guard let frontmost = NSWorkspace.shared.frontmostApplication else { return nil }
        return Int(frontmost.processIdentifier)
    }

    private static func focusedElement() -> AXUIElement? {
        var value: CFTypeRef?
        let system = AXUIElementCreateSystemWide()
        guard AXUIElementCopyAttributeValue(
            system, kAXFocusedUIElementAttribute as CFString, &value
        ) == .success, let value else { return nil }
        guard CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return unsafeDowncast(value, to: AXUIElement.self)
    }

    private static func elementAttribute(_ element: AXUIElement, _ name: String) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return unsafeDowncast(value, to: AXUIElement.self)
    }

    private static func stringAttribute(_ element: AXUIElement, _ name: String) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else {
            return nil
        }
        return value as? String
    }

    private static func selectedRange(_ element: AXUIElement) -> CFRange? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element, kAXSelectedTextRangeAttribute as CFString, &value
        ) == .success, let value, CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        let axValue = unsafeDowncast(value, to: AXValue.self)
        guard AXValueGetType(axValue) == .cfRange else { return nil }
        var range = CFRange()
        guard AXValueGetValue(axValue, .cfRange, &range) else { return nil }
        return range
    }
}
