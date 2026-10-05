import FluidAudio

public enum LanguagePolicy: Equatable, Sendable {
    case auto, russian, english

    public init(setting: String) {
        switch setting.lowercased() {
        case "ru": self = .russian
        case "en": self = .english
        default:   self = .auto          // "auto" and any unknown value
        }
    }

    /// FluidAudio language filter; nil = native multilingual decode.
    public var parakeet: Language? {
        switch self { case .auto: return nil; case .russian: return .russian; case .english: return .english }
    }

    /// whisper `-l` value.
    public var whisperFlag: String {
        switch self { case .auto: return "auto"; case .russian: return "ru"; case .english: return "en" }
    }
}
