// Where a dictation started: the app, its focused window and focused field, captured at the press, so the
// delivery can tell whether focus is still there (3.1 "perfect insertion"). The capture runs off the hot path
// with a short AX timeout. Chromium can hand out a new AX object for the same field after a re-render, so a
// field is also matched by a fingerprint (role, DOM id, placeholder, title, position) when the object differs.
// Enforced at delivery (3.1): another app, another window, or a jump from one text field to
// another keeps the text in the Journal instead of typing it into the wrong place; a field picked while speaking
// (no text field had focus at the press) receives it.

@preconcurrency import AppKit
import ApplicationServices
import Foundation

struct TargetSnapshot: @unchecked Sendable {
    struct Fingerprint: Equatable, Sendable {
        let role: String?
        let subrole: String?
        let domID: String?
        let placeholder: String?
        let title: String?
        let origin: CGPoint?
    }

    let pid: Int
    let window: AXUIElement?
    let windowTitle: String?
    /// The window's frame at capture: with the title, how a re-created AX window object is recognised. A title
    /// alone is not enough (two untitled documents, two windows on the same page).
    var windowFrame: CGRect? = nil
    let element: AXUIElement?
    let fingerprint: Fingerprint?
    /// A text field had focus at the press (the focused element reports a selection range).
    let editable: Bool
    /// The caret / selection at the press, put back after a refocus (a contenteditable otherwise puts the caret
    /// at the start when it regains focus, as the bench showed).
    var selection: CFRange? = nil

    enum Match: String, Sendable {
        case sameElement = "same-element"   // the very AX object: certain
        case sameField = "same-field"       // a new object with the same fingerprint in the same window
        case otherField = "other-field"     // same window, a different field
        case otherWindow = "other-window"   // same app, a different window or tab
        case otherApp = "other-app"
        case unknown                        // AX gives too little to tell
    }

    static let axTimeout: Float = 0.1

    /// Reads the focused window and field of `pid`. Never throws; missing pieces stay nil.
    static func capture(pid: Int) -> TargetSnapshot {
        let app = AXUIElementCreateApplication(pid_t(pid))
        AXUIElementSetMessagingTimeout(app, axTimeout)
        let window = element(app, kAXFocusedWindowAttribute)
        let field = element(app, kAXFocusedUIElementAttribute)
        return TargetSnapshot(
            pid: pid, window: window, windowTitle: window.flatMap { string($0, kAXTitleAttribute) },
            windowFrame: window.flatMap(frame),
            element: field, fingerprint: field.map(fingerprint), editable: field.map(hasSelection) ?? false,
            selection: field.flatMap(selectedRange)
        )
    }

    /// Compares this snapshot with what is focused now. `detail` is for the log.
    func matchNow() -> (match: Match, detail: String) {
        guard let front = NSWorkspace.shared.frontmostApplication.map({ Int($0.processIdentifier) }) else {
            return (.unknown, "no frontmost app")
        }
        guard front == pid else { return (.otherApp, "pid \(pid) → \(front)") }
        let now = TargetSnapshot.capture(pid: pid)
        let role = fingerprint?.role ?? "-"
        if let a = element, let b = now.element, CFEqual(a, b) { return (.sameElement, role) }
        // The same window: the same AX object, or (an app that re-creates it) the same title AND the same frame.
        // Log details carry roles only, never titles or DOM ids (they can hold the user's own text).
        let sameWindow: Bool? = {
            if let a = window, let b = now.window {
                if CFEqual(a, b) { return true }
                guard let t = windowTitle, t == now.windowTitle, let f = windowFrame, let g = now.windowFrame else { return false }
                return abs(f.minX - g.minX) < 1 && abs(f.minY - g.minY) < 1 && abs(f.width - g.width) < 1 && abs(f.height - g.height) < 1
            }
            return nil
        }()
        if sameWindow == false { return (.otherWindow, role) }
        guard let f0 = fingerprint, let f1 = now.fingerprint else {
            return (.unknown, "field \(element == nil ? "unreadable" : "readable") → \(now.element == nil ? "unreadable" : "readable")")
        }
        if f0 == f1 { return (.sameField, role) }
        return (.otherField, "\(role) → \(f1.role ?? "-")")
    }

    /// Whether a delivery may go ahead given this match. Another app or window keeps the text; another field
    /// keeps it only when the dictation started in a text field (a field chosen while speaking is the intent).
    func allows(_ match: Match) -> Bool {
        switch match {
        case .sameElement, .sameField, .unknown: return true
        case .otherApp, .otherWindow: return false
        case .otherField: return !editable
        }
    }

    /// Brings the target back: activates its app, raises its window and focuses its field, then waits (up to
    /// `budgetMS`) until the focus really is that field again. Returns the final match; insert only on
    /// `.sameElement` / `.sameField`. Main thread (activation and AX raise must not race the user).
    /// Set while a refocus is waiting on the main run loop: a press or click that arrives meanwhile must not start
    /// a second, nested refocus (it would restore an older caret after the newer one).
    @MainActor private static var restoring = false

    @MainActor
    func restoreFocus(budgetMS: Int = 600) -> (match: Match, detail: String) {
        guard !Self.restoring else { return (matchNow().match, "busy") }
        Self.restoring = true; defer { Self.restoring = false }
        if let app = NSRunningApplication(processIdentifier: pid_t(pid)), !app.isActive {
            Self.bringToFront(app)
        }
        if let window {
            AXUIElementSetAttributeValue(window, kAXMainAttribute as CFString, kCFBooleanTrue)
            AXUIElementPerformAction(window, kAXRaiseAction as CFString)
        }
        if let element { AXUIElementSetAttributeValue(element, kAXFocusedAttribute as CFString, kCFBooleanTrue) }
        let t0 = DispatchTime.now().uptimeNanoseconds
        var last = matchNow()
        while last.match != .sameElement && last.match != .sameField {
            if Int((DispatchTime.now().uptimeNanoseconds - t0) / 1_000_000) >= budgetMS { break }
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.03))
            if let element { AXUIElementSetAttributeValue(element, kAXFocusedAttribute as CFString, kCFBooleanTrue) }
            last = matchNow()
        }
        if last.match == .sameElement || last.match == .sameField, let selection, let element {
            var range = selection
            if let value = AXValueCreate(.cfRange, &range) {
                AXUIElementSetAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, value)
                RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.03))
            }
        }
        return last
    }

    /// Bring another app to the front from Rhemion, which usually runs in the background. Since macOS 14 a
    /// background app's `activate()` is refused (cooperative activation), so fall back to Accessibility: the
    /// app element's AXFrontmost (what Hammerspoon and similar tools use).
    @MainActor
    static func bringToFront(_ app: NSRunningApplication) {
        if app.activate(), waitFront(app) { return }
        let element = AXUIElementCreateApplication(app.processIdentifier)
        let err = AXUIElementSetAttributeValue(element, kAXFrontmostAttribute as CFString, kCFBooleanTrue)
        let ok = waitFront(app)
        log("front: \(app.localizedName ?? "app") via AXFrontmost (\(err.rawValue)) \(ok ? "ok" : "refused")")
    }

    @MainActor
    private static func waitFront(_ app: NSRunningApplication, ms: Int = 250) -> Bool {
        let t0 = DispatchTime.now().uptimeNanoseconds
        while NSWorkspace.shared.frontmostApplication?.processIdentifier != app.processIdentifier {
            if Int((DispatchTime.now().uptimeNanoseconds - t0) / 1_000_000) >= ms { return false }
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.02))
        }
        return true
    }

    // MARK: - AX helpers

    private static func selectedRange(_ e: AXUIElement) -> CFRange? {
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(e, kAXSelectedTextRangeAttribute as CFString, &v) == .success,
              let v, CFGetTypeID(v) == AXValueGetTypeID() else { return nil }
        var r = CFRange()
        return AXValueGetValue(unsafeDowncast(v, to: AXValue.self), .cfRange, &r) ? r : nil
    }

    private static func hasSelection(_ e: AXUIElement) -> Bool {
        var v: CFTypeRef?
        return AXUIElementCopyAttributeValue(e, kAXSelectedTextRangeAttribute as CFString, &v) == .success && v != nil
    }

    private static func fingerprint(_ e: AXUIElement) -> Fingerprint {
        Fingerprint(
            role: string(e, kAXRoleAttribute), subrole: string(e, kAXSubroleAttribute),
            domID: string(e, "AXDOMIdentifier"), placeholder: string(e, kAXPlaceholderValueAttribute),
            title: string(e, kAXTitleAttribute) ?? string(e, kAXDescriptionAttribute),
            origin: point(e, kAXPositionAttribute)
        )
    }

    private static func element(_ e: AXUIElement, _ name: String) -> AXUIElement? {
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(e, name as CFString, &v) == .success, let v,
              CFGetTypeID(v) == AXUIElementGetTypeID() else { return nil }
        return unsafeDowncast(v, to: AXUIElement.self)
    }

    private static func string(_ e: AXUIElement, _ name: String) -> String? {
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(e, name as CFString, &v) == .success else { return nil }
        return v as? String
    }

    private static func frame(_ e: AXUIElement) -> CGRect? {
        guard let p = point(e, kAXPositionAttribute) else { return nil }
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(e, kAXSizeAttribute as CFString, &v) == .success, let v,
              CFGetTypeID(v) == AXValueGetTypeID() else { return nil }
        var size = CGSize.zero
        return AXValueGetValue(unsafeDowncast(v, to: AXValue.self), .cgSize, &size) ? CGRect(origin: p, size: size) : nil
    }

    private static func point(_ e: AXUIElement, _ name: String) -> CGPoint? {
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(e, name as CFString, &v) == .success, let v,
              CFGetTypeID(v) == AXValueGetTypeID() else { return nil }
        var p = CGPoint.zero
        return AXValueGetValue(unsafeDowncast(v, to: AXValue.self), .cgPoint, &p) ? p : nil
    }
}

/// Snapshots in flight: one slot per press, bound to the runtime session when `started` arrives (the runtime
/// answers presses in order), looked up when that session's text is delivered.
final class TargetStore: @unchecked Sendable {
    private final class Slot: @unchecked Sendable {
        var snapshot: TargetSnapshot?
        var pinReturn = false
        let at = DispatchTime.now().uptimeNanoseconds
    }
    private let lock = NSLock()
    private let queue = DispatchQueue(label: "com.sageathor.rhemion.app.target", qos: .userInitiated)
    private var unbound: [Slot] = []
    private var bySession: [String: Slot] = [:]

    /// At the press with a known target (a pinned window): no capture, this is where the text goes.
    /// `pinReturn`: the take is delivered by jumping to the pinned window and coming back.
    func pressed(snapshot: TargetSnapshot, pinReturn: Bool) {
        let slot = Slot(); slot.snapshot = snapshot; slot.pinReturn = pinReturn
        lock.withLock { unbound.append(slot) }
    }

    /// Whether this session's take goes to the pinned window by "insert there, come back".
    func isPinReturn(session: String) -> Bool { lock.withLock { bySession[session]?.pinReturn ?? false } }

    /// At the press: reserve a slot now (order matters), fill it off the hot path.
    func pressed(pid: Int) {
        let slot = Slot()
        lock.withLock {
            let cutoff = slot.at &- 10_000_000_000   // a press with no `started` in 10 s never got one
            unbound.removeAll { $0.at < cutoff }
            unbound.append(slot)
        }
        queue.async {
            let snap = TargetSnapshot.capture(pid: pid)
            self.lock.withLock { slot.snapshot = snap }
        }
    }

    func started(session: String) {
        lock.withLock {
            guard !unbound.isEmpty else { return }
            bySession[session] = unbound.removeFirst()
            if bySession.count > 16 {   // deliveries normally take them out; never grow without bound
                let oldest = bySession.min { $0.value.at < $1.value.at }!.key
                bySession[oldest] = nil
            }
        }
    }

    /// The press's snapshot for this session, removed from the store. Waits briefly if the capture is still running.
    func take(session: String) -> TargetSnapshot? {
        guard let slot = lock.withLock({ bySession.removeValue(forKey: session) }) else { return nil }
        queue.sync {}   // the capture for this slot was queued before; let it finish
        return lock.withLock { slot.snapshot }
    }
}
