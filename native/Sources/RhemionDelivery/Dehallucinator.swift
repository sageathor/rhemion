import Foundation

/// Strips known whisper subtitle-credit hallucinations from recognized text.
///
/// whisper.cpp, trained partly on YouTube subtitles, hallucinates subtitle-CREDIT
/// lines on trailing or embedded silence (e.g. "Редактор субтитров А.Семкин Корректор
/// А.Егорова", "Субтитры сделал DimaTorzok", "Subtitles by the Amara.org community").
/// Silero VAD reduces but does not eliminate them. This is a deterministic,
/// high-precision post-filter — precision over recall: it would rather leave a
/// hallucination than eat a single word of real dictation.
///
/// It only removes:
///   * a WHOLE short take that is nothing but credit boilerplate (a silent take), or
///   * a TRAILING credit run appended after real speech (kept: the real text + the
///     sentence-ending punctuation before the run).
/// It never removes a match from the MIDDLE — an embedded credit phrase is not safely
/// distinguishable from dictated speech.
public struct Dehallucinator: Sendable {
    public init() {}

    /// A longer span is real speech, never "credit-only".
    private static let maxCreditChars = 200

    /// Non-breaking space, used alongside a regular space wherever the Python source's
    /// `[  ]` character class appears (it holds a literal space and U+00A0).
    private static let nbsp = "\u{00A0}"

    // --- Attribution target: what a credit is attributed TO. Required by every strong
    // clause, so a bare role word ("корректор", "subtitles") is never enough to strip. ---
    private static let namePattern: String =
        "(?:(?:[А-ЯЁ]\\.[ " + nbsp + "]*){1,2}[А-ЯЁ][а-яё\\-]+"          // initialled Cyrillic: А.Семкин, А. В. Семкин
        + "|@?[A-Za-zА-ЯЁ][\\w.\\-]{2,}"                                 // handle: DimaTorzok, @user
        + "|(?:[А-ЯЁA-Z][а-яёa-z\\-]+)(?:[ " + nbsp + "]+[А-ЯЁA-Z][а-яёa-z\\-]+){0,2})"  // 1-3 capitalized words

    private static let amaraPattern = "amara\\.org"

    // --- PRIMARY clauses: a full credit template. A credit run must START with one of
    // these, so "Корректор <name>" (secondary) can never be stripped on its own. ---
    private static let primaryPattern: String = {
        let alternatives = [
            "редактор(?:ы)?\\s+субтитров\\s+" + namePattern,
            "субтитры\\s+(?:сделал|делал|подготовил|создал|редактировал|перев[её]л)\\s+" + namePattern,
            "субтитры\\s+(?:предоставлены\\s+)?(?:сообществом\\s+)?" + amaraPattern,
            "subtitles?\\s+(?:by|made\\s+by|created\\s+by|translated\\s+by|provided\\s+by)\\s+" + namePattern,
            "captions?\\s+(?:by|provided\\s+by)\\s+" + namePattern,
            "subtitles?\\s+by\\s+the\\s+" + amaraPattern + "\\s+community",
            amaraPattern,
        ]
        return "(?:" + alternatives.joined(separator: "|") + ")"
    }()

    // --- SECONDARY clause: only valid trailing a primary one (never standalone). ---
    private static let secondaryPattern = "(?:корректор\\s+" + namePattern + ")"

    private static let sepPattern = "[\\s.,!?…—\\-]+"

    // A credit run: one primary, then up to two more primary/secondary clauses.
    private static let runPattern: String =
        primaryPattern + "(?:" + sepPattern + "(?:" + primaryPattern + "|" + secondaryPattern + ")){0,2}"

    // --- Weak signatures: real phrases that are ALSO common whisper filler. Only safe to
    // drop when they are the ENTIRE output (a silent take), never as a suffix. ---
    private static let weakPattern = "(?:продолжение следует|дальше больше|thanks for watching|thank you for watching)"

    private static let wholeRegex: NSRegularExpression = {
        let pattern = "^\\W*(?:" + runPattern + "|" + weakPattern + ")\\W*$"
        // swiftlint:disable:next force_try
        return try! NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
    }()

    // Trailing run at the very end, started by a strong boundary (sentence end + space,
    // newline, or start of text). Group 1 is the run to remove.
    private static let trailRegex: NSRegularExpression = {
        let pattern = "(?:(?<=[.!?…])\\s+|\\n\\s*|\\A\\s*)(" + runPattern + ")\\s*\\Z"
        // swiftlint:disable:next force_try
        return try! NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
    }()

    public func filter(_ text: String) -> String {
        let s = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.isEmpty { return text }

        // Whole short take that is nothing but credits / weak filler -> drop entirely.
        // Scalar count (not grapheme count) for exact parity with Python len() at the gate.
        if s.unicodeScalars.count <= Self.maxCreditChars {
            let sRange = NSRange(s.startIndex..<s.endIndex, in: s)
            if Self.wholeRegex.firstMatch(in: s, range: sRange) != nil {
                return ""
            }
        }

        // Trailing credit run appended after real speech -> strip only the run, keep the
        // real text and the punctuation that preceded the run.
        let textRange = NSRange(text.startIndex..<text.endIndex, in: text)
        if let match = Self.trailRegex.firstMatch(in: text, range: textRange) {
            let groupNSRange = match.range(at: 1)
            if groupNSRange.location != NSNotFound, let groupRange = Range(groupNSRange, in: text) {
                let run = text[groupRange]
                if run.unicodeScalars.count <= Self.maxCreditChars {
                    let prefix = text[text.startIndex..<groupRange.lowerBound]
                    return prefix.trimmingTrailingWhitespace()
                }
            }
        }

        return text
    }
}

private extension StringProtocol {
    /// Equivalent to Python's `str.rstrip()` with its default (Unicode whitespace) charset.
    func trimmingTrailingWhitespace() -> String {
        var view = self[...]
        while let last = view.last, last.isWhitespace {
            view = view.dropLast()
        }
        return String(view)
    }
}
