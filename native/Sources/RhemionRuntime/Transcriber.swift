import Foundation
import RhemionASR

/// Resolves a transcription engine by ID (falling back to a default), runs it over a WAV
/// file's samples, and times the finalize call. Returns nil (rather than throwing) on an
/// unknown engine ID or any session failure, so a caller can treat "no transcript" as a
/// normal, non-fatal outcome.
public struct Transcriber: Sendable {
    private let registry: TranscriptionEngineRegistry
    private let defaultEngineID: String

    public init(registry: TranscriptionEngineRegistry, defaultEngineID: String) {
        self.registry = registry
        self.defaultEngineID = defaultEngineID
    }

    public func run(wav: URL, engineID: String?, language: LanguagePolicy) async -> TranscriptResult? {
        let resolvedID = engineID ?? defaultEngineID
        guard let engine = registry.engine(id: resolvedID) else {
            logToStderr("[asr] transcriber: unknown engine '\(resolvedID)' (default '\(defaultEngineID)')\n")
            return nil
        }

        do {
            let session = try engine.makeSession(language: language)
            let samples = try WAVReader.readInt16Mono16k(wav)
            session.append(samples)

            let start = DispatchTime.now()
            let text = try await session.finalize()
            let elapsedNanoseconds = DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds
            let milliseconds = Double(elapsedNanoseconds) / 1_000_000

            return TranscriptResult(text: text, engineID: resolvedID, milliseconds: milliseconds)
        } catch {
            logToStderr("[asr] transcriber: engine '\(resolvedID)' failed: \(error)\n")
            return nil
        }
    }

    private func logToStderr(_ message: String) {
        FileHandle.standardError.write(Data(message.utf8))
    }
}
