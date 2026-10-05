import FluidAudio
import Foundation

/// A recognition model the user can select. Discovered by scanning, not hardcoded: whisper models
/// come from scanning a search path of directories (so a `.bin` dropped in -- or one already
/// downloaded by another tool -- is picked up, no per-file config and no duplicate download);
/// Parakeet models come from FluidAudio's SHARED cache (`~/Library/Application Support/FluidAudio/
/// Models`), which every FluidAudio app reuses, so they are de-duplicated across apps for free. A
/// small known-models table supplies nice labels; anything else still shows up.
///
/// NOTE: discovery runs at runtime START. A newly added file/dir appears in `rhemion models`
/// immediately (that CLI rescans) but is only RUNNABLE after a runtime restart, and only PRESENT
/// models are registered to run (missing ones list as downloadable).
public struct ModelEntry: Sendable {
    public let id: String            // stable settings value, e.g. "parakeet-v3" / "whisper-large-v3-turbo"
    public let label: String         // human name for the listing
    public let engine: String        // TranscriptionEngine.id: "parakeet" | "whisper"
    public let detail: String        // one-line description
    public let location: String      // parakeet: cache dir; whisper: weights file (tilde-expanded)
    public let found: Bool           // present on disk right now
    public let parakeetVersion: AsrModelVersion?   // set for parakeet models (to build the engine)
    public let whisperModel: String?               // resolved .bin path (to build the engine)

    public init(id: String, label: String, engine: String, detail: String, location: String,
                found: Bool, parakeetVersion: AsrModelVersion?, whisperModel: String?) {
        self.id = id; self.label = label; self.engine = engine; self.detail = detail
        self.location = location; self.found = found
        self.parakeetVersion = parakeetVersion; self.whisperModel = whisperModel
    }
}

public enum ModelRegistry {
    public static let defaultID = "parakeet-v3"

    /// Built-in whisper search directory. Extra dirs (setting `model_dirs`) are scanned in addition,
    /// letting the user reuse whisper models already downloaded elsewhere instead of duplicating them.
    public static let defaultWhisperDir = "~/.local/share/whisper"

    /// Known parakeet models: id, FluidAudio version, label, detail. (These live in FluidAudio's
    /// shared cache; presence is checked there.)
    private static let knownParakeet: [(id: String, version: AsrModelVersion, label: String, detail: String)] = [
        ("parakeet-v3", .v3, "Parakeet v3", "NVIDIA Parakeet v3 (FluidAudio, ANE) — multilingual, default"),
        ("parakeet-v2", .v2, "Parakeet v2", "NVIDIA Parakeet v2 (FluidAudio, ANE) — English-optimized"),
    ]

    /// Resolve downloadable models from the same table used by discovery, without scanning disk.
    public static func parakeetVersion(id: String) -> AsrModelVersion? {
        knownParakeet.first { $0.id == id }?.version
    }

    /// Nice labels/details for known whisper weight filenames; unknown `.bin` files still appear
    /// (labeled by filename). Keyed by the on-disk filename.
    private static let knownWhisper: [String: (label: String, detail: String)] = [
        "ggml-large-v3-turbo.bin": ("Whisper Large v3 Turbo", "whisper.cpp large-v3-turbo — multilingual, full precision"),
        "ggml-large-v3-turbo-q5_0.bin": ("Whisper Large v3 Turbo (Q5)", "whisper.cpp large-v3-turbo, Q5 quantized — smaller/faster"),
    ]

    /// Discover every model: Parakeet from the shared FluidAudio cache, whisper by scanning
    /// `defaultWhisperDir` + `extraDirs`. Parakeet and known-whisper models are always listed (as
    /// missing if absent, so the catalog shows what could be added); scanned unknown `.bin` files are
    /// added too. Whisper de-dups by model id (search-path order: earlier dirs win).
    public static func discover(extraDirs: [String] = []) -> [ModelEntry] {
        var out: [ModelEntry] = []

        for p in knownParakeet {
            let dir = AsrModels.defaultCacheDirectory(for: p.version)
            out.append(ModelEntry(id: p.id, label: p.label, engine: "parakeet", detail: p.detail,
                                  location: dir.path, found: AsrModels.modelsExist(at: dir, version: p.version),
                                  parakeetVersion: p.version, whisperModel: nil))
        }

        // Whisper: scan the search path for *.bin (excluding VAD helpers), de-dup by id.
        var seen = Set<String>()
        let dirs = ([defaultWhisperDir] + extraDirs).map(expandTilde)
        for dir in dirs {
            let names = (try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []
            for name in names.sorted() where hasBinSuffix(name) && !isVADName(name) {
                let id = whisperID(for: name)
                guard !seen.contains(id) else { continue }
                let path = (dir as NSString).appendingPathComponent(name)
                // A model must be a readable regular file: a directory named "x.bin", a broken
                // symlink, or a FIFO is not a model. (fileExists follows symlinks, so a symlink to a
                // real weights file still qualifies.)
                guard isUsableModelFile(path) else { continue }
                seen.insert(id)
                let known = knownWhisper[name]
                out.append(ModelEntry(id: id, label: known?.label ?? name, engine: "whisper",
                                      detail: known?.detail ?? "whisper.cpp model (\(name))",
                                      location: path, found: true, parakeetVersion: nil, whisperModel: path))
            }
        }
        // Known whisper models not found anywhere in the search path -> list as missing.
        for (name, meta) in knownWhisper.sorted(by: { $0.key < $1.key }) {
            let id = whisperID(for: name)
            guard !seen.contains(id) else { continue }
            let expected = (expandTilde(defaultWhisperDir) as NSString).appendingPathComponent(name)
            out.append(ModelEntry(id: id, label: meta.label, engine: "whisper", detail: meta.detail,
                                  location: expected, found: false, parakeetVersion: nil, whisperModel: expected))
        }
        return out
    }

    /// The discovered entry with this id (nil if none), for a given search path.
    public static func entry(id: String?, extraDirs: [String] = []) -> ModelEntry? {
        guard let id = id?.trimmingCharacters(in: .whitespacesAndNewlines), !id.isEmpty else { return nil }
        return discover(extraDirs: extraDirs).first { $0.id == id }
    }

    /// Pick the model id to start on: the desired one if present, else the default if present, else
    /// the first present model, else the default id (nothing found -- the runtime will surface that).
    public static func startupID(desired: String?, entries: [ModelEntry]) -> String {
        let present = entries.filter { $0.found }
        if let d = desired?.trimmingCharacters(in: .whitespacesAndNewlines),
           present.contains(where: { $0.id == d }) { return d }
        if present.contains(where: { $0.id == defaultID }) { return defaultID }
        return present.first?.id ?? defaultID
    }

    // whisper filename -> stable id: "ggml-large-v3-turbo-q5_0.bin" -> "whisper-large-v3-turbo-q5_0".
    // Extension stripping is case-insensitive (handles ".BIN"); the "ggml-" prefix too.
    private static func whisperID(for filename: String) -> String {
        var stem = (filename as NSString).deletingPathExtension
        if stem.lowercased().hasPrefix("ggml-") { stem = String(stem.dropFirst(5)) }
        return "whisper-\(stem)"
    }

    private static func hasBinSuffix(_ name: String) -> Bool { name.lowercased().hasSuffix(".bin") }

    // Exclude VAD helper models (e.g. ggml-silero-*.bin). Token-based, not a naive substring, so a
    // legitimate name like "invader-model.bin" is NOT excluded by containing "vad".
    private static func isVADName(_ name: String) -> Bool {
        let tokens = Set(name.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init))
        return tokens.contains("silero") || tokens.contains("vad")
    }

    private static func isUsableModelFile(_ path: String) -> Bool {
        var isDir: ObjCBool = false
        let fm = FileManager.default
        return fm.fileExists(atPath: path, isDirectory: &isDir) && !isDir.boolValue && fm.isReadableFile(atPath: path)
    }

    private static func expandTilde(_ path: String) -> String { (path as NSString).expandingTildeInPath }
}
