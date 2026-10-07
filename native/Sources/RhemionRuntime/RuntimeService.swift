import FluidAudio
import Foundation
import RhemionASR
import RhemionCore
import RhemionIPC

public protocol LineSink: Sendable {
    func send(_ line: String)
}

/// Hook for driving audio capture from session lifecycle events. RuntimeService only depends
/// on this thin protocol (implemented by a CaptureController-backed adapter in the composition
/// root), so it stays testable with a spy and does not hard-depend on the audio stack.
public protocol TakeSink: Sendable {
    func begin(session: String, pressedAt: Double)
    /// Ends the take and returns the finalized take's WAV URL, if any (nil when capture is
    /// disabled). Must return synchronously so RuntimeService can snapshot the URL on the
    /// actor at stop-time, before any later `begin` can overwrite what "the last take" means.
    @discardableResult
    func end(session: String) -> URL?
    /// Stops a take without making its partial audio available for transcription.
    func cancel(session: String)
}

public extension TakeSink {
    func cancel(session: String) { _ = end(session: session) }
}

public actor RuntimeService {
    public typealias ModelDownloader = @Sendable (AsrModelVersion, @escaping ProgressHandler) async throws -> URL

    /// FluidAudio's download. `replace()` true re-downloads files already on disk (a damaged model) instead
    /// of keeping them.
    public static func fluidDownloader(replace: @escaping @Sendable () -> Bool) -> ModelDownloader {
        { version, progress in try await AsrModels.download(force: replace(), version: version, progressHandler: progress) }
    }

    private let modelDownloader: ModelDownloader
    private var modelDownloadTask: Task<Void, Never>?
    private let coordinator: SessionCoordinator
    private let metrics: Metrics
    private let takeSink: TakeSink?
    /// Optional async transcript producer, given the just-ended session's id and the WAV URL
    /// snapshotted synchronously at stop-time (see `handle`). Injected so RuntimeService stays
    /// testable with a spy and does not hard-depend on the audio/ASR stack; the composition
    /// root wires a real one backed by Transcriber.
    private let transcriptProducer: (@Sendable (_ session: String, _ wav: URL) async -> TranscriptResult?)?
    /// Optional delivery pipeline, given the just-produced session id and raw transcript text.
    /// Returns the `DeliveryOutcome` (clean/enhanced/shouldDeliver), or nil when the pipeline
    /// itself is absent. Closure-injected so RuntimeService stays free of any RhemionDelivery
    /// import, same pattern as `transcriptProducer`; the composition root wires a real one
    /// backed by DeliveryPipeline + DictionaryStore.
    private let deliveryPipeline: (@Sendable (_ session: String, _ rawText: String) async -> DeliveryOutcome?)?
    /// Optional history sink, appended to AFTER the `.deliver` emit, still inside the detached
    /// transcription/delivery Task, so it never delays the paste. Nil in tests that don't care.
    private let history: HistorySink?
    private let contextProvider: (@Sendable (_ targetPid: Int?) -> HistoryApplication?)?
    /// Enumerates the pickable models + microphones for a `.listDevices` request. Injected (not called
    /// directly) so RuntimeService stays free of the ASR/CoreAudio stacks and remains unit-testable.
    private let devicesProvider: (@Sendable () -> (models: [ModelOption], mics: [MicOption]))?
    private let now: @Sendable () -> Double
    /// How long the detached delivery task waits for the client's `deliver-result` ack before
    /// finalizing the history row as not-delivered (`no-ack`). Injectable so tests can drive both
    /// the ack path (short values) and the timeout path deterministically; the round trip in
    /// practice is well under a second (a paste is ~100ms), so 5s is a generous safety ceiling.
    private let deliveryResultTimeout: Double
    /// The current session's reply sink, set on `.start` and cleared on `.stop`. Gates
    /// `emitLevel` so level events only ever reach a client while a session is actually active
    /// (never before start / after stop).
    private var activeReply: LineSink?
    private var activeCreatedAt: Date?
    private var activeApplication: HistoryApplication?
    /// The frontmost-app pid the client bound to the active session at `.start`, echoed back in
    /// that session's `.deliver` so the client inserts into the app that was focused when the
    /// dictation began -- not whatever is focused when the async transcript lands.
    private var activeTargetPid: Int?
    /// Delivery-result continuations, keyed by session: the detached delivery task parks here
    /// after emitting `.deliver`, and the matching `deliver-result` command (or the timeout)
    /// resumes it exactly once. No pre-registration buffer is needed: the delivery task registers
    /// its waiter synchronously (no actor-releasing suspension between emitting `.deliver` and the
    /// `withCheckedContinuation` below), and a valid ack causally follows that `.deliver` (the
    /// client must receive it and paste first) -- so an ack can never arrive before its waiter.
    /// An ack with no waiter is therefore a late/duplicate/unsolicited one and is dropped.
    private var deliveryWaiters: [String: CheckedContinuation<String?, Never>] = [:]

    public init(
        coordinator: SessionCoordinator,
        metrics: Metrics,
        takeSink: TakeSink? = nil,
        transcriptProducer: (@Sendable (_ session: String, _ wav: URL) async -> TranscriptResult?)? = nil,
        deliveryPipeline: (@Sendable (_ session: String, _ rawText: String) async -> DeliveryOutcome?)? = nil,
        history: HistorySink? = nil,
        contextProvider: (@Sendable (_ targetPid: Int?) -> HistoryApplication?)? = nil,
        devicesProvider: (@Sendable () -> (models: [ModelOption], mics: [MicOption]))? = nil,
        modelDownloader: @escaping ModelDownloader = { version, progress in
            try await AsrModels.download(version: version, progressHandler: progress)
        },
        deliveryResultTimeout: Double = 5.0,
        now: @escaping @Sendable () -> Double = { Double(DispatchTime.now().uptimeNanoseconds) / 1_000_000_000 }
    ) {
        self.modelDownloader = modelDownloader
        self.coordinator = coordinator
        self.metrics = metrics
        self.takeSink = takeSink
        self.transcriptProducer = transcriptProducer
        self.deliveryPipeline = deliveryPipeline
        self.history = history
        self.contextProvider = contextProvider
        self.devicesProvider = devicesProvider
        self.deliveryResultTimeout = deliveryResultTimeout
        self.now = now
    }

    public func handle(line: String, reply: LineSink) async {
        var buffer = Data((line.hasSuffix("\n") ? line : line + "\n").utf8)
        let commands = IPCCodec.decodeCommands(from: &buffer)
        for command in commands {
            switch command {
            case .start(let pressedAt, let targetPid):
                metrics.record("start_received", session: nil)
                switch await coordinator.start() {
                case .started(let id):
                    metrics.record("session_started", session: id.raw)
                    activeReply = reply
                    activeCreatedAt = Date()
                    // Resolve the app from the SAME target pid the client captured at press (the app
                    // the text is inserted into), not the runtime's own frontmost query: this is a
                    // non-GUI helper whose NSWorkspace frontmost tracking is unreliable and races the
                    // IPC hop (it mislabeled e.g. the ChatGPT desktop app as "Google Chrome").
                    activeApplication = contextProvider?(targetPid)
                    activeTargetPid = targetPid
                    emit(.started(session: id.raw), to: reply)
                    // pressedAt from the client (real hotkey-press time, client clock) when
                    // present, else the server's own receipt time. The two clocks are not
                    // directly comparable across processes -- both are recorded below rather
                    // than reconciled; deriving the true end-to-end number is a downstream
                    // measurement concern, not handled here.
                    if let pressedAt {
                        metrics.record("client_pressed_at=\(pressedAt)", session: id.raw)
                    }
                    takeSink?.begin(session: id.raw, pressedAt: pressedAt ?? now())
                case .rejected(let reason):
                    emit(.error(message: reason), to: reply)
                }
            case .stop:
                metrics.record("stop_received", session: nil)
                switch await coordinator.stop() {
                case .stopped(let id):
                    activeReply = nil
                    emit(.stopped(session: id.raw), to: reply)
                    // Snapshot the take's WAV URL synchronously, on the actor, right here --
                    // before returning control. A fast subsequent start+stop must not be able
                    // to overwrite what "this session's take" resolves to by the time the
                    // detached transcription Task below actually runs.
                    let wav = takeSink?.end(session: id.raw)
                    // The WAV's creation date is the take identity timestamp used by its month/stem.
                    // Falling back to the start snapshot only matters for injected/non-file sinks.
                    let createdAt = (try? wav?.resourceValues(forKeys: [.creationDateKey]).creationDate)
                        ?? activeCreatedAt ?? Date()
                    let application = activeApplication
                    let targetPid = activeTargetPid
                    activeCreatedAt = nil
                    activeApplication = nil
                    activeTargetPid = nil
                    if let transcriptProducer, let wav {
                        // Detached: transcription must not block the actor (or this handle
                        // call) from processing further commands. The transcript event still
                        // lands on the same reply sink once it's ready.
                        Task {
                            // Whether we emitted a `.deliver` at all (gates the terminal `.canceled`
                            // below). The TRUTH of whether it landed comes separately from the
                            // client's ack, recorded into the history row.
                            var emittedDeliver = false
                            if let result = await transcriptProducer(id.raw, wav) {
                                // Log the ASR time so a cold reload (e.g. the OS evicted the model
                                // after idle) is visible as a large transcript_ms vs the warm ~100ms.
                                self.metrics.record("transcript_ms=\(Int(result.milliseconds)) engine=\(result.engineID)", session: id.raw)
                                await self.emit(
                                    .transcript(engine: result.engineID, ms: result.milliseconds, text: result.text),
                                    to: reply
                                )
                                if let deliveryPipeline, let outcome = await deliveryPipeline(id.raw, result.text) {
                                    let finalText = outcome.shouldDeliver ? (outcome.enhanced ?? outcome.clean) : nil
                                    // Computed once and reused for both the .deliver emit's `original`
                                    // and the history row's `preDictionary` below, so the hotkey undo
                                    // and `rhemion history last --pre-dictionary` always agree: when
                                    // enhancement rewrote the delivered text, both decline to offer the
                                    // pre-dictionary text as an undo target.
                                    let original = undoOriginal(
                                        clean: outcome.clean,
                                        enhanced: outcome.enhanced,
                                        preDictionary: outcome.preDictionary
                                    )
                                    // The truthful outcome of the insertion. `none`/not-delivered
                                    // until either the client's ack says otherwise or (no text to
                                    // deliver) it stays not-delivered.
                                    var delivered = false
                                    var deliveryMethod = "none"
                                    var deliveryError: String? = nil
                                    if let finalText, !finalText.isEmpty {
                                        await self.emit(.deliver(session: id.raw, text: finalText, original: original, targetPid: targetPid), to: reply)
                                        emittedDeliver = true
                                        // Park until the client reports how the insert landed (or a
                                        // timeout), so history records the truth rather than assuming
                                        // success at emit time. Awaiting here delays only the history
                                        // write, never the paste (already emitted above).
                                        let ackStatus = await self.awaitDeliveryResult(session: id.raw)
                                        (delivered, deliveryMethod, deliveryError) = Self.classifyDeliveryResult(ackStatus)
                                    }
                                    // Record history AFTER the deliver emit + ack, so recording never delays the paste.
                                    if let history = self.history {
                                        let stem = wav.deletingPathExtension().lastPathComponent
                                        let entryID = stem.components(separatedBy: "--").last ?? stem
                                        let audioDurationMS = (try? WAVReader.readInt16Mono16k(wav).count)
                                            .map { Int((Double($0) / 16_000 * 1_000).rounded()) }
                                        let rec = HistoryEntry(
                                            id: entryID,
                                            createdAt: createdAt,
                                            sessionID: id.raw,
                                            engine: result.engineID,
                                            audioDurationMS: audioDurationMS,
                                            processingDurationMS: Int(result.milliseconds.rounded()),
                                            raw: result.text,
                                            clean: outcome.clean,
                                            enhanced: outcome.enhanced,
                                            delivered: delivered,
                                            deliveryMethod: deliveryMethod,
                                            deliveryError: deliveryError,
                                            application: application,
                                            audio: wav.lastPathComponent,
                                            preDictionary: original
                                        )
                                        await history.append(rec)
                                    }
                                }
                            }
                            // No `.deliver` was emitted at all (an empty/silent take dropped by the
                            // gate, or post-processing emptied it): tell the client so the notch
                            // indicator retracts. A gated take resolves fast (within the indicator's
                            // grace, so no spinner); a recognized-but-suppressed take resolves after
                            // ASR. (A `.deliver` that was emitted but failed to land is NOT canceled
                            // here -- the client already resolves its own indicator from the paste
                            // result; canceled is only for "there was nothing to deliver".)
                            if !emittedDeliver {
                                await self.emit(.canceled(session: id.raw), to: reply)
                            }
                        }
                    } else {
                        // No transcription path (no producer / no take WAV): still give the client a
                        // terminal event so the indicator retracts immediately instead of waiting out
                        // its safety timeout.
                        emit(.canceled(session: id.raw), to: reply)
                    }
                case .rejected(let reason):
                    emit(.error(message: reason), to: reply)
                }
            case .cancel:
                metrics.record("cancel_received", session: nil)
                // Abort the active take without delivering. Mirror `.stop`'s session teardown, but
                // hand the take to `cancel` (discards the partial audio, never exposes its WAV) and
                // start NO transcription/delivery Task — so no `.deliver`, no history row, and the
                // recall log is untouched (a canceled recording must not become "the last dictation").
                switch await coordinator.stop() {
                case .stopped(let id):
                    activeReply = nil
                    takeSink?.cancel(session: id.raw)
                    activeCreatedAt = nil
                    activeApplication = nil
                    activeTargetPid = nil
                    emit(.canceled(session: id.raw), to: reply)
                case .rejected:
                    // Nothing is recording (a race: the take already ended). Stay silent — the
                    // client only sends `.cancel` when it believes a recording is in progress, and
                    // there is no session to report a terminal event for.
                    break
                }
            case .deliverResult(let session, let status):
                // The client reporting how a `.deliver` landed. Hand it to the parked delivery
                // task (or buffer it if that task hasn't registered its waiter yet). Produces no
                // event back to the client.
                metrics.record("deliver_result=\(status)", session: session)
                resolveDeliveryResult(session: session, status: status)
            case .historyDelete(let ids):
                guard let store = history as? HistoryStore else {
                    emit(.historyDeleted(ids: ids, removedIDs: [], error: "History is unavailable."), to: reply)
                    continue
                }
                let results = await store.deleteEntries(ids: Set(ids))
                let removed = results.flatMap(\.removedIDs)
                let error = Set(ids).subtracting(removed).isEmpty ? nil
                    : "Some entries could not be deleted or were already missing. The journal has been refreshed."
                emit(.historyDeleted(ids: ids, removedIDs: removed, error: error), to: reply)
            case .exportNow:
                guard let store = history as? HistoryStore else {
                    emit(.exportCompleted(months: [], error: "History is unavailable."), to: reply)
                    continue
                }
                do {
                    let outcome = try await store.exportNowReporting()
                    emit(.exportCompleted(months: outcome.months, error: nil, skipped: outcome.skipped), to: reply)
                }
                catch { emit(.exportCompleted(months: [], error: error.localizedDescription), to: reply) }
            case .ping:
                emit(.pong, to: reply)
            case .downloadModel(let id):
                startModelDownload(id: id, reply: reply)
            case .cancelModelDownload:
                modelDownloadTask?.cancel()
            case .listDevices:
                // Answer from the runtime's own enumeration (the same source that actually selects the
                // engine/device), so the app's pickers never drift from selection reality. Fast +
                // low-frequency (a user opening Settings), so running it on the actor is fine.
                let devices = devicesProvider?() ?? (models: [], mics: [])
                emit(.devices(models: devices.models, mics: devices.mics), to: reply)
            }
        }
    }

    private func startModelDownload(id: String, reply: LineSink) {
        guard let version = ModelRegistry.parakeetVersion(id: id) else {
            emit(.modelDownload(id: id, state: "failed", fraction: nil,
                                error: "unknown or non-downloadable model"), to: reply)
            return
        }
        // Keep the slot occupied until cancellation has unwound the downloader, too.
        guard modelDownloadTask == nil else { return }
        modelDownloadTask = Task {
            // Bridge FluidAudio's synchronous callback to one ordered actor consumer. Bound the
            // buffer so a burst cannot accumulate work, and drain it before the terminal event.
            let (progress, continuation) = AsyncStream<Double>.makeStream(bufferingPolicy: .bufferingNewest(1))
            let progressTask = Task {
                var last: (time: Double, fraction: Double)?
                for await fraction in progress {
                    guard self.modelDownloadTask?.isCancelled == false, fraction.isFinite else { continue }
                    let time = self.now()
                    if let last, time - last.time < 0.15 || abs(fraction - last.fraction) < 0.005 { continue }
                    last = (time, fraction)
                    self.emit(.modelDownload(id: id, state: "downloading", fraction: fraction, error: nil), to: reply)
                }
            }
            let terminal: Event
            do {
                try Task.checkCancellation()
                _ = try await self.modelDownloader(version) { continuation.yield($0.fractionCompleted) }
                try Task.checkCancellation()
                terminal = .modelDownload(id: id, state: "done", fraction: 1.0, error: nil)
            } catch {
                if Task.isCancelled || error is CancellationError {
                    terminal = .modelDownload(id: id, state: "canceled", fraction: nil, error: nil)
                } else {
                    terminal = .modelDownload(id: id, state: "failed", fraction: nil, error: error.localizedDescription)
                }
            }
            continuation.finish()
            await progressTask.value
            // Cancellation may arrive while the final progress callback is draining.
            if Task.isCancelled {
                self.emit(.modelDownload(id: id, state: "canceled", fraction: nil, error: nil), to: reply)
            } else {
                self.emit(terminal, to: reply)
            }
            self.modelDownloadTask = nil
        }
    }

    /// Park the detached delivery task until the client's `deliver-result` ack for `session`
    /// arrives (returning its status word) or `deliveryResultTimeout` elapses (returning nil).
    /// The waiter is installed synchronously here; see `deliveryWaiters` for why no early-ack
    /// buffer is required.
    private func awaitDeliveryResult(session: String) async -> String? {
        await withCheckedContinuation { (continuation: CheckedContinuation<String?, Never>) in
            deliveryWaiters[session] = continuation
            let timeout = deliveryResultTimeout
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(max(0, timeout) * 1_000_000_000))
                await self?.timeoutDeliveryResult(session: session)
            }
        }
    }

    /// Resume the waiter for `session` with the client's reported status, exactly once. An ack
    /// with no registered waiter is a late (post-timeout), duplicate, or unsolicited one and is
    /// dropped -- the history row for that session is already finalized.
    private func resolveDeliveryResult(session: String, status: String) {
        if let continuation = deliveryWaiters.removeValue(forKey: session) {
            continuation.resume(returning: status)
        }
    }

    /// Fire on the timeout: if the waiter is still parked (no ack arrived), resume it with nil so
    /// history finalizes as not-delivered. A no-op if the ack already resumed it.
    private func timeoutDeliveryResult(session: String) {
        if let continuation = deliveryWaiters.removeValue(forKey: session) {
            continuation.resume(returning: nil)
        }
    }

    /// Map the client's delivery status word to the truthful history fields. Success words (across
    /// AX insert, synthetic typing, and clipboard paste) mean the text landed; `paste-ambiguous`
    /// likely landed but is flagged; anything else -- and a nil (no ack within the timeout) --
    /// means it did not land, with the status carried as the error for the history row.
    static func classifyDeliveryResult(_ status: String?) -> (delivered: Bool, method: String, error: String?) {
        guard let status else { return (false, "none", "no-ack") }
        switch status {
        case "inserted-verified", "submitted-unverified": return (true, "ax", nil)
        case "typed-submitted":                            return (true, "typed", nil)
        case "paste-submitted":                            return (true, "paste", nil)
        case "paste-ambiguous":                            return (true, "paste", "paste-ambiguous")
        default:                                           return (false, "none", status)
        }
    }

    private func emit(_ event: Event, to reply: LineSink) {
        if let line = try? IPCCodec.encode(event) { reply.send(line) }
    }

    /// Emits a `.level` event to the active session's reply sink, if a session is active
    /// (between `.start` and `.stop`); a no-op while idle. Called from the capture pipeline's
    /// throttled level tap via `Task { await service.emitLevel(rms) }`, hopping from the
    /// capture serial queue onto this actor.
    public func emitLevel(_ rms: Double) {
        guard let activeReply else { return }
        emit(.level(rms: rms), to: activeReply)
    }

    /// Terminates the logical session after capture fails asynchronously (for example, when
    /// the active microphone disappears). CaptureCoordinator has already canceled the audio
    /// take, so this only closes the session and tells the client not to expect a transcript.
    public func captureFailed(message: String) async {
        guard let reply = activeReply else { return }
        guard case .stopped = await coordinator.stop() else { return }
        activeReply = nil
        activeCreatedAt = nil
        activeApplication = nil
        activeTargetPid = nil
        emit(.error(message: message), to: reply)
    }

    /// True while a dictation is active (between `.start` and `.stop`). The keep-warm heartbeat
    /// checks this so its throwaway inference never queues ahead of real audio on the engine's
    /// serial actor.
    public func isRecording() -> Bool { activeReply != nil }
}
