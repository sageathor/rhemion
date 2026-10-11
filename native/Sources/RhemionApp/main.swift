// Rhemion — native menu-bar app. This file is the app shell; the dictation
// pieces plug into AppController as they land: RuntimeSupervisor, RuntimeClient,
// HotkeyTap, Delivery, NotchIndicator, full wiring.
//
// Isolated from any earlier install: own bundle id (com.sageathor.rhemion.app), own state under
// RHEMION_RUNTIME_DIR=~/.local/state/rhemion-v3. It must never touch an earlier version's data.

import AppKit
import AVFoundation
import Foundation
import RhemionIPC
import RhemionStorage

@MainActor
final class AppController: NSObject, NSApplicationDelegate {
    static var shared: AppController?
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    let supervisor = RuntimeSupervisor()
    var client: RuntimeClient?
    var delivery: Delivery?
    var hotkey: HotkeyTap?
    var indicator: NotchIndicator?
    private var recall: RecallHotkey?
    private var dictAdd: DictAdd?
    private var dictAddPanel: DictAddPanelController?
    let undoStore = UndoStore()
    private var undoReplace: UndoReplace?
    private var escGesture: EscapeGesture?
    /// Settings › Shortcuts for double Esc (3.1), read on the tap's callback: cancel and erase each on or off, and
    /// apps where Esc twice is left to the app.
    let escPolicy = Locked<(cancel: Bool, erase: Bool, except: Set<String>)>((true, true, []))
    func applyShortcutSettings(_ s: AppSettings) {
        escPolicy.value = (s.escCancelEnabled, s.escEraseEnabled, Set(s.escExceptionApps))
        hotkey?.handsFreeEnabled = s.handsFreeEnabled
        hotkey?.journalOnlyEnabled = s.journalOnlyEnabled
    }
    var bench: InsertionBench?
    private var canceledPurgeTimer: Timer?
    /// "Pin to this window" (3.1): every dictation goes to the pinned window's field.
    let pin = PinnedWindow()
    private var pinMenuItem: NSMenuItem?

    /// The menu-bar item shows the Pin chord bound in Settings, or none when it is off.
    private func showPinShortcut(_ specs: [String]) {
        let chord = HotkeySpec.menuEquivalent(specs)
        pinMenuItem?.keyEquivalent = chord?.key ?? ""
        pinMenuItem?.keyEquivalentModifierMask = chord?.modifiers ?? []
    }
    /// Press-time targets by runtime session (the last 100 takes), for the Journal's Insert again.
    /// The press that started the coming take was Journal only (Shift): read once by its `.started` (3.1).
    private let journalPress = Locked<Bool>(false)
    /// The app itself ended the take (Esc twice, a data operation): its `canceled` just retracts. Any other
    /// `canceled` after a stop means the take had no speech, which gets the calm empty-take cue.
    let userCanceled = Locked<Bool>(false)
    /// Insert again (3.1): the entry's press-time target, keyed by the `again-…` session, so the
    /// delivery checks the restored field strictly (same element or same field) right before AX or ⌘V.
    let againTargets = Locked<[String: TargetSnapshot]>([:])
    let recentTargets = Locked<[String: (at: Date, snap: TargetSnapshot)]>([:])   // developer-only, off unless enabled (deploy/insertion-bench)
    // "The user is actively dictating" — driven by the LOCAL PTT intent (onStart/onStop/abort), NOT by
    // runtime session events, so it can't be clobbered by a late terminal event from an EARLIER,
    // already-processing session, and it flips to false the instant the key is released (before the
    // runtime's `.stopped` round-trips). Read (lock-guarded) from the Esc tap to decide cancel vs erase.
    let recordingFlag = Locked<Bool>(false)
    /// Mirrors `recordingFlag` for DataOperations' "An active dictation will be discarded" copy.
    var isDictatingNow: Bool { recordingFlag.value }
    /// Clear the "actively dictating" flag without sending a stray `.stop` — `abortRecording()` alone
    /// resets HotkeyTap's own state but never fires `onStop`, so this flag would otherwise stay stuck
    /// `true` forever after a take is discarded. Same pairing as the double-Esc cancel path
    /// (`handleEscapeGesture`). Used by `DataOperations.quiesce()`.
    func clearRecordingFlag() { recordingFlag.value = false }
    /// The quiesce barrier: every destructive storage action (Clear Data, export deletion,
    /// uninstall) starts by calling `dataOps.quiesce()`.
    lazy var dataOps = DataOperations(app: self)
    /// The exact failure text `stuckReport()` reports when `quiesce()` comes back `.stuck` — a shared
    /// constant so a storage sheet (Clear Data, export deletion, farewell) can recognize this specific failure and show
    /// the dedicated "Quit Rhemion" state instead of an ordinary failure list, without widening
    /// `OperationReport` itself with a new case.
    static let quiesceStuckMessage = "Rhemion couldn't stop its engine. Quit and reopen Rhemion to continue."
    /// The exact text `busyReport()` returns when another storage operation already
    /// holds the barrier — the sheets/window match it and stay on their confirm step (never a failure).
    static let busyMessage = "Another storage operation is in progress."
    /// Up from the moment a destructive run* function's barrier comes back `.ready` until it returns —
    /// `applicationShouldTerminate` refuses to quit in between (a half-done removal). Every legitimate
    /// exit that happens INSIDE a run* function (Clear Data's settings-reset relaunch) clears it first; the others (restart,
    /// Done, Quit on stuck) run after the function has returned, when it is already down.
    var destructiveOpRunning = false
    /// A real (non-dry-run) Uninstall has run — set once `runUninstall` returns from anything but
    /// busy/stuck. From then on every way out goes through `finishUninstall()` (it exits by itself), never
    /// `NSApp.terminate`, which would let AppKit write the just-cleared defaults and saved state back.
    var uninstallEnded = false
    var settings = AppSettings()
    /// Flips to `true` the instant a settings reset's barrier clears (Clear Data with "Reset
    /// all settings", before settings.json is touched) and never back — it always ends in either a
    /// relaunch or a "Restart Rhemion"-only
    /// failure state, never a return to normal operation. Every site that saves `settings` FROM MEMORY
    /// (the hub's apply-on-change, the two onboarding writers) checks this first, so a save racing in
    /// during/after the reset can't resurrect the old settings.json over the fresh one Reset just wrote.
    var settingsWriteSuppressed = false
    // The runtime's latest answer to `.listDevices` — what the Settings model/mic pickers offer.
    private var availableModels: [ModelOption] = []
    private var availableMics: [MicOption] = []
    var hubWindow: HubWindowController?
    private var onboardingWindow: OnboardingWindowController?
    private let aboutWindow = AboutWindowController()
    /// What's New (once after an update; menu bar and About open it again). A login start waits for the user.
    private var whatsNew: WhatsNewWindowController?
    private var whatsNewPending = false
    private func showPendingWhatsNew() {
        guard whatsNewPending else { return }
        whatsNewPending = false
        whatsNew?.show()
    }
    private var farewellWindow: FarewellWindowController?
    private var clearDataWindow: ClearDataWindowController?
    let modelDownload = ModelDownloadModel()   // speech-model provisioning state (onboarding + settings)
    // Thread-safe mirror of "the speech model is present" for the PTT hot path: HotkeyTap's onStart can run
    // off the main actor, so it reads this instead of the @MainActor ModelDownloadModel to decide, without a
    // hop, whether to start a take or show the not-ready cue. Kept in sync on the main actor (syncModelState).
    private let modelReady = Locked<Bool>(false)
    /// Whether microphone access was already granted when the runtime started. The runtime does not touch
    /// the microphone without it, so a grant made later needs a runtime restart to take effect.
    private let micAuthorizedAtRuntimeStart = Locked<Bool>(false)
    private var devicesPollScheduled = false
    /// Microphone granted while a download runs: the download's own runtime restart picks it up.
    private var micRestartPending = false
    /// Watches for a microphone grant made in System Settings while Welcome is closed (stops once granted).
    private var micWatchTimer: Timer?
    private var setupIncompleteItem: NSMenuItem?   // "Finish setup: download the speech model", shown only when missing
    let inputMethod = Locked<String>("direct")

    override init() {
        super.init()
        AppController.shared = self
        // Menu-bar glyph: a MONOCHROME version of the app icon (orb + rings), so the tray matches the
        // logo. Loaded as a template image (macOS tints it to the light/dark menu bar).
        if let button = statusItem.button {
            if let url = Bundle.main.url(forResource: "MenuBarGlyph", withExtension: "png"),
               let img = NSImage(contentsOf: url) {
                img.isTemplate = true
                img.size = NSSize(width: 18, height: 18)
                button.image = img
            } else {
                button.title = "R3"   // fallback if the asset is missing
            }
        }
        // Clean menu-bar menu: no title line, separators between groups, Settings near the
        // bottom, Quit last. Diagnostics (indicator style, app.log) moved to Settings › Advanced; the dev
        // ping test was removed.
        let menu = NSMenu()
        let hubItem = NSMenuItem(title: "Open Rhemion…", action: #selector(openHub), keyEquivalent: "0")
        hubItem.target = self
        // Shown only while the speech model is missing (setup incomplete) — the one gentle nudge, no red badge.
        // Opens Welcome, where the Download button lives. Hidden by default; toggled in updateSetupMenuItem().
        let setupItem = NSMenuItem(title: "Finish setup: download the speech model", action: #selector(openWelcome), keyEquivalent: "")
        setupItem.target = self
        setupItem.isHidden = true
        setupIncompleteItem = setupItem
        let journalItem = NSMenuItem(title: "Journal", action: #selector(openJournal), keyEquivalent: "j")
        journalItem.target = self
        let dictionaryItem = NSMenuItem(title: "Dictionary", action: #selector(openDictionary), keyEquivalent: "d")
        dictionaryItem.target = self
        let settingsItem = NSMenuItem(title: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
        settingsItem.target = self
        let shortcutsItem = NSMenuItem(title: "Keyboard Shortcuts…", action: #selector(openShortcuts), keyEquivalent: "/")
        shortcutsItem.target = self
        let whatsNewItem = NSMenuItem(title: "What's New…", action: #selector(openWhatsNew), keyEquivalent: "")
        whatsNewItem.target = self
        let welcomeItem = NSMenuItem(title: "Welcome…", action: #selector(openWelcome), keyEquivalent: "")
        welcomeItem.target = self
        let quitItem = NSMenuItem(title: "Quit Rhemion", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        quitItem.keyEquivalentModifierMask = [.command, .option]   // same as the app menu: ⌘Q only closes windows
        quitItem.target = NSApp   // terminate: is handled by NSApp, not this controller
        menu.addItem(hubItem)
        menu.addItem(setupItem)
        menu.addItem(.separator())
        // Pin to this window (3.1): the menu-bar menu does not change the frontmost app, so "this window" is the
        // one the user was in. The shortcut shown is the chord bound in Settings (none when it is off).
        let pinItem = NSMenuItem(title: pin.isPinned ? "Unpin window" : "Pin to this window", action: #selector(togglePin), keyEquivalent: "")
        pinItem.target = self
        pinMenuItem = pinItem
        menu.addItem(pinItem)
        menu.addItem(.separator())
        menu.addItem(journalItem); menu.addItem(dictionaryItem); menu.addItem(.separator())
        menu.addItem(settingsItem); menu.addItem(shortcutsItem); menu.addItem(welcomeItem); menu.addItem(whatsNewItem); menu.addItem(.separator())
        let aboutItem = NSMenuItem(title: "About Rhemion", action: #selector(openAbout), keyEquivalent: "")
        aboutItem.target = self
        menu.addItem(aboutItem)
        menu.addItem(quitItem)
        Self.withoutItemIcons(menu)
        statusItem.menu = menu
    }

    func setStatus(_ message: String) { statusItem.button?.toolTip = message }

    // While a real window is open the app must have a Dock icon + Cmd-Tab entry, otherwise the
    // window vanishes behind other apps with no way back (an .accessory app has neither). We flip to
    // .regular while a window is open and back to .accessory when it closes.

    func setDockIconVisible(_ visible: Bool) {
        if visible {
            guard NSApp.activationPolicy() != .regular else { return }
            NSApp.setActivationPolicy(.regular)   // the Dock shows the bundle's AppIcon.icns (one icon, no choice)
        } else {
            // Called from a window's windowWillClose, while that window is still on screen: look again on the
            // next turn of the run loop, and only drop the Dock icon when no other app window is still open.
            // Flipping to .accessory with another window up (e.g. closing Welcome while the Journal is open)
            // pulls that window away too — each window must close on its own.
            DispatchQueue.main.async {
                let anyOpen = NSApp.windows.contains { $0.isVisible && $0.styleMask.contains(.titled) }
                guard !anyOpen, NSApp.activationPolicy() != .accessory else { return }
                NSApp.setActivationPolicy(.accessory)
            }
        }
    }

    /// Apply the saved recording-indicator preference; "auto" keeps NotchIndicator's own hardware default.
    private func applyIndicatorStyle(_ style: String, to indicator: NotchIndicator) {
        switch style {
        case "notch":    indicator.setStyle(.notch)
        case "floating": indicator.setStyle(.floating)
        default:         break
        }
    }

    /// Keyboard Shortcuts… (⌘/, 3.1): Settings opened on Shortcuts, where every keyboard action is listed.
    @objc func openShortcuts() {
        hubWindow?.selectSettings(.shortcuts)
        openSettings()
    }

    @objc func openSettings() {
        client?.send(.listDevices)   // refresh the model/mic pickers from the runtime on every open
        hubWindow?.show(dest: .settings)   // Settings lives in the hub; ⌘, opens it there
    }

    /// No quitting in the middle of a destructive operation
    /// A click on the Dock icon (the app is pinned there, or a window put the icon up): Rhemion is a
    /// menu-bar app with no window of its own at rest, so AppKit's default does nothing visible. Bring
    /// Welcome forward while it is open, otherwise open the hub (or bring a minimized/hidden one back).
    enum LaunchKind: Equatable {
        case loginItem, byUser, unknown
        var label: String {
            switch self { case .loginItem: "login item"; case .byUser: "by the user"; case .unknown: "unknown (no launch event)" }
        }
    }

    /// How this process was started, read from the launch Apple event: a login item start carries
    /// keyAELaunchedAsLogInItem in its 'oapp' event; any other 'oapp'/'odoc' is a user launch. No event
    /// (started by a script or debugger) counts as unknown and stays quiet like a login item.
    @MainActor static func launchKind() -> LaunchKind {
        guard let event = NSAppleEventManager.shared().currentAppleEvent,
              event.eventClass == AEEventClass(kCoreEventClass) else { return .unknown }
        if event.eventID == AEEventID(kAEOpenApplication),
           event.paramDescriptor(forKeyword: AEKeyword(keyAEPropData))?.enumCodeValue == OSType(keyAELaunchedAsLogInItem) {
            return .loginItem
        }
        return .byUser
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if let welcome = onboardingWindow, welcome.isShowing { welcome.bringToFront() } else { hubWindow?.show() }
        showPendingWhatsNew()
        return true
    }

    /// What a quit request (Cmd-Q, Dock Quit, logout) does now: refused mid-operation; after a real
    /// Uninstall routed to `finishUninstall()` (it exits by itself, so AppKit's own quit is cancelled — it
    /// would write the cleared defaults and saved state back); otherwise an ordinary quit.
    enum QuitDecision: Equatable { case quit, refuse, finishUninstall }

    nonisolated static func quitDecision(destructiveOpRunning: Bool, uninstallEnded: Bool) -> QuitDecision {
        if destructiveOpRunning { return .refuse }
        return uninstallEnded ? .finishUninstall : .quit
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        switch Self.quitDecision(destructiveOpRunning: destructiveOpRunning, uninstallEnded: uninstallEnded) {
        case .quit:
            return .terminateNow
        case .refuse:
            log("quit refused: a storage operation is running")
            return .terminateCancel
        case .finishUninstall:
            finishUninstall()   // exits; never returns in a real uninstall
            return .terminateCancel
        }
    }

    /// Store the runtime's latest device enumeration and push it into the hub's Settings pickers (a
    /// refresh while the window is open updates the option lists in place).
    @MainActor private func updateDevices(models: [ModelOption], mics: [MicOption]) {
        availableModels = models
        availableMics = mics
        hubWindow?.setDevices(models: models, mics: mics)
        modelDownload.devicesUpdated(models)   // drives the Speech-model row (present / preparing / ready)
        syncModelState()
        // While the runtime prepares the model, ask again shortly; the report flips to warm when it is done.
        if modelDownload.phase == .preparing, !devicesPollScheduled {
            devicesPollScheduled = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                guard let self else { return }
                self.devicesPollScheduled = false
                self.client?.send(.listDevices)
            }
        }
    }

    /// Push the current model phase into the hot-path readiness mirror and the menu. Call on the main actor
    /// after any change to `modelDownload.phase` (a `.devices` report or a `.modelDownload` event).
    @MainActor private func syncModelState() {
        modelReady.value = modelDownload.isReady
        updateSetupMenuItem()
        // Model just became ready: end any download/not-ready orb cue (leaves a live recording alone) and
        // clear the menu-bar "downloading…" tooltip.
        if modelDownload.isReady { indicator?.endModelCue(); setStatus("") }
    }

    /// Show the "Finish setup: download the speech model" menu line only when the model is actionable-missing
    /// (absent or a failed download), never while it's downloading/preparing/ready. No persistent red badge.
    @MainActor private func updateSetupMenuItem() {
        let show: Bool
        switch modelDownload.phase {
        case .missing, .failed: show = true
        default:                show = false
        }
        setupIncompleteItem?.isHidden = !show
    }

    /// A gated push-to-talk press (model not ready): don't start a take. Reset the hotkey state so a
    /// hands-free latch/countdown can't engage on the gated press, and show a graphical, non-error cue at the
    /// notch (progress ring if a download is running, else a brief down-arrow) with an English hover tooltip.
    @MainActor private func handleGatedPTT() {
        hotkey?.abortRecording()
        switch modelDownload.phase {
        case .downloading(let f):
            indicator?.downloadProgress(f)
            setStatus("Downloading speech model — \(Int(f * 100))%")
            showWelcomeForSetup()
        case .preparing:
            // Usually under a second (a first-time compile can take a minute): the spinner only; Welcome comes
            // forward only if it is already open, so a press right after login doesn't pop a window.
            indicator?.preparing()
            setStatus("Preparing speech model…")
            if let welcome = onboardingWindow, welcome.isShowing { welcome.bringToFront() }
        default:
            indicator?.downloadHint()
            setStatus("Download the speech model to use dictation (Welcome / Settings › Audio & Model)")
            showWelcomeForSetup()
        }
    }

    /// A dictation press without usable microphone access. Not granted: bring Welcome forward (its Microphone
    /// row asks). Granted since the runtime started: restart the runtime so it can prepare the microphone.
    @MainActor private func handleMicrophoneGate(granted: Bool) {
        hotkey?.abortRecording()
        if granted {
            // The runtime restarts to open the microphone; the spinner ends when it reports ready. During a
            // download the restart waits for it, and the download ring stays.
            if case .downloading = modelDownload.phase {} else { indicator?.preparing() }
            restartRuntimeForMicrophone()
        } else {
            indicator?.downloadHint()
            showWelcomeForSetup()
        }
    }

    @MainActor private func restartRuntimeForMicrophone() {
        guard !micAuthorizedAtRuntimeStart.value else { return }
        micWatchTimer?.invalidate(); micWatchTimer = nil
        // A restart now would cut a running download; its own restart (on "done") covers the microphone too.
        if case .downloading = modelDownload.phase { micRestartPending = true; return }
        micAuthorizedAtRuntimeStart.value = true
        micRestartPending = false
        log("microphone access granted; restarting the runtime so it can use the microphone")
        supervisor.restart()
    }

    /// Until microphone access is granted, check every 2 s (reading the status never prompts), so a grant
    /// made in System Settings with Welcome closed takes effect without spending a dictation press on it.
    @MainActor private func watchForMicrophoneGrant() {
        guard !micAuthorizedAtRuntimeStart.value, micWatchTimer == nil else { return }
        micWatchTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                if AVCaptureDevice.authorizationStatus(for: .audio) == .authorized { self.restartRuntimeForMicrophone() }
            }
        }
    }

    /// The words and the progress live in Welcome; the notch indicator stays wordless.
    @MainActor private func showWelcomeForSetup() {
        guard let welcome = onboardingWindow else { return }
        if welcome.isShowing { welcome.bringToFront() } else { welcome.show() }
    }

    @objc private func openHub() { hubWindow?.show(); showPendingWhatsNew() }
    @objc private func openWhatsNew() { whatsNewPending = false; whatsNew?.show() }

    // The Dictionary and Journal now live as hub destinations; these menu items just jump the
    // hub to the right tab. The old standalone windows are gone.
    @objc private func openDictionary() { hubWindow?.show(dest: .dictionary) }

    @objc private func openJournal() { hubWindow?.show(dest: .journal) }
    @objc private func togglePin() { pin.toggle() }

    @objc private func openWelcome() { onboardingWindow?.show() }
    @objc func openAbout() { aboutWindow.show() }

    // Global hotkeys are suspended while ANY settings recorder captures a chord; a depth counter keeps
    // them suspended until the last active recorder finishes (two rows can record at once).
    private var recordingDepth = 0
    private func beginHotkeyRecording() {
        if recordingDepth == 0 {
            recall?.suspend(); dictAdd?.suspend(); undoReplace?.suspend(); pin.suspend()
            escGesture?.suspend()   // let the recorder's monitor see Esc; don't act on it as a gesture
        }
        recordingDepth += 1
    }
    private func endHotkeyRecording() {
        recordingDepth = max(0, recordingDepth - 1)
        if recordingDepth == 0 {
            recall?.setHotkeys(settings.recallHotkeys)
            pin.setHotkeys(settings.pinHotkeys)
            dictAdd?.setHotkeys(settings.dictAddHotkeys)
            undoReplace?.setHotkeys(settings.undoHotkeys)
            escGesture?.resume()
        }
    }

    // MARK: - NSApplicationDelegate lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        installMainMenu()
        AppLog.enforceHygiene()   // 7 days / 15 MB of diagnostic logs, before the first line of this run
        AppLog.startHygieneTimer()
        log("Rhemion 3.0 launched. stateDir=\(AppPaths.stateDir.path)")

        // 0) Settings — the app owns active/settings.json (no source note). Materialize it so
        //    the runtime always has a complete snapshot, then load our view of it.
        SettingsStore.ensureExists()
        settings = SettingsStore.load()
        showPinShortcut(settings.pinHotkeys)   // the menu was built before settings were read
        settings.applyAppearance()
        inputMethod.value = settings.inputMethod
        // Reconcile the login-item registration to the saved preference (default on). Non-fatal: a
        // failure is logged and retried on the next launch/toggle, never crashes startup.
        LoginItem.reconcile(enabled: settings.launchAtLogin)
        log("settings: ptt=[\(settings.pttKeys.joined(separator: ","))], input=\(settings.inputMethod), language=\(settings.language)")

        // 1) Own isolated runtime. Migrate any history from the earlier location into the Application Support
        //    dataDir FIRST — before the runtime starts — so its startup reconcile finds the audio
        //    instead of treating every take's WAV as missing and purging the month's records.
        AppPaths.migrateDataDirIfNeeded()
        micAuthorizedAtRuntimeStart.value = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        supervisor.start()

        // 2) Delivery + socket client. The client routes `deliver` events into Delivery,
        //    which inserts natively and reports the outcome back as a delivery-result ack.
        let indicator = NotchIndicator()
        applyIndicatorStyle(settings.indicatorStyle, to: indicator)   // honor the saved Advanced preference
        let delivery = Delivery()
        // Arm/disarm the in-place undo from the delivery outcome (disarm at every delivery start, arm on
        // a landed dictionary substitution).
        delivery.onArmUndo = { [undoStore] deliveredN, pid, undoRaw, session in
            undoStore.arm(deliveredN: deliveredN, pid: pid, undoRaw: undoRaw, session: session)
        }
        delivery.onDisarmUndo = { [undoStore] in undoStore.disarm() }
        ClipboardPaste.trackKeyboardLayout()   // V for ⌘V by the shortcut layout, kept current on layout changes
        startBench(indicator: indicator)   // developer-only insertion bench (AppController+Bench.swift)
        let client = RuntimeClient(socketPath: supervisor.socketPath)
        client.onConnect = { [weak client, weak self] in
            log("runtime connected")
            // A reconnect while a download was still in flight means the runtime restarted under it — no
            // "failed" event will arrive, so surface it as interrupted (Retry appears; the `.devices` report
            // below then resolves ready/missing). This also unsticks a Download whose command was dropped
            // because the socket was down. `.preparing` is the intended post-"done" restart and is left to
            // resolve to `.ready` via devicesUpdated, so it is deliberately NOT treated as interrupted.
            Task { @MainActor in
                guard let self else { return }
                if case .downloading = self.modelDownload.phase {
                    self.modelDownload.phase = .failed("Download interrupted")
                    self.syncModelState()
                    self.indicator?.downloadHint()
                    self.setStatus("Speech model download interrupted — retry in Setup")
                }
            }
            client?.send(.listDevices)   // pre-warm the Settings model/mic lists + resolve model readiness
        }
        // Speech-model provisioning: the Download/Retry button asks the runtime to fetch the model (it owns
        // FluidAudio); Cancel aborts it. Progress + terminal state come back as `.modelDownload` events.
        modelDownload.onDownload = { [weak client, weak self] in
            guard let self, !self.dataOps.inProgress else { return }
            self.modelDownload.phase = .downloading(0)   // immediate feedback before the first progress event
            self.syncModelState()
            self.indicator?.downloadProgress(0)          // show the orb the instant Download is pressed (links the two)
            self.setStatus("Downloading speech model…")
            client?.send(.downloadModel(id: self.modelDownload.modelID))
        }
        modelDownload.onCancel = { [weak client] in client?.send(.cancelModelDownload) }
        let perf = DictationPerf()   // per-dictation latency by phase → `perf:` lines in app.log
        delivery.onVisible = { session, at in
            guard !session.hasPrefix("again-"), !session.hasPrefix("recall-"), !session.hasPrefix("bench-") else { return }
            perf.markVisible(at: at)
        }
        let targets = TargetStore()  // press-time target snapshots, matched at delivery: a lost target keeps the text
        let recents = recentTargets
        let again = againTargets
        // Insert again: only the restored field itself; never "unknown", never another field of the app.
        let againAllows: @Sendable (String, String) -> Bool? = { session, when in
            guard let snap = again.value[session] else { return nil }
            let (match, _) = snap.matchNow()
            let ok = match == .sameElement || match == .sameField
            log("insert again: target \(match.rawValue) \(when), \(ok ? "insert" : "kept")")
            return ok
        }
        delivery.targetRecheck = { session in
            if let ok = againAllows(session, "just before ⌘V") { return ok }
            guard let snap = recents.value[session]?.snap else { return true }
            let (match, _) = snap.matchNow()
            if !snap.allows(match) { log("target: \(match.rawValue) just before ⌘V, kept") }
            return snap.allows(match)
        }
        delivery.targetCheck = { session in
            if let ok = againAllows(session, "at delivery") { return ok }
            guard let snap = targets.take(session: session) else { return true }   // Recall, bench, no snapshot
            recents.value = { var m = recents.value; m[session] = (Date(), snap)
                if m.count > 100, let oldest = m.min(by: { $0.value.at < $1.value.at })?.key { m[oldest] = nil }
                return m }()
            let t0 = DispatchTime.now().uptimeNanoseconds
            let (match, detail) = snap.matchNow()
            let allowed = snap.allows(match)
            log("target: \(match.rawValue) (\(detail))\(match == .otherField && !snap.editable ? " picked-while-speaking" : "") \(allowed ? "insert" : "kept") \((DispatchTime.now().uptimeNanoseconds - t0) / 1_000_000) ms")
            return allowed
        }
        let journalPress = self.journalPress
        let userCanceled = self.userCanceled
        client.onEvent = { [weak client, weak self, inputMethod] event in
            // Per-tick microphone levels aren't logged (dozens a second while dictating); state changes are.
            if case .level = event {} else { log("event: \(eventLabel(event))") }
            switch event {
            case .started(let s):
                perf.markStarted(); targets.started(session: s); userCanceled.value = false
                let journal = journalPress.value; journalPress.value = false
                Task { @MainActor in indicator.recording(journalOnly: journal) }
            case .level(let rms): Task { @MainActor in indicator.onLevel(rms); self?.hotkey?.onLevel(rms) }
            case .stopped:        perf.markStopped(); Task { @MainActor in indicator.processing() }
            case let .transcript(_, ms, _): perf.markTranscript(engineMS: ms)
            case .canceled(let s):
                let byUser = userCanceled.value; userCanceled.value = false
                // Esc twice (or a data operation) retracts at once; a take with no speech gets the empty-take cue.
                perf.cancel(); Task { @MainActor in if byUser { indicator.hide() } else { indicator.empty() } }
                // A kept cancel is journaled by the runtime: keep its press-time target for Insert again.
                if let snap = targets.take(session: s) {
                    recents.value = { var m = recents.value; m[s] = (Date(), snap); return m }()
                }
            case .error:          perf.cancel(); Task { @MainActor in indicator.failed() }   // no text came back
            case .journaled:      perf.cancel(); Task { @MainActor in indicator.journaled() }   // saved to the journal only
            case let .rerecognized(id, ok, error):
                Task { @MainActor in self?.hubWindow?.journal.recognized(id: id, ok: ok, error: error) }
            case let .devices(models, mics): Task { @MainActor in self?.updateDevices(models: models, mics: mics) }
            case let .modelDownload(_, state, fraction, error):
                Task { @MainActor in
                    guard let self else { return }
                    // Always fold the event into the phase model — quiesce()'s own ~3s cancel-download
                    // poll (DataOperations.swift) reads `modelDownload.phase` as its only signal that the
                    // runtime's "canceled" reply landed, and this call is the only thing that flips phase
                    // away from `.downloading`. It has no side effect of its own (no UI, no supervisor
                    // call), so leaving it live during quiesce is safe.
                    self.modelDownload.downloadEvent(state: state, fraction: fraction, error: error)
                    guard !self.dataOps.inProgress else {
                        log("model-download event dropped: data operation in progress")
                        return
                    }
                    self.syncModelState()
                    switch state {
                    case "downloading":
                        let f = fraction ?? 0
                        self.indicator?.downloadProgress(f)
                        self.setStatus("Downloading speech model — \(Int(f * 100))%")
                    case "done":
                        // A finished download isn't usable until a fresh runtime discovers + registers it;
                        // restart so it does (and prewarms). Readiness then arrives via the next `.devices`.
                        self.setStatus("Preparing speech model…")
                        self.indicator?.preparing()   // spinner until the restarted runtime reports the model warm
                        // This restart also opens the microphone if access was granted during the download.
                        self.micAuthorizedAtRuntimeStart.value = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
                        self.micRestartPending = false
                        self.supervisor.restart()
                    case "failed":
                        self.indicator?.downloadHint()
                        self.setStatus("Speech model download interrupted — retry in Setup")
                        if self.micRestartPending { self.restartRuntimeForMicrophone() }
                    case "canceled":
                        self.indicator?.hide()
                        self.setStatus("")
                        if self.micRestartPending { self.restartRuntimeForMicrophone() }
                    default: break
                    }
                }
            case let .deliver(session, text, original, targetPid):
                perf.markDeliver()
                // Hop to the main actor to check the barrier (dataOps is @MainActor-isolated; this
                // closure runs on RuntimeClient's internal queue), same pattern as every other case here.
                Task { @MainActor in
                    guard self?.dataOps.inProgress != true else {
                        log("deliver dropped: data operation in progress")
                        return
                    }
                    let ack: (String, String) -> Void = { s, status in client?.send(.deliverResult(session: s, status: status)) }
                    let finished: (String) -> Void = { status in
                        log("delivery: \(status)")
                        perf.markInserted(method: "\(status)")
                        let ok = isDeliverySuccess(status)
                        // Not inserted, but the text is in the Journal: "kept" (amber), never the red "failed".
                        Task { @MainActor in
                            if ok { indicator.done(); self?.pin.refresh() } else { indicator.kept() }
                        }
                    }
                    if targets.isPinReturn(session: session), let self {
                        self.deliverToPinned(text: text, original: original, session: session, ack: ack, finished: finished)
                        return
                    }
                    delivery.onDeliver(
                        text: text, original: original, session: session, targetPid: targetPid,
                        inputMethod: inputMethod.value, sendAck: ack, onResult: finished
                    )
                }
            default: break
            }
        }
        client.connect()

        // 3) Push-to-talk hotkey: a bare modifier (from settings, default Right Option) drives
        //    start/stop over the socket, carrying the frontmost pid so the runtime binds delivery to
        //    the app that was focused at press.
        let hotkey = HotkeyTap()
        hotkey.onStart = { [weak client, weak self, recordingFlag, modelReady, micAuthorizedAtRuntimeStart, journalPress] pid, journalOnly in
            // Hot-path gate: don't start a take until the speech model is ready and the microphone may be used
            // — otherwise the runtime has nothing to record or nothing to recognise with. Read thread-safe
            // state (onStart can run off the main actor); show a cue and the Welcome window instead.
            let micGranted = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
            guard micGranted, micAuthorizedAtRuntimeStart.value else {
                Task { @MainActor in self?.handleMicrophoneGate(granted: micGranted) }
                return
            }
            guard modelReady.value else {
                Task { @MainActor in self?.handleGatedPTT() }
                return
            }
            // Barrier gate: this closure runs on the main run loop (HotkeyTap's tap source is added
            // there), so a synchronous MainActor read is safe here, matching escGesture.onDoubleTap below.
            // A quiesce in progress must not start a new take: reset the tap's latch state instead (no
            // recordingFlag, no `.start`) so the eventual release is a no-op too.
            let blocked = MainActor.assumeIsolated { self?.dataOps.inProgress ?? false }
            guard !blocked else {
                log("PTT ignored: data operation in progress")
                MainActor.assumeIsolated { self?.hotkey?.abortRecording() }
                return
            }
            log("PTT down -> start (pid \(pid))\(journalOnly ? " journal only" : "")")
            perf.markPress()
            recordingFlag.value = true
            // Journal only (Shift with the key, 3.1): nothing is inserted, so no target and no pinned window.
            if journalOnly {
                journalPress.value = true
                client?.send(.startJournal(pressedAt: nil, targetPid: Int(pid)))
                return
            }
            // A pinned window takes the text (3.1). "stay": go there now; "return": keep working, the text is put
            // there later by a jump. Otherwise: where this take started (app, window, field).
            let pinTarget = MainActor.assumeIsolated { self?.pin.target }
            let pinStay = MainActor.assumeIsolated { self?.settings.pinMode != "return" }
            if let pinTarget {
                targets.pressed(snapshot: pinTarget, pinReturn: !pinStay)
                client?.send(.start(pressedAt: nil, targetPid: pinTarget.pid))
                if pinStay { DispatchQueue.main.async { MainActor.assumeIsolated { _ = self?.pin.bringForward() } } }
            } else {
                targets.pressed(pid: Int(pid))
                client?.send(.start(pressedAt: nil, targetPid: Int(pid)))
            }
        }
        hotkey.onStop = { [weak client, weak self, recordingFlag] in
            guard recordingFlag.value else { return }   // a gated press never started — send no stray .stop
            recordingFlag.value = false
            let blocked = MainActor.assumeIsolated { self?.dataOps.inProgress ?? false }
            guard !blocked else { log("PTT ignored: data operation in progress"); return }
            log("PTT up -> stop")
            perf.markRelease()
            client?.send(.stop)
        }
        hotkey.onCountdown = { remaining in Task { @MainActor in indicator.countdown(remaining) } }
        hotkey.onCountdownCancel = { Task { @MainActor in indicator.cancelCountdown() } }
        hotkey.setPTTKeys(settings.pttKeys)
        hotkey.setHandsFreeTimings(ringAfter: Double(settings.handsfreeCountdownAfterSecs),
                                   countdown: Double(settings.handsfreeCountdownSecs))
        hotkey.start()

        // 3b) Recall hotkey (global Carbon chord, works under Secure Input): re-inserts the last
        //     dictation into the current focus. Default Cmd+Option+R. Success is silent; only a failure flashes the indicator.
        let recall = RecallHotkey()
        recall.onRecall = { [weak self] text in
            Task { @MainActor in
                guard let self, !self.dataOps.inProgress else { return }
                self.deliverRecall(text)
            }
        }
        recall.setHotkeys(settings.recallHotkeys)

        // 3b') Pin to this window (default ⌥⌘P): toggles the pin; the notch shows the resting orb, a click on it unpins.
        pin.setHotkeys(settings.pinHotkeys)
        pin.autoUnpinMinutes = settings.pinAutoUnpin ? settings.pinAutoUnpinMinutes : 0
        pin.onChange = { [weak self] on in
            self?.indicator?.setPinned(on)
            self?.pinMenuItem?.title = on ? "Unpin window" : "Pin to this window"
        }
        indicator.onPinnedOrbClick = { [weak self] in self?.pin.unpin(reason: "orb clicked") }

        // 3c) Dict-add hotkey (global Carbon chord, default Cmd+Option+W): reads the current selection
        //     then opens the "as heard → correct" panel, which writes the replacement into the
        //     dictionary the runtime hot-reloads.
        let dictAddPanel = DictAddPanelController()
        let dictAdd = DictAdd()
        dictAdd.onTrigger = { [weak self] selection, target in
            Task { @MainActor in
                guard let self, !self.dataOps.inProgress else { return }
                self.dictAddPanel?.show(heard: selection, target: target)
            }
        }
        dictAdd.setHotkeys(settings.dictAddHotkeys)

        // 3d) Undo-replace hotkey (global Carbon, default Cmd+Option+Shift+L): reverts
        //     the last dictation's dictionary replacement in place (Backspace×N + paste the original).
        let undoReplace = UndoReplace(store: undoStore)
        undoReplace.onError = { Task { @MainActor in indicator.error() } }
        undoReplace.setHotkeys(settings.undoHotkeys)
        undoStore.setTTL(Double(settings.undoTTLSecs))

        // 3e) Double-Esc gesture (active CGEventTap; a lone Esc passes through, only the second Esc of
        //     an engaged double-tap is swallowed): cancels a recording in progress, or erases the
        //     just-delivered take. Engages only while a take is recording or an armed take is fresh.
        let escGesture = EscapeGesture()
        let escPolicy = self.escPolicy
        escGesture.isEligible = { [recordingFlag, undoStore] in
            let p = escPolicy.value
            if let front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier, p.except.contains(front) { return false }
            return (p.cancel && recordingFlag.value) || (p.erase && undoStore.isArmed())
        }
        // Synchronous on the tap's main-run-loop callback (assumeIsolated is safe — we ARE on main), so
        // the swallow decision reflects whether the gesture actually claimed an action THIS press.
        escGesture.onDoubleTap = { [weak self] in
            MainActor.assumeIsolated { self?.handleEscapeGesture() ?? false }
        }
        escGesture.setWindowMS(settings.escDoubleTapMS)
        escGesture.start()
        applyShortcutSettings(settings)

        // 4) Hub window (it owns Settings, reached via "Open Rhemion…" or ⌘,). Apply-on-
        //    change: persist the snapshot, then re-apply live — rebind the PTT modifier and swap the
        //    delivery input method. `language`/`model` live in the same snapshot and the runtime
        //    re-reads them on the next take, no restart.
        hubWindow = HubWindowController(
            current: { [weak self] in self?.settings ?? AppSettings() },
            apply: { [weak self] updated in
                guard let self else { return }
                // A model-folder change alters what the runtime's whisper scan finds, so re-query the
                // device list afterward to refresh the model picker in place.
                let modelDirsChanged = self.settings.modelDirs != updated.modelDirs
                self.settings = updated
                updated.applyAppearance()
                if let ind = self.indicator { self.applyIndicatorStyle(updated.indicatorStyle, to: ind) }
                if !self.settingsWriteSuppressed, !SettingsStore.save(updated) {
                    log("settings: WARN save failed — live change applied but not persisted")
                }
                self.inputMethod.value = updated.inputMethod
                self.hubWindow?.journal.keepCanceledHours = updated.keepCanceledHours
                self.hotkey?.setPTTKeys(updated.pttKeys)
                self.hotkey?.setHandsFreeTimings(ringAfter: Double(updated.handsfreeCountdownAfterSecs),
                                                 countdown: Double(updated.handsfreeCountdownSecs))
                // Don't re-arm the global chords while a recorder is capturing (a settings change during
                // capture would re-register them mid-capture); endHotkeyRecording restores them from
                // self.settings when the last active recorder ends.
                if self.recordingDepth == 0 {
                    self.recall?.setHotkeys(updated.recallHotkeys)
                    self.pin.setHotkeys(updated.pinHotkeys)
                    self.dictAdd?.setHotkeys(updated.dictAddHotkeys)
                    self.undoReplace?.setHotkeys(updated.undoHotkeys)
                }
                self.showPinShortcut(updated.pinHotkeys)
                self.undoStore.setTTL(Double(updated.undoTTLSecs))
                self.pin.autoUnpinMinutes = updated.pinAutoUnpin ? updated.pinAutoUnpinMinutes : 0
                self.escGesture?.setWindowMS(updated.escDoubleTapMS)
                self.applyShortcutSettings(updated)
                LoginItem.reconcile(enabled: updated.launchAtLogin)
                if modelDirsChanged { self.client?.send(.listDevices) }
                log("settings changed: ptt=[\(updated.pttKeys.joined(separator: ","))], input=\(updated.inputMethod), language=\(updated.language)")
            },
            // While the recorder captures a chord, drop the global registrations so the current chord
            // reaches the local monitor (and no global hotkey fires mid-capture); restore afterward.
            // Ref-counted so two recorder rows recording at once don't restore while one is still open.
            beginRecording: { [weak self] in self?.beginHotkeyRecording() },
            endRecording: { [weak self] in self?.endHotkeyRecording() },
            client: client, modelDownload: modelDownload,
            runClearData: { [weak self] selection, progress in await self?.runClearData(selection, progress: progress) ?? OperationReport() },
            runDeleteExport: { [weak self] turnOff in await self?.runDeleteExport(turnOff: turnOff) ?? OperationReport() },
            isRecording: { [weak self] in self?.dataOps.isRecording ?? false },
            storageActivity: dataOps
        )
        // 4a) The Journal's Insert again (3.1): put a not-inserted text back where it was meant to go.
        hubWindow?.journal.keepCanceledHours = settings.keepCanceledHours
        // Canceled entries are kept only for Settings › Journal's "Keep them for": purge the expired ones now and hourly.
        DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [weak self] in self?.purgeExpiredCanceled() }   // once the runtime is up
        canceledPurgeTimer = Timer.scheduledTimer(withTimeInterval: 3600, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.purgeExpiredCanceled() }
        }
        let knownTargets = recentTargets
        hubWindow?.journal.canInsertAgain = { entry in entry.session.map { knownTargets.value[$0] != nil } ?? false }
        hubWindow?.journal.insertAgain = { [weak self] entry, done in self?.insertAgain(entry, done) }
        hubWindow?.journal.recognizeAgain = { [weak self] entry in self?.client?.send(.rerecognize(id: entry.id)) }

        // 4b) Uninstall: the farewell window, opened from Settings › Advanced › Storage.
        farewellWindow = FarewellWindowController(
            current: { [weak self] in self?.settings ?? AppSettings() },
            isRecording: { [weak self] in self?.dataOps.isRecording ?? false },
            canStart: { [weak self] in self?.canStartStorageOperation ?? false },
            run: { [weak self] options, progress in await self?.runUninstall(options, progress: progress) ?? OperationReport() },
            finish: { [weak self] in self?.finishUninstall() })
        hubWindow?.showUninstall = { [weak self] in self?.farewellWindow?.show() }
        // Clear Data is its own window in the farewell's format.
        clearDataWindow = ClearDataWindowController(restart: { [weak self] in self?.restartAfterClear() })
        hubWindow?.showClearData = { [weak self] make in self?.clearDataWindow?.show(make) }

        // The Dictionary and Journal are hub destinations now (Stages 4/5); no standalone windows to build.

        // 5) Welcome & Setup: first-run permissions + how-to. Shown once, re-openable from the menu.
        //    The PTT chooser writes the key live (persist + rebind the tap), same as a Settings change.
        onboardingWindow = OnboardingWindowController(
            current: { [weak self] in self?.settings ?? AppSettings() },
            setPTTKey: { [weak self] key in
                guard let self else { return }
                self.settings.pttKeys = [key]
                if !self.settingsWriteSuppressed, !SettingsStore.save(self.settings) { log("settings: WARN save failed (ptt from onboarding)") }
                self.hotkey?.setPTTKeys(self.settings.pttKeys)
                log("onboarding set ptt=\(key)")
            },
            setLaunchAtLogin: { [weak self] on in
                guard let self else { return }
                self.settings.launchAtLogin = on
                if !self.settingsWriteSuppressed, !SettingsStore.save(self.settings) { log("settings: WARN save failed (launch-at-login from onboarding)") }
                LoginItem.reconcile(enabled: on)
                log("onboarding set launch-at-login=\(on)")
            },
            modelDownload: modelDownload,
            onMicrophoneGranted: { [weak self] in self?.restartRuntimeForMicrophone() }
        )
        // Before Welcome marks itself shown: a fresh install has never seen it (then What's New stays quiet).
        let freshInstall = !OnboardingWindowController.hasBeenShown
        let launch = Self.launchKind()
        log("launch: \(launch.label)")
        if onboardingWindow?.needsShowing == true {
            onboardingWindow?.show()
        } else if launch == .byUser {
            // Started by the user (Dock icon, Finder, Spotlight): show something, as any app does. A login
            // item start stays quiet in the menu bar.
            hubWindow?.show()
        }
        watchForMicrophoneGrant()

        // 5b) What's New: once per version, after an update only; Welcome first when it is needed.
        let version = AboutInfo(bundle: .main).version
        let whatsNew = WhatsNewWindowController(version: version)
        self.whatsNew = whatsNew
        aboutWindow.onWhatsNew = { [weak whatsNew] in whatsNew?.show() }
        if WhatsNewPolicy.shouldShow(current: version, freshInstall: freshInstall), whatsNew.hasNotes,
           onboardingWindow?.isShowing != true {
            if launch == .byUser {
                let recording = recordingFlag
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                    if recording.value { self?.whatsNewPending = true } else { whatsNew.show() }   // never over a dictation
                }
            } else {
                whatsNewPending = true   // a login start: shown when Rhemion is first opened
            }
        }

        // Testing hook: RHEMION_OPEN_HUB=1 pops the hub on launch so it can be shown without clicking the
        // menu-bar item (no permanent behaviour change — the menu item is the real entry point).
        if let openHub = ProcessInfo.processInfo.environment["RHEMION_OPEN_HUB"], !openHub.isEmpty {
            hubWindow?.show(dest: openHub == "settings" ? .settings : nil)
        }

        self.indicator = indicator
        self.delivery = delivery
        self.client = client
        self.hotkey = hotkey
        applyShortcutSettings(settings)   // now that the hotkey is stored, its gesture switches apply too
        self.recall = recall
        self.dictAdd = dictAdd
        self.dictAddPanel = dictAddPanel
        self.undoReplace = undoReplace
        self.escGesture = escGesture
    }

    /// Stop every global hotkey/event tap (quit and the uninstall exit path).
    func stopInputs() {
        hotkey?.stop()
        recall?.stop()
        dictAdd?.stop()
        undoReplace?.stop()
        escGesture?.stop()
    }

    func applicationWillTerminate(_ notification: Notification) {
        stopInputs()
        supervisor.stop()
        log("Rhemion 3.0 terminating.")
    }
}

// Owner-only files by default.
umask(0o077)
// Writing to a socket whose peer (the runtime) has gone raises SIGPIPE, whose default action kills the
// process; ignore it so the client reconnects instead of crashing.
signal(SIGPIPE, SIG_IGN)

// SIGTERM (`kill`, a launchd stop) would end the process without applicationWillTerminate, leaving the
// runtime behind. Turn it into a normal quit, which stops the runtime first; the runtime also exits on
// its own when it sees its parent gone.
signal(SIGTERM, SIG_IGN)
let sigtermSource = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
sigtermSource.setEventHandler {
    log("SIGTERM: quitting")
    NSApp.terminate(nil)
}
sigtermSource.resume()

// One Rhemion at a time: a second launch brings the running one forward and quits here — before
// the runtime starts or any state is touched.
if SingleInstance.handOverIfAlreadyRunning() { exit(0) }

let app = NSApplication.shared
app.setActivationPolicy(.accessory)   // menu-bar only; no Dock icon (also declared LSUIElement)
let controller = AppController()
app.delegate = controller             // drives applicationDidFinishLaunching / WillTerminate
app.run()
