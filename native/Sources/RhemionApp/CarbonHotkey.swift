// CarbonHotkey — one global hotkey registered via Carbon RegisterEventHotKey, which keeps firing under
// macOS Secure Keyboard Entry (where a CGEventTap never sees letter key-downs). Multiple global
// hotkeys (recall, dict-add, …) share ONE event handler installed once by CarbonHotkeyDispatcher; the
// handler reads the fired hotkey's id and routes to the matching instance. A single shared handler
// avoids the ambiguity of installing the same handler proc on the app target more than once.
//
// setHotkey/suspend/stop run on the main run loop; onPress is delivered on the main queue.

import AppKit
import Carbon

private let hotkeySignature: OSType = 0x52484B31   // 'RHK1'

final class CarbonHotkey: @unchecked Sendable {
    /// Fired (on the main queue) when THIS hotkey is pressed.
    var onPress: (@Sendable () -> Void)?

    private let id: UInt32
    private var ref: EventHotKeyRef?

    init(id: UInt32) { self.id = id }

    /// (Re)bind to `spec` (e.g. "cmd+option+w"). Returns true if a chord is now bound; false if the spec
    /// is disabled/unparseable or registration failed. Main run loop only.
    @discardableResult
    func setHotkey(_ spec: String) -> Bool {
        unregister()
        guard let (modifiers, keyCode) = HotkeySpec.carbon(spec) else { return false }
        // Don't reserve a chord if the shared handler isn't installed — it would never dispatch.
        guard CarbonHotkeyDispatcher.shared.register(id: id, hotkey: self) else { return false }
        var newRef: EventHotKeyRef?
        let hotKeyID = EventHotKeyID(signature: hotkeySignature, id: id)
        guard RegisterEventHotKey(keyCode, modifiers, hotKeyID, GetApplicationEventTarget(), 0, &newRef) == noErr,
              newRef != nil else {
            CarbonHotkeyDispatcher.shared.unregister(id: id)
            return false
        }
        ref = newRef
        return true
    }

    /// Temporarily unbind the chord (so a settings recorder can capture keystrokes, including this
    /// hotkey's current chord). Rebind with setHotkey.
    func suspend() { unregister() }

    func stop() { unregister() }

    private func unregister() {
        if let ref { UnregisterEventHotKey(ref); self.ref = nil }
        CarbonHotkeyDispatcher.shared.unregister(id: id)
    }

    fileprivate func fire() { DispatchQueue.main.async { [weak self] in self?.onPress?() } }
}

/// A set of global chords that all fire ONE action (multi-binding). Each spec gets its own CarbonHotkey
/// under baseID + index; binding, suspend and stop apply to the whole group. `onPress` is shared, so a
/// press of any bound chord triggers the same handler. Ids per action use disjoint ranges (recall 10+,
/// dict-add 20+, undo 30+), so the caps below never let them overlap. Main run loop only.
final class CarbonHotkeyGroup: @unchecked Sendable {
    /// Fired (on the main queue) when ANY of the bound chords is pressed.
    var onPress: (@Sendable () -> Void)?

    private let baseID: UInt32
    private let maxBindings: Int
    private var hotkeys: [CarbonHotkey] = []

    init(baseID: UInt32, maxBindings: Int = 8) { self.baseID = baseID; self.maxBindings = maxBindings }

    /// (Re)bind to the given chord specs (rebuilds the group). Disabled/unparseable specs are skipped;
    /// returns how many chords are now bound. At most `maxBindings` are taken.
    @discardableResult
    func setHotkeys(_ specs: [String]) -> Int {
        hotkeys.forEach { $0.stop() }
        hotkeys.removeAll()
        for (index, spec) in specs.prefix(maxBindings).enumerated() {
            let hotkey = CarbonHotkey(id: baseID + UInt32(index))
            hotkey.onPress = { [weak self] in self?.onPress?() }
            if hotkey.setHotkey(spec) { hotkeys.append(hotkey) }
        }
        return hotkeys.count
    }

    /// Temporarily unbind every chord (so a settings recorder can capture keystrokes). Rebind via setHotkeys.
    func suspend() { hotkeys.forEach { $0.suspend() } }
    func stop() { hotkeys.forEach { $0.stop() }; hotkeys.removeAll() }
}

/// Owns the single Carbon event handler and an id → CarbonHotkey registry. All access is on the main
/// run loop (register/unregister from setHotkey/stop; dispatch from the Carbon handler, which Carbon
/// delivers on the main event loop), guarded by a lock as defense-in-depth.
final class CarbonHotkeyDispatcher: @unchecked Sendable {
    static let shared = CarbonHotkeyDispatcher()

    private let lock = NSLock()
    private var handler: EventHandlerRef?
    private var byID: [UInt32: CarbonHotkey] = [:]

    /// Register `hotkey` under `id`, installing the shared handler if needed. Returns false if the
    /// handler could not be installed — the caller then must not reserve a chord that never dispatches.
    @discardableResult
    func register(id: UInt32, hotkey: CarbonHotkey) -> Bool {
        ensureHandler()
        lock.lock(); defer { lock.unlock() }
        guard handler != nil else { return false }
        byID[id] = hotkey
        return true
    }

    func unregister(id: UInt32) {
        lock.lock(); byID[id] = nil; lock.unlock()
    }

    private func ensureHandler() {
        lock.lock(); let installed = handler != nil; lock.unlock()
        guard !installed else { return }
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                      eventKind: UInt32(kEventHotKeyPressed))
        var newHandler: EventHandlerRef?
        let status = InstallEventHandler(GetApplicationEventTarget(), carbonHotkeyDispatch, 1, &eventType,
                                         nil, &newHandler)
        if status == noErr {
            lock.lock(); handler = newHandler; lock.unlock()
        } else {
            log("hotkeys: InstallEventHandler failed (status \(status))")
        }
    }

    fileprivate func dispatch(id: UInt32) {
        lock.lock(); let hotkey = byID[id]; lock.unlock()
        hotkey?.fire()
    }
}

/// C trampoline: read which hotkey fired and route it through the dispatcher.
private let carbonHotkeyDispatch: EventHandlerUPP = { _, event, _ in
    guard let event else { return noErr }
    var firedID = EventHotKeyID()
    let status = GetEventParameter(event, EventParamName(kEventParamDirectObject),
                                   EventParamType(typeEventHotKeyID), nil,
                                   MemoryLayout<EventHotKeyID>.size, nil, &firedID)
    guard status == noErr else { return noErr }
    CarbonHotkeyDispatcher.shared.dispatch(id: firedID.id)
    return noErr
}
