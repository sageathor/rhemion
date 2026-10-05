import Foundation

/// Final result of the delivery post-processing pipeline.
public struct ProcessedText: Equatable, Sendable {
    public let text: String
    public let shouldDeliver: Bool
    /// The "as spoken" text: the same pipeline run WITHOUT the dictionary step, used
    /// later for undo. Non-nil only when `shouldDeliver`, the dictionary actually
    /// changed the sanitized text, and the no-dictionary result is non-empty and
    /// differs from the final `text`. Otherwise nil.
    public let preDictionary: String?
    public init(text: String, shouldDeliver: Bool, preDictionary: String? = nil) {
        self.text = text
        self.shouldDeliver = shouldDeliver
        self.preDictionary = preDictionary
    }
}

/// Composes the single deterministic pipeline that turns a raw ASR transcript into
/// the final, terminal-safe, dictionary-corrected text.
///
/// Order (spec Section 4): filter junk patterns -> trim -> dictionary replacements ->
/// dehallucination -> whitespace normalization. Concretely:
///   1. `sanitizer.sanitize(raw)` — strips control/line-ish scalars, collapses spaces,
///      trims, and gates on `maxChars`. `overLimit` short-circuits to a non-deliverable
///      empty result (the runtime would record history instead of pasting).
///   2. `dictionary.apply(...)` — whole-word variant -> canonical replacements.
///   3. `dehallucinator.filter(...)` — strips whisper subtitle-credit hallucinations.
///   4. Final normalize: collapse any double spaces the dictionary/dehallucinator may
///      have introduced, then trim. Never re-introduces newlines.
public struct PostProcessor: Sendable {
    private let sanitizer: TextSanitizer
    private let dehallucinator: Dehallucinator

    public init(sanitizer: TextSanitizer = TextSanitizer(), dehallucinator: Dehallucinator = Dehallucinator()) {
        self.sanitizer = sanitizer
        self.dehallucinator = dehallucinator
    }

    public func process(_ raw: String, dictionary: RecognitionDictionary) -> ProcessedText {
        let sanitized = sanitizer.sanitize(raw)
        if sanitized.overLimit {
            return ProcessedText(text: "", shouldDeliver: false)
        }

        let replaced = dictionary.apply(sanitized.text)
        let filtered = dehallucinator.filter(replaced)

        // Re-sanitize as the true last step so terminal-safety holds end-to-end: a dictionary
        // canonical (inserted verbatim) could carry a control/tab/format char that the initial
        // sanitize never saw. This also does the final space-collapse, trim, and over-limit
        // re-check (dictionary expansion can push a borderline take over the ceiling).
        let normalized = sanitizer.sanitize(filtered)
        if normalized.overLimit {
            return ProcessedText(text: "", shouldDeliver: false)
        }

        let final = normalized.text
        guard !final.isEmpty else {
            return ProcessedText(text: "", shouldDeliver: false)
        }

        // The dictionary changed something only if it altered the sanitized input; in
        // that case, recompute the no-dictionary branch (dehallucinate + normalize) to
        // get the "as spoken" text for undo.
        var pre: String? = nil
        if replaced != sanitized.text {
            let preNorm = sanitizer.sanitize(dehallucinator.filter(sanitized.text)).text
            if !preNorm.isEmpty && preNorm != final {
                pre = preNorm
            }
        }

        return ProcessedText(text: final, shouldDeliver: true, preDictionary: pre)
    }
}
