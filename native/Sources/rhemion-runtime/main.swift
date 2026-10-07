import Foundation
import AppKit
import AVFoundation
import RhemionASR
import RhemionAudio
import RhemionCore
import RhemionDelivery
import RhemionIPC
import RhemionRuntime

// Privacy hardening: force an owner-only umask before anything is created, so every file the
// runtime writes (WAV audio takes, the dictate JSONL of transcripts, rendered history notes,
// snapshots) is 0600 and every directory 0700 by default -- not world-readable 0644/0755. Explicit
// per-file permissions below are defense-in-depth on top of this.
umask(0o077)

struct ConnectionSink: LineSink {
    let connection: UnixSocketConnection
    func send(_ line: String) { connection.send(line) }
}

func logToStderr(_ message: String) {
    FileHandle.standardError.write(Data("rhemion-runtime: \(message)\n".utf8))
}

let socketPath = RuntimePaths.stateDirectory().appendingPathComponent("runtime.sock").path
try RuntimePaths.ensureStateDirectory()

let metrics = Metrics.fromEnvironment()
let startupSettings = SettingsSnapshot.load()

// Startup reconcile + retention are wired below, after the shared `history` store exists, so every
// history mutation (live append, retention delete, audio expiry, reconcile) goes through ONE actor
// instance and can never race a parallel one. Both are fire-and-forget and never delay readiness.

// Composition root for capture: CaptureCoordinator owns enumeration, settings resolution and
// the warm AUHAL engine. This factory prepares one candidate and wires it through the conversion
// pipeline into a per-take WAV; the coordinator falls through to the next ranked candidate when
// preparation fails and runs without capture when none can be prepared.
// Routes the capture pipeline's converted samples to a throttled `.level` IPC event. `onLevel`
// is wired below, after `service` exists -- see the note on ThrottledLevelTap for why that
// ordering is safe (no capture take can begin before the runtime accepts its first connection).
let levelRouter = ThrottledLevelTap()

func makeCapture(for device: AudioDeviceInfo) throws -> TakeSink {
    let engine = AUHALCapture(deviceID: device.id)
    try engine.prepare()
    let pipeline = CapturePipeline(
        converter: AVAudioConverterAdapter(),
        ring: AudioRingBuffer(capacity: Int(AudioFormat.sampleRate) * 30),
        now: { Double(DispatchTime.now().uptimeNanoseconds) / 1_000_000_000 },
        levelTap: { samples in levelRouter.tap(samples) }
    )
    let controller = CaptureController(
        engine: engine,
        pipeline: pipeline,
        sinkFactory: WAVSinkFactory(),
        metrics: metrics
    )
    return CaptureControllerTakeSink(controller: controller)
}

let capture = CaptureCoordinator(
    listener: CoreAudioDeviceChangeListener(),
    deviceLossPolicy: .failTake,
    makeCapture: makeCapture,
    // Reading the status never prompts; preparing the input unit would. The app asks for access in its
    // Welcome window and restarts this runtime once it is granted.
    canCapture: { AVCaptureDevice.authorizationStatus(for: .audio) == .authorized },
    log: logToStderr
)

// Composition root for ASR: discover models at startup (whisper by scanning the search path;
// Parakeet from FluidAudio's shared cache) and register the PRESENT ones keyed by model id. Lives
// in makeModelRegistry(entries:snapshot:) so it is unit-tested -- an empty registry would make the
// runtime silently emit no transcript.
//
// MODEL SELECTION is live among REGISTERED models: RHEMION_ASR_MODEL pins one (debugging); otherwise
// the active model is the snapshot's `model`, re-read per take (see resolveModelID) so switching
// applies to the next dictation without a restart. A newly added dir/file (model_dirs) needs a
// restart to be discovered + registered.
let pinnedModelID = ProcessInfo.processInfo.environment["RHEMION_ASR_MODEL"]
let discoveredModels = ModelRegistry.discover(extraDirs: startupSettings.modelDirs)
let engineRegistry = makeModelRegistry(entries: discoveredModels, snapshot: startupSettings)
let startupModelID = ModelRegistry.startupID(desired: pinnedModelID ?? startupSettings.model, entries: discoveredModels)
let transcriber = Transcriber(registry: engineRegistry, defaultEngineID: startupModelID)

// Fresh-install / misconfig guard: if NO model is present, the runtime would otherwise start fine
// and only reveal the problem as a canceled take. Surface it loudly at startup instead.
if engineRegistry.ids.isEmpty {
    logToStderr("[model] WARNING: no recognition models found -- dictation will produce no transcript. "
        + "Run `rhemion models`; download parakeet-v3 (FluidAudio cache) or add a whisper model dir via `model_dirs`.")
} else {
    logToStderr("[model] startup model=\(startupModelID); registered=[\(engineRegistry.ids.sorted().joined(separator: ", "))]")
}
logToStderr("[lang] policy=\(LanguagePolicy(setting: startupSettings.language).whisperFlag)")

// The model to use for THIS take: the pinned env override, else the current snapshot's model
// (re-read from disk, matching how the mic setting hot-reloads) -- but only if it is a REGISTERED
// (present, startup-discovered) model; otherwise fall back to the startup model AND log it, so a
// typo'd/absent model id is visible in the log rather than silently ignored.
let resolveModelID: @Sendable () -> String = {
    let desired = pinnedModelID ?? SettingsSnapshot.load().model
    if engineRegistry.engine(id: desired) != nil { return desired }
    logToStderr("[model] requested '\(desired)' is not available; using '\(startupModelID)' (see `rhemion models`)")
    return startupModelID
}

// The language policy for THIS take: the current snapshot's language, re-read from disk each
// take (matching how the model selection above hot-reloads, so a language change applies to the
// next dictation without a restart).
let resolveLanguage: @Sendable () -> LanguagePolicy = {
    LanguagePolicy(setting: SettingsSnapshot.load().language)
}

// Warm the selected model at startup so the FIRST live dictation is instant. Parakeet's first
// call otherwise pays a ~20s cold model load+compile; since its actor serializes transcription,
// every dictation held during that window queues and then flushes in a burst (observed live).
// Only the startup model is warmed (whisper models shell out per take and need no keep-warm; a
// live switch to another parakeet model pays its cold load once on first use).
// Fire-and-forget at utility priority: the runtime starts listening immediately and the warm-up
// finishes in the background before the user's first real dictation completes.
// `startupWarm` tells the app (via the `.devices` report) when the startup model is ready, so it can show
// "Preparing speech model" instead of claiming ready while a first-time compile still runs.
final class WarmFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    var isSet: Bool { lock.lock(); defer { lock.unlock() }; return value }
    func set() { lock.lock(); value = true; lock.unlock() }
}
let startupWarm = WarmFlag()
let startupDamaged = WarmFlag()   // set when the startup model could not be prepared even after a retry
if let warmEngine = engineRegistry.engine(id: startupModelID) {
    Task.detached(priority: .utility) {
        let start = Date()
        var warmed = await warmEngine.prewarm()
        if !warmed {
            logToStderr("[model] prewarm(\(startupModelID)) failed; retrying once")
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            warmed = await warmEngine.prewarm()
        }
        // Never leave the app on "Preparing" forever. A model that cannot be prepared twice is reported as
        // damaged: the app says so and offers a fresh download, instead of showing Ready and failing later.
        if !warmed { startupDamaged.set() }
        startupWarm.set()
        logToStderr(warmed
            ? "[timing] prewarm(\(startupModelID)) done in \(String(format: "%.1f", Date().timeIntervalSince(start)))s"
            : "[model] prewarm(\(startupModelID)) failed twice; reported as damaged")
    }
} else {
    startupWarm.set()   // nothing to warm
}

// Transcript producer: runs the selected engine over the WAV URL RuntimeService snapshotted
// at stop-time (passed in, not re-read here) -- reading `captureController.lastTakeURL` late,
// from inside this closure, would race a fast subsequent start+stop overwriting it. Nil only
// when capture is unavailable -- then there is no take WAV to transcribe.
let transcriptProducer: (@Sendable (String, URL) async -> TranscriptResult?)? = { @Sendable _, wav in
        // Drop accidental taps / silent holds BEFORE the engine sees them: an empty press-release
        // otherwise makes Parakeet hallucinate garbage (random letters/digits) that then gets pasted.
        guard let samples = try? WAVReader.readInt16Mono16k(wav), AudioGate.worthTranscribing(samples) else {
            return nil
        }
        return await transcriber.run(wav: wav, engineID: resolveModelID(), language: resolveLanguage())
}

// Composition root for delivery: a hot-reloading dictionary store (the file need not exist
// yet -- DictionaryStore resolves to .empty until the app writes it) feeding a deterministic
// post-processing pipeline (Noop enhancer).
let dictStore = DictionaryStore(url: RuntimePaths.stateDirectory().appendingPathComponent("active/dictionary.json"))
let pipeline = DeliveryPipeline()
let deliveryPipeline: @Sendable (String, String) async -> DeliveryOutcome? = { _, raw in
    let delivered = await pipeline.run(raw: raw, dictionary: dictStore.current())
    return DeliveryOutcome(
        clean: delivered.clean,
        enhanced: delivered.enhanced,
        shouldDeliver: delivered.shouldDeliver,
        preDictionary: delivered.preDictionary
    )
}

// Machine history is appended per month; its human-readable monthly view is regenerated after delivery.
// No fixed directory: the store re-resolves the History root per commit, so it tracks a data_dir
// the settings snapshot may only gain after startup (the client may import it post-login).
let history = HistoryStore()

let service = RuntimeService(
    coordinator: SessionCoordinator(),
    metrics: metrics,
    takeSink: capture,
    transcriptProducer: transcriptProducer,
    deliveryPipeline: deliveryPipeline,
    history: history,
    contextProvider: { targetPid in
        // Prefer resolving the exact pid the client bound to this take (the app the text is
        // inserted into) via a direct LaunchServices lookup, which — unlike frontmostApplication —
        // does not depend on activation tracking that a non-GUI helper process cannot observe
        // reliably. Fall back to the frontmost app only when no pid was sent.
        let app = targetPid.flatMap { NSRunningApplication(processIdentifier: pid_t($0)) }
            ?? NSWorkspace.shared.frontmostApplication
        guard app?.localizedName != nil || app?.bundleIdentifier != nil else { return nil }
        return HistoryApplication(name: app?.localizedName, bundleID: app?.bundleIdentifier)
    },
    devicesProvider: {
        // The runtime's own view of what's pickable: models from the same discovery that builds the
        // engine registry, mics from the same CoreAudio enumeration the capture layer selects from —
        // so the app's Settings pickers can never list something selection wouldn't actually use.
        let snapshot = SettingsSnapshot.load()
        // Only the startup model is prewarmed; any other model counts as warm (it loads on first use).
        let models = ModelRegistry.discover(extraDirs: snapshot.modelDirs).map {
            ModelOption(id: $0.id, label: $0.label, engine: $0.engine, found: $0.found,
                        warm: $0.id != startupModelID || startupWarm.isSet,
                        damaged: $0.id == startupModelID && startupDamaged.isSet)
        }
        let mics = CoreAudioDeviceEnumerator.inputDevices().map {
            MicOption(uid: $0.uid, name: $0.name, builtIn: $0.isBuiltIn)
        }
        return (models: models, mics: mics)
    },
    modelDownloader: RuntimeService.fluidDownloader(replace: { startupDamaged.isSet })
)

// Dictation explicitly uses failTake (also the coordinator default). The retarget policy is
// reserved for a future call-recording take that can define how partial audio spans the gap.
capture.setDeviceLossHandler { message in
    Task { await service.captureFailed(message: message) }
}

// Now that `service` exists, wire the level router to emit through it. See ThrottledLevelTap's
// header: this assignment happens strictly before `server.start` below, so before any capture
// take (and so any call to `levelRouter.tap`) can occur.
levelRouter.onLevel = { rms in
    Task { await service.emitLevel(rms) }
}

// Keep-warm heartbeat: after the initial prewarm, periodically run one tiny silent inference while
// idle so the model and its compiled ANE program stay resident. This guards against a pause "after
// a while" if the OS evicts the model during a long idle -- the whole point of the tool is to hear
// instantly, every time, not just right after startup. Skipped while a dictation is active so it
// never queues ahead of real audio on the engine's serial actor. Utility priority; ~100ms warm.
// Warms the startup model (a Parakeet model by default): it is the one with a resident ANE program
// to keep hot; whisper models shell out per take and need no keep-warm, so a live switch is fine.
if let warmEngine = engineRegistry.engine(id: startupModelID) {
    Task.detached(priority: .utility) {
        while true {
            try? await Task.sleep(nanoseconds: 60_000_000_000)   // 60s
            if await service.isRecording() { continue }
            await warmEngine.prewarm()
        }
    }
}

// Startup reconcile + journal auto-cleanup (retention), on the shared `history` actor. Retention runs
// at most once per calendar day. Transcript expiry deletes whole entries older than the transcript
// cutoff via the normal deletion path (record + audio + exported note); audio expiry then removes only
// the WAV of retained takes older than the (separate) audio cutoff, keeping the transcript. Both knobs
// default to off (0 = keep forever), so this is a complete no-op unless the user opts in.
Task.detached(priority: .utility) {
    let stateDir = RuntimePaths.stateDirectory(), historyDir = RuntimePaths.historyDirectory()
    let startupMonth = HistoryStore.month(Date())
    if await history.reconcile(month: startupMonth) == nil {
        logToStderr("history startup reconcile failed for \(startupMonth)")
    }
    // Settings are re-read each pass, so enabling cleanup applies without a restart. Runs at most once
    // per calendar day, and ONLY when a knob is enabled — the day is never marked done while retention
    // is off, so enabling it later the same day still runs. Both delete and audio expiry go through the
    // shared `history` actor (serialized with live appends).
    while true {
        let s = SettingsSnapshot.load()
        let now = Date()
        let audioCutoff = s.audioRetentionCutoff(from: now)
        let transcriptCutoff = s.transcriptRetentionCutoff(from: now)
        if (audioCutoff != nil || transcriptCutoff != nil), HistoryRetention.shouldRunToday(stateDirectory: stateDir, now: now) {
            do {
                var deletedIDs = Set<String>()
                if let cutoff = transcriptCutoff {
                    deletedIDs = HistoryRetention.expiredTranscriptIDs(stateDirectory: stateDir, historyDirectory: historyDir, before: cutoff)
                    if !deletedIDs.isEmpty { _ = await history.deleteEntries(ids: deletedIDs) }
                }
                if let cutoff = audioCutoff {
                    _ = await history.expireAudio(before: cutoff, excludingIDs: deletedIDs)
                }
                try HistoryRetention.markRanToday(stateDirectory: stateDir, now: now)
            } catch { logToStderr("history retention failed: \(error)") }
        }
        try? await Task.sleep(nanoseconds: 3_600_000_000_000)   // re-check hourly
    }
}

// Scheduled export: while export mode is "scheduled", export the transcript notes on the chosen
// interval. A marker records the last run, so an interval that elapsed while the runtime was off
// exports on the first tick after startup ("missed run at next start"). Settings are re-read each
// tick, so switching mode/interval applies within one tick. A no-op in "auto"/"manual" mode.
Task.detached(priority: .utility) {
    let stateDir = RuntimePaths.stateDirectory()
    while true {
        let snapshot = SettingsSnapshot.load()
        if let interval = snapshot.exportScheduleSeconds {
            let last = ScheduledExport.lastRun(stateDirectory: stateDir)
            if last == nil || Date().timeIntervalSince(last!) >= interval {
                do { _ = try await history.exportNow(); try ScheduledExport.markRun(stateDirectory: stateDir, at: Date()) }
                catch { logToStderr("scheduled export failed: \(error)") }
            }
        }
        try? await Task.sleep(nanoseconds: 300_000_000_000)   // re-check every 5 min
    }
}

let server = UnixSocketServer(path: socketPath)

try server.start { line, connection in
    let sink = ConnectionSink(connection: connection)
    // M1 assumes one command per line and a request-response client (one command at a
    // time per connection); pipelined clients could observe reordered events across
    // detached Tasks — revisit at the delivery milestone.
    Task { await service.handle(line: line, reply: sink) }
}

// Leave with the app. If Rhemion dies without stopping us (SIGTERM skips applicationWillTerminate, a
// crash, kill -9), a runtime left behind would share the state folder and socket with the next app's
// runtime. Watch the parent and exit as soon as it is gone. Exit WITHOUT server.stop(): by then the next
// runtime may already own runtime.sock, and stop() would unlink it; the next start replaces a stale one.
let parentPid = getppid()
let parentWatch: DispatchSourceProcess? = parentPid > 1
    ? DispatchSource.makeProcessSource(identifier: parentPid, eventMask: .exit, queue: .global()) : nil
parentWatch?.setEventHandler {
    FileHandle.standardError.write(Data("rhemion-runtime: parent \(parentPid) exited; exiting\n".utf8))
    exit(0)
}
parentWatch?.resume()
if parentPid > 1, kill(parentPid, 0) != 0 { exit(0) }   // the parent died before the watch was armed

FileHandle.standardError.write(Data("rhemion-runtime listening on \(socketPath)\n".utf8))
dispatchMain()
