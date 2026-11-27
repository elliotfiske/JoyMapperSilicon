import CoreGraphics
import Foundation

/// Where a running app's driver listens. The app publishes it as JSON in its endpoint file.
public struct Endpoint: Codable, Sendable, Equatable {
    public var port: UInt16
    public var token: String
    public var pid: Int32

    public init(port: UInt16, token: String, pid: Int32) {
        self.port = port
        self.token = token
        self.pid = pid
    }

    /// The file a running app publishes its endpoint to when nothing else is asked for:
    /// `~/Library/Caches/<bundle id>/background-driver.json`.
    public static func defaultFile(bundleIdentifier: String) -> URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appending(components: bundleIdentifier, "background-driver.json")
    }

    /// Environment variables the app reads at launch.
    public enum Environment {
        public static let port = "BACKGROUND_DRIVER_PORT"
        public static let token = "BACKGROUND_DRIVER_TOKEN"
        /// Publish the endpoint here instead of the default file, so a copy launched by a test
        /// doesn't take over the one scripts attach to.
        public static let endpointFile = "BACKGROUND_DRIVER_ENDPOINT_FILE"
    }
}

/// An accessibility element in one of the app's windows.
public struct Element: Codable, Sendable, Equatable {
    public var identifier: String
    public var role: String
    public var label: String
    public var value: String
    public var enabled: Bool
    /// In the window's coordinates, top-left origin (like XCUITest), including the title bar.
    public var frame: CGRect
    public var window: Int

    public init(identifier: String, role: String, label: String, value: String, enabled: Bool, frame: CGRect, window: Int) {
        self.identifier = identifier
        self.role = role
        self.label = label
        self.value = value
        self.enabled = enabled
        self.frame = frame
        self.window = window
    }
}

/// One element plus the text of the static texts inside it, for asserting on containers.
public struct ElementDetail: Codable, Sendable, Equatable {
    public var element: Element
    /// Each descendant static text's value (or label, if it has no value), in reading order.
    public var texts: [String]

    public init(element: Element, texts: [String]) {
        self.element = element
        self.texts = texts
    }
}

public struct Status: Codable, Sendable, Equatable {
    public var pid: Int32
    public var active: Bool
    public var hidden: Bool
    public var frontmost: String?
    public var keyWindow: String?

    public init(pid: Int32, active: Bool, hidden: Bool, frontmost: String?, keyWindow: String?) {
        self.pid = pid
        self.active = active
        self.hidden = hidden
        self.frontmost = frontmost
        self.keyWindow = keyWindow
    }
}

public struct WindowInfo: Codable, Sendable, Equatable {
    public var number: Int
    public var title: String
    public var frame: CGRect
    public var key: Bool
    public var main: Bool
    public var occluded: Bool

    public init(number: Int, title: String, frame: CGRect, key: Bool, main: Bool, occluded: Bool) {
        self.number = number
        self.title = title
        self.frame = frame
        self.key = key
        self.main = main
        self.occluded = occluded
    }
}

/// The body of `/click` and `/hover`. Give `id`, or `label` for elements without one.
public struct Target: Codable, Sendable, Equatable {
    public var id: String?
    public var label: String?
    /// A window title prefix; the frontmost match wins.
    public var window: String?
    public var count: Int?

    public init(id: String? = nil, label: String? = nil, window: String? = nil, count: Int? = nil) {
        self.id = id
        self.label = label
        self.window = window
        self.count = count
    }
}

/// The body of `/key`: a named key (`space`, `return`, `escape`, `left`, …) or one character.
public struct KeyPress: Codable, Sendable, Equatable {
    public var key: String
    /// `command`, `shift`, `option`, `control`.
    public var modifiers: [String]?
    public var window: String?

    public init(key: String, modifiers: [String]? = nil, window: String? = nil) {
        self.key = key
        self.modifiers = modifiers
        self.window = window
    }
}

/// The body of `/close`.
public struct WindowTarget: Codable, Sendable, Equatable {
    public var window: String?

    public init(window: String? = nil) { self.window = window }
}

/// What every error response carries.
public struct ErrorBody: Codable, Sendable, Equatable {
    public var error: String
}
