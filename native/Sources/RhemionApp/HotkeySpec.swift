// HotkeySpec — the single source of truth for global-hotkey chord strings ("cmd+option+r"), shared by
// RecallHotkey (Carbon registration) and the settings recorder (capture NSEvent → spec, and pretty
// display). Keeping parse, key-code mapping, and formatting here means the recorder can only ever
// produce a chord RecallHotkey can bind.
//
// Spec grammar: modifier tokens (cmd/command, opt/option/alt, ctrl/control, shift) joined by "+" with a
// final key (a letter a-z or digit 0-9). At least one modifier + a key. "off"/"none"/"" = disabled.

import AppKit
import Carbon

enum HotkeySpec {
    /// ANSI virtual key codes for letters and digits (covers realistic dictation chords).
    static let keyCodeByName: [String: Int] = [
        "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9,
        "b": 11, "q": 12, "w": 13, "e": 14, "r": 15, "y": 16, "t": 17, "o": 31, "u": 32,
        "i": 34, "p": 35, "l": 37, "j": 38, "k": 40, "n": 45, "m": 46,
        "1": 18, "2": 19, "3": 20, "4": 21, "5": 23, "6": 22, "7": 26, "8": 28, "9": 25, "0": 29,
    ]
    private static let nameByKeyCode: [Int: String] =
        Dictionary(uniqueKeysWithValues: keyCodeByName.map { ($0.value, $0.key) })

    /// Modifier tokens in a stable output order ("cmd+option+…" style).
    private static let orderedModifiers: [(token: String, flag: NSEvent.ModifierFlags, carbon: Int)] = [
        ("cmd", .command, cmdKey), ("option", .option, optionKey),
        ("control", .control, controlKey), ("shift", .shift, shiftKey),
    ]
    private static let modifierAliases: [String: NSEvent.ModifierFlags] = [
        "cmd": .command, "command": .command, "opt": .option, "option": .option, "alt": .option,
        "ctrl": .control, "control": .control, "shift": .shift,
    ]

    static func isDisabled(_ spec: String) -> Bool {
        let s = spec.lowercased().replacingOccurrences(of: " ", with: "")
        return s.isEmpty || s == "off" || s == "none"
    }

    /// Parse a spec into a Carbon modifier mask + key code for RegisterEventHotKey, or nil if disabled
    /// or unparseable.
    static func carbon(_ spec: String) -> (modifiers: UInt32, keyCode: UInt32)? {
        guard !isDisabled(spec) else { return nil }
        let parts = spec.lowercased().replacingOccurrences(of: " ", with: "").split(separator: "+").map(String.init)
        guard parts.count >= 2, let last = parts.last, let keyCode = keyCodeByName[last] else { return nil }
        var mask = 0
        for token in parts.dropLast() {
            guard let flag = modifierAliases[token] else { return nil }
            for m in orderedModifiers where m.flag == flag { mask |= m.carbon }
        }
        guard mask != 0 else { return nil }
        return (UInt32(mask), UInt32(keyCode))
    }

    /// Build a spec from a captured key event. Returns nil unless there is at least one modifier and a
    /// mappable key (so a bare key or a modifier-only press is rejected, matching the recall grammar).
    static func spec(modifierFlags: NSEvent.ModifierFlags, keyCode: UInt16) -> String? {
        guard let key = nameByKeyCode[Int(keyCode)] else { return nil }
        let mods = orderedModifiers.filter { modifierFlags.contains($0.flag) }.map(\.token)
        guard !mods.isEmpty else { return nil }
        return (mods + [key]).joined(separator: "+")
    }

    /// The chord as ORDERED display caps, e.g. "cmd+option+r" -> ["⌘","⌥","R"]. Disabled -> [] (so the
    /// recorder field shows its placeholder). Used to render each key as its own cap chip.
    static func caps(_ spec: String) -> [String] {
        guard !isDisabled(spec) else { return [] }
        let parts = spec.lowercased().replacingOccurrences(of: " ", with: "").split(separator: "+").map(String.init)
        guard let last = parts.last else { return [] }
        return parts.dropLast().map { symbol($0) } + [last.uppercased()]
    }

    /// The modifier symbols currently held, in canonical order — for the live preview while recording.
    static func modifierCaps(_ flags: NSEvent.ModifierFlags) -> [String] {
        orderedModifiers.filter { flags.contains($0.flag) }.map { symbol($0.token) }
    }

    private static func symbol(_ token: String) -> String {
        ["cmd": "⌘", "command": "⌘", "opt": "⌥", "option": "⌥", "alt": "⌥",
         "ctrl": "⌃", "control": "⌃", "shift": "⇧"][token] ?? token.uppercased()
    }

    /// Pretty form for the UI, e.g. "cmd+option+r" -> "⌘⌥R". Disabled -> "None".
    static func display(_ spec: String) -> String {
        guard !isDisabled(spec) else { return "None" }
        let symbols: [String: String] = ["cmd": "⌘", "command": "⌘", "opt": "⌥", "option": "⌥",
                                         "alt": "⌥", "ctrl": "⌃", "control": "⌃", "shift": "⇧"]
        let parts = spec.lowercased().replacingOccurrences(of: " ", with: "").split(separator: "+").map(String.init)
        guard let last = parts.last else { return "None" }
        let prefix = parts.dropLast().map { symbols[$0] ?? $0 }.joined()
        return prefix + last.uppercased()
    }
}
