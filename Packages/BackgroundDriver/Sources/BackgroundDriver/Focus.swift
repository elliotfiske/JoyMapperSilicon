import AppKit
import ObjectiveC

/// A window that isn't key only passes a click on to the view under it if that view
/// `acceptsFirstMouse(for:)`; otherwise the click just makes the window key. A background app
/// can't have a key window, so synthesized clicks on most SwiftUI content (`onTapGesture`,
/// rows, cards) would be dropped. While the driver delivers its own events, the views it clicks
/// accept first mouse; real clicks are unaffected.
@MainActor
enum FirstMouse {
    private static var accepting = false
    private static var patched: Set<Method> = []

    static func accepting<T>(at point: NSPoint, in window: NSWindow, _ body: () async -> T) async -> T {
        if let root = window.contentView?.superview ?? window.contentView, var view = root.hitTest(point) {
            patch(view)
            while let superview = view.superview { patch(superview); view = superview }
        }
        accepting = true
        defer { accepting = false }
        return await body()
    }

    /// Wraps the implementation this view's class uses (its own or an inherited one), once.
    private static func patch(_ view: NSView) {
        let selector = #selector(NSView.acceptsFirstMouse(for:))
        guard let method = class_getInstanceMethod(type(of: view), selector),
              patched.insert(method).inserted
        else { return }
        typealias Original = @convention(c) (NSView, Selector, NSEvent?) -> Bool
        let original = unsafeBitCast(method_getImplementation(method), to: Original.self)
        let replacement: @convention(block) (NSView, NSEvent?) -> Bool = { view, event in
            MainActor.assumeIsolated { accepting } || original(view, selector, event)
        }
        method_setImplementation(method, imp_implementationWithBlock(replacement))
    }
}

/// Menu commands without a fixed target (Close, Copy, …) go to the key window's responder
/// chain, and a background app has no key window, so AppKit disables them. For a shortcut that
/// matches one, the driver sends its action down the target window's chain itself.
@MainActor
enum MenuShortcut {
    /// Returns whether a menu item handled the shortcut.
    static func perform(_ event: NSEvent, in window: NSWindow) -> Bool {
        guard let menu = NSApp.mainMenu, let item = item(for: event, in: menu),
              item.target == nil, let action = item.action
        else { return false }
        // The chain AppKit would search from the key window: its responders, the window's
        // delegate, then the app and its delegate.
        var chain: [AnyObject] = []
        var responder: NSResponder? = window.firstResponder ?? window
        while let current = responder { chain.append(current); responder = current.nextResponder }
        chain += [window.delegate, NSApp, NSApp.delegate].compactMap { $0 }
        guard let target = chain.first(where: { $0.responds(to: action) }) else { return false }
        return NSApp.sendAction(action, to: target, from: item)
    }

    struct Item: Encodable {
        var path: String
        var shortcut: String
        var action: String?
        var hasTarget: Bool
        var enabled: Bool
    }

    /// Every main-menu item with a shortcut, for discovering what a key press will do.
    static func items() -> [Item] {
        var found: [Item] = []
        func walk(_ menu: NSMenu, path: String) {
            for item in menu.items {
                let itemPath = path.isEmpty ? item.title : "\(path) > \(item.title)"
                if let submenu = item.submenu { walk(submenu, path: itemPath) }
                guard !item.keyEquivalent.isEmpty else { continue }
                let mask = item.keyEquivalentModifierMask
                let modifiers = [(NSEvent.ModifierFlags.control, "⌃"), (.option, "⌥"), (.shift, "⇧"), (.command, "⌘")]
                    .filter { mask.contains($0.0) }.map(\.1).joined()
                found.append(Item(
                    path: itemPath, shortcut: modifiers + item.keyEquivalent, action: item.action.map(NSStringFromSelector),
                    hasTarget: item.target != nil, enabled: item.isEnabled
                ))
            }
        }
        NSApp.mainMenu.map { walk($0, path: "") }
        return found
    }

    private static func item(for event: NSEvent, in menu: NSMenu) -> NSMenuItem? {
        let relevant: NSEvent.ModifierFlags = [.command, .shift, .option, .control]
        for item in menu.items {
            if let submenu = item.submenu, let match = self.item(for: event, in: submenu) { return match }
            guard !item.keyEquivalent.isEmpty else { continue }
            let shift = item.keyEquivalent != item.keyEquivalent.lowercased()
            let modifiers = item.keyEquivalentModifierMask.union(shift ? .shift : [])
            if item.keyEquivalent.lowercased() == event.charactersIgnoringModifiers?.lowercased(),
               modifiers.intersection(relevant) == event.modifierFlags.intersection(relevant) {
                return item
            }
        }
        return nil
    }
}

/// macOS tells an app when a window is fully covered, and SwiftUI stops refreshing lazy
/// containers (`LazyVGrid`, `LazyVStack`, …) in such a window: they keep showing whatever they
/// showed when the window was covered, even as the state behind them changes. A copy launched in
/// the background starts covered, so while the driver runs, its windows always report being
/// visible.
@MainActor
enum AlwaysVisible {
    private static var installed = false

    static func install() {
        guard !installed else { return }
        installed = true
        let selector = #selector(getter: NSWindow.occlusionState)
        guard let method = class_getInstanceMethod(NSWindow.self, selector) else { return }
        typealias Original = @convention(c) (NSWindow, Selector) -> NSWindow.OcclusionState
        let original = unsafeBitCast(method_getImplementation(method), to: Original.self)
        let replacement: @convention(block) (NSWindow) -> NSWindow.OcclusionState = { window in
            original(window, selector).union(.visible)
        }
        // Installed before any window exists (`start()` runs before `NSApp` is set up), so every
        // window sees the patched value from the beginning.
        method_setImplementation(method, imp_implementationWithBlock(replacement))
    }
}
