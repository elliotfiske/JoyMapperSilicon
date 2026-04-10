# JoyMapperSilicon SwiftUI Rewrite — Design Spec

## Overview

Full rewrite of JoyMapperSilicon from AppKit/Storyboards/Core Data to SwiftUI/async-await/Point-Free Sharing. The existing `JoyConSwift` vendored framework stays untouched. The new code lives in a new `JoyMapperSiliconV2/` source directory alongside the old code for reference.

## Goals

- SwiftUI `App` lifecycle with a single `Window` scene (dock app, no menu bar icon)
- `@Observable` model layer replacing NotificationCenter-driven communication
- Point-Free `@Shared(.fileStorage(...))` replacing Core Data for persistence
- Codable value-type models replacing NSManagedObject subclasses
- Copy/paste of key configurations via `NSPasteboard` + JSON encoding

## Non-Goals (Out of Scope)

- File-based import/export of key mappings
- Undo support
- Migration from the old Core Data store
- Rewriting `JoyConSwift` (kept as-is)
- Async/await wrapper for `JoyConSwift` (future work)
- Localization (carry over `.strings` files, but no new translation work)

---

## Architecture

### App Entry Point

```swift
@main
struct JoyMapperApp: App {
    @State private var appModel = AppModel()

    var body: some Scene {
        Window("JoyMapper Silicon", id: "settings") {
            ContentView()
                .environment(appModel)
        }
    }
}
```

- `Window` (not `WindowGroup`) produces a single-instance window that reopens when the dock icon is clicked.
- No `MenuBarExtra`. No `NSApplicationDelegateAdaptor` unless terminate-confirmation is added later.
- `AppModel` is the single root of all app state, injected via SwiftUI environment.

### AppModel

`AppModel` is an `@Observable` class that replaces both the current `AppDelegate` coordination role and `DataManager` persistence role.

**Responsibilities:**

1. **Owns `JoyConManager`** — configures connect/disconnect/connectionState handlers in `init()`, calls `runAsync()` to start the HID run loop on a background thread.
2. **Owns persisted state** — `@Shared(.fileStorage("controllers.json")) var controllerProfiles: [ControllerProfile]` — the full saved configuration tree.
3. **Owns runtime state** — `var controllers: [GameController]` — live controller objects with HID device references, connection status, and timers. Linked to `controllerProfiles` by serial ID.
4. **Observes app activation** — registers for `NSWorkspace.didActivateApplicationNotification` to trigger per-app config switching on all connected controllers.
5. **Handles controller lifecycle** — connect (match existing profile or create new), disconnect (clear HID reference, update status), remove (delete profile and runtime object).

**Key design decision:** Persisted state (`controllerProfiles`) and runtime state (`controllers`) are separate. Profiles are `Codable` value types saved to disk. `GameController` objects hold a reference to their profile and the live `JoyConSwift.Controller` HID handle. Changes to key mappings flow: SwiftUI view edits profile -> `@Shared` auto-persists -> `GameController` reads current config on next button press.

### Persistence Model

Six Core Data entities become five `Codable` structs (with `AppData` inlined into `AppConfig`):

```swift
struct ControllerProfile: Codable, Identifiable {
    var id: String                   // serialID from HID device
    var type: ControllerType
    var bodyColor: CodableColor?
    var buttonColor: CodableColor?
    var defaultKeyConfig: KeyConfig
    var appConfigs: [AppConfig]
}

struct AppConfig: Codable, Identifiable {
    var id: UUID
    var bundleID: String
    var displayName: String
    var keyConfig: KeyConfig
}

struct KeyConfig: Codable {
    var keyMaps: [KeyMap]
    var leftStick: StickConfig?
    var rightStick: StickConfig?
}

struct KeyMap: Codable, Identifiable {
    var id: UUID
    var button: String               // JoyCon.Button raw value or StickDirection
    var keyCode: Int?
    var modifiers: Int?
    var mouseButton: Int?
    var isEnabled: Bool
}

struct StickConfig: Codable {
    var type: StickType              // .mouse, .mouseWheel, .key, .none
    var speed: Double
    var keyMaps: [KeyMap]            // 4 entries: up/down/left/right
}
```

**Persistence mechanism:** `@Shared(.fileStorage("controllers.json"))` from Point-Free Sharing. Single JSON file in the app's Application Support directory. No migration machinery — the model is simple enough that additive changes (new optional fields) are forwards-compatible.

**Copy/paste:** `KeyConfig` is `Codable`, so copy encodes to JSON on `NSPasteboard` with a custom UTI, paste decodes it. This replaces the current `KeyConfigClipboard` implementation.

### GameController (Runtime Bridge)

`GameController` is the runtime bridge between `JoyConSwift.Controller` (HID device) and the persisted `ControllerProfile`. It is an `@Observable` class.

**Responsibilities:**
- Holds a reference to the live `JoyConSwift.Controller` and the corresponding `ControllerProfile`
- Registers `buttonPressHandler`/`buttonReleaseHandler`/stick handlers on the HID controller
- On button/stick input: looks up the active `KeyConfig` (default or per-app), finds the matching `KeyMap`, and dispatches `CGEvent.post(tap: .cghidEventTap)`
- Tracks `connectionState` (`.connected`, `.connecting`, `.disconnected`, `.error`) as an observable property
- Manages the icon/battery polling timer
- Handles per-app config switching via `switchApp(bundleID:)`

This class is largely carried over from the existing `GameController.swift`, adapted to read from `ControllerProfile` structs instead of Core Data entities. `GameController` looks up its profile from `AppModel.controllerProfiles` by serial ID — it does not hold a direct reference to the value-type struct.

### MetaKeyState

Carried over as-is. Tracks modifier key state and releases "stuck" modifiers via `CGEvent`. No changes needed.

### SpecialKeyName

Carried over as-is. Maps key codes to human-readable names for the UI.

---

## Views

### ContentView (3-Pane Layout)

The main window is a 3-pane layout matching the current design:

- **Left pane:** Controller grid (`ControllerListView`) — shows all known controllers with connection status and icon
- **Top-right pane:** App list (`AppListView`) — "Default" row + per-app config rows for the selected controller
- **Bottom-right pane:** Key mapping list (`KeyMapListView`) — outline of button mappings and stick configs for the selected app/default config

Selection state lives in `ContentView` as `@State`:
- `selectedControllerID: String?` — serial ID of selected controller
- `selectedAppConfigID: UUID?` — nil means "Default" row is selected

### ControllerListView

Grid of controller cards. Each card shows:
- Controller icon (composite image from `GameControllerIcon`)
- Connection state indicator (connected/connecting/disconnected/error)
- Controller type label

Uses SwiftUI `LazyVGrid` or `List` with selection binding.

### AppListView

Table with rows:
- Row 0: "Default" (always present, uses `defaultKeyConfig`)
- Row 1+: Per-app configs (bundle ID, display name, icon)
- Add/remove buttons at the bottom (add opens `NSOpenPanel` for `.app` selection)

### KeyMapListView

Outline/disclosure-group structure:
- **Buttons section:** One row per button mapping. Each row shows button name, mapped key/mouse action, enabled toggle.
- **Left Stick section** (if applicable): Stick type picker, speed slider, 4 directional key map rows.
- **Right Stick section** (if applicable): Same as left stick.

Clicking a button mapping row opens `KeyConfigEditor` as a sheet.

### KeyConfigEditor

Modal sheet for editing a single `KeyMap`:
- Combo box / picker for key selection (uses `SpecialKeyName` list + search)
- Modifier checkboxes (Shift, Control, Option, Command)
- Mouse button picker (for mouse-mapped buttons)
- Enable/disable toggle

### AccessibilityBanner

Conditionally shown at the top of `ContentView` when `AXIsProcessTrusted()` returns false. Shows warning icon, explanation text, and "Open Settings..." button. Polls every 2 seconds (same as current implementation).

### StickConfigView

Inline view within `KeyMapListView` for stick configuration:
- Type picker (Mouse / Mouse Wheel / Key / None)
- Speed slider (when type is Mouse or Mouse Wheel)
- 4 directional key map rows (when type is Key)

---

## Folder Structure

```
JoyMapperSiliconV2/
├── App/
│   ├── JoyMapperApp.swift            # @main, Window scene
│   └── AppModel.swift                # @Observable, owns manager + persistence + runtime
├── Models/
│   ├── ControllerProfile.swift       # Top-level persisted model
│   ├── AppConfig.swift               # Per-app configuration
│   ├── KeyConfig.swift               # Button + stick mappings container
│   ├── KeyMap.swift                   # Single button-to-key mapping
│   ├── StickConfig.swift             # Stick behavior + directional maps
│   └── ControllerType.swift          # Enum bridging JoyCon.ControllerType
├── Controllers/
│   ├── GameController.swift          # Runtime HID → CGEvent bridge
│   ├── GameControllerIcon.swift      # Composite icon rendering
│   └── MetaKeyState.swift            # Modifier key tracking (carried over)
├── Views/
│   ├── ContentView.swift             # 3-pane layout
│   ├── ControllerListView.swift      # Left pane: controller grid
│   ├── AppListView.swift             # Top-right: per-app configs
│   ├── KeyMapListView.swift          # Bottom-right: key mapping outline
│   ├── KeyConfigEditor.swift         # Modal sheet for editing one mapping
│   ├── AccessibilityBanner.swift     # AXIsProcessTrusted warning
│   └── StickConfigView.swift         # Stick config inline editor
└── Utilities/
    ├── SpecialKeyName.swift          # Key code → name mapping (carried over)
    ├── CodableColor.swift            # NSColor ↔ Codable bridge
    └── KeyConfigClipboard.swift      # Copy/paste via NSPasteboard + JSON
```

---

## Migration from Old Code

| Old Component | New Replacement |
|---------------|-----------------|
| `@NSApplicationMain AppDelegate` | `@main JoyMapperApp` + `AppModel` |
| `Main.storyboard` (en + ja) | SwiftUI views |
| `ControllerViewItem.xib` | `ControllerListView` |
| Core Data model (`.xcdatamodeld`) | `@Shared(.fileStorage)` + Codable structs |
| `DataManager` | `AppModel` (persistence via `@Shared`) |
| `ControllerData` (NSManagedObject) | `ControllerProfile` (struct) |
| `AppConfig` (NSManagedObject) | `AppConfig` (struct) |
| `KeyConfig` (NSManagedObject) | `KeyConfig` (struct) |
| `KeyMap` (NSManagedObject) | `KeyMap` (struct) |
| `StickConfig` (NSManagedObject) | `StickConfig` (struct) |
| `AppData` (NSManagedObject) | Inlined into `AppConfig` (bundleID + displayName) |
| `ViewController` + extensions | `ContentView` + child views |
| `KeyConfigViewController` | `KeyConfigEditor` |
| `AppSettingsViewController` | Dropped (settings are inline now) |
| `AppNotifications` (NotificationCenter) | `@Observable` property changes on `AppModel` / `GameController` |
| `Notifications.swift` | Deleted |
| `AppNotifications.swift` | Deleted (user notifications can be added later) |
| Launcher helper app | Deleted (dock app, no login-item needed) |
| `JoyConSwift` framework | Kept as-is, same Tuist target |

## Build System Changes

`Project.swift` will be updated to:
- Change the main app target's sources glob from `JoyKeyMapper/**/*.swift` to `JoyMapperSiliconV2/**/*.swift`
- Remove storyboard/xib resources
- Add Point-Free Sharing as an SPM dependency
- Remove the `JoyMapperSiliconLauncher` target
- Remove the "Embed Login Items" script phase
- Remove the `coreDataModels` entry

---

## Open Questions (Deferred)

1. **Async wrapper for JoyConSwift** — future work to bridge HID callbacks to `AsyncStream`. Not needed for the initial rewrite since `runAsync()` + closure handlers work fine.
2. **User notifications** — the old app sent macOS notifications on connect/disconnect. Can be re-added later.
3. **Localization** — `.strings` files carry over, but new SwiftUI views will use `LocalizedStringKey` / `String(localized:)`. Full translation pass deferred.
4. **App icon in per-app config** — the old Core Data model stored app icons as binary data. The new model can derive icons from `bundleID` at runtime via `NSWorkspace.shared.icon(forFile:)` instead of persisting them.
