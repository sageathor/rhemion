// Settings — the app owns the config. There is no source note: the app reads and writes the
// snapshot directly. That snapshot is the single store — `$RHEMION_RUNTIME_DIR/active/settings.json`
// (default: ~/.local/state/rhemion-v3/active/settings.json) — the SAME file the runtime reads via
// SettingsSnapshot.load() for model/language/microphone. Flat snake_case keys, so the runtime reads
// them unchanged.
//
// The UI edits a subset (PTT key, input method, language); the rest are carried with sane defaults so
// the file stays a complete, valid snapshot. Unknown keys already in the file are preserved on save.
// `data_dir` is deliberately NOT written: the history location is fixed by the supervisor's
// RHEMION_DATA_DIR env, which wins over any snapshot value (RuntimePaths.dataDirectory).

import Foundation
import AppKit

struct AppSettings: Equatable, Sendable {
    // Recognition — the runtime reads these (SettingsSnapshot). Only `language` is in the UI so far.
    var model: String = "parakeet-v3"
    var language: String = "auto"                 // auto | ru | en                      (UI)
    var audioMicrophone: String = "auto"
    var whisperBinary: String = ""                // empty = the runtime looks for Homebrew's whisper-cli
    var modelDirs: String = ""
    var historyAudioRetentionDays: Int = 0
    var historyRetentionMonths: Int = 0

    // Export starts off with no folder: the user turns it on in Settings › Journal and picks the folder then.
    var exportDir: String = ""
    var indicatorStyle: String = "auto"            // auto | notch | floating  (recording indicator)  (UI)
    var exportMode: String = "off"                 // auto | manual | scheduled | off     (UI)
    var exportSchedule: String = "daily"           // hourly | daily | weekly             (UI, scheduled only)
    var theme: String = "system"
    var exportInitialized: Bool = false
    // Journal auto-cleanup (UI: stepper + unit). 0 = keep forever. Audio expiry removes only the WAV;
    // transcript expiry removes the whole entry (record + audio + exported line).
    var audioRetentionValue: Int = 0
    var audioRetentionUnit: String = "days"        // days | weeks | months
    var transcriptRetentionValue: Int = 0
    var transcriptRetentionUnit: String = "months" // days | weeks | months

    @MainActor func applyAppearance() {
        NSApp.appearance = theme == "light" ? NSAppearance(named: .aqua)
            : theme == "dark" ? NSAppearance(named: .darkAqua) : nil
    }

    // General — the app applies these.
    // Start Rhemion at login (SMAppService). Default on, so a fresh install registers itself.
    var launchAtLogin: Bool = true                 //                                      (UI)
    var pttKeys: [String] = ["right_cmd"]         // one or more pttKeyOptions (any engages PTT)  (UI)
    // Default is Right Command.
    var inputMethod: String = "direct"            // direct | clipboard                   (UI)
    // Cmd+Option+R by default.
    var recallHotkeys: [String] = ["cmd+option+r"]     // recall chords, any fires (UI: recorder rows)
    // Cmd+Option+W by default.
    var dictAddHotkeys: [String] = ["cmd+option+w"]    // dict-add chords, any fires (UI: recorder rows)
    // Cmd+Option+Shift+L by default.
    var undoHotkeys: [String] = ["cmd+option+shift+l"] // undo-replace chords, any fires (UI: recorder rows)
    // How long the last delivered take stays reversible — governs BOTH undo-replace and double-Esc
    // delete (they share one armed record). Labeled "Reversal window" in the UI.
    var undoTTLSecs: Int = 8                       // (UI: stepper)
    // Double-tap Esc = cancel a recording in progress, or erase the just-delivered take. This is the
    // max gap (milliseconds) between the two Esc presses; a lone Esc always passes through.
    var escDoubleTapMS: Int = 350                  // (UI: stepper)

    // Hands-free silence auto-stop (UI: steppers). Ring appears after N s of silence, then an M s
    // countdown; auto-stop at N+M.
    var handsfreeCountdownAfterSecs: Int = 30
    var handsfreeCountdownSecs: Int = 10

    // Allowed sets (also the UI option lists).
    static let languageOptions     = ["auto", "ru", "en"]
    static let inputMethodOptions  = ["direct", "clipboard"]
    static let pttKeyOptions       = ["right_option", "left_option", "right_cmd", "left_cmd",
                                      "right_control", "left_control", "right_shift", "left_shift", "fn"]
    static let exportModeOptions   = ["auto", "manual", "scheduled", "off"]
    static let exportScheduleOptions = ["hourly", "daily", "weekly"]
    static let retentionUnitOptions  = ["days", "weeks", "months"]
}

/// Reads and writes the settings snapshot. Never throws on read (last-known-good file → built-in
/// defaults). Writes atomically, owner-only.
enum SettingsStore {
    static let didChange = Notification.Name("RhemionSettingsDidChange")
    static var url: URL { AppPaths.stateDir.appendingPathComponent("active/settings.json", isDirectory: false) }

    /// `url` is injectable so tests use a private file instead of mutating the process-wide RHEMION_RUNTIME_DIR.
    static func load(from url: URL = SettingsStore.url) -> AppSettings {
        let object = (try? Data(contentsOf: url))
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
        var s = AppSettings()
        s.exportDir = ((object["export_dir"] as? String ?? s.exportDir) as NSString).expandingTildeInPath
        s.exportMode = oneof(object["export_mode"], s.exportMode, AppSettings.exportModeOptions)
        s.exportSchedule = oneof(object["export_schedule"], s.exportSchedule, AppSettings.exportScheduleOptions)
        s.theme = oneof(object["theme"], s.theme, ["system", "light", "dark"])
        s.indicatorStyle = oneof(object["indicator_style"], s.indicatorStyle, ["auto", "notch", "floating"])
        s.exportInitialized = object["export_initialized"] as? Bool ?? false
        s.audioRetentionValue      = num(object["history_audio_retention_value"], s.audioRetentionValue)
        s.audioRetentionUnit       = oneof(object["history_audio_retention_unit"], s.audioRetentionUnit, AppSettings.retentionUnitOptions)
        s.transcriptRetentionValue = num(object["history_transcript_retention_value"], s.transcriptRetentionValue)
        s.transcriptRetentionUnit  = oneof(object["history_transcript_retention_unit"], s.transcriptRetentionUnit, AppSettings.retentionUnitOptions)
        s.model                     = str(object["model"], s.model)
        s.language                  = oneof(object["language"], s.language, AppSettings.languageOptions)
        s.audioMicrophone           = str(object["audio_microphone"], s.audioMicrophone)
        s.whisperBinary             = str(object["whisper_binary"], s.whisperBinary)
        s.modelDirs                 = str(object["model_dirs"], s.modelDirs)
        s.historyAudioRetentionDays = num(object["history_audio_retention_days"], s.historyAudioRetentionDays)
        s.historyRetentionMonths    = num(object["history_retention_months"], s.historyRetentionMonths)
        s.launchAtLogin             = bool(object["general_launch_at_login"], s.launchAtLogin)
        s.pttKeys                   = keyList(object["general_ptt_keys"], object["general_ptt_key"], s.pttKeys, AppSettings.pttKeyOptions)
        s.inputMethod               = oneof(object["general_input_method"], s.inputMethod, AppSettings.inputMethodOptions)
        s.recallHotkeys             = specList(object["general_recall_hotkeys"], object["general_recall_hotkey"], s.recallHotkeys)
        s.dictAddHotkeys            = specList(object["general_dict_add_hotkeys"], object["general_dict_add_hotkey"], s.dictAddHotkeys)
        s.undoHotkeys               = specList(object["general_undo_replace_hotkeys"], object["general_undo_replace_hotkey"], s.undoHotkeys)
        s.undoTTLSecs               = num(object["undo_ttl_secs"], s.undoTTLSecs)
        s.escDoubleTapMS            = num(object["general_esc_double_tap_ms"], s.escDoubleTapMS)
        s.handsfreeCountdownAfterSecs = num(object["handsfree_countdown_after_secs"], s.handsfreeCountdownAfterSecs)
        s.handsfreeCountdownSecs      = num(object["handsfree_countdown_secs"], s.handsfreeCountdownSecs)
        return s
    }

    /// Merge the typed keys over whatever is already on disk (preserving unknown keys), then write
    /// atomically with 0600. Returns false only if the write itself failed.
    @discardableResult
    static func save(_ s: AppSettings, to url: URL = SettingsStore.url) -> Bool {
        // Coordinate the read/merge/write with the runtime's migration flag update.
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        let lock = open(url.path + ".lock", O_CREAT | O_RDWR, 0o600)
        guard lock >= 0 else { return false }
        defer { close(lock) }
        guard flock(lock, LOCK_EX) == 0 else { return false }
        defer { flock(lock, LOCK_UN) }
        var object = (try? Data(contentsOf: url))
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
        // The runtime owns the migration flag. A stale Settings window must not reset it. But when NO
        // settings.json existed yet (e.g. Reset just deleted it), there's no on-disk folder to compare
        // against — trust the caller's value instead of forcing false.
        let savedFolder = (object["export_dir"] as? String).map { ($0 as NSString).expandingTildeInPath }
        let sameFolder = savedFolder == (s.exportDir as NSString).expandingTildeInPath
        let oldInitialized = object["export_initialized"] as? Bool ?? false
        object["export_initialized"] = savedFolder == nil ? s.exportInitialized : (sameFolder ? (oldInitialized || s.exportInitialized) : false)
        object["export_dir"] = (s.exportDir as NSString).expandingTildeInPath
        object["export_mode"] = s.exportMode
        object["export_schedule"] = s.exportSchedule
        object["theme"] = s.theme
        object["indicator_style"] = s.indicatorStyle
        object["history_audio_retention_value"]      = s.audioRetentionValue
        object["history_audio_retention_unit"]       = s.audioRetentionUnit
        object["history_transcript_retention_value"] = s.transcriptRetentionValue
        object["history_transcript_retention_unit"]  = s.transcriptRetentionUnit
        object["model"]                        = s.model
        object["language"]                     = s.language
        object["audio_microphone"]             = s.audioMicrophone
        object["whisper_binary"]               = s.whisperBinary
        object["model_dirs"]                   = s.modelDirs
        object["history_audio_retention_days"] = s.historyAudioRetentionDays
        object["history_retention_months"]     = s.historyRetentionMonths
        object["general_launch_at_login"]      = s.launchAtLogin
        object["general_ptt_keys"]             = s.pttKeys
        object["general_ptt_key"]              = s.pttKeys.first ?? "right_option"   // legacy mirror (downgrade safety)
        object["general_input_method"]         = s.inputMethod
        object["general_recall_hotkeys"]       = s.recallHotkeys
        object["general_dict_add_hotkeys"]     = s.dictAddHotkeys
        object["general_undo_replace_hotkeys"] = s.undoHotkeys
        // Legacy single-string mirrors so a downgrade to a pre-multi-binding build still reads a hotkey.
        object["general_recall_hotkey"]        = s.recallHotkeys.first ?? "off"
        object["general_dict_add_hotkey"]      = s.dictAddHotkeys.first ?? "off"
        object["general_undo_replace_hotkey"]  = s.undoHotkeys.first ?? "off"
        object["undo_ttl_secs"]                = s.undoTTLSecs
        object["general_esc_double_tap_ms"]    = s.escDoubleTapMS
        object["handsfree_countdown_after_secs"] = s.handsfreeCountdownAfterSecs
        object["handsfree_countdown_secs"]     = s.handsfreeCountdownSecs

        let directory = url.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        guard let data = try? JSONSerialization.data(withJSONObject: object,
                                                     options: [.prettyPrinted, .sortedKeys]) else { return false }
        do {
            // .atomic writes to a sibling temp and renames it onto `url` in a single step: the runtime
            // (SettingsSnapshot.load) never sees a missing or half-written file, and a failed write
            // leaves the previous snapshot intact. umask(0o077) makes the new file 0600; re-assert it.
            try data.write(to: url, options: .atomic)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            NotificationCenter.default.post(name: Self.didChange, object: nil)
            return true
        } catch {
            return false
        }
    }

    /// Materialize new keys as well as a missing file, so the runtime always has a
    /// complete snapshot to read. Called once at launch.
    static func ensureExists() {
        save(load())
    }

    // Coercion — anything unexpected falls back, never crashes.
    private static func str(_ v: Any?, _ fallback: String) -> String {
        if let s = v as? String, !s.isEmpty { return s }
        return fallback
    }
    private static func oneof(_ v: Any?, _ fallback: String, _ allowed: [String]) -> String {
        if let s = v as? String, allowed.contains(s) { return s }
        return fallback
    }
    private static func bool(_ v: Any?, _ fallback: Bool) -> Bool {
        if let b = v as? Bool { return b }
        return fallback
    }
    private static func num(_ v: Any?, _ fallback: Int) -> Int {
        if let n = v as? Int { return max(0, n) }
        // Int(d) traps on non-finite or out-of-range doubles (e.g. a JSON 1e100) — guard before casting.
        if let d = v as? Double { return (d.isFinite && d >= 0 && d <= 1_000_000_000) ? Int(d) : fallback }
        if let s = v as? String, let n = Int(s) { return max(0, n) }
        return fallback
    }
    // A list of allowed keys (PTT). Prefer the array key (filtered to `allowed`); if absent, migrate the
    // legacy single string; if neither is usable, the default. Only the app reads these keys.
    private static func keyList(_ arr: Any?, _ legacy: Any?, _ fallback: [String], _ allowed: [String]) -> [String] {
        if let a = arr as? [Any] {
            let items = a.compactMap { $0 as? String }.filter { allowed.contains($0) }
            if !items.isEmpty { return items }
        }
        if let s = legacy as? String, allowed.contains(s) { return [s] }
        return fallback
    }
    // A list of chord specs. The array key is authoritative when present (even holding "off" entries a
    // user disabled); otherwise migrate the legacy single string; otherwise the default.
    private static func specList(_ arr: Any?, _ legacy: Any?, _ fallback: [String]) -> [String] {
        if let a = arr as? [Any] {
            let items = a.compactMap { $0 as? String }
            if !items.isEmpty { return items }
        }
        if let s = legacy as? String, !s.isEmpty { return [s] }
        return fallback
    }
}
