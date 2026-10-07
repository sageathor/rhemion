import Darwin
import Foundation

public enum StorageCategory: String, CaseIterable, Sendable {
    case applicationData, exportRegistry, temporary, models, externalModels,
         transcripts, dictionary, recordings, legacyContent, export
    /// Content the user made: deleted only by an explicit, default-off option, confirmed in the operation
    /// pop-up's confirm step.
    public var isUserContent: Bool { [.transcripts, .dictionary, .recordings, .legacyContent, .export].contains(self) }
}

public struct StorageItem: Hashable, Sendable {
    public let category: StorageCategory
    public let root: URL          // trusted root; never removed itself
    public let relative: [String] // plain components under root (non-empty)
    public init(category: StorageCategory, root: URL, relative: [String]) {
        self.category = category; self.root = root; self.relative = relative
    }
    public var url: URL { relative.reduce(root) { $0.appendingPathComponent($1) } }
}

/// THE ONE PLACE that knows where Rhemion keeps data (maintenance rule: a new feature that writes to disk
/// registers its paths here in the same change; StorageGuardTests enforces it).
public struct StorageLayout: Sendable {
    public let home, stateDir, dataDir, tmpBase, fluidModelsRoot, whisperDir: URL
    public let parakeetFolders: [String]
    public let extraModelDirs: [URL]
    public let exportDir: URL?
    public let bundleID: String
    /// The selected recognition model (settings `model`, e.g. "parakeet-v3", "whisper-large-v3-turbo") —
    /// what Clear Data's "Model in use" keeps apart from "Unused models".
    public let selectedModel: String
    /// Renders month notes for export re-adoption (the app's calendar = the runtime's).
    public let calendar: Calendar

    public init(home: URL, stateDir: URL, dataDir: URL, tmpBase: URL, fluidModelsRoot: URL,
                parakeetFolders: [String], whisperDir: URL, extraModelDirs: [URL], exportDir: URL?, bundleID: String,
                selectedModel: String = "", calendar: Calendar = .current) {
        self.home = home; self.stateDir = stateDir; self.dataDir = dataDir; self.tmpBase = tmpBase
        self.fluidModelsRoot = fluidModelsRoot; self.parakeetFolders = parakeetFolders; self.whisperDir = whisperDir
        self.extraModelDirs = extraModelDirs; self.exportDir = exportDir; self.bundleID = bundleID
        self.selectedModel = selectedModel; self.calendar = calendar
    }

    public var historyDir: URL { dataDir.appendingPathComponent("history") }
    public var tmpRoot: URL { tmpBase.appendingPathComponent(bundleID) }
    public var registryURL: URL { stateDir.appendingPathComponent(ExportRegistry.fileName) }

    /// Explicit "never delete" — the decision not to delete is deliberate, not forgotten.
    /// Returned AS BUILT (not standardized): Foundation's standardizedFileURL maps /private/var/... to
    /// /var/..., which would break URL-equality comparisons (e.g. in tests) against paths built the same
    /// way this layout builds them. `isSafe` below does its own standardized-path comparison instead.
    public var neverDelete: [URL] {
        var list = [home, home.appendingPathComponent(".local/state/rhemion"),
                    home.appendingPathComponent("Developer/Rhemion-2.0-retired"),
                    home.appendingPathComponent(".cache/fluidaudio"),
                    fluidModelsRoot, whisperDir, stateDir, dataDir, historyDir] + extraModelDirs
        if let exportDir { list.append(exportDir) }
        return list
    }

    /// Content roots a non-content category must never reach into.
    private var contentRoots: [URL] {
        [historyDir, stateDir.appendingPathComponent("log"), stateDir.appendingPathComponent("data"),
         home.appendingPathComponent(".local/state/rhemion")] + (exportDir.map { [$0] } ?? [])
    }

    public func isSafe(_ item: StorageItem) -> Bool {
        let target = item.url.standardizedFileURL.path
        guard !item.relative.isEmpty else { return false }
        if neverDelete.contains(where: { $0.standardizedFileURL.path == target }) { return false }
        // Never reach INTO these either: an earlier version's state and install, FluidAudio's shared cache.
        let protectedTrees = [".local/state/rhemion", "Developer/Rhemion-2.0-retired", ".cache/fluidaudio"]
            .map { home.appendingPathComponent($0).standardizedFileURL.path }
        if protectedTrees.contains(where: { target.hasPrefix($0 + "/") }) { return false }
        if !item.category.isUserContent,
           contentRoots.contains(where: { target == $0.standardizedFileURL.path || target.hasPrefix($0.standardizedFileURL.path + "/") }) {
            return false
        }
        return true
    }

    /// whisper.cpp's Core ML encoder for `ggml-<name>[-qX_Y].bin` is `ggml-<name>-encoder.mlmodelc` next
    /// to it (the quantization suffix is dropped — see whisper.cpp `whisper_get_coreml_path_encoder`).
    public static func whisperEncoderName(forModel bin: String) -> String? {
        guard bin.lowercased().hasSuffix(".bin") else { return nil }
        var stem = String(bin.dropLast(4))
        if let dash = stem.lastIndex(of: "-") {
            let tail = Array(stem[dash...])
            if tail.count == 5, tail[1] == "q", tail[3] == "_" { stem = String(stem[..<dash]) }
        }
        return stem + "-encoder.mlmodelc"
    }

    /// Every `.bin` model in a folder plus the Core ML encoder that belongs to it (removed with it).
    private func whisperFiles(in dir: URL, _ names: [String], _ item: (URL, [String]) -> StorageItem?) -> [StorageItem] {
        let bins = names.filter { $0.lowercased().hasSuffix(".bin") }
        let encoders = Set(bins.compactMap(Self.whisperEncoderName(forModel:))).intersection(names).sorted()
        return (bins + encoders).compactMap { item(dir, [$0]) }
    }

    public func items(_ c: StorageCategory) -> [StorageItem] {
        let fm = FileManager.default
        func exists(_ u: URL) -> Bool { fm.fileExists(atPath: u.path) }
        func names(_ u: URL) -> [String] { ((try? fm.contentsOfDirectory(atPath: u.path)) ?? []).sorted() }
        func item(_ root: URL, _ rel: [String]) -> StorageItem? {
            let i = StorageItem(category: c, root: root, relative: rel)
            return exists(i.url) && isSafe(i) ? i : nil
        }
        let lib = home.appendingPathComponent("Library")
        let months = names(historyDir).filter { $0.range(of: #"^\d{4}-\d{2}$"#, options: .regularExpression) != nil }
        switch c {
        case .applicationData:
            // Stray atomic temps of the last-run markers (a crash between write and rename leaves one).
            let strayTemps = names(stateDir).filter {
                ($0.hasPrefix(".history-retention-") || $0.hasPrefix(".export-last-run-")) && $0.hasSuffix(".tmp")
            }.map { [$0] }
            // The diagnostic logs and their rotated copies (`LogRotation`).
            let logs = LogRotation.files(in: stateDir).map { [$0] }
            return ([["active", "settings.json"], ["active", "settings.json.lock"]] + logs
                    + [["runtime.sock"], ["export-last-run"], ["history-retention-last-run"]] + strayTemps).compactMap { item(stateDir, $0) }
                + [item(lib.appendingPathComponent("Preferences"), ["\(bundleID).plist"]),
                   item(lib.appendingPathComponent("Caches"), [bundleID]),
                   // CoreML's compiled-model cache for the runtime helper (named after the executable).
                   item(lib.appendingPathComponent("Caches"), ["rhemion-runtime"]),
                   item(lib.appendingPathComponent("Saved Application State"), ["\(bundleID).savedState"])].compactMap { $0 }
        case .exportRegistry:
            return [item(stateDir, [ExportRegistry.fileName])].compactMap { $0 }
        case .temporary:
            return [item(tmpBase, [bundleID])].compactMap { $0 }
        case .models:
            return parakeetFolders.compactMap { item(fluidModelsRoot, [$0]) } + whisperFiles(in: whisperDir, names(whisperDir), item)
        case .externalModels:
            return scannedExtraModelDirs.flatMap { dir in whisperFiles(in: dir, names(dir), item) }
        case .transcripts:
            let log = stateDir.appendingPathComponent("log")
            return names(log).filter { $0.hasPrefix("dictate-") || $0.hasPrefix(".dictate-") }.compactMap { item(stateDir, ["log", $0]) }
                + [item(historyDir, ["README.md"])].compactMap { $0 }
                + months.flatMap { m in names(historyDir.appendingPathComponent(m)).filter { $0 != "Audio" }.compactMap { item(historyDir, [m, $0]) } }
        case .dictionary:
            return [item(stateDir, ["active", "dictionary.json"])].compactMap { $0 }
        case .recordings:
            return months.compactMap { item(historyDir, [$0, "Audio"]) }
        case .legacyContent:
            return [item(stateDir, ["data"])].compactMap { $0 }
        case .export:
            return exportNames().compactMap { item(exportDir!, [$0]) }
        }
    }

    // MARK: export ownership

    /// Month notes in the export folder that are Rhemion's: registry-owned with a matching hash, or an
    /// exact match of the current render (re-adoption, `ExportNote`). Sorted; empty without a folder.
    func exportNames() -> [String] {
        guard let exportDir else { return [] }
        let registry = ExportRegistry.load(from: registryURL)
        let owned = registry.ownedFiles(in: exportDir)
        let adoptable = ExportNote.adoptable(in: exportDir, state: stateDir, registry: registry, calendar: calendar).keys
        return Array(Set(owned).union(adoptable)).sorted()
    }

    /// Whether an "Exported transcripts" row is offered: a folder is set AND (export is on, or the registry
    /// owns entries for that folder). Cheap and synchronous — reads only the small registry JSON, renders
    /// nothing — so a row's visibility never waits for the size scan.
    public func showsExportRow(exportMode: String) -> Bool {
        guard let exportDir else { return false }
        if exportMode != "off" { return true }
        return !ExportRegistry.load(from: registryURL).ownedFiles(in: exportDir).isEmpty
    }

    /// Month notes in the export folder Rhemion can't confirm as its own (kept by any deletion).
    public func unconfirmedExportFiles() -> [String] {
        guard let exportDir else { return [] }
        let mine = Set(exportNames())
        let names = (try? FileManager.default.contentsOfDirectory(atPath: exportDir.path)) ?? []
        return names.filter { ExportRegistry.isMonthNote($0) && !mine.contains($0) }.sorted()
    }

    // MARK: Clear Data groupings

    /// "parakeet-v3" → "parakeet-tdt-0.6b-v3" (FluidAudio's cache folder for that version).
    public static func parakeetFolder(forModel id: String) -> String? {
        guard id.hasPrefix("parakeet-"), id.count > "parakeet-".count else { return nil }
        return "parakeet-tdt-0.6b-" + id.dropFirst("parakeet-".count)
    }

    /// The runtime's whisper id for a weights file: "ggml-large-v3-turbo-q5_0.bin" → "whisper-large-v3-turbo-q5_0".
    public static func whisperID(forFile name: String) -> String {
        var stem = (name as NSString).deletingPathExtension
        if stem.lowercased().hasPrefix("ggml-") { stem = String(stem.dropFirst(5)) }
        return "whisper-\(stem)"
    }

    /// Whisper's silence (VAD) helper, e.g. ggml-silero-v5.1.2.bin — token rule of the runtime's registry.
    public static func isSilenceModel(_ name: String) -> Bool {
        let tokens = Set(name.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init))
        return tokens.contains("silero") || tokens.contains("vad")
    }

    // MARK: physical identity

    /// The path with every symlink resolved (`realpath`), or the standardized path when it can't be resolved.
    public static func resolvedPath(_ url: URL) -> String {
        if let real = Darwin.realpath(url.path, nil) { defer { free(real) }; return String(cString: real) }
        return url.standardizedFileURL.path
    }

    /// Where the entry ITSELF lives: its folder resolved, its own name as is — a symlink and its target are
    /// two entries, the same entry reached through two folder spellings is one. Clear Data dedupes by this.
    public static func entryPath(_ url: URL) -> String {
        resolvedPath(url.deletingLastPathComponent()) + "/" + url.lastPathComponent
    }

    /// The extra model folders that are really extra: a folder that resolves to the built-in whisper folder
    /// or to an earlier extra folder (a duplicate entry, a symlink to it) is scanned once, not twice.
    public var scannedExtraModelDirs: [URL] {
        var seen: Set<String> = [Self.resolvedPath(whisperDir)]
        return extraModelDirs.filter { seen.insert(Self.resolvedPath($0)).inserted }
    }

    // MARK: the effective model (the runtime's rule)

    /// The Parakeet versions the runtime knows (`ModelRegistry.knownParakeet`, in its order) and the files
    /// FluidAudio's `AsrModels.modelsExist(at:version:)` requires for each (int8 encoder = Encoder.mlmodelc).
    /// Pinned to FluidAudio by `RhemionASRTests/ParakeetPresenceParityTests` (this target can't link it).
    public static let parakeetModels: [(id: String, folder: String, required: [String])] = [
        ("parakeet-v3", "parakeet-tdt-0.6b-v3",
         ["Preprocessor.mlmodelc", "Encoder.mlmodelc", "Decoder.mlmodelc", "JointDecisionv3.mlmodelc", "parakeet_vocab.json"]),
        ("parakeet-v2", "parakeet-tdt-0.6b-v2",
         ["Preprocessor.mlmodelc", "Encoder.mlmodelc", "Decoder.mlmodelc", "JointDecision.mlmodelc", "parakeet_vocab.json"]),
    ]
    static let defaultModelID = "parakeet-v3"

    /// The whisper models the runtime discovers (`ModelRegistry.discover`): the built-in folder, then the
    /// extra folders, names sorted; a `.bin` that isn't a silence model and is a readable regular file
    /// (symlinks followed); the first file per id wins.
    func discoveredWhisper() -> [(id: String, file: URL)] {
        let fm = FileManager.default
        var seen = Set<String>(), out: [(id: String, file: URL)] = []
        for dir in [whisperDir] + extraModelDirs {
            for name in ((try? fm.contentsOfDirectory(atPath: dir.path)) ?? []).sorted()
            where name.lowercased().hasSuffix(".bin") && !Self.isSilenceModel(name) {
                let id = Self.whisperID(forFile: name), file = dir.appendingPathComponent(name)
                var isDir: ObjCBool = false
                guard !seen.contains(id), fm.fileExists(atPath: file.path, isDirectory: &isDir), !isDir.boolValue,
                      fm.isReadableFile(atPath: file.path) else { continue }
                seen.insert(id); out.append((id, file))
            }
        }
        return out
    }

    /// The model dictation actually runs on — `ModelRegistry.startupID` / the runtime's `resolveModelID`:
    /// the trimmed setting if its files are present, else Parakeet V3 if present, else the first present
    /// model (Parakeet V3, V2, then whisper in search order), else Parakeet V3.
    public var effectiveModel: String {
        let fm = FileManager.default
        let parakeet = Self.parakeetModels.filter { p in
            p.required.allSatisfy { fm.fileExists(atPath: fluidModelsRoot.appendingPathComponent(p.folder).appendingPathComponent($0).path) }
        }.map(\.id)
        let present = parakeet + discoveredWhisper().map(\.id)
        let desired = selectedModel.trimmingCharacters(in: .whitespacesAndNewlines)
        if present.contains(desired) { return desired }
        if present.contains(Self.defaultModelID) { return Self.defaultModelID }
        return present.first ?? Self.defaultModelID
    }

    /// Every model artifact split into the effective model's ("in use") and the rest ("unused").
    /// Fail-safe: the artifacts of the trimmed SETTING's model are kept too whenever they exist (even when
    /// incomplete, so not effective) — should app and runtime ever disagree on the effective model, nothing
    /// the user selected or the runtime may run is listed as unused.
    /// In use = the paths the runtime would load, by PHYSICAL identity (resolved paths): Parakeet — the
    /// version's folder; Whisper — the discovered .bin + its Core ML encoder (next to the path the runtime
    /// passes and next to the real file, should the .bin be a symlink) + every silence model. Any artifact
    /// that resolves to (or into, or around) a kept path is in use too — a symlink, a folder listed twice,
    /// an extra folder that is the built-in one. Each entry appears once. Extra folders' items keep the
    /// `externalModels` category.
    public func modelItems() -> (inUse: [StorageItem], unused: [StorageItem]) {
        let effective = effectiveModel
        let selected = selectedModel.trimmingCharacters(in: .whitespacesAndNewlines)
        // The silence model goes with Whisper: in use when Whisper is effective, or selected and on disk.
        var whisperSelected = effective.hasPrefix("whisper-")
        var keep: [String] = []
        let whisper = discoveredWhisper()
        for id in Set([effective, selected]) where !id.isEmpty {
            if let folder = Self.parakeetFolder(forModel: id) {
                keep.append(Self.resolvedPath(fluidModelsRoot.appendingPathComponent(folder)))
            }
            // Any .bin with this id in the search path (not only the discovered one): a setting's file
            // that isn't usable right now is still the user's choice.
            var files = whisper.filter { $0.id == id }.map(\.file)
            if id.hasPrefix("whisper-") {
                for dir in [whisperDir] + extraModelDirs {
                    for name in ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? [])
                    where name.lowercased().hasSuffix(".bin") && Self.whisperID(forFile: name) == id {
                        files.append(dir.appendingPathComponent(name))
                    }
                }
            }
            if id.hasPrefix("whisper-") && !files.isEmpty { whisperSelected = true }
            for file in files {
                let real = URL(fileURLWithPath: Self.resolvedPath(file))
                keep.append(real.path)
                for bin in [file, real] {
                    if let encoder = Self.whisperEncoderName(forModel: bin.lastPathComponent) {
                        keep.append(Self.resolvedPath(bin.deletingLastPathComponent().appendingPathComponent(encoder)))
                    }
                }
            }
        }
        func kept(_ path: String) -> Bool {
            keep.contains { path == $0 || path.hasPrefix($0 + "/") || $0.hasPrefix(path + "/") }
        }
        var inUse: [StorageItem] = [], unused: [StorageItem] = [], seen = Set<String>()
        let all = items(.models) + items(.externalModels)
        for item in all where seen.insert(Self.entryPath(item.url)).inserted {
            let name = item.relative.last ?? ""
            let silence = item.root != fluidModelsRoot && name.lowercased().hasSuffix(".bin") && Self.isSilenceModel(name)
            if kept(Self.resolvedPath(item.url)) || (whisperSelected && silence) { inUse.append(item) } else { unused.append(item) }
        }
        return (inUse, unused)
    }

    /// Cache: temporary files, the app's and the runtime helper's caches, and stray atomic temps of the
    /// last-run markers. Never logs.
    public func cacheItems() -> [StorageItem] {
        let fm = FileManager.default
        func item(_ c: StorageCategory, _ root: URL, _ rel: [String]) -> StorageItem? {
            let i = StorageItem(category: c, root: root, relative: rel)
            return fm.fileExists(atPath: i.url.path) && isSafe(i) ? i : nil
        }
        let caches = home.appendingPathComponent("Library").appendingPathComponent("Caches")
        let strays = ((try? fm.contentsOfDirectory(atPath: stateDir.path)) ?? []).sorted().filter {
            ($0.hasPrefix(".history-retention-") || $0.hasPrefix(".export-last-run-")) && $0.hasSuffix(".tmp")
        }
        // Not the runtime helper's cache: it is CoreML's compiled speech model (see compiledModelItems), and
        // clearing it makes the next start prepare the model again (~30 s). It goes with the model instead.
        return items(.temporary)
            + [item(.applicationData, caches, [bundleID])].compactMap { $0 }
            + strays.compactMap { item(.applicationData, stateDir, [$0]) }
    }

    /// CoreML's compiled form of the speech model, cached for the runtime helper (named after the executable).
    /// Removed together with the model in use (a compiled copy of a deleted model is dead weight) and on
    /// uninstall (it is part of `.applicationData`); never by Cache.
    public func compiledModelItems() -> [StorageItem] {
        let i = StorageItem(category: .applicationData,
                            root: home.appendingPathComponent("Library").appendingPathComponent("Caches"),
                            relative: ["rhemion-runtime"])
        return FileManager.default.fileExists(atPath: i.url.path) && isSafe(i) ? [i] : []
    }

    /// Logs: Rhemion's own diagnostic logs — app.log, runtime.log and their rotated copies (`LogRotation`).
    /// Never the dictation logs (`log/dictate-*.jsonl` are the Journal). New ones start on the next write.
    public func logItems() -> [StorageItem] {
        LogRotation.files(in: stateDir).compactMap { name in
            let i = StorageItem(category: .applicationData, root: stateDir, relative: [name])
            return FileManager.default.fileExists(atPath: i.url.path) && isSafe(i) ? i : nil
        }
    }

    /// Settings: settings.json (+ its lock), the defaults domain's plist and the saved window state.
    public func settingsItems() -> [StorageItem] {
        let fm = FileManager.default
        func item(_ root: URL, _ rel: [String]) -> StorageItem? {
            let i = StorageItem(category: .applicationData, root: root, relative: rel)
            return fm.fileExists(atPath: i.url.path) && isSafe(i) ? i : nil
        }
        let lib = home.appendingPathComponent("Library")
        return [item(stateDir, ["active", "settings.json"]), item(stateDir, ["active", "settings.json.lock"]),
                item(lib.appendingPathComponent("Preferences"), ["\(bundleID).plist"]),
                item(lib.appendingPathComponent("Saved Application State"), ["\(bundleID).savedState"])].compactMap { $0 }
    }
}
