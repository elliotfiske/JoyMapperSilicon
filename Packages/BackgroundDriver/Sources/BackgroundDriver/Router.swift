import AppKit

/// The driver's HTTP API. Every request needs `Authorization: Bearer <token>`.
///
/// | Request | Does |
/// |---|---|
/// | `GET /status` | pid, whether the app is active or hidden, the frontmost app, the key window |
/// | `GET /windows` | the app's windows |
/// | `GET /elements?id=<prefix>&window=<title prefix>` | elements with an accessibility identifier |
/// | `GET /element?id=<id>&within=<id>&window=<title prefix>` | one element and the texts inside it |
/// | `GET /tree?window=<title prefix>` | the whole accessibility tree, as text |
/// | `GET /menu` | main-menu items that have shortcuts |
/// | `POST /click {"id" or "label", "window"?, "count"?}` | clicks the element's center |
/// | `POST /hover {"id" or "label", "window"?}` | moves the (synthetic) mouse over the element |
/// | `POST /key {"key", "modifiers"?, "window"?}` | presses a key in a window |
/// | `POST /close {"window"?}` | closes a window, like its close button |
/// | `GET /snapshot?window=<title prefix>&method=views\|windowserver` | the window as PNG |
///
/// `window` is a title prefix; the frontmost matching window wins.
@MainActor
final class Router {
    private let token: String
    private var awake = false

    init(token: String) { self.token = token }

    func handle(_ request: HTTPRequest) async -> HTTPResponse {
        guard request.headers["authorization"] == "Bearer \(token)" else { return .error("bad token", status: 401) }
        if !awake {
            await ElementLocator.wakeSwiftUIAccessibility()
            awake = true
        }
        ElementLocator.catchUp()
        do {
            switch (request.method, request.path) {
            case ("GET", "/status"): return .json(status())
            case ("GET", "/windows"): return .json(ElementLocator.windows().map(WindowInfo.init))
            case ("GET", "/element"): return element(request.query)
            case ("GET", "/elements"):
                let windows = ElementLocator.windows(titlePrefix: request.query["window"])
                return .json(ElementLocator.elements(in: windows, identifierPrefix: request.query["id"]))
            case ("GET", "/menu"): return .json(MenuShortcut.items())
            case ("GET", "/tree"):
                let text = ElementLocator.dump(ElementLocator.windows(titlePrefix: request.query["window"]))
                return HTTPResponse(status: 200, contentType: "text/plain; charset=utf-8", body: Data(text.utf8))
            case ("POST", "/click"): return try await click(decode(request))
            case ("POST", "/hover"): return try hover(decode(request))
            case ("POST", "/key"): return try key(decode(request))
            case ("POST", "/close"): return try close(decode(request))
            case ("GET", "/snapshot"): return snapshot(request.query)
            default: return .error("no route \(request.method) \(request.path)", status: 404)
            }
        } catch {
            return .error("bad body: \(error)", status: 400)
        }
    }

    // MARK: - Routes

    private func status() -> Status {
        Status(
            pid: ProcessInfo.processInfo.processIdentifier,
            active: NSApp.isActive,
            hidden: NSApp.isHidden,
            frontmost: NSWorkspace.shared.frontmostApplication?.bundleIdentifier,
            keyWindow: NSApp.keyWindow?.title
        )
    }

    private func element(_ query: [String: String]) -> HTTPResponse {
        guard let id = query["id"],
              let (node, window) = ElementLocator.find(
                  identifier: id, label: nil, within: query["within"], in: ElementLocator.windows(titlePrefix: query["window"])
              )
        else { return .error("no element \(query["id"] ?? "")", status: 404) }
        return .json(ElementLocator.detail(node, in: window))
    }

    private func click(_ target: Target) async throws -> HTTPResponse {
        guard var (point, window) = locate(target) else { return .error("no element \(target.id ?? target.label ?? "")", status: 404) }
        // Give the app's views up to 2s to catch up with its layout, so the click lands where
        // the element is now rather than where something else used to be.
        for _ in 0..<20 {
            guard let (node, nodeWindow) = find(target) else { break }
            let frame = ElementLocator.baseFrame(of: node, in: nodeWindow)
            (point, window) = (NSPoint(x: frame.midX, y: frame.midY), nodeWindow)
            if ElementLocator.clickReaches(node, at: point, in: window) { break }
            try? await Task.sleep(for: .milliseconds(100))
            ElementLocator.catchUp([window])
        }
        await EventSynthesizer.click(at: point, in: window, count: target.count ?? 1)
        return .json(status())
    }

    private func hover(_ target: Target) throws -> HTTPResponse {
        guard let (point, window) = locate(target) else { return .error("no element \(target.id ?? target.label ?? "")", status: 404) }
        EventSynthesizer.hover(at: point, in: window)
        return .json(status())
    }

    private func key(_ press: KeyPress) throws -> HTTPResponse {
        guard let key = Key(press.key) else { return .error("unknown key \(press.key)", status: 400) }
        // Default to the frontmost of the app's windows, which is where a real key press would land.
        let window = ElementLocator.windows(titlePrefix: press.window).first
        EventSynthesizer.key(key, modifiers: .init(names: press.modifiers ?? []), in: window)
        return .json(status())
    }

    /// ⌘W isn't a menu item in every app (and a background app has no key window for it), so
    /// closing is its own request.
    private func close(_ target: WindowTarget) throws -> HTTPResponse {
        guard let window = ElementLocator.windows(titlePrefix: target.window).first else { return .error("no window", status: 404) }
        window.performClose(nil)
        return .json(status())
    }

    private func snapshot(_ query: [String: String]) -> HTTPResponse {
        guard let window = ElementLocator.windows(titlePrefix: query["window"]).first else {
            return .error("no window", status: 404)
        }
        let method = query["method"].flatMap(WindowSnapshot.Method.init) ?? .views
        guard let png = WindowSnapshot.png(of: window, method: method) else { return .error("snapshot failed", status: 500) }
        return HTTPResponse(status: 200, contentType: "image/png", body: png)
    }

    // MARK: - Helpers

    private func find(_ target: Target) -> (node: ElementLocator.Node, window: NSWindow)? {
        ElementLocator.find(identifier: target.id, label: target.label, in: ElementLocator.windows(titlePrefix: target.window))
    }

    /// The element's center in window base coordinates.
    private func locate(_ target: Target) -> (NSPoint, NSWindow)? {
        guard let (node, window) = find(target) else { return nil }
        let frame = ElementLocator.baseFrame(of: node, in: window)
        return (NSPoint(x: frame.midX, y: frame.midY), window)
    }

    private func decode<T: Decodable>(_ request: HTTPRequest) throws -> T {
        try JSONDecoder().decode(T.self, from: request.body.isEmpty ? Data("{}".utf8) : request.body)
    }
}

extension WindowInfo {
    @MainActor init(_ window: NSWindow) {
        self.init(
            number: window.windowNumber,
            title: window.title,
            frame: window.frame,
            key: window.isKeyWindow,
            main: window.isMainWindow,
            occluded: !window.occlusionState.contains(.visible)
        )
    }
}
