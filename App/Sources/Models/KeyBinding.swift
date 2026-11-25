import Foundation

/// What a controller button does: a key (optionally with modifiers), a lone modifier, a mouse
/// button, or any mix. An empty binding does nothing.
struct KeyBinding: Codable, Equatable, Hashable, Sendable {
    /// A macOS virtual key code (`kVK_*`), or a `SpecialKey` media key.
    var keyCode: Int?
    var modifiers: Modifiers = []
    var mouseButton: MouseButton?
    /// Starts, stops or pastes dictation instead of sending input.
    var action: DictationAction?

    static let none = KeyBinding()

    var isEmpty: Bool {
        let hasKey = keyCode != nil
        let hasMouse = mouseButton != nil
        let hasModifier = !modifiers.isEmpty
        let hasAction = action != nil
        return !hasKey && !hasMouse && !hasModifier && !hasAction
    }

    /// "⌘⇧K", "Left click", "⌥ + Right click", or "—".
    var displayString: String {
        guard !isEmpty else { return "—" }
        if let action { return action.displayName }
        var parts: [String] = []
        let modifierText = modifiers.symbols
        let keyText = keyCode.map(KeyNames.name(for:))
        switch (keyText, mouseButton) {
        case let (key?, nil):
            parts.append(modifierText + key)
        case let (nil, mouse?):
            if !modifierText.isEmpty { parts.append(modifierText) }
            parts.append(mouse.displayName)
        case let (key?, mouse?):
            parts.append(modifierText + key)
            parts.append(mouse.displayName)
        case (nil, nil):
            parts.append(modifierText)
        }
        return parts.joined(separator: " + ")
    }

    static func key(_ code: Int, _ modifiers: Modifiers = []) -> KeyBinding {
        KeyBinding(keyCode: code, modifiers: modifiers)
    }

    static func mouse(_ button: MouseButton) -> KeyBinding {
        KeyBinding(mouseButton: button)
    }

    static func dictation(_ action: DictationAction) -> KeyBinding {
        KeyBinding(action: action)
    }
}

struct Modifiers: OptionSet, Codable, Hashable, Sendable {
    let rawValue: Int

    static let shift = Modifiers(rawValue: 1 << 0)
    static let control = Modifiers(rawValue: 1 << 1)
    static let option = Modifiers(rawValue: 1 << 2)
    static let command = Modifiers(rawValue: 1 << 3)

    /// In the order macOS menus show them.
    static let ordered: [(Modifiers, String)] = [
        (.control, "⌃"), (.option, "⌥"), (.shift, "⇧"), (.command, "⌘"),
    ]

    var symbols: String {
        Self.ordered
            .filter { contains($0.0) }
            .map(\.1)
            .joined()
    }
}

enum MouseButton: Int, Codable, Sendable, CaseIterable, Hashable {
    case left = 0
    case right = 1
    case middle = 2
    case back = 3
    case forward = 4

    var displayName: String {
        switch self {
        case .left: "Left click"
        case .right: "Right click"
        case .middle: "Middle click"
        case .back: "Mouse button 4"
        case .forward: "Mouse button 5"
        }
    }
}
