import Foundation
import RhemionAudio

/// Errors raised by `WhisperEngine` / `WhisperSession`.
public enum WhisperEngineError: Error, CustomStringConvertible {
    case binaryNotFound(String)
    case modelNotFound(String)
    case processLaunchFailed(String)
    case untrustedBinary(String)

    public var description: String {
        switch self {
        case .binaryNotFound(let path):
            return "whisper-cli binary not found at \(path)"
        case .modelNotFound(let path):
            return "whisper model not found at \(path)"
        case .processLaunchFailed(let reason):
            return "failed to launch whisper-cli: \(reason)"
        case .untrustedBinary(let reason):
            return "refusing to run whisper-cli: \(reason)"
        }
    }
}

/// Guards the configurable `whisper_binary` before it is executed: the runtime hands it the raw
/// recording, so a path an untrusted principal could point at another program is an exfiltration
/// vector. Require an absolute, real regular file (not a swappable symlink), owned by this user or
/// root, and not group/world-writable (so no other principal can replace it). Throws otherwise.
func validateTrustedExecutable(_ path: String) throws {
    guard path.hasPrefix("/") else {
        throw WhisperEngineError.untrustedBinary("not an absolute path: \(path)")
    }
    // Resolve symlinks and validate the REAL target: the default /opt/homebrew/bin/whisper-cli is a
    // Homebrew symlink into Cellar, so rejecting symlinks outright would break the happy path. realpath
    // canonicalizes the whole chain (and fails if the path is missing); the ownership/mode checks then
    // apply to the actual binary that would run, so a target an untrusted principal could replace is
    // still refused.
    guard let resolvedC = realpath(path, nil) else {
        throw WhisperEngineError.untrustedBinary("cannot resolve \(path)")
    }
    let resolved = String(cString: resolvedC)
    free(resolvedC)
    var info = stat()
    guard stat(resolved, &info) == 0 else {
        throw WhisperEngineError.untrustedBinary("cannot stat \(path)")
    }
    guard (info.st_mode & S_IFMT) == S_IFREG else {
        throw WhisperEngineError.untrustedBinary("not a regular file: \(path)")
    }
    guard info.st_uid == geteuid() || info.st_uid == 0 else {
        throw WhisperEngineError.untrustedBinary("not owned by this user or root: \(path)")
    }
    guard (info.st_mode & S_IWGRP) == 0, (info.st_mode & S_IWOTH) == 0 else {
        throw WhisperEngineError.untrustedBinary("group- or world-writable (replaceable): \(path)")
    }
    guard access(resolved, X_OK) == 0 else {
        throw WhisperEngineError.untrustedBinary("not executable: \(path)")
    }
}

/// Batch transcription engine backed by the `whisper-cli` command-line tool.
/// Each session accumulates samples in memory, then on `finalize()` writes them to a
/// temporary WAV file and shells out to `whisper-cli` to produce a text transcript.
public struct WhisperEngine: TranscriptionEngine {
    /// Built-in locations, used when neither a settings override nor an env var supplies one.
    /// Shared with the registry builder and the `rhemion engines` discovery helper so all three
    /// report the same "where whisper looks by default".
    public static let defaultBinary = "/opt/homebrew/bin/whisper-cli"
    public static let defaultModel = "~/.local/share/whisper/ggml-large-v3-turbo.bin"

    public let binary: String
    public let model: String

    public init(
        binary: String = ProcessInfo.processInfo.environment["RHEMION_WHISPER_BIN"] ?? WhisperEngine.defaultBinary,
        model: String = ProcessInfo.processInfo.environment["RHEMION_WHISPER_MODEL"] ?? WhisperEngine.defaultModel
    ) {
        self.binary = (binary as NSString).expandingTildeInPath
        self.model = (model as NSString).expandingTildeInPath
    }

    public var id: String { "whisper" }

    public func makeSession(language: LanguagePolicy) throws -> ASRSession {
        WhisperSession(binary: binary, model: model, language: language.whisperFlag)
    }

    /// Rhemion's own temp folder (RHEMION_TMP_DIR, set by the app's supervisor) so Uninstall can remove
    /// it without masks over the shared $TMPDIR; falls back to the system temp dir for CLI use.
    public static func temporaryRoot() -> URL {
        guard let custom = ProcessInfo.processInfo.environment["RHEMION_TMP_DIR"], !custom.isEmpty else {
            return FileManager.default.temporaryDirectory
        }
        let url = URL(fileURLWithPath: custom, isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        return url
    }
}

/// Pure builder for the `whisper-cli` invocation arguments, factored out of `WhisperSession`
/// so the `-l` flag's language mapping is testable without running the binary.
func whisperCLIArguments(model: String, wavPath: String, language: String) -> [String] {
    ["-m", model, "-f", wavPath, "-l", language, "-otxt", "-nt"]
}

/// Thread-safe holder for data accumulated on a background drain thread. `@unchecked Sendable`
/// is safe here because each instance is written by exactly one background closure and only
/// read after that closure has signaled completion via `DispatchGroup.wait()` (a happens-before
/// barrier), so there is no concurrent access.
private final class DataBox: @unchecked Sendable {
    var data = Data()
}

/// Result of running `whisper-cli` to completion.
private struct WhisperProcessResult {
    var status: Int32
    var stderrText: String
}

/// Runs `whisper-cli` synchronously to completion, draining stdout/stderr concurrently with
/// execution to avoid the classic `Process` deadlock: pipe buffers are ~64KB, and whisper-cli
/// prints a startup banner plus per-segment text and timing info, which can exceed that before
/// the process exits. Reading only after `waitUntilExit()` would block forever if the child
/// blocks on `write()` to a full pipe while we block on `waitUntilExit()`.
///
/// This is deliberately a plain (non-`async`) function: `DispatchGroup.wait()` is unavailable
/// from asynchronous contexts, so the blocking wait lives here and `WhisperSession.finalize()`
/// simply calls it.
private func runWhisperCLI(binary: String, arguments: [String]) throws -> WhisperProcessResult {
    // The runtime is about to hand this program the recording; refuse to launch it unless it passes
    // the trust checks (absolute, real file, owned by us or root, not other-writable).
    try validateTrustedExecutable(binary)
    let process = Process()
    process.executableURL = URL(fileURLWithPath: binary)
    process.arguments = arguments

    let stdoutPipe = Pipe()
    let stderrPipe = Pipe()
    process.standardOutput = stdoutPipe
    process.standardError = stderrPipe

    let stdoutBox = DataBox()
    let stderrBox = DataBox()
    let drainGroup = DispatchGroup()

    drainGroup.enter()
    DispatchQueue.global(qos: .utility).async {
        stdoutBox.data = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        drainGroup.leave()
    }
    drainGroup.enter()
    DispatchQueue.global(qos: .utility).async {
        stderrBox.data = stderrPipe.fileHandleForReading.readDataToEndOfFile()
        drainGroup.leave()
    }

    do {
        try process.run()
    } catch {
        throw WhisperEngineError.processLaunchFailed(error.localizedDescription)
    }
    process.waitUntilExit()
    drainGroup.wait()

    let stderrText = String(data: stderrBox.data, encoding: .utf8) ?? "<non-UTF8 stderr>"
    return WhisperProcessResult(status: process.terminationStatus, stderrText: stderrText)
}

/// `ASRSession` implementation that batches all audio and transcribes it once, on `finalize()`.
private final class WhisperSession: ASRSession {
    private let binary: String
    private let model: String
    /// The resolved whisper-cli `-l` value ("auto"/"ru"/"en"), already mapped from the session's
    /// `LanguagePolicy` by `WhisperEngine.makeSession(language:)`.
    private let language: String
    private var samples: [Int16] = []

    init(binary: String, model: String, language: String) {
        self.binary = binary
        self.model = model
        self.language = language
    }

    func append(_ samples: [Int16]) {
        self.samples.append(contentsOf: samples)
    }

    func finalize() async throws -> String {
        guard FileManager.default.fileExists(atPath: binary) else {
            throw WhisperEngineError.binaryNotFound(binary)
        }
        guard FileManager.default.fileExists(atPath: model) else {
            throw WhisperEngineError.modelNotFound(model)
        }

        let wavURL = WhisperEngine.temporaryRoot()
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("wav")
        let txtURL = wavURL.appendingPathExtension("txt")

        defer {
            try? FileManager.default.removeItem(at: wavURL)
            try? FileManager.default.removeItem(at: txtURL)
        }

        let writer = try WAVWriter(url: wavURL)
        try writer.append(samples)
        try writer.finalize()

        let result = try runWhisperCLI(
            binary: binary,
            arguments: whisperCLIArguments(model: model, wavPath: wavURL.path, language: language)
        )

        if result.status != 0 {
            // Keep the spec behavior (still returns "" below, never throws for this), but
            // log loudly so a crash/OOM/corrupt-model doesn't silently look like "no speech".
            let truncated = result.stderrText.count > 2000
                ? String(result.stderrText.prefix(2000)) + "... (truncated)"
                : result.stderrText
            FileHandle.standardError.write(Data(
                "[whisper] whisper-cli exited with status \(result.status): \(truncated)\n".utf8
            ))
        }

        guard FileManager.default.fileExists(atPath: txtURL.path) else {
            return ""
        }
        guard let text = try? String(contentsOf: txtURL, encoding: .utf8) else {
            return ""
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
