import Darwin
import Foundation
import RhemionStorage

/// The app's isolated state directory — kept separate from the earlier versions' ~/.local/state/rhemion so
/// nothing the app or its runtime writes can collide with data from an earlier install.
enum AppPaths {
    /// Home from the password database, not the environment — the home for all app state
    /// paths (stateDir, dataDir, and the storage layout that Clear Data / Uninstall walk),
    /// so a spoofed $HOME can't redirect deletion.
    static var trustedHome: URL {
        guard let pw = getpwuid(getuid()), let dir = pw.pointee.pw_dir else { return FileManager.default.homeDirectoryForCurrentUser }
        return URL(fileURLWithPath: String(cString: dir), isDirectory: true)
    }

    /// Resolves the system temp directory through `realpath` (e.g. /var/folders/... on macOS), NOT
    /// `URL.resolvingSymlinksInPath()` — Foundation's resolver maps /private/var back to the /var
    /// symlink, which SafeRemover refuses to touch, so the Temporary storage category would never be
    /// cleaned. Shared by RuntimeSupervisor (RHEMION_TMP_DIR for the child runtime) and
    /// `storageLayout` (what gets deleted) so both name the exact same folder. Falls back to the
    /// unresolved path if `realpath` fails.
    static func resolvedTemporaryDirectory() -> URL {
        let path = FileManager.default.temporaryDirectory.path
        if let real = Darwin.realpath(path, nil) {
            defer { free(real) }
            return URL(fileURLWithPath: String(cString: real), isDirectory: true)
        }
        return URL(fileURLWithPath: path, isDirectory: true)
    }

    static var stateDir: URL {
        let home = trustedHome
        let v3 = home.appendingPathComponent(".local/state/rhemion-v3", isDirectory: true)
        // The RHEMION_RUNTIME_DIR override exists for tests/the supervisor, but must NEVER resolve to
        // the earlier versions' directory — writing settings/dictionary/log there would corrupt that install.
        // resolvingSymlinksInPath also standardizes (resolves ".."), so compare RESOLVED paths and
        // reject the legacy dir OR anything inside it — a symlinked or "../"-relative override can't
        // reach that directory.
        let legacy = home.appendingPathComponent(".local/state/rhemion", isDirectory: true).resolvingSymlinksInPath()
        if let override = ProcessInfo.processInfo.environment["RHEMION_RUNTIME_DIR"], !override.isEmpty {
            let url = URL(fileURLWithPath: override, isDirectory: true).resolvingSymlinksInPath()
            if url == legacy || url.path.hasPrefix(legacy.path + "/") { return v3 }
            return url
        }
        return v3
    }
    /// Where iCloud keeps its containers (iCloud Drive itself is `com~apple~CloudDocs` in here) — used
    /// only to NAME a folder the way Finder does (`FolderLocation`), never to store anything.
    static func iCloudContainersRoot(home: URL) -> URL {
        home.appendingPathComponent("Library/Mobile Documents", isDirectory: true)
    }
    static var logURL: URL { stateDir.appendingPathComponent("app.log") }
    /// Where dictation recordings + rendered history live — a normal macOS app data location
    /// (Application Support), NOT the hidden state dir and NEVER the Obsidian vault (the vault only
    /// ever receives transcript exports). Passed to the runtime as RHEMION_DATA_DIR.
    static var dataDir: URL {
        trustedHome
            .appendingPathComponent("Library/Application Support/Rhemion", isDirectory: true)
    }
    /// One-time move of history from the earlier location (`<stateDir>/data/history`) into `dataDir/history`.
    /// Lossless (see HistoryMigration); idempotent. Must run BEFORE the runtime starts.
    static func migrateDataDirIfNeeded() {
        let old = stateDir.appendingPathComponent("data/history", isDirectory: true)
        let new = dataDir.appendingPathComponent("history", isDirectory: true)
        do {
            let r = try HistoryMigration.migrate(old: old, new: new)
            if r.movedFiles > 0 || r.removedOld {
                log("history migration: moved \(r.movedFiles), renamed conflicts \(r.renamedConflicts), old removed \(r.removedOld)")
            }
        } catch { log("history migration failed: \(error)") }
    }

    /// THE ONE PLACE that maps `AppSettings` onto `StorageLayout` — everything Clear Data /
    /// Uninstall can touch. Names for `parakeetFolders` and `fluidModelsRoot` confirmed against
    /// FluidAudio's `AsrModels.defaultCacheDirectory(for:)` (Repo.parakeetV3/.parakeetV2 → folderName
    /// strips "-coreml" from the repo slug → "parakeet-tdt-0.6b-v3" / "parakeet-tdt-0.6b-v2", under
    /// `~/Library/Application Support/FluidAudio/Models`).
    static func storageLayout(settings: AppSettings) -> StorageLayout {
        let home = trustedHome
        return StorageLayout(
            home: home, stateDir: stateDir, dataDir: dataDir,
            tmpBase: resolvedTemporaryDirectory(),
            fluidModelsRoot: home.appendingPathComponent("Library/Application Support/FluidAudio/Models"),
            parakeetFolders: ["parakeet-tdt-0.6b-v3", "parakeet-tdt-0.6b-v2"],
            whisperDir: home.appendingPathComponent(".local/share/whisper"),
            extraModelDirs: extraModelDirs(settings.modelDirs),
            exportDir: validatedExportDir(settings.exportDir, home: home, stateDir: stateDir, dataDir: dataDir),
            bundleID: "com.sageathor.rhemion.app", selectedModel: settings.model)
    }

    /// The export folder under the SAME rule the runtime exports with (`ExportFolder.validate`): an
    /// empty, relative, symlinked or overlapping setting is no export folder at all (nil), so Storage
    /// never counts — and Clear Data/Uninstall never delete from — a folder the runtime would refuse.
    static func validatedExportDir(_ raw: String, home: URL, stateDir: URL, dataDir: URL) -> URL? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return try? ExportFolder.validate(trimmed, state: stateDir,
                                          history: dataDir.appendingPathComponent("history", isDirectory: true), home: home)
    }

    /// Settings stores model folders joined with ":" — the SAME rule the runtime uses
    /// (mirrors RhemionCore SettingsSnapshot.parseModelDirs), never ",": a folder name may contain a comma. After "~"
    /// expansion only absolute paths survive — a relative leftover would resolve against the current
    /// working directory and point Clear Data / Uninstall at a folder the user never added.
    static func extraModelDirs(_ raw: String) -> [URL] {
        raw.split(separator: ":").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
            .map { ($0 as NSString).expandingTildeInPath }
            .filter { $0.hasPrefix("/") }
            .map { URL(fileURLWithPath: $0, isDirectory: true) }
    }

    /// `RHEMION_UNINSTALL_DRYRUN=1` swaps every destructive/system effect for `DryRunEffects` (which
    /// only logs), so the uninstall UI's preview and tests never run the real ones.
    static func makeEffects() -> SystemEffects {
        ProcessInfo.processInfo.environment["RHEMION_UNINSTALL_DRYRUN"] == "1" ? DryRunEffects() : AppEffects()
    }
}
