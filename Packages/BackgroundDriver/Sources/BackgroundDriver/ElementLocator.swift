import AppKit
import ApplicationServices
import QuartzCore

/// Walks the app's own accessibility tree in-process, the same tree VoiceOver and XCUITest read.
@MainActor
enum ElementLocator {
    /// SwiftUI only builds its accessibility tree once an assistive client asks for it; until
    /// then a hosting view has no children. Reading our own windows through the AX API counts as
    /// asking, needs no Accessibility permission, and lasts for the life of the process.
    /// The main thread answers the request, so it's made from a background task.
    static func wakeSwiftUIAccessibility() async {
        let pid = ProcessInfo.processInfo.processIdentifier
        await Task.detached {
            var windows: CFTypeRef?
            _ = AXUIElementCopyAttributeValue(AXUIElementCreateApplication(pid), kAXWindowsAttribute as CFString, &windows)
        }.value
    }

    /// A window that's fully covered skips AppKit's display cycle, and SwiftUI only applies state
    /// changes to its views (and accessibility tree) during that cycle. So a background window can
    /// show, and report, a state from long ago. Forcing a layout and display pass brings it up to
    /// date before the driver reads it.
    static func catchUp(_ windows: [NSWindow] = windows()) {
        for window in windows {
            guard let content = window.contentView else { continue }
            content.needsLayout = true
            content.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
        }
        CATransaction.flush()
    }

    /// Windows the driver can act on, frontmost first: on screen (or minimized) and titled,
    /// which leaves out menus, tooltips, and the like.
    static func windows(titlePrefix: String? = nil) -> [NSWindow] {
        NSApp.windows
            .filter { window in
                (window.isVisible || window.isMiniaturized)
                    && !window.title.isEmpty
                    && (titlePrefix.map { window.title.hasPrefix($0) } ?? true)
            }
            .sorted { $0.orderedIndex < $1.orderedIndex }
    }

    static func elements(in windows: [NSWindow], identifierPrefix: String? = nil) -> [Element] {
        var found: [Element] = []
        for window in windows {
            visit(Node(window)) { node in
                guard let identifier = node.accessibilityIdentifier(), !identifier.isEmpty else { return }
                if let identifierPrefix, !identifier.hasPrefix(identifierPrefix) { return }
                found.append(element(node, identifier: identifier, in: window))
            }
        }
        return found
    }

    /// The first element with exactly this identifier (or, for AppKit controls without one,
    /// this label), and the window it's in. With `within`, only inside the element with that
    /// identifier.
    static func find(identifier: String?, label: String?, within: String? = nil, in windows: [NSWindow]) -> (node: Node, window: NSWindow)? {
        for window in windows {
            var root = Node(window)
            if let within {
                guard let container = find(identifier: within, label: nil, in: [window]) else { continue }
                root = container.node
            }
            var match: Node?
            visit(root) { node in
                guard match == nil else { return }
                if let identifier, node.accessibilityIdentifier() == identifier { match = node }
                if identifier == nil, let label, node.accessibilityLabel() == label { match = node }
            }
            if let match { return (match, window) }
        }
        return nil
    }

    /// The element's frame in window base coordinates (bottom-left origin), which is what
    /// `NSEvent` locations use.
    static func baseFrame(of node: Node, in window: NSWindow) -> CGRect {
        window.convertFromScreen(node.accessibilityFrame())
    }

    /// Whether a click at `point` would reach the element: hit-testing must land on the view that
    /// owns it, or on a view inside that one that isn't itself another accessibility container
    /// (another scroll view, say). Right after SwiftUI moves things, the AppKit views it hosts
    /// can lag behind its layout for a moment, and a click then lands on whatever used to be
    /// there.
    static func clickReaches(_ node: Node, at point: NSPoint, in window: NSWindow) -> Bool {
        guard let owner = node.owningView,
              let root = window.contentView?.superview ?? window.contentView,
              var view = root.hitTest(root.superview?.convert(point, from: nil) ?? point)
        else { return false }
        while view !== owner {
            let isOtherContainer = view.isAccessibilityElement()
            guard !isOtherContainer, let superview = view.superview else { return false }
            view = superview
        }
        return true
    }

    /// The whole tree as indented text, one node per line, like `XCUIElement.debugDescription`.
    static func dump(_ windows: [NSWindow]) -> String {
        var lines: [String] = []
        func walk(_ node: Node, depth: Int) {
            let role = node.accessibilityRole()?.rawValue ?? "?"
            let identifier = node.accessibilityIdentifier().map { "id=\($0)" }
            let label = node.accessibilityLabel().map { "label=\($0.prefix(60))" }
            let type = "<\(type(of: node.object))>"
            let parts = [role, identifier, label, type].compactMap { $0 }
            let indent = String(repeating: "  ", count: depth)
            lines.append(indent + parts.joined(separator: " "))
            guard depth < 60 else { return }
            for child in node.children { walk(child, depth: depth + 1) }
        }
        windows.forEach { walk(Node($0), depth: 0) }
        return lines.joined(separator: "\n")
    }

    /// The element and the text inside it.
    static func detail(_ node: Node, in window: NSWindow) -> ElementDetail {
        var texts: [String] = []
        visit(node) { descendant in
            guard descendant.object !== node.object, descendant.accessibilityRole() == .staticText else { return }
            let value = descendant.accessibilityValue().map { "\($0)" } ?? ""
            texts.append(value.isEmpty ? descendant.accessibilityLabel() ?? "" : value)
        }
        return ElementDetail(element: element(node, identifier: node.accessibilityIdentifier() ?? "", in: window), texts: texts)
    }

    private static func element(_ node: Node, identifier: String, in window: NSWindow) -> Element {
        let base = baseFrame(of: node, in: window)
        let topLeft = CGRect(x: base.minX, y: window.frame.height - base.maxY, width: base.width, height: base.height)
        return Element(
            identifier: identifier,
            role: node.accessibilityRole()?.rawValue ?? "",
            label: node.accessibilityLabel() ?? "",
            value: (node.accessibilityValue()).map { "\($0)" } ?? "",
            enabled: node.isAccessibilityEnabled(),
            frame: topLeft,
            window: window.windowNumber
        )
    }

    /// Wraps an accessibility object. SwiftUI's elements implement the NSAccessibility methods
    /// without declaring the protocol, so they're called through Objective-C dynamic dispatch.
    struct Node {
        let object: AnyObject

        init(_ object: AnyObject) { self.object = object }

        func accessibilityIdentifier() -> String? {
            nonEmpty(object.accessibilityIdentifier?()) ?? legacy(.identifier) as? String
        }

        func accessibilityLabel() -> String? {
            nonEmpty(object.accessibilityLabel?() ?? nil) ?? legacy(.description) as? String
        }

        func accessibilityValue() -> Any? {
            let modern: Any?? = object.accessibilityValue?()
            if let value = modern ?? nil { return value }
            return legacy(.value)
        }

        func accessibilityRole() -> NSAccessibility.Role? {
            if let role = modernRole { return role }
            guard let legacyRole = legacy(.role) as? String else { return nil }
            return NSAccessibility.Role(rawValue: legacyRole)
        }

        /// The role from the modern API: `nil` if the object doesn't implement it or has none.
        private var modernRole: NSAccessibility.Role? {
            let answer: NSAccessibility.Role?? = object.accessibilityRole?()
            guard let implemented = answer else { return nil }
            return implemented
        }

        func accessibilityFrame() -> NSRect {
            let frame = object.accessibilityFrame?() ?? .zero
            if frame != .zero { return frame }
            return legacyFrame() ?? .zero
        }

        func isAccessibilityEnabled() -> Bool { object.isAccessibilityEnabled?() ?? (legacy(.enabled) as? Bool) ?? true }

        func accessibilityParent() -> Node? {
            let parent = (object.accessibilityParent?() ?? nil) ?? legacy(.parent)
            return parent.map { Node($0 as AnyObject) }
        }

        var children: [Node] {
            let modern = (object.accessibilityChildren?() ?? nil) ?? []
            let all = modern.isEmpty ? (legacy(.children) as? [Any] ?? []) : modern
            return all.map { Node($0 as AnyObject) }
        }

        // Some AppKit elements (the rows of a SwiftUI `List`, which is an NSOutlineView) only
        // answer the older attribute-based accessibility API, so fall back to it. It's
        // deprecated, hence the compiler warnings, but it's what those elements implement.
        // Asking every node for its legacy attributes is slow, so it's only done for elements the
        // modern API doesn't describe at all: those report no role.
        private func legacy(_ attribute: NSAccessibility.Attribute) -> Any? {
            guard modernRole == nil else { return nil }
            guard let object = object as? NSObject,
                  object.accessibilityAttributeNames().contains(attribute)
            else { return nil }
            return object.accessibilityAttributeValue(attribute)
        }

        /// The legacy API gives a top-left-origin position on the primary screen and a size;
        /// `accessibilityFrame` is bottom-left screen coordinates.
        private func legacyFrame() -> NSRect? {
            guard let position = (legacy(.position) as? NSValue)?.pointValue,
                  let size = (legacy(.size) as? NSValue)?.sizeValue,
                  let primary = NSScreen.screens.first
            else { return nil }
            let bottomLeftY = primary.frame.height - position.y - size.height
            return NSRect(x: position.x, y: bottomLeftY, width: size.width, height: size.height)
        }

        private func nonEmpty(_ string: String?) -> String? {
            guard let string, !string.isEmpty else { return nil }
            return string
        }

        /// The AppKit view this element lives in: itself if it's a view (toolbar items, AppKit
        /// controls), else its nearest ancestor that is (a SwiftUI hosting or scroll view).
        var owningView: NSView? {
            var current: Node? = self
            while let node = current {
                if let view = node.object as? NSView { return view }
                current = node.accessibilityParent()
            }
            return nil
        }
    }

    private static func visit(_ root: Node, _ body: (Node) -> Void) {
        var seen: Set<ObjectIdentifier> = []
        var stack: [Node] = [root]
        while let node = stack.popLast() {
            guard seen.insert(ObjectIdentifier(node.object)).inserted else { continue }
            body(node)
            stack.append(contentsOf: node.children.reversed())
        }
    }
}
