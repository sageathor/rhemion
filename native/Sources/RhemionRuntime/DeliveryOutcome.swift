import Foundation

/// Result of running the delivery pipeline over a raw transcript: the post-processed
/// `clean` text, an optional `enhanced` replacement, and whether anything should be
/// delivered at all. Defined in RhemionRuntime (rather than re-exporting RhemionDelivery's
/// `DeliveredText`) so RhemionRuntime's public type surface stays free of a RhemionDelivery
/// import -- the composition root maps `DeliveredText` onto this at the call site.
public struct DeliveryOutcome: Sendable {
    public let clean: String
    public let enhanced: String?
    public let shouldDeliver: Bool
    /// The "as spoken" text before the dictionary substitution that produced `clean`
    /// (mirrors `ProcessedText.preDictionary` / `DeliveredText.preDictionary`), carried
    /// through unconditionally. `undoOriginal` below applies the enhancement gate.
    public let preDictionary: String?

    public init(clean: String, enhanced: String?, shouldDeliver: Bool, preDictionary: String? = nil) {
        self.clean = clean
        self.enhanced = enhanced
        self.shouldDeliver = shouldDeliver
        self.preDictionary = preDictionary
    }
}

/// Gates `preDictionary` (the pre-dictionary "as spoken" text) for use as `Event.deliver`'s
/// `original`. Only meaningful as an undo target when the delivered text is exactly the
/// dictionary-corrected `clean` text -- i.e. enhancement did not also rewrite it. If an
/// enhancer changed the text, undoing the dictionary substitution alone would not reproduce
/// what was actually typed, so this returns nil rather than offering a misleading undo.
///
/// - Parameters:
///   - clean: the post-processed, dictionary-corrected text.
///   - enhanced: the enhancer's output, or nil when enhancement did not run / is off.
///   - preDictionary: the "as spoken" text before the dictionary step, or nil when the
///     dictionary made no change (nothing to undo).
/// - Returns: `preDictionary` when the delivered text equals `clean` and `preDictionary`
///   is non-nil; otherwise nil.
public func undoOriginal(clean: String, enhanced: String?, preDictionary: String?) -> String? {
    guard enhanced == nil || enhanced == clean else { return nil }
    return preDictionary
}
