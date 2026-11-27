import AppKit

/// Renders one of the app's own windows to PNG.
@MainActor
enum WindowSnapshot {
    enum Method: String, Codable, Sendable {
        /// The view hierarchy draws itself into a bitmap: no permission needed, works on any
        /// display and behind other windows. Layers AppKit can't draw this way (some materials,
        /// Metal) come out flat or blank.
        case views
        /// The window server's copy of the window (`CGWindowListCreateImage`). Exact, and
        /// apps may capture their own windows without Screen Recording permission.
        case windowServer = "windowserver"
    }

    static func png(of window: NSWindow, method: Method) -> Data? {
        switch method {
        case .views:
            guard let view = window.contentView?.superview ?? window.contentView,
                  let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds)
            else { return nil }
            view.cacheDisplay(in: view.bounds, to: rep)
            return rep.representation(using: .png, properties: [:])
        case .windowServer:
            guard let image = windowListImage(CGWindowID(window.windowNumber)) else { return nil }
            return NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
        }
    }

    private typealias CreateImage = @convention(c) (CGRect, UInt32, CGWindowID, UInt32) -> Unmanaged<CGImage>?

    /// `CGWindowListCreateImage` is marked unavailable in the macOS 15 SDK but still ships.
    private static func windowListImage(_ id: CGWindowID) -> CGImage? {
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGWindowListCreateImage") else { return nil }
        let create = unsafeBitCast(symbol, to: CreateImage.self)
        let includingWindow: UInt32 = 1 << 3
        let boundsIgnoreFraming: UInt32 = 1 << 0
        let bestResolution: UInt32 = 1 << 3
        return create(.null, includingWindow, id, boundsIgnoreFraming | bestResolution)?.takeRetainedValue()
    }
}
