import Carbon.HIToolbox
import Foundation

/// The saved settings for one physical controller.
struct ControllerProfile: Codable, Equatable, Identifiable, Sendable {
    /// CoreBluetooth's identifier for the controller. Stable on this Mac.
    var id: String
    var kind: ControllerKind
    var name: String
    /// Used in every app that has no override.
    var defaultConfig: MappingConfig
    /// Per-app mappings, picked by the frontmost app's bundle ID.
    var appOverrides: [AppOverride] = []

    init(id: String, kind: ControllerKind, name: String? = nil) {
        self.id = id
        self.kind = kind
        self.name = name ?? kind.displayName
        self.defaultConfig = .starter(for: kind)
    }

    /// The mappings in effect while `bundleID` is the frontmost app.
    func config(forFrontmostApp bundleID: String?) -> MappingConfig {
        let override = appOverrides.first { $0.bundleID == bundleID }
        return override?.config ?? defaultConfig
    }
}

struct AppOverride: Codable, Equatable, Identifiable, Sendable {
    var id: UUID
    var bundleID: String
    var appName: String
    var config: MappingConfig
}

/// Which buttons and stick directions produce which keys, for one controller in one context.
struct MappingConfig: Codable, Equatable, Sendable {
    var buttons: [ControllerButton: KeyBinding] = [:]
    var stick = StickConfig()

    func binding(for button: ControllerButton) -> KeyBinding {
        buttons[button] ?? .none
    }

    /// A usable starting point for walking-and-browsing: the stick moves the pointer (L) or
    /// scrolls (R), the shoulder buttons click.
    static func starter(for kind: ControllerKind) -> MappingConfig {
        switch kind {
        case .joyCon2Left:
            return MappingConfig(
                buttons: [
                    .zl: .mouse(.left),
                    .l: .mouse(.right),
                    .up: .key(kVK_UpArrow),
                    .down: .key(kVK_DownArrow),
                    .left: .key(kVK_LeftArrow),
                    .right: .key(kVK_RightArrow),
                    .minus: .key(kVK_Tab, [.command]),
                ],
                stick: StickConfig(mode: .mouse, speed: 25)
            )
        case .joyCon2Right:
            return MappingConfig(
                buttons: [
                    .zr: .mouse(.left),
                    .r: .mouse(.right),
                    .a: .key(kVK_Return),
                    .b: .key(kVK_Escape),
                    .x: .key(kVK_Space),
                    .y: .key(kVK_Delete),
                    .plus: .key(kVK_Tab, [.command]),
                ],
                stick: StickConfig(mode: .scroll, speed: 25)
            )
        }
    }
}

struct StickConfig: Codable, Equatable, Sendable {
    var mode: StickMode = .none
    /// Pointer points (or scroll pixels) per report at full tilt, at 60 reports a second.
    var speed: Double = 25
    /// Tilt below this fraction of full range counts as centered.
    var deadzone: Double = 0.15
    /// Used when `mode` is `.keys`.
    var directions: [StickDirection: KeyBinding] = [:]

    func binding(for direction: StickDirection) -> KeyBinding {
        directions[direction] ?? .none
    }
}

enum StickMode: String, Codable, Sendable, CaseIterable, Hashable {
    case none
    case mouse
    case scroll
    case keys

    var displayName: String {
        switch self {
        case .none: "Nothing"
        case .mouse: "Move pointer"
        case .scroll: "Scroll"
        case .keys: "Keys"
        }
    }
}
