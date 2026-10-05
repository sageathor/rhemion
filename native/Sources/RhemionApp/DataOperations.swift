// DataOperations — the `quiesce` barrier every destructive storage action (export, history
// delete, clear data, export deletion, uninstall) starts with: block new input, discard an active
// take without inserting text, cancel a model download in flight, drop late runtime events, stop the
// runtime and WAIT for it. `resume()` lifts the blocks and brings the runtime back for recovery or
// after a completed operation.

import Foundation

enum QuiesceOutcome: Equatable { case ready, stuck }

/// The barrier every destructive storage action starts with: block new input, discard an
/// active take, cancel a model download, drop late runtime events, stop the runtime and WAIT for it.
/// Observable so the Storage section can disable its buttons while an operation holds the barrier.
@MainActor
final class DataOperations: ObservableObject {
    private unowned let app: AppController
    init(app: AppController) { self.app = app }

    /// Up from `quiesce()` until `resume()`. Deliberately stays up after a real failed settings reset/Uninstall
    /// (the app may be half-removed; the only way out is restart/quit) and after `.stuck`.
    @Published private(set) var inProgress = false {
        didSet {
            DictionaryStore.writesSuppressed.value = inProgress   // no dictionary.json writes mid-operation
            AppLog.hygienePaused.value = inProgress               // no log rotation mid-operation
        }
    }
    var isRecording: Bool { app.isDictatingNow }
    /// The result of the last `quiesce()` call, if any. `.stuck` means the runtime (or a child) survived
    /// SIGKILL — `resume()` refuses while this stands, so nothing starts a second runtime over a live one.
    private(set) var lastOutcome: QuiesceOutcome?

    /// Enter the quiesced state. Blocks (`inProgress`) go up FIRST, so nothing racing in on the main
    /// actor after this call can start a new take, deliver a late transcript, or re-arm hotkeys — then
    /// the in-flight take/download are torn down and the runtime is stopped and awaited.
    func quiesce() async -> QuiesceOutcome {
        inProgress = true
        app.hotkey?.abortRecording()          // no onStop fires; nothing gets inserted for this take
        app.clearRecordingFlag()              // abortRecording() alone leaves isDictatingNow stuck true
        app.client?.send(.cancel)             // tell the runtime (if still up) to discard the take too
        if case .downloading = app.modelDownload.phase {
            app.client?.send(.cancelModelDownload)
            // Poll for the download to actually stop (its terminal event is async), up to ~3s, rather
            // than tearing down the socket out from under an in-flight download.
            for _ in 0..<60 {
                if case .downloading = app.modelDownload.phase { try? await Task.sleep(for: .milliseconds(50)) }
                else { break }
            }
            if case .downloading = app.modelDownload.phase {
                log("quiesce: model-download cancel timed out after ~3s, still downloading")
            }
        }
        app.client?.disconnect()              // stop reconnecting + drop the socket: no more events can arrive
        let stopped = await app.supervisor.stopAndWait()
        let outcome: QuiesceOutcome = stopped ? .ready : .stuck
        lastOutcome = outcome
        return outcome                        // on .stuck: keep inProgress = true (no input, no 2nd runtime)
    }

    /// Recovery / after a completed operation: lift the blocks and bring the runtime back. Refuses when
    /// the last `quiesce()` left the runtime `.stuck` — starting a fresh runtime over one that never
    /// actually died would give the app two runtimes racing on the same socket/data dir.
    func resume() {
        guard lastOutcome != .stuck else {
            log("resume refused: runtime stuck")
            return
        }
        app.supervisor.start()
        app.client?.connect()
        inProgress = false
    }
}
