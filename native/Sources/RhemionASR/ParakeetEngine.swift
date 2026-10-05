import FluidAudio
import Foundation

/// Owns the warm `AsrManager` and loads the model exactly once.
/// Actor isolation makes it safely sendable and serializes model loading and transcription.
actor ParakeetModelHost {
    private let manager = AsrManager(config: .default)
    private let version: AsrModelVersion
    private var loadTask: Task<Void, Error>?

    init(version: AsrModelVersion) {
        // Privacy: the dictation runtime must NEVER reach the network. FluidAudio can otherwise
        // auto-download or re-download models from HuggingFace when the local cache is missing or
        // fails to load. Force strict offline so any such attempt throws instead of making a request;
        // installing models is a separate, explicit, user-invoked step, not something the runtime does.
        ModelHub.offlineMode = true
        self.version = version
    }

    /// Loads the model exactly once. Concurrent first-use awaits the same in-flight
    /// load task rather than starting a second load (actors are reentrant, so a bare flag
    /// checked across `await` points would let two callers both load). A failed load is
    /// cleared so the next call can retry.
    private func ensureLoaded() async throws {
        if let loadTask {
            try await loadTask.value
            return
        }

        let task = Task { [manager, version] in
            let directory = AsrModels.defaultCacheDirectory(for: version)
            guard AsrModels.modelsExist(at: directory, version: version) else {
                throw ParakeetEngineError.modelsMissing(directory.path)
            }
            let models = try await AsrModels.load(from: directory, version: version)
            try await manager.loadModels(models)
        }
        loadTask = task

        do {
            try await task.value
        } catch {
            loadTask = nil
            throw error
        }
    }

    /// Eagerly load the model AND run one throwaway inference so the Core ML program is compiled
    /// (onto the ANE) before the first real dictation. Without this the first transcription pays a
    /// ~20s cold load+compile cost; because this actor serializes transcription, every dictation
    /// held during that window queues behind it and then flushes in a burst. Best-effort: any
    /// error is swallowed, so a failed prewarm simply leaves the lazy path to retry on real use
    /// (and surface the error there), exactly as before.
    @discardableResult func prewarm() async -> Bool {
        do {
            try await ensureLoaded()
            // Model load alone does not compile the inference graph; one tiny silent buffer forces
            // that first-inference compilation up front. 0.5s at 16 kHz is enough and returns fast.
            // Multilingual (nil) on purpose: prewarm compiles the graph, it doesn't decode real
            // speech, so there is no per-take language to honor here.
            var state = TdtDecoderState.make(decoderLayers: await manager.decoderLayerCount)
            _ = try await manager.transcribe(
                [Float](repeating: 0, count: 8000),
                decoderState: &state,
                language: nil
            )
            return true
        } catch {
            // Best-effort: real transcription retries the load and surfaces any error.
            return false
        }
    }

    /// `language` is per-call (not stored) so one warm model instance can serve takes with
    /// different language policies; `nil` requests FluidAudio's native multilingual decode.
    func transcribe(_ samples: [Float], language: Language?) async throws -> String {
        try await ensureLoaded()
        var state = TdtDecoderState.make(decoderLayers: await manager.decoderLayerCount)
        let result = try await manager.transcribe(
            samples,
            decoderState: &state,
            language: language
        )
        return result.text
    }
}

/// Parakeet V3 transcription engine backed by FluidAudio.
/// The model is warm-loaded once and shared by all sessions created by this engine.
public struct ParakeetEngine: TranscriptionEngine {
    public let id = "parakeet"
    private let host: ParakeetModelHost

    /// `version` selects which cached Parakeet model to load (default v3). Map a settings string
    /// with `ParakeetEngine.modelVersion(from:)` so an unknown value falls back to v3. Language is
    /// no longer fixed at construction -- it is resolved per session, see `makeSession(language:)`.
    public init(version: AsrModelVersion = .v3) {
        self.host = ParakeetModelHost(version: version)
    }

    /// Maps a settings token ("v2"/"v3", case-insensitive) to an `AsrModelVersion`; anything else
    /// falls back to v3. Kept here so the runtime and the registry agree on the mapping.
    public static func modelVersion(from token: String?) -> AsrModelVersion {
        switch token?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "v2": return .v2
        default:   return .v3
        }
    }

    public func makeSession(language: LanguagePolicy) throws -> ASRSession {
        ParakeetSession(host: host, language: language.parakeet)
    }

    @discardableResult public func prewarm() async -> Bool {
        await host.prewarm()
    }
}

/// Internal (not `private`) so tests can assert the mapped language a session was built with,
/// via `@testable import RhemionASR` -- see `ParakeetEngineTests`/seam tests.
final class ParakeetSession: ASRSession {
    private let host: ParakeetModelHost
    let language: Language?
    private var samples: [Int16] = []

    init(host: ParakeetModelHost, language: Language?) {
        self.host = host
        self.language = language
    }

    func append(_ samples: [Int16]) {
        self.samples.append(contentsOf: samples)
    }

    func finalize() async throws -> String {
        // No captured audio -> nothing to recognize. Return empty without invoking the model,
        // honoring the ASRSession no-speech contract (WhisperEngine behaves the same).
        guard !samples.isEmpty else { return "" }
        let floatSamples = samples.map { Float($0) / 32768.0 }
        return try await host.transcribe(floatSamples, language: language)
    }
}

public enum ParakeetEngineError: LocalizedError {
    case modelsMissing(String)

    public var errorDescription: String? {
        switch self {
        case .modelsMissing(let path):
            return "Parakeet v3 models not found at \(path). Download them first."
        }
    }
}
