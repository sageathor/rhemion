import RhemionASR
import RhemionCore

/// Composition helper: discovers models (Parakeet from FluidAudio's shared cache; whisper by
/// scanning the search path = default dir + snapshot `model_dirs`) and registers each PRESENT one,
/// keyed by model id, so the active model can switch live (the per-take choice selects a different
/// pre-built engine -- see main.swift). Only the whisper CLI binary is a shared advanced override.
///
/// Missing models are intentionally NOT registered (there is nothing to run); they still appear in
/// `rhemion models` as downloadable. Adding a new search dir or file takes a restart (this runs at
/// startup); switching among already-registered models is live.
public func makeModelRegistry(from snapshot: SettingsSnapshot) -> TranscriptionEngineRegistry {
    makeModelRegistry(entries: ModelRegistry.discover(extraDirs: snapshot.modelDirs), snapshot: snapshot)
}

/// Registers the PRESENT entries from an already-computed discovery (so callers that also need the
/// entry list -- e.g. to pick the startup model -- can discover once).
public func makeModelRegistry(entries: [ModelEntry], snapshot: SettingsSnapshot) -> TranscriptionEngineRegistry {
    let registry = TranscriptionEngineRegistry()
    let whisperBinary = snapshot.whisperBinary ?? WhisperEngine.defaultBinary
    for entry in entries where entry.found {
        let engine: TranscriptionEngine
        switch entry.engine {
        case "whisper":
            engine = WhisperEngine(binary: whisperBinary, model: entry.whisperModel ?? WhisperEngine.defaultModel)
        default: // parakeet
            engine = ParakeetEngine(version: entry.parakeetVersion ?? .v3)
        }
        registry.register(engine, as: entry.id)
    }
    return registry
}

/// Convenience for tests and callers with no snapshot: discover with the default search path.
public func makeModelRegistry() -> TranscriptionEngineRegistry {
    makeModelRegistry(from: SettingsSnapshot())
}
