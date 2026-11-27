import AppKit

/// Builds `NSEvent`s at a window location and hands them to `NSApp.sendEvent`, the path real
/// events take once they're dequeued (so local event monitors see them), without going through
/// the window server.
@MainActor
enum EventSynthesizer {
    static func click(at point: NSPoint, in window: NSWindow, count: Int) async {
        await FirstMouse.accepting(at: point, in: window) {
            for click in 1...max(count, 1) {
                // AppKit controls (toolbar items, NSButton) track the mouse inside `mouseDown`,
                // pulling events off the queue until the button comes up, so the up has to be
                // queued first. Without a tracking loop, the run loop delivers it right after.
                NSApp.postEvent(mouse(.leftMouseUp, at: point, in: window, clickCount: click), atStart: false)
                NSApp.sendEvent(mouse(.leftMouseDown, at: point, in: window, clickCount: click))
                // Let the up land before a double click's second down.
                try? await Task.sleep(for: .milliseconds(30))
            }
        }
    }

    /// Tracking areas the last `hover` entered, so the next one can exit them.
    private static var hovered: [NSTrackingArea] = []

    /// Sends the `mouseExited`/`mouseEntered`/`mouseMoved` events AppKit would derive from real
    /// cursor movement straight to the tracking areas involved. (A synthesized `mouseMoved` alone
    /// doesn't reach them: AppKit computes enter/exit from the real cursor.)
    static func hover(at point: NSPoint, in window: NSWindow) {
        guard let root = window.contentView?.superview ?? window.contentView else { return }
        var under: [NSTrackingArea] = []
        func collect(_ view: NSView) {
            let local = view.convert(point, from: nil)
            under += view.trackingAreas.filter { $0.rect.contains(local) }
            view.subviews.forEach(collect)
        }
        collect(root)

        for area in hovered where !under.contains(where: { $0 === area }) {
            send(.mouseExited, to: area, at: point, in: window)
        }
        for area in under {
            if !hovered.contains(where: { $0 === area }) { send(.mouseEntered, to: area, at: point, in: window) }
            if area.options.contains(.mouseMoved), let owner = area.owner as? NSResponder {
                owner.mouseMoved(with: mouse(.mouseMoved, at: point, in: window, clickCount: 0))
            }
        }
        hovered = under
    }

    static func key(_ key: Key, modifiers: NSEvent.ModifierFlags, in window: NSWindow?) {
        // AppKit's order for a shortcut is the key window, then the main menu; nil-target menu
        // items resolve through the key window too. A background app has none, so aim both at
        // the target window.
        if modifiers.contains(.command), let window {
            let down = keyEvent(.keyDown, key, modifiers: modifiers, in: window)
            if window.performKeyEquivalent(with: down) || MenuShortcut.perform(down, in: window) { return }
        }
        NSApp.sendEvent(keyEvent(.keyDown, key, modifiers: modifiers, in: window))
        NSApp.sendEvent(keyEvent(.keyUp, key, modifiers: modifiers, in: window))
    }

    private static var now: TimeInterval { ProcessInfo.processInfo.systemUptime }

    private static func mouse(_ type: NSEvent.EventType, at point: NSPoint, in window: NSWindow, clickCount: Int) -> NSEvent {
        NSEvent.mouseEvent(
            with: type, location: point, modifierFlags: [], timestamp: now,
            windowNumber: window.windowNumber, context: nil, eventNumber: 0,
            clickCount: clickCount, pressure: type == .leftMouseDown ? 1 : 0
        )!
    }

    private static func keyEvent(_ type: NSEvent.EventType, _ key: Key, modifiers: NSEvent.ModifierFlags, in window: NSWindow?) -> NSEvent {
        NSEvent.keyEvent(
            with: type, location: .zero, modifierFlags: modifiers, timestamp: now,
            windowNumber: window?.windowNumber ?? 0, context: nil,
            characters: modifiers.contains(.shift) ? key.characters.uppercased() : key.characters,
            charactersIgnoringModifiers: key.characters, isARepeat: false, keyCode: key.code
        )!
    }

    private static func send(_ type: NSEvent.EventType, to area: NSTrackingArea, at point: NSPoint, in window: NSWindow) {
        guard area.options.contains(.mouseEnteredAndExited), let owner = area.owner as? NSResponder,
              let event = NSEvent.enterExitEvent(
                  with: type, location: point, modifierFlags: [], timestamp: now,
                  windowNumber: window.windowNumber, context: nil, eventNumber: 0,
                  trackingNumber: Int(bitPattern: Unmanaged.passUnretained(area).toOpaque()), userData: nil
              )
        else { return }
        if type == .mouseEntered { owner.mouseEntered(with: event) } else { owner.mouseExited(with: event) }
    }
}
