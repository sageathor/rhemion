// PinnedWindow — "Pin to this window" (3.1). While a window is pinned, every dictation goes to
// its field, wherever the user works. Two behaviours (Settings › General):
//   stay (default)  pressing the dictation key brings the pinned window forward at once; the user stays there.
//   return          the user keeps working where they are; when the text is ready the pinned window comes forward
//                   for a moment, the text goes in at its caret, and the previous window comes back.
// Pin / unpin: the global chord (default ⌥⌘P), the menu-bar menu, or a click on the resting orb at the notch.
// The pin ends on its own when the window is gone (checked every few seconds and before each delivery) or, when
// enabled, after an interval. It is never kept across launches.

@preconcurrency import AppKit
import Foundation

@MainActor
final class PinnedWindow {
    private(set) var target: TargetSnapshot?
    private var expiry: Timer?
    private var alive: Timer?
    private let hotkeys = CarbonHotkeyGroup(baseID: 40)   // pin: ids 40..47
    /// Called after every pin / unpin (menu title, the notch's resting orb).
    var onChange: ((_ pinned: Bool) -> Void)?
    var isPinned: Bool { target != nil }

    init() {
        hotkeys.onPress = { [weak self] in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.toggle() } }
        }
    }

    func setHotkeys(_ specs: [String]) { log("pin: bound \(hotkeys.setHotkeys(specs)) of \(specs.count) binding(s)") }
    func suspend() { hotkeys.suspend() }

    /// Pin the window the user is working in (the frontmost app, never Rhemion itself), or unpin.
    func toggle() {
        if isPinned { unpin(reason: "by the user"); return }
        guard let front = NSWorkspace.shared.frontmostApplication,
              front.processIdentifier != ProcessInfo.processInfo.processIdentifier else {
            log("pin: nothing to pin (Rhemion is in front)"); return
        }
        let snap = TargetSnapshot.capture(pid: Int(front.processIdentifier))
        guard snap.window != nil else { log("pin: the front app has no window"); return }
        target = snap
        log("pin: pinned \(front.localizedName ?? "app") (field \(snap.editable ? "focused" : "none"))")
        armTimers()
        onChange?(true)
    }

    func unpin(reason: String) {
        guard isPinned else { return }
        target = nil
        expiry?.invalidate(); expiry = nil
        alive?.invalidate(); alive = nil
        log("pin: unpinned (\(reason))")
        onChange?(false)
    }

    /// Settings › General: auto-unpin after `minutes` (0 = never), applied to the current pin and future ones.
    var autoUnpinMinutes = 0 { didSet { if isPinned { armTimers() } } }

    private func armTimers() {
        expiry?.invalidate(); expiry = nil
        if autoUnpinMinutes > 0 {
            expiry = Timer.scheduledTimer(withTimeInterval: Double(autoUnpinMinutes) * 60, repeats: false) { [weak self] _ in
                MainActor.assumeIsolated { self?.unpin(reason: "after \(self?.autoUnpinMinutes ?? 0) min") }
            }
        }
        alive?.invalidate()
        alive = Timer.scheduledTimer(withTimeInterval: 4, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let t = self.target else { return }
                if !Self.windowExists(t) { self.unpin(reason: "the window is gone") }
            }
        }
    }

    /// The pinned app is still running and its window still answers Accessibility.
    static func windowExists(_ t: TargetSnapshot) -> Bool {
        guard let app = NSRunningApplication(processIdentifier: pid_t(t.pid)), !app.isTerminated, let window = t.window else { return false }
        var role: CFTypeRef?
        // Only "no such element" means closed: a background app can answer "cannot complete" for a moment.
        return AXUIElementCopyAttributeValue(window, kAXRoleAttribute as CFString, &role) != .invalidUIElement
    }

    /// Whether the user is in the pinned window right now (then nothing is moved: their caret is the place).
    func isInFront() -> Bool {
        guard let t = target, let w = t.window,
              NSWorkspace.shared.frontmostApplication?.processIdentifier == pid_t(t.pid) else { return false }
        let now = TargetSnapshot.capture(pid: t.pid)
        return now.window.map { CFEqual($0, w) } ?? false
    }

    /// After text went in (or when the user worked there): remember the pinned field's current caret, so the next
    /// dictation continues after this one instead of at the caret from the moment of pinning.
    func refresh() {
        guard let t = target, let w = t.window else { return }
        let now = TargetSnapshot.capture(pid: t.pid)
        if let nw = now.window, CFEqual(nw, w), now.element != nil { target = now }
    }

    /// Bring the pinned field forward (app, window, field, caret). Unpins when the window is gone.
    /// Returns whether the focus is in the pinned field now. Already there: nothing is moved.
    func bringForward() -> Bool {
        guard let t = target else { return false }
        guard Self.windowExists(t) else { unpin(reason: "the window is gone"); return false }
        if isInFront() { refresh(); return true }
        let (match, detail) = t.restoreFocus()
        log("pin: brought forward \(match.rawValue) (\(detail))")
        return match == .sameElement || match == .sameField
    }
}
