import Foundation

/// Result of transcription from an ASR engine.
public struct TranscriptResult: Equatable, Sendable {
    public var text: String
    public var engineID: String
    public var milliseconds: Double

    public init(text: String, engineID: String, milliseconds: Double) {
        self.text = text
        self.engineID = engineID
        self.milliseconds = milliseconds
    }
}

/// Session for accumulating audio samples and finalizing transcription.
///
/// Contract (shared by every engine behind this seam so engines are swappable):
/// - Empty/silent audio or no recognized speech resolves to the empty string --
///   `finalize()` never throws merely because there was nothing to transcribe.
/// - A genuine engine or setup failure (missing binary/model, process launch failure)
///   may be surfaced by throwing; a caught throw means "no transcript", not silence.
/// - A session is single-shot: `append` any number of times, then `finalize` once.
///   Reusing a session after `finalize` is not supported.
public protocol ASRSession: AnyObject {
    func append(_ samples: [Int16])
    func finalize() async throws -> String
}

/// Engine capable of creating transcription sessions.
public protocol TranscriptionEngine: Sendable {
    var id: String { get }
    /// Creates a session for one take, resolved to the given language policy (e.g. Parakeet maps
    /// `.auto` to multilingual decoding with no language filter; whisper maps it to the `auto` CLI
    /// flag). Engines no longer fix a language at construction -- language is a per-take choice.
    func makeSession(language: LanguagePolicy) throws -> ASRSession
    /// Eagerly load and compile whatever the first real transcription would otherwise load
    /// lazily, so the first live dictation is not stalled by a cold model load. Safe to call at
    /// startup and idempotent. Default: a no-op for engines that hold no warm state (e.g. an
    /// engine that shells out per call). Returns whether the engine is now warm.
    @discardableResult func prewarm() async -> Bool
}

public extension TranscriptionEngine {
    @discardableResult func prewarm() async -> Bool { true }

    /// Convenience for language-agnostic callers (e.g. the asr-compare bench harness): builds a
    /// session with `.auto`, matching the multilingual behavior every engine had before per-take
    /// language selection existed. Protocol requirements can't carry default parameter values in
    /// Swift, hence this extension rather than a default on the requirement itself.
    func makeSession() throws -> ASRSession {
        try makeSession(language: .auto)
    }
}

/// Registry for managing transcription engines by ID.
/// `@unchecked Sendable`: all mutable state is guarded by `lock`, so concurrent registration
/// and lookup (e.g. from a detached transcription Task) is safe.
public final class TranscriptionEngineRegistry: @unchecked Sendable {
    private var engines: [String: TranscriptionEngine] = [:]
    private let lock = NSLock()

    public init() {}

    public func register(_ engine: TranscriptionEngine) {
        register(engine, as: engine.id)
    }

    /// Register under an explicit key (e.g. a model id like "parakeet-v3") rather than the engine's
    /// own id. Lets several models that share an engine type coexist, each selectable by model id.
    public func register(_ engine: TranscriptionEngine, as key: String) {
        lock.lock()
        defer { lock.unlock() }
        engines[key] = engine
    }

    public func engine(id: String) -> TranscriptionEngine? {
        lock.lock()
        defer { lock.unlock() }
        return engines[id]
    }

    public var ids: [String] {
        lock.lock()
        defer { lock.unlock() }
        return Array(engines.keys)
    }
}
