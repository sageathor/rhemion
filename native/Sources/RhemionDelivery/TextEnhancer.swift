import Foundation

/// Seam for optional LLM-based text enhancement of an already-clean, delivered transcript.
/// Exists from day one so a real enhancer (local or remote LLM) is a protocol
/// implementation plus a policy flip, never a rewrite of `DeliveryPipeline`. In
/// Milestone 4A the only implementation is `NoopEnhancer` and the default policy is `.off`.
public protocol TextEnhancer: Sendable {
    func enhance(_ text: String) async -> String
}

/// Identity enhancer: returns the input unchanged. The 4A default, keeping the
/// enhancement seam wired but inert.
public struct NoopEnhancer: TextEnhancer {
    public init() {}
    public func enhance(_ text: String) async -> String { text }
}

/// Governs whether/how `DeliveryPipeline` applies a `TextEnhancer` to the post-processed text.
public enum EnhancementPolicy: Sendable {
    /// Enhancer is not invoked. `DeliveredText.enhanced` is always `nil`. The 4A default.
    case off
    /// Enhancer runs synchronously to delivery: `run` awaits it before returning, and
    /// `DeliveredText.enhanced` carries the result.
    case wait
    /// Reserved for a future phase (4B+): deliver `clean` immediately, then replace it
    /// with an enhanced version via a second, later event once enhancement finishes.
    /// In 4A this is NOT implemented as async replacement — `run` behaves like `.off`
    /// and returns `clean` with `enhanced == nil`. No background enhancement task is
    /// started here; building that machinery is out of scope for this task.
    case asyncReplace
}

/// The text a caller should deliver (e.g. paste) after post-processing and optional
/// enhancement. When `shouldDeliver` is true, the caller emits `enhanced ?? clean`.
public struct DeliveredText: Equatable, Sendable {
    public let clean: String
    public let enhanced: String?
    public let shouldDeliver: Bool
    /// Carried through from `ProcessedText.preDictionary` (the "as spoken" text before the
    /// dictionary step), unchanged by enhancement. Consumers gate its use against `enhanced`
    /// themselves -- see `undoOriginal` in RhemionRuntime.
    public let preDictionary: String?

    public init(clean: String, enhanced: String?, shouldDeliver: Bool, preDictionary: String? = nil) {
        self.clean = clean
        self.enhanced = enhanced
        self.shouldDeliver = shouldDeliver
        self.preDictionary = preDictionary
    }
}

/// Ties `PostProcessor` output to optional `TextEnhancer` application per `EnhancementPolicy`,
/// producing the final `DeliveredText` for the runtime to emit.
public struct DeliveryPipeline: Sendable {
    private let postProcessor: PostProcessor
    private let enhancer: any TextEnhancer
    private let policy: EnhancementPolicy

    public init(
        postProcessor: PostProcessor = PostProcessor(),
        enhancer: any TextEnhancer = NoopEnhancer(),
        policy: EnhancementPolicy = .off
    ) {
        self.postProcessor = postProcessor
        self.enhancer = enhancer
        self.policy = policy
    }

    public func run(raw: String, dictionary: RecognitionDictionary) async -> DeliveredText {
        let processed = postProcessor.process(raw, dictionary: dictionary)
        let clean = processed.text
        let preDictionary = processed.preDictionary

        // Never run the enhancer on a non-deliverable result (over-limit or emptied
        // by dehallucination) — there is nothing worth enhancing.
        guard processed.shouldDeliver else {
            return DeliveredText(clean: clean, enhanced: nil, shouldDeliver: false, preDictionary: preDictionary)
        }

        switch policy {
        case .off:
            return DeliveredText(clean: clean, enhanced: nil, shouldDeliver: true, preDictionary: preDictionary)
        case .wait:
            let enhanced = await enhancer.enhance(clean)
            return DeliveredText(clean: clean, enhanced: enhanced, shouldDeliver: true, preDictionary: preDictionary)
        case .asyncReplace:
            // Future phase: deliver `clean` now, enhance in the background, and emit a
            // second "replace" event once done. Not built in 4A — see the case doc above.
            return DeliveredText(clean: clean, enhanced: nil, shouldDeliver: true, preDictionary: preDictionary)
        }
    }
}
