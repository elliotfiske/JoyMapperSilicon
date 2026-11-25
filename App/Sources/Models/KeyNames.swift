import Carbon.HIToolbox
import Foundation

/// Media and display keys that aren't ordinary key codes. They're sent as system-defined events
/// (`NX_KEYTYPE_*`), so they live above the virtual key code range.
enum SpecialKey {
    static let base = 0x7000
    static let brightnessUp = base + 2   // NX_KEYTYPE_BRIGHTNESS_UP
    static let brightnessDown = base + 3 // NX_KEYTYPE_BRIGHTNESS_DOWN
    static let play = base + 16          // NX_KEYTYPE_PLAY
    static let next = base + 17          // NX_KEYTYPE_NEXT
    static let previous = base + 18      // NX_KEYTYPE_PREVIOUS
    static let fast = base + 19          // NX_KEYTYPE_FAST
    static let rewind = base + 20        // NX_KEYTYPE_REWIND

    /// Key codes that have to go out as system-defined events, mapped to their `NX_KEYTYPE_*`.
    static let systemDefined: [Int: Int32] = [
        kVK_VolumeUp: 0,   // NX_KEYTYPE_SOUND_UP
        kVK_VolumeDown: 1, // NX_KEYTYPE_SOUND_DOWN
        kVK_Mute: 7,       // NX_KEYTYPE_MUTE
        brightnessUp: 2,
        brightnessDown: 3,
        play: 16,
        next: 17,
        previous: 18,
        fast: 19,
        rewind: 20,
    ]
}

enum KeyNames {
    static func name(for code: Int) -> String {
        names[code] ?? "Key \(code)"
    }

    /// Every key the editor offers, sorted by name.
    static let all: [(code: Int, name: String)] = names
        .map { (code: $0.key, name: $0.value) }
        .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }

    static let names: [Int: String] = letters.merging(others) { first, _ in first }

    private static let letters: [Int: String] = [
        kVK_ANSI_A: "A", kVK_ANSI_B: "B", kVK_ANSI_C: "C", kVK_ANSI_D: "D",
        kVK_ANSI_E: "E", kVK_ANSI_F: "F", kVK_ANSI_G: "G", kVK_ANSI_H: "H",
        kVK_ANSI_I: "I", kVK_ANSI_J: "J", kVK_ANSI_K: "K", kVK_ANSI_L: "L",
        kVK_ANSI_M: "M", kVK_ANSI_N: "N", kVK_ANSI_O: "O", kVK_ANSI_P: "P",
        kVK_ANSI_Q: "Q", kVK_ANSI_R: "R", kVK_ANSI_S: "S", kVK_ANSI_T: "T",
        kVK_ANSI_U: "U", kVK_ANSI_V: "V", kVK_ANSI_W: "W", kVK_ANSI_X: "X",
        kVK_ANSI_Y: "Y", kVK_ANSI_Z: "Z",
        kVK_ANSI_0: "0", kVK_ANSI_1: "1", kVK_ANSI_2: "2", kVK_ANSI_3: "3",
        kVK_ANSI_4: "4", kVK_ANSI_5: "5", kVK_ANSI_6: "6", kVK_ANSI_7: "7",
        kVK_ANSI_8: "8", kVK_ANSI_9: "9",
        kVK_ANSI_Minus: "-", kVK_ANSI_Equal: "=",
        kVK_ANSI_LeftBracket: "[", kVK_ANSI_RightBracket: "]",
        kVK_ANSI_Semicolon: ";", kVK_ANSI_Quote: "'",
        kVK_ANSI_Comma: ",", kVK_ANSI_Period: ".",
        kVK_ANSI_Slash: "/", kVK_ANSI_Backslash: "\\",
        kVK_ANSI_Grave: "`",
    ]

    private static let others: [Int: String] = [
        kVK_Return: "Return", kVK_Tab: "Tab", kVK_Space: "Space",
        kVK_Delete: "Delete", kVK_ForwardDelete: "Forward Delete", kVK_Escape: "Escape",
        kVK_Command: "⌘ Command", kVK_Shift: "⇧ Shift", kVK_Option: "⌥ Option",
        kVK_Control: "⌃ Control", kVK_RightShift: "Right ⇧", kVK_RightOption: "Right ⌥",
        kVK_RightControl: "Right ⌃", kVK_Function: "fn", kVK_CapsLock: "Caps Lock",
        kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4", kVK_F5: "F5",
        kVK_F6: "F6", kVK_F7: "F7", kVK_F8: "F8", kVK_F9: "F9", kVK_F10: "F10",
        kVK_F11: "F11", kVK_F12: "F12", kVK_F13: "F13", kVK_F14: "F14", kVK_F15: "F15",
        kVK_F16: "F16", kVK_F17: "F17", kVK_F18: "F18", kVK_F19: "F19", kVK_F20: "F20",
        kVK_Home: "Home", kVK_End: "End", kVK_PageUp: "Page Up", kVK_PageDown: "Page Down",
        kVK_LeftArrow: "←", kVK_RightArrow: "→", kVK_UpArrow: "↑", kVK_DownArrow: "↓",
        kVK_Help: "Help",
        kVK_ANSI_Keypad0: "Keypad 0", kVK_ANSI_Keypad1: "Keypad 1", kVK_ANSI_Keypad2: "Keypad 2",
        kVK_ANSI_Keypad3: "Keypad 3", kVK_ANSI_Keypad4: "Keypad 4", kVK_ANSI_Keypad5: "Keypad 5",
        kVK_ANSI_Keypad6: "Keypad 6", kVK_ANSI_Keypad7: "Keypad 7", kVK_ANSI_Keypad8: "Keypad 8",
        kVK_ANSI_Keypad9: "Keypad 9", kVK_ANSI_KeypadEnter: "Keypad Enter",
        kVK_ANSI_KeypadPlus: "Keypad +", kVK_ANSI_KeypadMinus: "Keypad -",
        kVK_ANSI_KeypadMultiply: "Keypad *", kVK_ANSI_KeypadDivide: "Keypad /",
        kVK_ANSI_KeypadEquals: "Keypad =", kVK_ANSI_KeypadDecimal: "Keypad .",
        kVK_ANSI_KeypadClear: "Keypad Clear",
        kVK_VolumeUp: "Volume Up", kVK_VolumeDown: "Volume Down", kVK_Mute: "Mute",
        SpecialKey.brightnessUp: "Brightness Up", SpecialKey.brightnessDown: "Brightness Down",
        SpecialKey.play: "Play/Pause", SpecialKey.next: "Next Track",
        SpecialKey.previous: "Previous Track", SpecialKey.fast: "Fast Forward",
        SpecialKey.rewind: "Rewind",
    ]
}
