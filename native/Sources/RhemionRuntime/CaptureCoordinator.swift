import CoreAudio
import Foundation
import RhemionAudio
import RhemionCore

/// Observes changes which can affect input-device resolution. The callback may arrive on any
/// thread; CaptureCoordinator always moves it onto its private serial queue.
public protocol AudioDeviceChangeListening: AnyObject {
    func start(_ onChange: @escaping @Sendable () -> Void)
    func stop()
}

/// CoreAudio listener for input topology and system-default changes.
public final class CoreAudioDeviceChangeListener: AudioDeviceChangeListening, @unchecked Sendable {
    private let listenerQueue = DispatchQueue(label: "RhemionRuntime.CoreAudioDeviceChangeListener")
    private var block: AudioObjectPropertyListenerBlock?

    public init() {}

    public func start(_ onChange: @escaping @Sendable () -> Void) {
        guard block == nil else { return }
        let newBlock: AudioObjectPropertyListenerBlock = { _, _ in onChange() }
        block = newBlock
        for selector in [kAudioHardwarePropertyDevices, kAudioHardwarePropertyDefaultInputDevice] {
            var address = AudioObjectPropertyAddress(
                mSelector: selector,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            AudioObjectAddPropertyListenerBlock(
                AudioObjectID(kAudioObjectSystemObject), &address, listenerQueue, newBlock
            )
        }
    }

    public func stop() {
        guard let block else { return }
        for selector in [kAudioHardwarePropertyDevices, kAudioHardwarePropertyDefaultInputDevice] {
            var address = AudioObjectPropertyAddress(
                mSelector: selector,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            AudioObjectRemovePropertyListenerBlock(
                AudioObjectID(kAudioObjectSystemObject), &address, listenerQueue, block
            )
        }
        self.block = nil
    }

    deinit { stop() }
}

/// Owns the warm capture engine and all input-device resolution. All state and all calls into
/// a CaptureController-backed TakeSink are confined to one serial queue, so a CoreAudio callback
/// cannot replace an engine while its ring buffer/pipeline is recording.
public final class CaptureCoordinator: TakeSink, @unchecked Sendable {
    public typealias CaptureFactory = (AudioDeviceInfo) throws -> TakeSink

    public enum DeviceLossPolicy: Sendable {
        /// Dictation policy: discard the partial take and surface a terminal failure.
        case failTake
        /// Call-recording groundwork: keep the take open and retarget its live capture engine.
        /// The future consumer owns gap semantics and partial-audio stitching.
        case retarget
    }

    public protocol LiveRetargetingTakeSink: TakeSink {
        func retarget(to device: AudioDeviceInfo) throws
    }

    private let queue = DispatchQueue(label: "RhemionRuntime.CaptureCoordinator")
    private let settings: () -> SettingsSnapshot
    private let devices: () -> [AudioDeviceInfo]
    private let systemDefaultID: () -> UInt32?
    private let makeCapture: CaptureFactory
    private let listener: AudioDeviceChangeListening?
    private let log: (String) -> Void
    private let deviceLossPolicy: DeviceLossPolicy

    private var capture: TakeSink?
    private var device: AudioDeviceInfo?
    private var active = false
    private var selectionDirty = true
    private var lastRejectedLog: [String] = []
    /// Whether the microphone may be touched yet. Preparing an input unit makes macOS ask for microphone
    /// access, so nothing is prepared until access is granted (the app asks in its Welcome window).
    private let canCapture: () -> Bool
    private var loggedDeferred = false   // the rejections last logged; logged again only when they change
    private var activeSession: String?
    private var deviceLossHandler: (@Sendable (String) -> Void)?

    public init(
        settings: @escaping () -> SettingsSnapshot = { SettingsSnapshot.load() },
        devices: @escaping () -> [AudioDeviceInfo] = { CoreAudioDeviceEnumerator.inputDevices() },
        systemDefaultID: @escaping () -> UInt32? = { CoreAudioDeviceEnumerator.systemDefaultInputID() },
        listener: AudioDeviceChangeListening? = nil,
        deviceLossPolicy: DeviceLossPolicy = .failTake,
        makeCapture: @escaping CaptureFactory,
        canCapture: @escaping () -> Bool = { true },
        log: @escaping (String) -> Void = { _ in }
    ) {
        self.settings = settings
        self.devices = devices
        self.systemDefaultID = systemDefaultID
        self.listener = listener
        self.deviceLossPolicy = deviceLossPolicy
        self.makeCapture = makeCapture
        self.canCapture = canCapture
        self.log = log

        queue.sync { resolveIfNeeded(force: true) }
        listener?.start { [weak self] in self?.deviceSelectionChanged() }
    }

    deinit { listener?.stop() }

    public func setDeviceLossHandler(_ handler: @escaping @Sendable (String) -> Void) {
        queue.sync { deviceLossHandler = handler }
    }

    /// Re-resolves unconditionally before every take, making settings edits effective on the
    /// next dictation. The already-prepared capture is retained when its device id still wins.
    public func begin(session: String, pressedAt: Double) {
        queue.sync {
            guard !active else { return }
            resolveIfNeeded(force: true)
            active = true
            activeSession = session
            capture?.begin(session: session, pressedAt: pressedAt)
        }
    }

    public func end(session: String) -> URL? {
        queue.sync {
            guard active else { return nil }
            let url = capture?.end(session: session)
            active = false
            activeSession = nil
            if selectionDirty { resolveIfNeeded(force: true) }
            return url
        }
    }

    /// Abort the active take, discarding its partial audio (the underlying sink's `cancel` finalizes
    /// the pipeline but never exposes the WAV for transcription). Mirrors `end`'s teardown but returns
    /// nothing — used by the runtime's `.cancel` command. A no-op when no take is active.
    public func cancel(session: String) {
        queue.sync {
            guard active else { return }
            capture?.cancel(session: session)
            active = false
            activeSession = nil
            if selectionDirty { resolveIfNeeded(force: true) }
        }
    }

    private func deviceSelectionChanged() {
        queue.async { [weak self] in
            guard let self else { return }
            selectionDirty = true
            guard active else {
                resolveIfNeeded(force: true)
                return
            }

            let allDevices = devices()
            guard let current = device,
                  !allDevices.contains(where: { $0.id == current.id }) else { return }
            handleDeviceLoss(current: current, availableDevices: allDevices)
        }
    }

    private func handleDeviceLoss(current: AudioDeviceInfo, availableDevices: [AudioDeviceInfo]) {
        let message = "capture device disconnected: \(current.name) (\(current.uid))"
        log(message)

        switch deviceLossPolicy {
        case .failTake:
            if let session = activeSession { capture?.cancel(session: session) }
            active = false
            activeSession = nil
            deviceLossHandler?(message)
            // Do not build another engine on the failure callback path. The next begin performs
            // the normal Stage-2 resolution and preparation before starting a fresh dictation.
        case .retarget:
            let configured = settings().audioMicrophone
            let mode: InputMode = configured == "auto" ? .auto : .specific(uid: configured, modelUID: nil)
            let candidates = AudioDeviceSelector.rank(
                mode: mode, devices: availableDevices, systemDefaultID: systemDefaultID()
            )
            guard let target = candidates.first,
                  let retargetable = capture as? LiveRetargetingTakeSink else {
                if let session = activeSession { capture?.cancel(session: session) }
                active = false
                activeSession = nil
                deviceLossHandler?(message)
                return
            }
            do {
                try retargetable.retarget(to: target)
                device = target
                selectionDirty = false
                log("retargeted live capture to \(target.uid) (\(target.name))")
            } catch {
                if let session = activeSession { capture?.cancel(session: session) }
                active = false
                activeSession = nil
                deviceLossHandler?("\(message); retarget failed: \(error)")
            }
        }
    }

    private func resolveIfNeeded(force: Bool) {
        guard force || selectionDirty else { return }
        selectionDirty = false
        guard canCapture() else {
            capture = nil
            device = nil
            selectionDirty = true
            if !loggedDeferred { log("microphone access not granted yet; capture deferred"); loggedDeferred = true }
            return
        }
        loggedDeferred = false
        let allDevices = devices()
        let configured = settings().audioMicrophone
        let mode: InputMode = configured == "auto" ? .auto : .specific(uid: configured, modelUID: nil)
        let candidates = AudioDeviceSelector.rank(
            mode: mode, devices: allDevices, systemDefaultID: systemDefaultID()
        )

        // Selection runs before every take; log the skipped devices only when that list changes.
        let rejectedLines = allDevices.filter { mode == .auto && !$0.isAutoEligible }.map {
            "rejected capture device \($0.uid) (\($0.name)): \($0.exclusionReason ?? "not auto-eligible")"
        }
        if rejectedLines != lastRejectedLog {
            lastRejectedLog = rejectedLines
            rejectedLines.forEach { log($0) }
        }

        if let first = candidates.first, first.id == device?.id { return }

        guard let prepared = AudioDeviceSelector.firstPrepared(
            candidates: candidates,
            prepare: makeCapture,
            onFailure: { [log] candidate, error in
                log("failed to prepare capture device \(candidate.uid) (\(candidate.name)): \(error)")
            }
        ) else {
            capture = nil
            device = nil
            log("no input device found; running without capture")
            return
        }

        capture = prepared.value
        device = prepared.device
        log("selected capture device \(prepared.device.uid) (\(prepared.device.name))")
    }
}
