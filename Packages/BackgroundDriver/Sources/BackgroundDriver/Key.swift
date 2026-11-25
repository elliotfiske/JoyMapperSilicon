import AppKit

/// A key on a US ANSI keyboard: its virtual key code and the characters it types.
public struct Key: Sendable, Equatable {
    public var code: UInt16
    public var characters: String

    /// Named keys (`space`, `return`, `left`, …) or a single character (`r`, `,`, `5`).
    public init?(_ name: String) {
        if let named = Self.named[name.lowercased()] {
            self = named
        } else if name.count == 1, let code = Self.codes[Character(name.lowercased())] {
            self.init(code: code, characters: name.lowercased())
        } else {
            return nil
        }
    }

    public init(code: UInt16, characters: String) {
        self.code = code
        self.characters = characters
    }

    private static let named: [String: Key] = [
        "space": Key(code: 49, characters: " "),
        "return": Key(code: 36, characters: "\r"),
        "enter": Key(code: 36, characters: "\r"),
        "tab": Key(code: 48, characters: "\t"),
        "delete": Key(code: 51, characters: "\u{7F}"),
        "escape": Key(code: 53, characters: "\u{1B}"),
        "left": Key(code: 123, characters: String(UnicodeScalar(NSLeftArrowFunctionKey)!)),
        "right": Key(code: 124, characters: String(UnicodeScalar(NSRightArrowFunctionKey)!)),
        "down": Key(code: 125, characters: String(UnicodeScalar(NSDownArrowFunctionKey)!)),
        "up": Key(code: 126, characters: String(UnicodeScalar(NSUpArrowFunctionKey)!)),
    ]

    private static let codes: [Character: UInt16] = [
        "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9,
        "b": 11, "q": 12, "w": 13, "e": 14, "r": 15, "y": 16, "t": 17, "1": 18, "2": 19,
        "3": 20, "4": 21, "6": 22, "5": 23, "=": 24, "9": 25, "7": 26, "-": 27, "8": 28,
        "0": 29, "]": 30, "o": 31, "u": 32, "[": 33, "i": 34, "p": 35, "l": 37, "j": 38,
        "'": 39, "k": 40, ";": 41, "\\": 42, ",": 43, "/": 44, "n": 45, "m": 46, ".": 47,
        "`": 50, " ": 49,
    ]
}

extension NSEvent.ModifierFlags {
    /// `command`, `shift`, `option`, `control`; unknown names are ignored.
    init(names: [String]) {
        self = []
        for name in names {
            switch name.lowercased() {
            case "command", "cmd": insert(.command)
            case "shift": insert(.shift)
            case "option", "alt": insert(.option)
            case "control", "ctrl": insert(.control)
            default: break
            }
        }
    }
}
