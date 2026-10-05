import Foundation

public struct SettingsSnapshot: Equatable, Sendable {
    /// The default recognition model id. Kept here (a plain string) so low-level RhemionCore stays
    /// free of an ASR dependency; the authoritative registry that maps ids to engines/paths and
    /// validates them lives in RhemionASR (`ModelRegistry`). An empty `model` falls back to this;
    /// an unknown-but-nonempty value is passed through and resolved (and normalized) by the registry.
    public static let defaultModel = "parakeet-v3"

    public let audioMicrophone: String
    public let dataDir: String?
    /// Legacy fixed-unit retention (days for audio, months for transcripts). Still parsed for
    /// back-compat with settings files from earlier versions; the UI writes the value+unit fields below instead.
    public let historyAudioRetentionDays: Int
    public let historyRetentionMonths: Int
    /// Export mode: "auto" (after each dictation), "manual" (button only), "scheduled" (interval),
    /// "off" (no export at all — the app also hides the journal's export chip + button).
    public let exportMode: String
    /// Interval for `exportMode == "scheduled"`: "hourly" | "daily" | "weekly".
    public let exportSchedule: String
    /// Journal auto-cleanup, each a number + unit ("days" | "weeks" | "months"); 0 = keep forever.
    /// Audio expiry deletes only the local WAV (the transcript stays); transcript expiry deletes the
    /// whole entry (record + its audio + its line in the exported note).
    public let audioRetentionValue: Int
    public let audioRetentionUnit: String
    public let transcriptRetentionValue: Int
    public let transcriptRetentionUnit: String
    /// Active recognition model id (e.g. "parakeet-v3"); a name from ModelRegistry. Never empty.
    public let model: String
    /// Recognition language preference (e.g. "auto", "ru", "en"); defaults to "auto" when absent.
    /// Kept as a plain string here so RhemionCore stays free of ASR dependencies; the authoritative
    /// mapper (LanguagePolicy) lives in RhemionASR.
    public let language: String
    /// Advanced override: path to the shared `whisper-cli` binary. Nil = use the built-in default.
    public let whisperBinary: String?
    /// Extra directories to scan for models, in addition to the built-in defaults. Lets the user
    /// reuse whisper models already downloaded elsewhere instead of duplicating them. Parsed from a
    /// ":"-separated `model_dirs` string (PATH-style); empty entries dropped.
    public let modelDirs: [String]

    public init(audioMicrophone: String = "auto", dataDir: String? = nil,
                historyAudioRetentionDays: Int = 0, historyRetentionMonths: Int = 0,
                exportMode: String = "off", exportSchedule: String = "daily",
                audioRetentionValue: Int = 0, audioRetentionUnit: String = "days",
                transcriptRetentionValue: Int = 0, transcriptRetentionUnit: String = "months",
                model: String = SettingsSnapshot.defaultModel, whisperBinary: String? = nil,
                modelDirs: [String] = [], language: String = "auto") {
        let value = audioMicrophone.trimmingCharacters(in: .whitespacesAndNewlines)
        self.audioMicrophone = value.isEmpty ? "auto" : value
        let data = dataDir?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.dataDir = data?.isEmpty == false ? data : nil
        self.historyAudioRetentionDays = max(0, historyAudioRetentionDays)
        self.historyRetentionMonths = max(0, historyRetentionMonths)
        self.exportMode = ["auto", "manual", "scheduled", "off"].contains(exportMode) ? exportMode : "off"
        self.exportSchedule = ["hourly", "daily", "weekly"].contains(exportSchedule) ? exportSchedule : "daily"
        self.audioRetentionValue = max(0, audioRetentionValue)
        self.audioRetentionUnit = Self.retentionUnits.contains(audioRetentionUnit) ? audioRetentionUnit : "days"
        self.transcriptRetentionValue = max(0, transcriptRetentionValue)
        self.transcriptRetentionUnit = Self.retentionUnits.contains(transcriptRetentionUnit) ? transcriptRetentionUnit : "months"
        let m = model.trimmingCharacters(in: .whitespacesAndNewlines)
        self.model = m.isEmpty ? SettingsSnapshot.defaultModel : m
        self.whisperBinary = SettingsSnapshot.trimmedOrNil(whisperBinary)
        self.modelDirs = modelDirs.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        let lang = language.trimmingCharacters(in: .whitespacesAndNewlines)
        self.language = lang.isEmpty ? "auto" : lang
    }

    public static let retentionUnits = ["days", "weeks", "months"]

    /// Seconds between scheduled exports, or nil when the mode is not "scheduled".
    public var exportScheduleSeconds: Double? {
        guard exportMode == "scheduled" else { return nil }
        switch exportSchedule {
        case "hourly": return 3600
        case "weekly": return 604_800
        default:       return 86_400   // daily
        }
    }

    /// The instant before which local audio expires (nil = keep forever). Only the WAV is removed.
    public func audioRetentionCutoff(from now: Date, calendar: Calendar = .current) -> Date? {
        Self.cutoff(value: audioRetentionValue, unit: audioRetentionUnit, from: now, calendar: calendar)
    }

    /// The instant before which whole entries (record + audio + exported line) expire (nil = keep forever).
    public func transcriptRetentionCutoff(from now: Date, calendar: Calendar = .current) -> Date? {
        Self.cutoff(value: transcriptRetentionValue, unit: transcriptRetentionUnit, from: now, calendar: calendar)
    }

    static func cutoff(value: Int, unit: String, from now: Date, calendar: Calendar) -> Date? {
        guard value > 0 else { return nil }
        switch unit {
        case "weeks":  return calendar.date(byAdding: .day, value: -value * 7, to: now)
        case "months": return calendar.date(byAdding: .month, value: -value, to: now)
        default:       return calendar.date(byAdding: .day, value: -value, to: now)   // days
        }
    }

    /// Split a ":"-separated `model_dirs` value into directories (empty entries dropped).
    public static func parseModelDirs(_ value: String?) -> [String] {
        (value ?? "").split(separator: ":").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
    }

    private static func trimmedOrNil(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else { return nil }
        return trimmed
    }

    public static func load(from url: URL? = nil) -> SettingsSnapshot {
        let url = url ?? RuntimePaths.stateDirectory().appendingPathComponent("active/settings.json")
        guard let data = try? Data(contentsOf: url),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return SettingsSnapshot() }
        return SettingsSnapshot(
            audioMicrophone: object["audio_microphone"] as? String ?? "auto",
            dataDir: object["data_dir"] as? String,
            historyAudioRetentionDays: object["history_audio_retention_days"] as? Int ?? 0,
            historyRetentionMonths: object["history_retention_months"] as? Int ?? 0,
            exportMode: object["export_mode"] as? String ?? "off",
            exportSchedule: object["export_schedule"] as? String ?? "daily",
            audioRetentionValue: object["history_audio_retention_value"] as? Int ?? 0,
            audioRetentionUnit: object["history_audio_retention_unit"] as? String ?? "days",
            transcriptRetentionValue: object["history_transcript_retention_value"] as? Int ?? 0,
            transcriptRetentionUnit: object["history_transcript_retention_unit"] as? String ?? "months",
            model: object["model"] as? String ?? SettingsSnapshot.defaultModel,
            whisperBinary: object["whisper_binary"] as? String,
            modelDirs: SettingsSnapshot.parseModelDirs(object["model_dirs"] as? String),
            language: object["language"] as? String ?? "auto"
        )
    }
}
