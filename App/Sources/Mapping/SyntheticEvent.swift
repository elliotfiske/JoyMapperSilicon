import Foundation

/// A keyboard or mouse event the mapping engine wants to send. Kept free of CoreGraphics so the
/// engine can be tested by recording these.
enum SyntheticEvent: Hashable, Sendable, Codable {
    case key(code: Int, down: Bool, modifiers: Modifiers)
    /// Volume, brightness and media keys: an `NX_KEYTYPE_*` value.
    case systemKey(type: Int32, down: Bool)
    case mouseButton(MouseButton, down: Bool, modifiers: Modifiers)
    /// Moves the pointer by a delta in points (+y down, like the screen). `dragging` is the mouse
    /// button held at the time, so apps see a drag rather than a move.
    case mouseMove(dx: Double, dy: Double, dragging: MouseButton?)
    /// Scrolls by pixels (+y scrolls content down).
    case scroll(dx: Double, dy: Double)

    var logDescription: String {
        switch self {
        case let .key(code, down, modifiers):
            "key \(modifiers.symbols)\(KeyNames.name(for: code)) \(down ? "down" : "up")"
        case let .systemKey(type, down):
            "system key \(type) \(down ? "down" : "up")"
        case let .mouseButton(button, down, modifiers):
            "\(modifiers.symbols)\(button.displayName) \(down ? "down" : "up")"
        case let .mouseMove(dx, dy, dragging):
            String(format: "move %.1f,%.1f", dx, dy) + (dragging.map { " dragging \($0.displayName)" } ?? "")
        case let .scroll(dx, dy):
            String(format: "scroll %.1f,%.1f", dx, dy)
        }
    }
}

/// Where synthetic events go: CoreGraphics in the app, a recorder in tests.
protocol EventPoster: Sendable {
    func post(_ event: SyntheticEvent)
}
