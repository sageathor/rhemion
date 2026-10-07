// DictAdd — a global hotkey that adds a word to the recognition dictionary from the current text
// selection. On the press it reads the AX selection (BEFORE any panel opens, so
// the original field is still focused) and hands it to the app, which opens the "as heard → correct"
// panel and writes the replacement to active/dictionary.json (the runtime hot-reloads it).
//
// Global CarbonHotkey (fires under Secure Keyboard Entry). Default Cmd+Option+W.

import Foundation

final class DictAdd: @unchecked Sendable {
    /// Fired on the main queue with the current selection ("" if none) when the chord is pressed. The
    /// selection is read here, before the panel steals focus — that ordering is the whole point.
    var onTrigger: (@Sendable (String, AXSelection.Target?) -> Void)?

    private let hotkeys = CarbonHotkeyGroup(baseID: 20)   // dict-add: ids 20..27

    init() { hotkeys.onPress = { [weak self] in self?.fired() } }

    /// (Re)bind the dict-add chords (any of them triggers; "off"/"none"/"" entries disable). Main run loop only.
    func setHotkeys(_ specs: [String]) {
        log("dict-add: bound \(hotkeys.setHotkeys(specs)) of \(specs.count) binding(s)")
    }

    /// Temporarily unbind so a settings recorder can capture keystrokes (including the current chords).
    func suspend() { hotkeys.suspend() }

    func stop() { hotkeys.stop() }

    private func fired() {   // main run loop
        log("dict-add: pressed")
        onTrigger?(AXSelection.currentSelection() ?? "", AXSelection.currentTarget())
    }
}
