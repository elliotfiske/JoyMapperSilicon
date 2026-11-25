import AppKit
import CoreGraphics

/// Posts synthetic events to the session through CoreGraphics. Needs the Accessibility
/// permission; without it, macOS drops the events silently.
struct CGEventPoster: EventPoster {
    func post(_ event: SyntheticEvent) {
        let source = CGEventSource(stateID: .hidSystemState)
        switch event {
        case let .key(code, down, modifiers):
            let key = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(code), keyDown: down)
            key?.flags = Self.flags(modifiers)
            key?.post(tap: .cgSessionEventTap)

        case let .systemKey(type, down):
            postSystemKey(type: type, down: down)

        case let .mouseButton(button, down, modifiers):
            let position = Self.currentPointerLocation()
            let (eventType, cgButton) = Self.mouseEventType(button, down: down)
            let mouse = CGEvent(mouseEventSource: source, mouseType: eventType, mouseCursorPosition: position, mouseButton: cgButton)
            mouse?.flags = Self.flags(modifiers)
            if button.rawValue >= MouseButton.middle.rawValue {
                mouse?.setIntegerValueField(.mouseEventButtonNumber, value: Int64(button.rawValue))
            }
            mouse?.post(tap: .cgSessionEventTap)

        case let .mouseMove(dx, dy, dragging):
            let current = Self.currentPointerLocation()
            let target = Self.clampToScreens(CGPoint(x: current.x + dx, y: current.y + dy))
            let (eventType, cgButton) = Self.moveEventType(dragging: dragging)
            let move = CGEvent(mouseEventSource: source, mouseType: eventType, mouseCursorPosition: target, mouseButton: cgButton)
            // Games read deltas, not positions.
            move?.setIntegerValueField(.mouseEventDeltaX, value: Int64(dx.rounded()))
            move?.setIntegerValueField(.mouseEventDeltaY, value: Int64(dy.rounded()))
            move?.post(tap: .cgSessionEventTap)

        case let .scroll(dx, dy):
            // Positive dy scrolls content down, which is a negative wheel delta.
            let scroll = CGEvent(
                scrollWheelEvent2Source: source,
                units: .pixel,
                wheelCount: 2,
                wheel1: Int32(-dy),
                wheel2: Int32(-dx),
                wheel3: 0
            )
            scroll?.post(tap: .cgSessionEventTap)
        }
    }

    private func postSystemKey(type: Int32, down: Bool) {
        // NX_KEYDOWN (0x0a) or NX_KEYUP (0x0b) in the upper byte of the low word.
        let state = down ? 0x0a00 : 0x0b00
        let data1 = (Int(type) << 16) | state
        let event = NSEvent.otherEvent(
            with: .systemDefined,
            location: .zero,
            modifierFlags: NSEvent.ModifierFlags(rawValue: UInt(state)),
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: 0,
            context: nil,
            subtype: 8, // NX_SUBTYPE_AUX_CONTROL_BUTTONS
            data1: data1,
            data2: -1
        )
        event?.cgEvent?.post(tap: .cgSessionEventTap)
    }

    private static func flags(_ modifiers: Modifiers) -> CGEventFlags {
        var flags: CGEventFlags = []
        if modifiers.contains(.shift) { flags.insert(.maskShift) }
        if modifiers.contains(.control) { flags.insert(.maskControl) }
        if modifiers.contains(.option) { flags.insert(.maskAlternate) }
        if modifiers.contains(.command) { flags.insert(.maskCommand) }
        return flags
    }

    private static func mouseEventType(_ button: MouseButton, down: Bool) -> (CGEventType, CGMouseButton) {
        switch button {
        case .left: (down ? .leftMouseDown : .leftMouseUp, .left)
        case .right: (down ? .rightMouseDown : .rightMouseUp, .right)
        case .middle, .back, .forward:
            (down ? .otherMouseDown : .otherMouseUp, CGMouseButton(rawValue: UInt32(button.rawValue)) ?? .center)
        }
    }

    private static func moveEventType(dragging: MouseButton?) -> (CGEventType, CGMouseButton) {
        switch dragging {
        case nil: (.mouseMoved, .left)
        case .left: (.leftMouseDragged, .left)
        case .right: (.rightMouseDragged, .right)
        case let other?: (.otherMouseDragged, CGMouseButton(rawValue: UInt32(other.rawValue)) ?? .center)
        }
    }

    /// The pointer in CoreGraphics coordinates (top-left origin of the primary display).
    private static func currentPointerLocation() -> CGPoint {
        CGEvent(source: nil)?.location ?? .zero
    }

    /// Keeps the pointer on some display. Checks each display, not the bounding box of all of
    /// them, so it can't drift into the gap of an L-shaped layout.
    private static func clampToScreens(_ point: CGPoint) -> CGPoint {
        var count: UInt32 = 0
        CGGetActiveDisplayList(0, nil, &count)
        var displays = [CGDirectDisplayID](repeating: 0, count: Int(count))
        CGGetActiveDisplayList(count, &displays, &count)
        let bounds = displays.map { CGDisplayBounds($0) }
        if bounds.contains(where: { $0.contains(point) }) { return point }

        // Off every display: pull it to the nearest point on the nearest one.
        let nearest = bounds.min { distance(from: point, to: $0) < distance(from: point, to: $1) }
        guard let nearest else { return point }
        return CGPoint(
            x: min(max(point.x, nearest.minX), nearest.maxX - 1),
            y: min(max(point.y, nearest.minY), nearest.maxY - 1)
        )
    }

    private static func distance(from point: CGPoint, to rect: CGRect) -> CGFloat {
        let dx = max(rect.minX - point.x, 0, point.x - rect.maxX)
        let dy = max(rect.minY - point.y, 0, point.y - rect.maxY)
        return (dx * dx + dy * dy).squareRoot()
    }
}

/// Writes events as JSON lines instead of posting them. Used by the background UI tests
/// (`JOYMAPPER_EVENT_LOG=<path>`) so they can check the whole pipeline without typing into
/// whatever app is in front.
final class FileRecordingPoster: EventPoster, @unchecked Sendable {
    private let handle: FileHandle?
    private let lock = NSLock()
    private let encoder = JSONEncoder()

    init(url: URL) {
        FileManager.default.createFile(atPath: url.path, contents: nil)
        handle = try? FileHandle(forWritingTo: url)
    }

    func post(_ event: SyntheticEvent) {
        guard let data = try? encoder.encode(event) else { return }
        lock.lock()
        defer { lock.unlock() }
        handle?.write(data + Data("\n".utf8))
    }
}
