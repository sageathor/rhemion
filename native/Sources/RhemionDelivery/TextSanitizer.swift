import Foundation

public struct SanitizedText: Equatable, Sendable {
    public let text: String
    public let overLimit: Bool
    public init(text: String, overLimit: Bool) { self.text = text; self.overLimit = overLimit }
}

/// Terminal-safety sanitizer: no CR/LF/ESC/control ever reaches a paste.
public struct TextSanitizer: Sendable {
    private let maxChars: Int
    public init(maxChars: Int = 20_000) { self.maxChars = maxChars }

    private static let lineish: Set<Unicode.Scalar> = ["\n", "\r", "\t", "\u{2028}", "\u{2029}", "\u{0B}", "\u{0C}"]
    private static let space = Unicode.Scalar(0x20)!

    public func sanitize(_ raw: String) -> SanitizedText {
        // Decide per Unicode SCALAR (not per grapheme cluster), a Cf
        // scalar such as ZWJ/ZWNJ that Swift would merge into a neighboring grapheme must
        // still be dropped, so a whole-Character strip guard would be unfaithful.
        var scalars = String.UnicodeScalarView()
        for scalar in raw.unicodeScalars {
            if Self.lineish.contains(scalar) { scalars.append(Self.space); continue }
            // Drop controls (Cc), format (Cf), line/para separators (Zl/Zp).
            if Self.isStrippable(scalar) { continue }
            scalars.append(scalar)
        }
        var s = String(scalars).precomposedStringWithCanonicalMapping
        while s.contains("  ") { s = s.replacingOccurrences(of: "  ", with: " ") }
        s = s.trimmingCharacters(in: .whitespaces)
        // Scalar count (not grapheme count).
        if s.unicodeScalars.count > maxChars { return SanitizedText(text: "", overLimit: true) }
        return SanitizedText(text: s, overLimit: false)
    }

    private static func isStrippable(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.properties.generalCategory {
        case .control, .format, .lineSeparator, .paragraphSeparator: return true
        default: return false
        }
    }
}
