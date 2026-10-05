// HotkeyTap — global push-to-talk on a bare modifier.
// A CGEventTap (session, flagsChanged+keyDown, listen-only) keyed on the DEVICE-specific modifier
// bit (Right Option = 0x40), so it fires under Secure Keyboard Entry.
// The tap is created only AFTER Accessibility is granted (a tap created while
// untrusted is starved), retrying until the grant lands. Accessibility alone is enough (no Input Monitoring).

import AppKit
import ApplicationServices

final class HotkeyTap: @unchecked Sendable {
    // Modifier bits: per-modifier device bit + logical bit; ALL_LOGICAL = shift|ctrl|opt|cmd.
    private static let allLogical: UInt64 = 0x1E0000
    private static let modBits: [String: (dev: UInt64, logical: UInt64)] = [
        "right_cmd":     (0x10,   0x100000),
        "left_cmd":      (0x08,   0x100000),
        "right_option":  (0x40,   0x80000),
        "left_option":   (0x20,   0x80000),
        "right_control": (0x2000, 0x40000),
        "left_control":  (0x01,   0x40000),
        "right_shift":   (0x04,   0x20000),
        "left_shift":    (0x02,   0x20000),
        // Fn / Globe: no device-specific left/right bit — it reports as maskSecondaryFn (0x800000). Its
        // logical bit is outside ALL_LOGICAL, so the "other modifier held" guard stays the full
        // shift|ctrl|opt|cmd set: Fn alone engages, Fn+⌘ does not. NOTE (user-side, not this code): some
        // external keyboards handle Fn in firmware and emit no flagsChanged for it, and the Globe key's
        // System Settings action (emoji / dictation / input source) may also fire.
        "fn":            (0x800000, 0x800000),
    ]

    // The UNION of the active PTT modifiers' device bits (any of them engages PTT), and the mask of
    // "any OTHER logical modifier is held" (everything but the selected PTT keys). Both are set together
    // via setPTTKeys and read only on the main run loop (handle + setPTTKeys both run there), so plain
    // vars are safe. Default: Right Option (0x40).
    private var pttDeviceMask: UInt64 = 0x40
    private var otherModsMask: UInt64 = 0x1E0000 & ~0x80000

    /// Select which bare modifier(s) engage PTT — any one of them starts dictation (e.g. Fn on a laptop
    /// OR Right Command on an external keyboard where Fn doesn't report). `names` are MOD_BITS keys;
    /// unknown names are ignored. The live tap is untouched — only which flag bits we test change — so
    /// this applies immediately, mid-session, with no tap teardown. An empty/all-invalid list disables
    /// PTT (mask 0 never matches). MUST be called on the main run loop.
    func setPTTKeys(_ names: [String]) {
        var device: UInt64 = 0
        var logical: UInt64 = 0
        for name in names { if let m = Self.modBits[name] { device |= m.dev; logical |= m.logical } }
        pttDeviceMask = device
        otherModsMask = Self.allLogical & ~logical
    }

    /// Called (on the main run loop) when PTT engages; carries the frontmost app's pid at press.
    var onStart: (@Sendable (Int32) -> Void)?
    /// Called (on the main run loop) when PTT releases (or a missed release self-heals).
    var onStop: (@Sendable () -> Void)?
    /// Called on the main run loop while latched hands-free is silent: `remaining` shrinks 1→0 as the
    /// countdown ring depletes; onCountdownCancel fires when speech resumes.
    var onCountdown: (@Sendable (Double) -> Void)?
    var onCountdownCancel: (@Sendable () -> Void)?

    // Hands-free tunables: fixed feel constants + configurable silence timings.
    private static let tapMax = 0.35, dblWindow = 0.35, silenceLevel = 0.10, silenceTick = 0.1
    private var ringStart = 30.0            // continuous silence before the countdown ring appears
    private var silenceSecs = 40.0          // total silence before auto-stop (ringStart + countdown)

    private var handsfree = false, pending = false
    private var pttWasDown = false          // previous PTT-bit state, to act on the down/up EDGE only
    private var pressT: CFTimeInterval = 0
    private var lastLevel = 0.0, silAccum = 0.0
    private var pendingTimer: Timer?, silTimer: Timer?

    /// Silence auto-stop: the ring appears after `ringAfter`s of silence, then a `countdown`s countdown;
    /// auto-stop at ringAfter+countdown. Main run loop only.
    func setHandsFreeTimings(ringAfter: Double, countdown: Double) {
        ringStart = max(1, ringAfter)
        silenceSecs = ringStart + max(1, countdown)
    }

    /// Fed the runtime's level (0..1) so the silence watch can see the mic. Main run loop only.
    func onLevel(_ rms: Double) { lastLevel = rms }

    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var held = false
    private var retryTimer: Timer?

    func start() {
        requestPermissions()
        ensureTap()
    }

    func stop() {
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let runLoopSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes) }
        tap = nil; runLoopSource = nil
        retryTimer?.invalidate(); retryTimer = nil
        pendingTimer?.invalidate(); pendingTimer = nil
        stopSilenceWatch()
        held = false; handsfree = false; pending = false
    }

    // MARK: - permissions + tap lifecycle

    private func requestPermissions() {
        // No system prompt here: the Welcome window asks for Accessibility (its button), so nothing pops up
        // before it on first run. Until access is granted, ensureTap() keeps retrying.
        // No Input Monitoring request: an Accessibility-trusted process may create keyboard taps, so
        // Accessibility alone covers the push-to-talk key (verified on a daily Mac with no Input Monitoring grant).
    }

    private func ensureTap() {
        guard tap == nil else { return }
        guard AXIsProcessTrusted() else { scheduleRetry(); return }
        if !createTap() { scheduleRetry() } else { retryTimer?.invalidate(); retryTimer = nil }
    }

    private func scheduleRetry() {
        guard retryTimer == nil else { return }
        retryTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] timer in
            guard let self else { timer.invalidate(); return }
            if self.tap != nil { timer.invalidate(); self.retryTimer = nil; return }
            if AXIsProcessTrusted(), self.createTap() { timer.invalidate(); self.retryTimer = nil }
        }
    }

    private func createTap() -> Bool {
        let mask = (1 << CGEventType.flagsChanged.rawValue) | (1 << CGEventType.keyDown.rawValue)
        let userInfo = Unmanaged.passUnretained(self).toOpaque()   // self outlives the tap (held by AppController)
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap,
                                          options: .listenOnly, eventsOfInterest: CGEventMask(mask),
                                          callback: hotkeyTapCallback, userInfo: userInfo) else {
            return false
        }
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        self.tap = tap
        self.runLoopSource = source
        return true
    }

    // MARK: - event handling (main run loop)

    fileprivate func handle(type: CGEventType, event: CGEvent) {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }   // re-enable if the system disabled us
            return
        }
        let flags = event.flags.rawValue
        if type == .keyDown {
            // Self-heal a missed/coalesced release (only when NOT latched): a keyDown while we think
            // we're held but the PTT modifier is up means the release event was lost.
            if held && !handsfree && (flags & pttDeviceMask) == 0 { pttWasDown = false; doStop() }
            return
        }
        // flagsChanged: act on the PTT bit's EDGE, not on it merely being set — otherwise ANY modifier
        // change while the PTT key is held (e.g. tapping Shift) would read as a press and stop/restart.
        let pttDown = (flags & pttDeviceMask) != 0
        let pressed = pttDown && !pttWasDown
        let released = !pttDown && pttWasDown
        pttWasDown = pttDown
        let otherHeld = (flags & otherModsMask) != 0
        if pressed {
            if handsfree { doStop(); return }                          // a tap while latched = stop
            if pending {                                               // second tap in the window = latch hands-free
                pending = false; pendingTimer?.invalidate(); pendingTimer = nil
                handsfree = true
                startSilenceWatch()
                return
            }
            if !held && !otherHeld {                                   // key alone = dictation; key+mod = a normal hotkey
                held = true
                pressT = CACurrentMediaTime()
                beginDictation()
            }
        } else if released {
            if handsfree { return }                                    // release of the latching tap: stay latched
            guard held else { return }
            held = false
            if CACurrentMediaTime() - pressT >= Self.tapMax {
                doStop()                                               // a hold: normal momentary stop
            } else {
                pending = true                                         // a quick tap: wait for a possible second tap
                pendingTimer?.invalidate()
                pendingTimer = scheduleCommon(Self.dblWindow) { [weak self] in
                    guard let self, self.pending else { return }
                    self.pending = false; self.pendingTimer = nil
                    self.doStop()
                }
            }
        }
    }

    /// Schedule a one-shot main-thread timer in the COMMON run-loop mode, so it still fires while a menu
    /// or other modal loop is tracking (the default mode is paused then). The tap's own source is added
    /// in common mode too, so this keeps timing consistent with events.
    private func scheduleCommon(_ interval: TimeInterval, _ block: @escaping @Sendable () -> Void) -> Timer {
        let timer = Timer(timeInterval: interval, repeats: false) { _ in MainActor.assumeIsolated { block() } }
        RunLoop.main.add(timer, forMode: .common)
        return timer
    }

    private func beginDictation() {
        let pid = MainActor.assumeIsolated {   // the tap's run-loop source is on the main run loop
            NSWorkspace.shared.frontmostApplication?.processIdentifier ?? -1
        }
        onStart?(pid)
    }

    /// Abort an in-progress recording WITHOUT emitting `onStop` — used by the double-Esc cancel
    /// gesture, which tells the runtime to discard the take itself. Clears all recording state and
    /// timers so the eventual PTT release (or a coalesced-keyDown self-heal) takes the guarded no-op
    /// path instead of sending a stray `.stop`. `pttWasDown` is left as-is: the physical key may still
    /// be down, and the next release edge clears it while `held == false` makes that edge a no-op.
    /// Main run loop only.
    func abortRecording() {
        stopSilenceWatch()
        pendingTimer?.invalidate(); pendingTimer = nil
        held = false; handsfree = false; pending = false
    }

    /// One stop path: hold-release, single-tap, tap-while-latched, silence timeout.
    private func doStop() {
        stopSilenceWatch()
        handsfree = false; pending = false
        pendingTimer?.invalidate(); pendingTimer = nil
        held = false
        onStop?()
    }

    private func stopSilenceWatch() {
        silTimer?.invalidate(); silTimer = nil
        silAccum = 0
    }

    /// While latched: sample the mic level; RING_START of continuous silence shows the countdown ring,
    /// SILENCE_SECS auto-stops; any speech resets and cancels the ring.
    private func startSilenceWatch() {
        stopSilenceWatch()
        silAccum = 0
        onCountdownCancel?()
        let timer = Timer(timeInterval: Self.silenceTick, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                guard self.handsfree else { self.stopSilenceWatch(); return }
                if self.lastLevel >= Self.silenceLevel {
                    if self.silAccum > 0 { self.onCountdownCancel?() }
                    self.silAccum = 0
                } else {
                    self.silAccum += Self.silenceTick
                    if self.silAccum >= self.ringStart {
                        let remaining = (self.silenceSecs - self.silAccum) / (self.silenceSecs - self.ringStart)
                        self.onCountdown?(remaining)
                    }
                    if self.silAccum >= self.silenceSecs { self.doStop() }
                }
            }
        }
        RunLoop.main.add(timer, forMode: .common)   // keep sampling while a menu/modal loop is tracking
        silTimer = timer
    }
}

/// C trampoline: recover the HotkeyTap from userInfo and forward. Runs on the main run loop (the tap's
/// source is added there), so `handle` is effectively single-threaded / main-actor.
private let hotkeyTapCallback: CGEventTapCallBack = { _, type, event, userInfo in
    if let userInfo {
        Unmanaged<HotkeyTap>.fromOpaque(userInfo).takeUnretainedValue().handle(type: type, event: event)
    }
    return Unmanaged.passUnretained(event)
}
