import Foundation

public enum Command: Equatable, Sendable {
    /// `pressedAt` is the client's own monotonic seconds at hotkey press, sent as `"ts"` in the
    /// wire message. `nil` when the client omits it (back-compat with `{"cmd":"start"}`) or sends
    /// a non-numeric value; callers fall back to the server's own clock in that case.
    ///
    /// `targetPid` is the pid of the frontmost application at the moment the client captured the
    /// hotkey press (sent as `"target_pid"`). It binds the delivery target to THIS session so a
    /// later, overlapping dictation cannot redirect this take's text to a different app: the
    /// runtime echoes it back in the matching `.deliver` event. `nil` when the client omits it or
    /// sends a non-integer value (back-compat / no frontmost app).
    case start(pressedAt: Double?, targetPid: Int?)
    case stop
    /// Abort the active take WITHOUT delivering: the runtime stops capture, discards the partial
    /// audio (no transcription), writes no history row, and emits `.canceled`. Unlike `.stop`, the
    /// take never becomes "the last dictation" — so a canceled recording can't leak into recall or
    /// be re-inserted. Sent by the client's double-Esc gesture while a recording is in progress.
    case cancel
    /// Exact history IDs; an additive command used by the journal only.
    case historyDelete(ids: [String])
    case exportNow
    case ping
    /// The client's report of how a `.deliver` actually landed, keyed by the session it answers.
    /// `status` is the delivery status word the client's delivery layer produced (e.g.
    /// `paste-submitted`, `inserted-verified`, `target-changed`, `error`). The runtime maps it to
    /// the truthful `delivered`/`deliveryMethod`/`deliveryError` history fields instead of
    /// recording delivery eagerly at emit time.
    case deliverResult(session: String, status: String)
    /// Ask the runtime for the pickable recognition models and input microphones it currently sees,
    /// answered by a single `.devices` event. Additive; used by the app's Settings › Audio & model
    /// pickers so the list is the runtime's own view (the same enumeration that actually selects the
    /// engine/device), never a second app-side scan that could drift out of sync.
    case listDevices
    case downloadModel(id: String)
    case cancelModelDownload
}

/// A recognition model the picker can offer — the display subset of RhemionASR's ModelEntry, carried
/// over IPC so the app needn't link the ASR stack.
public struct ModelOption: Equatable, Sendable {
    public let id: String       // the value written to the `model` setting, e.g. "parakeet-v3"
    public let label: String    // human name for the row
    public let engine: String   // "parakeet" | "whisper"
    public let found: Bool      // present on disk right now (usable without a download)
    /// Loaded and compiled, ready for an instant first dictation. A freshly downloaded (or cache-cleared)
    /// model is found but not warm while the runtime prepares it, which can take tens of seconds.
    public let warm: Bool
    public init(id: String, label: String, engine: String, found: Bool, warm: Bool = true) {
        self.id = id; self.label = label; self.engine = engine; self.found = found; self.warm = warm
    }
}

/// An input device the picker can offer — the display subset of RhemionAudio's AudioDeviceInfo.
public struct MicOption: Equatable, Sendable {
    public let uid: String      // the value written to the `audio_microphone` setting
    public let name: String     // human name for the row
    public let builtIn: Bool    // the Mac's built-in mic (labeled as such)
    public init(uid: String, name: String, builtIn: Bool) {
        self.uid = uid; self.name = name; self.builtIn = builtIn
    }
}

public enum Event: Equatable, Sendable {
    case started(session: String)
    case stopped(session: String)
    case transcript(engine: String, ms: Double, text: String)
    /// `original` is the "as spoken" text before the dictionary substitution that produced
    /// `text`, present only when a real dictionary replacement occurred (used by the client
    /// to offer in-place undo). `nil` when there is nothing to undo.
    ///
    /// `targetPid` echoes the pid the client bound to this session at `.start` (see
    /// `Command.start`). The client inserts into THIS pid rather than whatever app is frontmost
    /// when the (asynchronous) transcript finally lands, so an overlapping later dictation can
    /// never receive this take's text. `nil` when the client sent no pid.
    case deliver(session: String, text: String, original: String?, targetPid: Int?)
    case error(message: String)
    /// The take produced nothing to deliver (dropped by the audio gate as an empty/silent tap, or
    /// post-processing emptied it). Lets the indicator retract without ever showing a spinner.
    case canceled(session: String)
    /// One terminal response across all months, including empty/partial results.
    case historyDeleted(ids: [String], removedIDs: [String], error: String?)
    /// `skipped`: month notes NOT written because a same-named file exists that Rhemion didn't write
    /// (spec 4.5 — surfaced in the export status). Omitted from the wire when empty.
    case exportCompleted(months: [String], error: String?, skipped: [String] = [])
    case pong
    /// Normalized 0...1 mic loudness, emitted throttled while a session is active. Powers the
    /// notch indicator's audio meter and hands-free silence-stop.
    case level(rms: Double)
    /// The runtime's answer to `.listDevices`: the models and microphones it currently sees.
    case devices(models: [ModelOption], mics: [MicOption])
    case modelDownload(id: String, state: String, fraction: Double?, error: String?)
}

public enum IPCError: Error {
    case malformedLine
    case encodeFailed
}
