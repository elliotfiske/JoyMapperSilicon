# SwiftUI Rewrite Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Rewrite JoyMapperSilicon from AppKit/Storyboards/Core Data to a SwiftUI App with @Observable models and Point-Free Sharing persistence, in a new `JoyMapperSiliconV2/` source directory.

**Architecture:** SwiftUI `@main App` with a single `Window` scene. `AppModel` (@Observable) owns `JoyConManager`, persisted `[ControllerProfile]` via `@Shared(.fileStorage)`, and live `[GameController]` runtime state. Views observe `AppModel` via SwiftUI environment. `JoyConSwift` framework stays untouched.

**Tech Stack:** SwiftUI, Swift Observation (@Observable), Point-Free Sharing (@Shared/.fileStorage), Tuist, JoyConSwift (vendored IOKit/HID framework)

**Spec:** `docs/superpowers/specs/2026-04-10-swiftui-rewrite-design.md`

---

## File Structure

```
JoyMapperSiliconV2/
├── App/
│   ├── JoyMapperApp.swift            # @main App, Window scene
│   └── AppModel.swift                # @Observable root: JoyConManager + persistence + runtime
├── Models/
│   ├── ControllerProfile.swift       # Top-level persisted model (Codable)
│   ├── AppConfig.swift               # Per-app key config (Codable)
│   ├── KeyConfig.swift               # Button + stick mapping container (Codable)
│   ├── KeyMap.swift                   # Single button→key mapping (Codable)
│   ├── StickConfig.swift             # Stick behavior + directional maps (Codable)
│   └── ButtonNames.swift             # JoyCon.Button ↔ String maps, controllerButtons list
├── Controllers/
│   ├── GameController.swift          # Runtime HID → CGEvent bridge (@Observable)
│   ├── GameControllerIcon.swift      # Composite icon rendering (carried over)
│   └── MetaKeyState.swift            # Modifier key tracking (carried over as-is)
├── Views/
│   ├── ContentView.swift             # 3-pane layout shell
│   ├── ControllerListView.swift      # Left pane: controller grid
│   ├── AppListView.swift             # Top-right: per-app config list
│   ├── KeyMapListView.swift          # Bottom-right: key mapping outline
│   ├── KeyConfigEditor.swift         # Modal sheet for editing one KeyMap
│   ├── AccessibilityBanner.swift     # AXIsProcessTrusted warning bar
│   └── StickConfigView.swift         # Inline stick config editor
└── Utilities/
    ├── SpecialKeyName.swift          # Key code → name mapping (carried over as-is)
    ├── CodableColor.swift            # NSColor ↔ Codable bridge
    └── KeyConfigClipboard.swift      # Copy/paste KeyConfig via NSPasteboard + JSON
```

**Also modified:**
- `Project.swift` — retarget sources, add Sharing dependency, remove launcher
- `Tuist/Package.swift` (new) — declare SPM dependency on swift-sharing

---

## Task 1: Build System — Add Sharing dependency and new source target

**Files:**
- Create: `Tuist/Package.swift`
- Modify: `Project.swift`
- Create: `JoyMapperSiliconV2/App/JoyMapperApp.swift` (minimal placeholder to verify build)

- [ ] **Step 1: Create `Tuist/Package.swift` with Point-Free Sharing dependency**

```swift
// Tuist/Package.swift
// @generated
// This file is used by Tuist to resolve external dependencies.
import PackageDescription

#if TUIST
import ProjectDescription
import ProjectDescriptionHelpers

let packageSettings = PackageSettings(
    productTypes: [
        "Sharing": .framework,
    ]
)
#endif

let package = Package(
    name: "JoyMapperSilicon",
    dependencies: [
        .package(url: "https://github.com/pointfreeco/swift-sharing", from: "2.0.0"),
    ]
)
```

- [ ] **Step 2: Update `Project.swift` to use `JoyMapperSiliconV2/` sources and depend on Sharing**

Replace the main app target definition. Key changes:
- Sources glob: `"JoyMapperSiliconV2/**/*.swift"`
- Resources: remove storyboards/xib, keep `JoyKeyMapper/Assets.xcassets` (reuse existing assets)
- Remove `coreDataModels`
- Add dependency on `Sharing`
- Remove `JoyMapperSiliconLauncher` target entirely
- Remove "Embed Login Items" script phase

```swift
import ProjectDescription

let project = Project(
    name: "JoyMapperSilicon",
    settings: .settings(
        base: [
            "DEVELOPMENT_TEAM": "CKGA64W25Z",
            "CODE_SIGN_STYLE": "Automatic",
            "SWIFT_VERSION": "6.0",
        ],
        debug: [
            "ENABLE_TESTABILITY": "YES",
        ]
    ),
    targets: [
        // MARK: - Main App
        .target(
            name: "JoyMapperSilicon",
            destinations: [.mac],
            product: .app,
            bundleId: "com.elliotfiske.JoyMapperSilicon",
            deploymentTargets: .macOS("26.0"),
            infoPlist: .file(path: "JoyKeyMapper/Info.plist"),
            sources: ["JoyMapperSiliconV2/**/*.swift"],
            resources: .resources(
                [
                    "JoyKeyMapper/Assets.xcassets",
                    "JoyKeyMapper/Misc/*.strings",
                ]
            ),
            entitlements: .file(path: "JoyKeyMapper/JoyKeyMapper.entitlements"),
            scripts: [
                .post(
                    path: "scripts/set_build_number.sh",
                    name: "Set build number"
                ),
            ],
            dependencies: [
                .target(name: "JoyConSwift"),
                .external(name: "Sharing"),
            ],
            settings: .settings(
                base: [
                    "ENABLE_HARDENED_RUNTIME": "YES",
                    "ASSETCATALOG_COMPILER_APPICON_NAME": "AppIcon",
                    "CURRENT_PROJECT_VERSION": "10",
                    "MARKETING_VERSION": "1.0",
                    "CODE_SIGN_ENTITLEMENTS": "JoyKeyMapper/JoyKeyMapper.entitlements",
                ],
                configurations: [
                    .debug(name: "Debug"),
                    .release(name: "Release"),
                ]
            )
        ),

        // MARK: - Vendored JoyConSwift
        .target(
            name: "JoyConSwift",
            destinations: [.mac],
            product: .framework,
            bundleId: "com.elliotfiske.JoyConSwift",
            deploymentTargets: .macOS("26.0"),
            sources: ["Vendor/JoyConSwift/Sources/**/*.swift"],
            settings: .settings(
                base: [
                    "DEFINES_MODULE": "YES",
                ]
            )
        ),
    ]
)
```

- [ ] **Step 3: Create minimal `JoyMapperApp.swift` placeholder**

```swift
// JoyMapperSiliconV2/App/JoyMapperApp.swift
import SwiftUI

@main
struct JoyMapperApp: App {
    var body: some Scene {
        Window("JoyMapper Silicon", id: "settings") {
            Text("Hello, JoyMapper!")
        }
    }
}
```

- [ ] **Step 4: Fetch dependencies and regenerate Xcode project**

Run:
```bash
cd /Users/efiske/conductor/workspaces/JoyMapperSilicon/marseille-v1
tuist install
tuist generate --no-open
```

Expected: Tuist resolves the Sharing package and generates a project that includes `JoyMapperSiliconV2/` sources.

- [ ] **Step 5: Build to verify**

Build via Xcode or `xcodebuild`. The app should launch and show "Hello, JoyMapper!" in a window.

- [ ] **Step 6: Commit**

```bash
git add Tuist/Package.swift Project.swift JoyMapperSiliconV2/App/JoyMapperApp.swift
git commit -m "feat: scaffold SwiftUI app with Sharing dependency"
```

---

## Task 2: Codable Models — ControllerProfile, AppConfig, KeyConfig, KeyMap, StickConfig

**Files:**
- Create: `JoyMapperSiliconV2/Models/ControllerProfile.swift`
- Create: `JoyMapperSiliconV2/Models/AppConfig.swift`
- Create: `JoyMapperSiliconV2/Models/KeyConfig.swift`
- Create: `JoyMapperSiliconV2/Models/KeyMap.swift`
- Create: `JoyMapperSiliconV2/Models/StickConfig.swift`
- Create: `JoyMapperSiliconV2/Utilities/CodableColor.swift`

- [ ] **Step 1: Create `CodableColor.swift`**

This bridges `NSColor` to `Codable` by storing RGBA components.

```swift
// JoyMapperSiliconV2/Utilities/CodableColor.swift
import AppKit

struct CodableColor: Codable, Equatable, Hashable {
    var red: Double
    var green: Double
    var blue: Double
    var alpha: Double

    init(red: Double, green: Double, blue: Double, alpha: Double = 1.0) {
        self.red = red
        self.green = green
        self.blue = blue
        self.alpha = alpha
    }

    init(_ nsColor: NSColor) {
        let color = nsColor.usingColorSpace(.sRGB) ?? nsColor
        self.red = Double(color.redComponent)
        self.green = Double(color.greenComponent)
        self.blue = Double(color.blueComponent)
        self.alpha = Double(color.alphaComponent)
    }

    init(_ cgColor: CGColor) {
        self.init(NSColor(cgColor: cgColor) ?? .gray)
    }

    var nsColor: NSColor {
        NSColor(
            sRGBRed: CGFloat(red),
            green: CGFloat(green),
            blue: CGFloat(blue),
            alpha: CGFloat(alpha)
        )
    }
}
```

- [ ] **Step 2: Create `KeyMap.swift`**

```swift
// JoyMapperSiliconV2/Models/KeyMap.swift
import Foundation

struct KeyMap: Codable, Identifiable, Equatable, Hashable {
    var id: UUID = UUID()
    var button: String
    var keyCode: Int = -1
    var modifiers: Int = 0
    var mouseButton: Int = -1
    var isEnabled: Bool = true
}
```

- [ ] **Step 3: Create `StickConfig.swift`**

```swift
// JoyMapperSiliconV2/Models/StickConfig.swift
import Foundation

enum StickType: String, Codable, CaseIterable {
    case mouse = "Mouse"
    case mouseWheel = "Mouse Wheel"
    case key = "Key"
    case none = "None"
}

enum StickDirection: String, Codable, CaseIterable {
    case left = "Left"
    case right = "Right"
    case up = "Up"
    case down = "Down"
}

struct StickConfig: Codable, Equatable {
    var type: StickType = .none
    var speed: Double = 25.0
    var keyMaps: [KeyMap]

    static func defaultConfig() -> StickConfig {
        StickConfig(
            type: .none,
            speed: 25.0,
            keyMaps: [
                KeyMap(button: StickDirection.left.rawValue),
                KeyMap(button: StickDirection.right.rawValue),
                KeyMap(button: StickDirection.up.rawValue),
                KeyMap(button: StickDirection.down.rawValue),
            ]
        )
    }
}
```

- [ ] **Step 4: Create `KeyConfig.swift`**

```swift
// JoyMapperSiliconV2/Models/KeyConfig.swift
import Foundation

struct KeyConfig: Codable, Equatable {
    var keyMaps: [KeyMap]
    var leftStick: StickConfig?
    var rightStick: StickConfig?
}
```

- [ ] **Step 5: Create `AppConfig.swift`**

```swift
// JoyMapperSiliconV2/Models/AppConfig.swift
import Foundation

struct AppConfig: Codable, Identifiable, Equatable {
    var id: UUID = UUID()
    var bundleID: String
    var displayName: String
    var keyConfig: KeyConfig
}
```

- [ ] **Step 6: Create `ControllerProfile.swift`**

This references `JoyCon.ControllerType` from the vendored framework. We store the raw string value for Codable compatibility.

```swift
// JoyMapperSiliconV2/Models/ControllerProfile.swift
import Foundation
import JoyConSwift

struct ControllerProfile: Codable, Identifiable, Equatable {
    var id: String  // serialID from HID device
    var controllerType: String  // JoyCon.ControllerType.rawValue
    var bodyColor: CodableColor?
    var buttonColor: CodableColor?
    var leftGripColor: CodableColor?
    var rightGripColor: CodableColor?
    var defaultKeyConfig: KeyConfig
    var appConfigs: [AppConfig]

    var type: JoyCon.ControllerType {
        JoyCon.ControllerType(rawValue: controllerType) ?? .unknown
    }

    static func create(serialID: String, type: JoyCon.ControllerType) -> ControllerProfile {
        let hasLeftStick = type == .JoyConL || type == .ProController
        let hasRightStick = type == .JoyConR || type == .ProController

        return ControllerProfile(
            id: serialID,
            controllerType: type.rawValue,
            defaultKeyConfig: KeyConfig(
                keyMaps: [],
                leftStick: hasLeftStick ? .defaultConfig() : nil,
                rightStick: hasRightStick ? .defaultConfig() : nil
            ),
            appConfigs: []
        )
    }
}
```

- [ ] **Step 7: Build to verify all models compile**

Run: `tuist generate --no-open` then build. All models should compile without errors.

- [ ] **Step 8: Commit**

```bash
git add JoyMapperSiliconV2/Models/ JoyMapperSiliconV2/Utilities/CodableColor.swift
git commit -m "feat: add Codable persistence models and CodableColor"
```

---

## Task 3: ButtonNames — shared button/direction name mappings

**Files:**
- Create: `JoyMapperSiliconV2/Models/ButtonNames.swift`

These dictionaries are used by both `GameController` (to look up KeyMaps by button) and by views (to display button names). In the old code they lived in `ViewController+NSOutlineViewDelegate.swift` as file-level globals.

- [ ] **Step 1: Create `ButtonNames.swift`**

```swift
// JoyMapperSiliconV2/Models/ButtonNames.swift
import JoyConSwift

let buttonNames: [JoyCon.Button: String] = [
    .Up: "Up",
    .Right: "Right",
    .Down: "Down",
    .Left: "Left",
    .A: "A",
    .B: "B",
    .X: "X",
    .Y: "Y",
    .L: "L",
    .ZL: "ZL",
    .R: "R",
    .ZR: "ZR",
    .Minus: "Minus",
    .Plus: "Plus",
    .Capture: "Capture",
    .Home: "Home",
    .LStick: "LStick Push",
    .RStick: "RStick Push",
    .LeftSL: "Left SL",
    .LeftSR: "Left SR",
    .RightSL: "Right SL",
    .RightSR: "Right SR",
    .Start: "Start",
    .Select: "Select",
]

let directionNames: [JoyCon.StickDirection: String] = [
    .Up: "Up",
    .Right: "Right",
    .Down: "Down",
    .Left: "Left",
]

/// Which buttons each controller type has, in display order.
let controllerButtons: [JoyCon.ControllerType: [JoyCon.Button]] = [
    .JoyConL: [.Up, .Right, .Down, .Left, .LeftSL, .LeftSR, .L, .ZL, .Minus, .Capture, .LStick],
    .JoyConR: [.A, .B, .X, .Y, .RightSL, .RightSR, .R, .ZR, .Plus, .Home, .RStick],
    .ProController: [.A, .B, .X, .Y, .L, .ZL, .R, .ZR, .Up, .Right, .Down, .Left, .Minus, .Plus, .Capture, .Home, .LStick, .RStick],
    .FamicomController1: [.A, .B, .L, .R, .Up, .Right, .Down, .Left, .Start, .Select],
    .FamicomController2: [.A, .B, .L, .R, .Up, .Right, .Down, .Left],
]
```

- [ ] **Step 2: Build to verify**

- [ ] **Step 3: Commit**

```bash
git add JoyMapperSiliconV2/Models/ButtonNames.swift
git commit -m "feat: add button/direction name mappings"
```

---

## Task 4: Carry over utilities — MetaKeyState, SpecialKeyName

**Files:**
- Create: `JoyMapperSiliconV2/Utilities/SpecialKeyName.swift` (copy from `JoyKeyMapper/Views/KeyMapList/SpecialKeyName.swift`)
- Create: `JoyMapperSiliconV2/Controllers/MetaKeyState.swift` (copy from `JoyKeyMapper/DataModels/MetaKeyState.swift`)

These files are carried over as-is. The only change needed is that `MetaKeyState.swift` currently references the Core Data `KeyMap` type (for `Set<KeyMap>`). In the new code, `KeyMap` is a Codable struct that already conforms to `Hashable`, so it will work as a Set element without changes.

- [ ] **Step 1: Copy `SpecialKeyName.swift`**

Copy `JoyKeyMapper/Views/KeyMapList/SpecialKeyName.swift` → `JoyMapperSiliconV2/Utilities/SpecialKeyName.swift` with no changes.

```bash
mkdir -p JoyMapperSiliconV2/Utilities
cp JoyKeyMapper/Views/KeyMapList/SpecialKeyName.swift JoyMapperSiliconV2/Utilities/SpecialKeyName.swift
```

- [ ] **Step 2: Copy and adapt `MetaKeyState.swift`**

Copy `JoyKeyMapper/DataModels/MetaKeyState.swift` → `JoyMapperSiliconV2/Controllers/MetaKeyState.swift`.

The old code uses `KeyMap` (Core Data NSManagedObject) in `Set<KeyMap>` and accesses `config.modifiers` as an implicit `Int32`. The new `KeyMap` struct stores `modifiers` as `Int`, so the code needs a minor type adjustment.

```swift
// JoyMapperSiliconV2/Controllers/MetaKeyState.swift
import InputMethodKit

private let shiftKey = Int32(kVK_Shift)
private let optionKey = Int32(kVK_Option)
private let controlKey = Int32(kVK_Control)
private let commandKey = Int32(kVK_Command)
private let metaKeys = [kVK_Shift, kVK_Option, kVK_Control, kVK_Command]
private var pushedKeyConfigs = Set<KeyMap>()

func resetMetaKeyState() {
    let source = CGEventSource(stateID: .hidSystemState)
    pushedKeyConfigs.removeAll()

    DispatchQueue.main.async {
        metaKeys.forEach {
            let ev = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode($0), keyDown: false)
            ev?.post(tap: .cghidEventTap)
        }
    }
}

func getMetaKeyState() -> (shift: Bool, option: Bool, control: Bool, command: Bool) {
    var shift = false
    var option = false
    var control = false
    var command = false

    pushedKeyConfigs.forEach {
        let modifiers = NSEvent.ModifierFlags(rawValue: UInt($0.modifiers))
        shift = shift || modifiers.contains(.shift)
        option = option || modifiers.contains(.option)
        control = control || modifiers.contains(.control)
        command = command || modifiers.contains(.command)
    }

    return (shift, option, control, command)
}

func metaKeyEvent(config: KeyMap, keyDown: Bool) {
    var shift: Bool
    var option: Bool
    var control: Bool
    var command: Bool

    if keyDown {
        (shift, option, control, command) = getMetaKeyState()
        pushedKeyConfigs.insert(config)
    } else {
        pushedKeyConfigs.remove(config)
        (shift, option, control, command) = getMetaKeyState()
    }

    let source = CGEventSource(stateID: .hidSystemState)
    let modifiers = NSEvent.ModifierFlags(rawValue: UInt(config.modifiers))
    if !shift && modifiers.contains(.shift) {
        let ev = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_Shift), keyDown: keyDown)
        ev?.post(tap: .cghidEventTap)
    }

    if !option && modifiers.contains(.option) {
        let ev = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_Option), keyDown: keyDown)
        ev?.post(tap: .cghidEventTap)
    }

    if !control && modifiers.contains(.control) {
        let ev = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_Control), keyDown: keyDown)
        ev?.post(tap: .cghidEventTap)
    }

    if !command && modifiers.contains(.command) {
        let ev = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_Command), keyDown: keyDown)
        ev?.post(tap: .cghidEventTap)
    }
}
```

- [ ] **Step 3: Build to verify**

- [ ] **Step 4: Commit**

```bash
git add JoyMapperSiliconV2/Utilities/SpecialKeyName.swift JoyMapperSiliconV2/Controllers/MetaKeyState.swift
git commit -m "feat: carry over MetaKeyState and SpecialKeyName utilities"
```

---

## Task 5: GameController — Runtime HID→CGEvent bridge

**Files:**
- Create: `JoyMapperSiliconV2/Controllers/GameController.swift`
- Create: `JoyMapperSiliconV2/Controllers/GameControllerIcon.swift` (copy with minor adaptation)

This is the largest task. `GameController` is adapted from the existing 694-line class to work with the new Codable models instead of Core Data entities.

- [ ] **Step 1: Copy `GameControllerIcon.swift` as-is**

The icon rendering code uses `NSImage` drawing APIs and references `GameController` properties (`type`, `bodyColor`, `buttonColor`, `leftGripColor`, `rightGripColor`, `connectionState`, `isEnabled`, `controller?.battery`, `controller?.isCharging`). These property names are preserved in the new `GameController`, so the icon code can be copied directly.

```bash
mkdir -p JoyMapperSiliconV2/Controllers
cp JoyKeyMapper/DataModels/GameControllerIcon.swift JoyMapperSiliconV2/Controllers/GameControllerIcon.swift
```

- [ ] **Step 2: Create `GameController.swift`**

The new `GameController` is `@Observable` and reads from `ControllerProfile` structs instead of Core Data. It takes a closure to look up its profile (since profiles are value types owned by `AppModel`).

Key differences from old code:
- No `ControllerData` — uses `serialID` to look up `ControllerProfile` from `AppModel`
- `updateKeyMap()` iterates Swift arrays instead of `NSOrderedSet.enumerateObjects`
- No `AppNotifications` calls (deferred — user notifications out of scope)
- No `AppDelegate` references — battery/charging changes just update the observable icon
- `ConnectionDisplayState` stays the same

```swift
// JoyMapperSiliconV2/Controllers/GameController.swift
import AppKit
import JoyConSwift
import InputMethodKit
import Observation

@Observable
class GameController {
    let serialID: String

    var type: JoyCon.ControllerType
    var bodyColor: NSColor
    var buttonColor: NSColor
    var leftGripColor: NSColor?
    var rightGripColor: NSColor?

    var controller: JoyConSwift.Controller? {
        didSet { setControllerHandler() }
    }

    // The profile lookup closure — returns the current profile from AppModel
    var profileLookup: () -> ControllerProfile?

    private var currentKeyConfig: KeyConfig?
    private var currentButtonMap: [JoyCon.Button: KeyMap] = [:]
    private var currentLStickMode: StickType = .none
    private var currentLStickMap: [JoyCon.StickDirection: KeyMap] = [:]
    private var currentRStickMode: StickType = .none
    private var currentRStickMap: [JoyCon.StickDirection: KeyMap] = [:]

    var isEnabled: Bool = true {
        didSet { updateControllerIcon() }
    }

    enum ConnectionDisplayState {
        case disconnected
        case connecting
        case connected
        case error
    }

    var connectionState: ConnectionDisplayState = .disconnected {
        didSet {
            if connectionState != oldValue {
                updateControllerIcon()
            }
        }
    }

    var isLeftDragging = false
    var isRightDragging = false
    var isCenterDragging = false
    var isButton4Dragging = false
    var isButton5Dragging = false

    var lastAccess: Date?
    var timer: Timer?

    var icon: NSImage? {
        if _icon == nil { updateControllerIcon() }
        return _icon
    }
    private var _icon: NSImage?

    var localizedBatteryString: String {
        (controller?.battery ?? .unknown).localizedString
    }

    // The active bundleID for per-app switching
    private var activeBundleID: String?

    init(serialID: String, profile: ControllerProfile, profileLookup: @escaping () -> ControllerProfile?) {
        self.serialID = serialID
        self.type = profile.type
        self.bodyColor = profile.bodyColor?.nsColor ?? NSColor(red: 55/255, green: 55/255, blue: 55/255, alpha: 1)
        self.buttonColor = profile.buttonColor?.nsColor ?? NSColor(red: 55/255, green: 55/255, blue: 55/255, alpha: 1)
        self.leftGripColor = profile.leftGripColor?.nsColor
        self.rightGripColor = profile.rightGripColor?.nsColor
        self.profileLookup = profileLookup
        self.reloadKeyConfig()
    }

    // MARK: - Key Config

    func reloadKeyConfig() {
        guard let profile = profileLookup() else { return }
        let keyConfig: KeyConfig
        if let bundleID = activeBundleID,
           let appConfig = profile.appConfigs.first(where: { $0.bundleID == bundleID }) {
            keyConfig = appConfig.keyConfig
        } else {
            keyConfig = profile.defaultKeyConfig
        }
        self.currentKeyConfig = keyConfig
        updateKeyMap(keyConfig)
    }

    func switchApp(bundleID: String) {
        activeBundleID = bundleID
        reloadKeyConfig()
    }

    private func updateKeyMap(_ keyConfig: KeyConfig) {
        var newButtonMap: [JoyCon.Button: KeyMap] = [:]
        for keyMap in keyConfig.keyMaps {
            if let entry = buttonNames.first(where: { $0.value == keyMap.button }) {
                newButtonMap[entry.key] = keyMap
            }
        }
        currentButtonMap = newButtonMap

        // Left stick
        currentLStickMode = keyConfig.leftStick?.type ?? .none
        var newLeftStickMap: [JoyCon.StickDirection: KeyMap] = [:]
        if let leftStick = keyConfig.leftStick {
            for keyMap in leftStick.keyMaps {
                if let entry = directionNames.first(where: { $0.value == keyMap.button }) {
                    newLeftStickMap[entry.key] = keyMap
                }
            }
        }
        currentLStickMap = newLeftStickMap

        // Right stick
        currentRStickMode = keyConfig.rightStick?.type ?? .none
        var newRightStickMap: [JoyCon.StickDirection: KeyMap] = [:]
        if let rightStick = keyConfig.rightStick {
            for keyMap in rightStick.keyMaps {
                if let entry = directionNames.first(where: { $0.value == keyMap.button }) {
                    newRightStickMap[entry.key] = keyMap
                }
            }
        }
        currentRStickMap = newRightStickMap
    }

    // MARK: - Controller event handlers

    func setControllerHandler() {
        guard let controller = controller else { return }

        controller.setPlayerLights(l1: .on, l2: .off, l3: .off, l4: .off)
        controller.enableIMU(enable: true)
        controller.setInputMode(mode: .standardFull)

        controller.buttonPressHandler = { [weak self] button in
            self?.handleButtonPress(button: button)
        }
        controller.buttonReleaseHandler = { [weak self] button in
            guard self?.isEnabled == true else { return }
            self?.handleButtonRelease(button: button)
        }
        controller.leftStickHandler = { [weak self] newDir, oldDir in
            guard self?.isEnabled == true else { return }
            self?.handleLeftStick(newDirection: newDir, oldDirection: oldDir)
        }
        controller.rightStickHandler = { [weak self] newDir, oldDir in
            guard self?.isEnabled == true else { return }
            self?.handleRightStick(newDirection: newDir, oldDirection: oldDir)
        }
        controller.leftStickPosHandler = { [weak self] pos in
            guard self?.isEnabled == true else { return }
            self?.handleLeftStickPos(pos: pos)
        }
        controller.rightStickPosHandler = { [weak self] pos in
            guard self?.isEnabled == true else { return }
            self?.handleRightStickPos(pos: pos)
        }
        controller.batteryChangeHandler = { [weak self] _, _ in
            self?.updateControllerIcon()
        }
        controller.isChargingChangeHandler = { [weak self] _ in
            self?.updateControllerIcon()
        }

        // Update colors from hardware
        self.type = controller.type
        self.bodyColor = NSColor(cgColor: controller.bodyColor) ?? self.bodyColor
        self.buttonColor = NSColor(cgColor: controller.buttonColor) ?? self.buttonColor
        if let lg = controller.leftGripColor { self.leftGripColor = NSColor(cgColor: lg) }
        if let rg = controller.rightGripColor { self.rightGripColor = NSColor(cgColor: rg) }

        updateControllerIcon()
    }

    // MARK: - Button press/release (CGEvent dispatch)

    func handleButtonPress(button: JoyCon.Button) {
        guard let config = currentButtonMap[button] else { return }
        pressKey(config: config)
    }

    func handleButtonRelease(button: JoyCon.Button) {
        guard let config = currentButtonMap[button] else { return }
        releaseKey(config: config)
    }

    func pressKey(config: KeyMap) {
        DispatchQueue.main.async { [self] in
            let source = CGEventSource(stateID: .hidSystemState)

            if config.keyCode >= 0 {
                metaKeyEvent(config: config, keyDown: true)

                if let systemKey = systemDefinedKey[config.keyCode] {
                    let mousePos = NSEvent.mouseLocation
                    let flags = NSEvent.ModifierFlags(rawValue: 0x0a00)
                    let data1 = Int((systemKey << 16) | 0x0a00)
                    let ev = NSEvent.otherEvent(
                        with: .systemDefined, location: mousePos, modifierFlags: flags,
                        timestamp: ProcessInfo().systemUptime, windowNumber: 0, context: nil,
                        subtype: Int16(NX_SUBTYPE_AUX_CONTROL_BUTTONS), data1: data1, data2: -1)
                    ev?.cgEvent?.post(tap: .cghidEventTap)
                } else {
                    let event = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(config.keyCode), keyDown: true)
                    event?.flags = CGEventFlags(rawValue: CGEventFlags.RawValue(config.modifiers))
                    event?.post(tap: .cghidEventTap)
                }
            } else if config.mouseButton < 0 && config.modifiers != 0 {
                metaKeyEvent(config: config, keyDown: true)
            }

            if config.mouseButton >= 0 {
                let mousePos = NSEvent.mouseLocation
                let cursorPos = CGPoint(x: mousePos.x, y: NSScreen.screens[0].frame.maxY - mousePos.y)
                metaKeyEvent(config: config, keyDown: true)

                var event: CGEvent?
                switch config.mouseButton {
                case 0:
                    event = CGEvent(mouseEventSource: source, mouseType: .leftMouseDown, mouseCursorPosition: cursorPos, mouseButton: .left)
                    isLeftDragging = true
                case 1:
                    event = CGEvent(mouseEventSource: source, mouseType: .rightMouseDown, mouseCursorPosition: cursorPos, mouseButton: .right)
                    isRightDragging = true
                case 2:
                    event = CGEvent(mouseEventSource: source, mouseType: .otherMouseDown, mouseCursorPosition: cursorPos, mouseButton: .center)
                    isCenterDragging = true
                case 3:
                    event = CGEvent(mouseEventSource: source, mouseType: .otherMouseDown, mouseCursorPosition: cursorPos, mouseButton: CGMouseButton(rawValue: 3)!)
                    isButton4Dragging = true
                case 4:
                    event = CGEvent(mouseEventSource: source, mouseType: .otherMouseDown, mouseCursorPosition: cursorPos, mouseButton: CGMouseButton(rawValue: 4)!)
                    isButton5Dragging = true
                default: break
                }
                event?.flags = CGEventFlags(rawValue: CGEventFlags.RawValue(config.modifiers))
                event?.post(tap: .cghidEventTap)
            }
        }
    }

    func releaseKey(config: KeyMap) {
        DispatchQueue.main.async { [self] in
            let source = CGEventSource(stateID: .hidSystemState)

            if config.keyCode >= 0 {
                if let systemKey = systemDefinedKey[config.keyCode] {
                    let mousePos = NSEvent.mouseLocation
                    let flags = NSEvent.ModifierFlags(rawValue: 0x0b00)
                    let data1 = Int((systemKey << 16) | 0x0b00)
                    let ev = NSEvent.otherEvent(
                        with: .systemDefined, location: mousePos, modifierFlags: flags,
                        timestamp: ProcessInfo().systemUptime, windowNumber: 0, context: nil,
                        subtype: Int16(NX_SUBTYPE_AUX_CONTROL_BUTTONS), data1: data1, data2: -1)
                    ev?.cgEvent?.post(tap: .cghidEventTap)
                } else {
                    let event = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(config.keyCode), keyDown: false)
                    event?.flags = CGEventFlags(rawValue: CGEventFlags.RawValue(config.modifiers))
                    event?.post(tap: .cghidEventTap)
                }
                metaKeyEvent(config: config, keyDown: false)
            } else if config.mouseButton < 0 && config.modifiers != 0 {
                metaKeyEvent(config: config, keyDown: false)
            }

            if config.mouseButton >= 0 {
                let mousePos = NSEvent.mouseLocation
                let cursorPos = CGPoint(x: mousePos.x, y: NSScreen.screens[0].frame.maxY - mousePos.y)

                var event: CGEvent?
                switch config.mouseButton {
                case 0:
                    event = CGEvent(mouseEventSource: source, mouseType: .leftMouseUp, mouseCursorPosition: cursorPos, mouseButton: .left)
                    isLeftDragging = false
                case 1:
                    event = CGEvent(mouseEventSource: source, mouseType: .rightMouseUp, mouseCursorPosition: cursorPos, mouseButton: .right)
                    isRightDragging = false
                case 2:
                    event = CGEvent(mouseEventSource: source, mouseType: .otherMouseUp, mouseCursorPosition: cursorPos, mouseButton: .center)
                    isCenterDragging = false
                case 3:
                    event = CGEvent(mouseEventSource: source, mouseType: .otherMouseUp, mouseCursorPosition: cursorPos, mouseButton: CGMouseButton(rawValue: 3)!)
                    isButton4Dragging = false
                case 4:
                    event = CGEvent(mouseEventSource: source, mouseType: .otherMouseUp, mouseCursorPosition: cursorPos, mouseButton: CGMouseButton(rawValue: 4)!)
                    isButton5Dragging = false
                default: break
                }
                event?.post(tap: .cghidEventTap)
            }
        }
    }

    // MARK: - Stick handlers

    func handleLeftStick(newDirection: JoyCon.StickDirection, oldDirection: JoyCon.StickDirection) {
        guard currentLStickMode == .key else { return }
        if let config = currentLStickMap[oldDirection] { releaseKey(config: config) }
        stick45DegreeRelease(newDirection: newDirection, oldDirection: oldDirection, stickConfig: currentLStickMap)
        if let config = currentLStickMap[newDirection] { pressKey(config: config) }
        stick45DegreePress(newDirection: newDirection, oldDirection: oldDirection, stickConfig: currentLStickMap)
    }

    func handleRightStick(newDirection: JoyCon.StickDirection, oldDirection: JoyCon.StickDirection) {
        guard currentRStickMode == .key else { return }
        if let config = currentRStickMap[oldDirection] { releaseKey(config: config) }
        stick45DegreeRelease(newDirection: newDirection, oldDirection: oldDirection, stickConfig: currentRStickMap)
        if let config = currentRStickMap[newDirection] { pressKey(config: config) }
        stick45DegreePress(newDirection: newDirection, oldDirection: oldDirection, stickConfig: currentRStickMap)
    }

    private func stick45DegreeRelease(newDirection: JoyCon.StickDirection, oldDirection: JoyCon.StickDirection, stickConfig: [JoyCon.StickDirection: KeyMap]) {
        if oldDirection == .UpLeft || oldDirection == .UpRight {
            if let config = stickConfig[.Up] { releaseKey(config: config) }
        }
        if oldDirection == .DownLeft || oldDirection == .DownRight {
            if let config = stickConfig[.Down] { releaseKey(config: config) }
        }
        if oldDirection == .UpLeft || oldDirection == .DownLeft {
            if let config = stickConfig[.Left] { releaseKey(config: config) }
        }
        if oldDirection == .UpRight || oldDirection == .DownRight {
            if let config = stickConfig[.Right] { releaseKey(config: config) }
        }
    }

    private func stick45DegreePress(newDirection: JoyCon.StickDirection, oldDirection: JoyCon.StickDirection, stickConfig: [JoyCon.StickDirection: KeyMap]) {
        if newDirection == .UpLeft || newDirection == .UpRight {
            if let config = stickConfig[.Up] { pressKey(config: config) }
        }
        if newDirection == .DownLeft || newDirection == .DownRight {
            if let config = stickConfig[.Down] { pressKey(config: config) }
        }
        if newDirection == .UpLeft || newDirection == .DownLeft {
            if let config = stickConfig[.Left] { pressKey(config: config) }
        }
        if newDirection == .UpRight || newDirection == .DownRight {
            if let config = stickConfig[.Right] { pressKey(config: config) }
        }
    }

    func handleLeftStickPos(pos: CGPoint) {
        let speed = CGFloat(currentKeyConfig?.leftStick?.speed ?? 0)
        switch currentLStickMode {
        case .mouse: stickMouseHandler(pos: pos, speed: speed)
        case .mouseWheel: stickMouseWheelHandler(pos: pos, speed: speed)
        default: break
        }
    }

    func handleRightStickPos(pos: CGPoint) {
        let speed = CGFloat(currentKeyConfig?.rightStick?.speed ?? 0)
        switch currentRStickMode {
        case .mouse: stickMouseHandler(pos: pos, speed: speed)
        case .mouseWheel: stickMouseWheelHandler(pos: pos, speed: speed)
        default: break
        }
    }

    private func stickMouseHandler(pos: CGPoint, speed: CGFloat) {
        guard pos.x != 0 || pos.y != 0 else { return }
        let mousePos = NSEvent.mouseLocation
        let primaryScreenMaxY = NSScreen.screens[0].frame.maxY

        var minX = CGFloat.infinity, maxX = -CGFloat.infinity
        var minY = CGFloat.infinity, maxY = -CGFloat.infinity
        for screen in NSScreen.screens {
            let frame = screen.frame
            let cgLeft = frame.minX; let cgRight = frame.maxX
            let cgTop = primaryScreenMaxY - frame.maxY
            let cgBottom = primaryScreenMaxY - frame.minY
            minX = min(minX, cgLeft); maxX = max(maxX, cgRight)
            minY = min(minY, cgTop); maxY = max(maxY, cgBottom)
        }

        let newX = min(max(minX, mousePos.x + pos.x * speed), maxX)
        let newY = min(max(minY, primaryScreenMaxY - mousePos.y - pos.y * speed), maxY)
        let newPos = CGPoint(x: newX, y: newY)

        let source = CGEventSource(stateID: .hidSystemState)
        let (mouseType, mouseButton): (CGEventType, CGMouseButton) = {
            if isLeftDragging { return (.leftMouseDragged, .left) }
            if isRightDragging { return (.rightMouseDragged, .right) }
            if isCenterDragging { return (.otherMouseDragged, .center) }
            if isButton4Dragging { return (.otherMouseDragged, CGMouseButton(rawValue: 3)!) }
            if isButton5Dragging { return (.otherMouseDragged, CGMouseButton(rawValue: 4)!) }
            return (.mouseMoved, .left)
        }()
        let event = CGEvent(mouseEventSource: source, mouseType: mouseType, mouseCursorPosition: newPos, mouseButton: mouseButton)
        event?.post(tap: .cghidEventTap)
    }

    private func stickMouseWheelHandler(pos: CGPoint, speed: CGFloat) {
        guard pos.x != 0 || pos.y != 0 else { return }
        let source = CGEventSource(stateID: .hidSystemState)
        let event = CGEvent(scrollWheelEvent2Source: source, units: .pixel, wheelCount: 2,
                            wheel1: Int32(pos.y * speed), wheel2: Int32(pos.x * speed), wheel3: 0)
        event?.post(tap: .cghidEventTap)
    }

    // MARK: - Icon

    func updateControllerIcon() {
        _icon = GameControllerIcon(for: self)
    }

    // MARK: - Timer

    func startTimer() {
        stopTimer()
        let checkInterval: TimeInterval = 60
        timer = Timer.scheduledTimer(withTimeInterval: checkInterval, repeats: true) { [weak self] _ in
            guard let lastAccess = self?.lastAccess else { return }
            let now = Date()
            // Auto-disconnect after 30 min idle (hardcoded for now, was AppSettings.disconnectTime)
            let disconnectTime: TimeInterval = 30 * 60
            if now.timeIntervalSince(lastAccess) > disconnectTime {
                self?.disconnect()
            }
        }
        lastAccess = Date()
    }

    func stopTimer() {
        timer?.invalidate()
        timer = nil
    }

    func updateAccessTime() {
        lastAccess = Date()
    }

    @objc func toggleEnableKeyMappings() {
        isEnabled.toggle()
    }

    func disconnect() {
        stopTimer()
        controller?.setHCIState(state: .disconnect)
    }
}

// MARK: - Battery localization (carried over from old code)

extension JoyCon.BatteryStatus {
    static let stringMap: [JoyCon.BatteryStatus: String] = [
        .empty: "Empty", .critical: "Critical", .low: "Low",
        .medium: "Medium", .full: "Full", .unknown: "Unknown",
    ]

    var string: String { Self.stringMap[self] ?? "Unknown" }
    var localizedString: String { NSLocalizedString(string, comment: "BatteryStatus") }
}
```

- [ ] **Step 3: Build to verify**

- [ ] **Step 4: Commit**

```bash
git add JoyMapperSiliconV2/Controllers/
git commit -m "feat: add GameController runtime bridge and icon rendering"
```

---

## Task 6: AppModel — Root observable state + JoyConManager wiring

**Files:**
- Create: `JoyMapperSiliconV2/App/AppModel.swift`
- Modify: `JoyMapperSiliconV2/App/JoyMapperApp.swift`

- [ ] **Step 1: Create `AppModel.swift`**

```swift
// JoyMapperSiliconV2/App/AppModel.swift
import AppKit
import JoyConSwift
import Observation
import Sharing

@Observable
class AppModel {
    let manager = JoyConManager()

    @ObservationIgnored
    @Shared(.fileStorage(
        URL.applicationSupportDirectory
            .appendingPathComponent("JoyMapperSilicon", isDirectory: true)
            .appendingPathComponent("controllers.json")
    ))
    var controllerProfiles: [ControllerProfile] = []

    var controllers: [GameController] = []

    private var workspaceObserver: Any?

    init() {
        manager.connectHandler = { [weak self] controller in
            DispatchQueue.main.async { self?.connectController(controller) }
        }
        manager.disconnectHandler = { [weak self] controller in
            DispatchQueue.main.async { self?.disconnectController(controller) }
        }
        manager.connectionStateHandler = { [weak self] device, state in
            DispatchQueue.main.async { self?.handleConnectionState(device: device, state: state) }
        }

        // Hydrate GameControllers from saved profiles
        for profile in controllerProfiles {
            let gc = makeGameController(for: profile)
            controllers.append(gc)
        }

        _ = manager.runAsync()

        workspaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil, queue: .main
        ) { [weak self] notification in
            guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  let bundleID = app.bundleIdentifier else { return }
            resetMetaKeyState()
            self?.controllers.forEach { $0.switchApp(bundleID: bundleID) }
        }
    }

    deinit {
        if let observer = workspaceObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
    }

    // MARK: - Controller Lifecycle

    private func connectController(_ hidController: JoyConSwift.Controller) {
        let serialID = hidController.serialID

        if let existing = controllers.first(where: { $0.serialID == serialID }) {
            existing.controller = hidController
            existing.connectionState = .connected
            existing.startTimer()
            // Update profile colors from hardware
            updateProfileColors(serialID: serialID, from: existing)
            return
        }

        // New controller — create profile and runtime object
        let profile = ControllerProfile.create(serialID: serialID, type: hidController.type)
        $controllerProfiles.withLock { $0.append(profile) }

        let gc = makeGameController(for: profile)
        gc.controller = hidController
        gc.connectionState = .connected
        gc.startTimer()
        controllers.append(gc)

        // Update profile colors from hardware
        updateProfileColors(serialID: serialID, from: gc)
    }

    private func disconnectController(_ hidController: JoyConSwift.Controller) {
        guard let gc = controllers.first(where: { $0.serialID == hidController.serialID }) else { return }
        gc.controller = nil
        gc.connectionState = .disconnected
        gc.updateControllerIcon()
    }

    private func handleConnectionState(device: IOHIDDevice, state: ConnectionState) {
        let serialID = IOHIDDeviceGetProperty(device, kIOHIDSerialNumberKey as CFString) as? String ?? ""

        switch state {
        case .matching, .initializing:
            if let gc = controllers.first(where: { $0.serialID == serialID && !serialID.isEmpty }) {
                gc.connectionState = .connecting
            }
        case .connected:
            break // Handled by connectHandler
        case .error(let error):
            NSLog("Connection error for %@: %@", serialID, String(describing: error))
            if let gc = controllers.first(where: { $0.serialID == serialID && !serialID.isEmpty }) {
                gc.connectionState = .error
            }
        }
    }

    func removeController(_ gc: GameController) {
        gc.disconnect()
        $controllerProfiles.withLock { profiles in
            profiles.removeAll { $0.id == gc.serialID }
        }
        controllers.removeAll { $0.serialID == gc.serialID }
    }

    // MARK: - Helpers

    private func makeGameController(for profile: ControllerProfile) -> GameController {
        let serialID = profile.id
        return GameController(serialID: serialID, profile: profile) { [weak self] in
            self?.controllerProfiles.first { $0.id == serialID }
        }
    }

    private func updateProfileColors(serialID: String, from gc: GameController) {
        $controllerProfiles.withLock { profiles in
            guard let index = profiles.firstIndex(where: { $0.id == serialID }) else { return }
            profiles[index].controllerType = gc.type.rawValue
            profiles[index].bodyColor = CodableColor(gc.bodyColor)
            profiles[index].buttonColor = CodableColor(gc.buttonColor)
            if let lg = gc.leftGripColor { profiles[index].leftGripColor = CodableColor(lg) }
            if let rg = gc.rightGripColor { profiles[index].rightGripColor = CodableColor(rg) }
        }
    }
}
```

- [ ] **Step 2: Update `JoyMapperApp.swift` to use AppModel**

```swift
// JoyMapperSiliconV2/App/JoyMapperApp.swift
import SwiftUI

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

- [ ] **Step 3: Create a stub `ContentView.swift` so the app compiles**

```swift
// JoyMapperSiliconV2/Views/ContentView.swift
import SwiftUI

struct ContentView: View {
    @Environment(AppModel.self) private var appModel

    var body: some View {
        Text("Controllers: \(appModel.controllers.count)")
            .frame(minWidth: 600, minHeight: 400)
    }
}
```

- [ ] **Step 4: Build to verify**

The app should launch, show the controller count (likely 0), and connect to controllers if a Joy-Con/Pro Controller is paired via Bluetooth.

- [ ] **Step 5: Commit**

```bash
git add JoyMapperSiliconV2/App/ JoyMapperSiliconV2/Views/ContentView.swift
git commit -m "feat: add AppModel with JoyConManager wiring and persistence"
```

---

## Task 7: ContentView — 3-pane layout shell

**Files:**
- Modify: `JoyMapperSiliconV2/Views/ContentView.swift`
- Create: `JoyMapperSiliconV2/Views/ControllerListView.swift`
- Create: `JoyMapperSiliconV2/Views/AppListView.swift`
- Create: `JoyMapperSiliconV2/Views/KeyMapListView.swift`
- Create: `JoyMapperSiliconV2/Views/AccessibilityBanner.swift`

- [ ] **Step 1: Create `AccessibilityBanner.swift`**

```swift
// JoyMapperSiliconV2/Views/AccessibilityBanner.swift
import SwiftUI

struct AccessibilityBanner: View {
    @State private var isTrusted = AXIsProcessTrusted()

    let timer = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

    var body: some View {
        if !isTrusted {
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.yellow)
                Text("Accessibility permission is required for key mapping to work.")
                    .font(.callout)
                Spacer()
                Button("Request Access\u{2026}") {
                    let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary
                    AXIsProcessTrustedWithOptions(options)
                }
                Button("Open Settings\u{2026}") {
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(.yellow.opacity(0.15))
            .onReceive(timer) { _ in
                isTrusted = AXIsProcessTrusted()
            }
        }
    }
}
```

- [ ] **Step 2: Create stub `ControllerListView.swift`**

```swift
// JoyMapperSiliconV2/Views/ControllerListView.swift
import SwiftUI

struct ControllerListView: View {
    @Environment(AppModel.self) private var appModel
    @Binding var selectedControllerID: String?

    var body: some View {
        List(selection: $selectedControllerID) {
            ForEach(appModel.controllers, id: \.serialID) { controller in
                HStack {
                    if let icon = controller.icon {
                        Image(nsImage: icon)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(width: 48, height: 48)
                    }
                    VStack(alignment: .leading) {
                        Text(controller.type.rawValue)
                            .font(.headline)
                        Text(controller.connectionState == .connected ? "Connected" : "Disconnected")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .tag(controller.serialID)
            }
        }
    }
}
```

- [ ] **Step 3: Create stub `AppListView.swift`**

```swift
// JoyMapperSiliconV2/Views/AppListView.swift
import SwiftUI

struct AppListView: View {
    @Environment(AppModel.self) private var appModel
    var controllerID: String?
    @Binding var selectedAppConfigID: UUID?

    private var profile: ControllerProfile? {
        appModel.controllerProfiles.first { $0.id == controllerID }
    }

    var body: some View {
        List(selection: $selectedAppConfigID) {
            if profile != nil {
                Text("Default")
                    .tag(nil as UUID?)

                ForEach(profile?.appConfigs ?? []) { appConfig in
                    HStack {
                        if let icon = NSWorkspace.shared.icon(forFile:
                            NSWorkspace.shared.urlForApplication(withBundleIdentifier: appConfig.bundleID)?.path ?? ""
                        ) {
                            Image(nsImage: icon)
                                .resizable()
                                .frame(width: 20, height: 20)
                        }
                        Text(appConfig.displayName)
                    }
                    .tag(appConfig.id as UUID?)
                }
            }
        }
    }
}
```

- [ ] **Step 4: Create stub `KeyMapListView.swift`**

```swift
// JoyMapperSiliconV2/Views/KeyMapListView.swift
import SwiftUI

struct KeyMapListView: View {
    var keyConfig: KeyConfig?

    var body: some View {
        List {
            if let keyConfig {
                Section("Buttons") {
                    ForEach(keyConfig.keyMaps) { keyMap in
                        HStack {
                            Text(keyMap.button)
                            Spacer()
                            if keyMap.keyCode >= 0 {
                                Text(SpecialKeyName[keyMap.keyCode] ?? "Key \(keyMap.keyCode)")
                                    .foregroundStyle(.secondary)
                            } else if keyMap.mouseButton >= 0 {
                                Text("Mouse \(keyMap.mouseButton)")
                                    .foregroundStyle(.secondary)
                            } else {
                                Text("Not set")
                                    .foregroundStyle(.tertiary)
                            }
                        }
                    }
                }

                if let leftStick = keyConfig.leftStick {
                    Section("Left Stick") {
                        Text("Type: \(leftStick.type.rawValue)")
                    }
                }

                if let rightStick = keyConfig.rightStick {
                    Section("Right Stick") {
                        Text("Type: \(rightStick.type.rawValue)")
                    }
                }
            } else {
                Text("Select a controller and app config")
                    .foregroundStyle(.secondary)
            }
        }
    }
}
```

- [ ] **Step 5: Update `ContentView.swift` with 3-pane layout**

```swift
// JoyMapperSiliconV2/Views/ContentView.swift
import SwiftUI

struct ContentView: View {
    @Environment(AppModel.self) private var appModel

    @State private var selectedControllerID: String?
    @State private var selectedAppConfigID: UUID?

    private var selectedProfile: ControllerProfile? {
        appModel.controllerProfiles.first { $0.id == selectedControllerID }
    }

    private var selectedKeyConfig: KeyConfig? {
        guard let profile = selectedProfile else { return nil }
        if let appConfigID = selectedAppConfigID,
           let appConfig = profile.appConfigs.first(where: { $0.id == appConfigID }) {
            return appConfig.keyConfig
        }
        return profile.defaultKeyConfig
    }

    var body: some View {
        VStack(spacing: 0) {
            AccessibilityBanner()

            HSplitView {
                ControllerListView(selectedControllerID: $selectedControllerID)
                    .frame(minWidth: 160, idealWidth: 200)

                VSplitView {
                    AppListView(
                        controllerID: selectedControllerID,
                        selectedAppConfigID: $selectedAppConfigID
                    )
                    .frame(minHeight: 100, idealHeight: 150)

                    KeyMapListView(keyConfig: selectedKeyConfig)
                        .frame(minHeight: 200)
                }
            }
        }
        .frame(minWidth: 700, minHeight: 500)
    }
}
```

- [ ] **Step 6: Build to verify**

The app should launch with a 3-pane layout. Controller list shows connected controllers, app list shows "Default" when one is selected, key map list shows the empty default config.

- [ ] **Step 7: Commit**

```bash
git add JoyMapperSiliconV2/Views/
git commit -m "feat: add 3-pane layout with controller, app, and key map views"
```

---

## Task 8: KeyConfigEditor — Modal sheet for editing a single KeyMap

**Files:**
- Create: `JoyMapperSiliconV2/Views/KeyConfigEditor.swift`

- [ ] **Step 1: Create `KeyConfigEditor.swift`**

```swift
// JoyMapperSiliconV2/Views/KeyConfigEditor.swift
import SwiftUI
import InputMethodKit

struct KeyConfigEditor: View {
    @Binding var keyMap: KeyMap
    @Environment(\.dismiss) private var dismiss

    // Sorted list of special key names for the picker
    private let keyOptions: [(code: Int, name: String)] = {
        var options = SpecialKeyName.map { (code: $0.key, name: $0.value) }
        options.sort { $0.name < $1.name }
        return options
    }()

    @State private var searchText = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Edit Mapping: \(keyMap.button)")
                .font(.headline)

            Toggle("Enabled", isOn: $keyMap.isEnabled)

            GroupBox("Keyboard") {
                VStack(alignment: .leading, spacing: 8) {
                    Picker("Key", selection: $keyMap.keyCode) {
                        Text("None").tag(-1)
                        ForEach(keyOptions, id: \.code) { option in
                            Text(option.name).tag(option.code)
                        }
                    }

                    HStack {
                        Text("Modifiers:")
                        let modifiers = Binding(
                            get: { NSEvent.ModifierFlags(rawValue: UInt(keyMap.modifiers)) },
                            set: { keyMap.modifiers = Int($0.rawValue) }
                        )
                        Toggle("⇧", isOn: flagBinding(modifiers, flag: .shift))
                        Toggle("⌃", isOn: flagBinding(modifiers, flag: .control))
                        Toggle("⌥", isOn: flagBinding(modifiers, flag: .option))
                        Toggle("⌘", isOn: flagBinding(modifiers, flag: .command))
                    }
                    .toggleStyle(.checkbox)
                }
                .padding(4)
            }

            GroupBox("Mouse") {
                Picker("Mouse Button", selection: $keyMap.mouseButton) {
                    Text("None").tag(-1)
                    Text("Left Click").tag(0)
                    Text("Right Click").tag(1)
                    Text("Middle Click").tag(2)
                    Text("Button 4").tag(3)
                    Text("Button 5").tag(4)
                }
                .padding(4)
            }

            HStack {
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding()
        .frame(width: 350)
    }

    private func flagBinding(_ flags: Binding<NSEvent.ModifierFlags>, flag: NSEvent.ModifierFlags) -> Binding<Bool> {
        Binding(
            get: { flags.wrappedValue.contains(flag) },
            set: { isOn in
                if isOn {
                    flags.wrappedValue.insert(flag)
                } else {
                    flags.wrappedValue.remove(flag)
                }
            }
        )
    }
}
```

- [ ] **Step 2: Build to verify**

- [ ] **Step 3: Commit**

```bash
git add JoyMapperSiliconV2/Views/KeyConfigEditor.swift
git commit -m "feat: add KeyConfigEditor modal sheet"
```

---

## Task 9: Wire KeyMapListView editing — tap to edit, write back to profile

**Files:**
- Modify: `JoyMapperSiliconV2/Views/KeyMapListView.swift`
- Create: `JoyMapperSiliconV2/Views/StickConfigView.swift`

This task connects the key map list to actual editing. Tapping a row opens `KeyConfigEditor` as a sheet. Changes write back through the `@Shared` controller profiles.

- [ ] **Step 1: Create `StickConfigView.swift`**

```swift
// JoyMapperSiliconV2/Views/StickConfigView.swift
import SwiftUI

struct StickConfigView: View {
    @Binding var stickConfig: StickConfig
    var label: String
    @State private var editingKeyMap: KeyMap?
    @State private var editingIndex: Int?

    var body: some View {
        Section(label) {
            Picker("Type", selection: $stickConfig.type) {
                ForEach(StickType.allCases, id: \.self) { type in
                    Text(type.rawValue).tag(type)
                }
            }

            if stickConfig.type == .mouse || stickConfig.type == .mouseWheel {
                HStack {
                    Text("Speed")
                    Slider(value: $stickConfig.speed, in: 1...100)
                    Text("\(Int(stickConfig.speed))")
                        .monospacedDigit()
                        .frame(width: 30)
                }
            }

            if stickConfig.type == .key {
                ForEach(Array(stickConfig.keyMaps.enumerated()), id: \.element.id) { index, keyMap in
                    HStack {
                        Text(keyMap.button)
                        Spacer()
                        if keyMap.keyCode >= 0 {
                            Text(SpecialKeyName[keyMap.keyCode] ?? "Key \(keyMap.keyCode)")
                                .foregroundStyle(.secondary)
                        } else {
                            Text("Not set")
                                .foregroundStyle(.tertiary)
                        }
                    }
                    .contentShape(Rectangle())
                    .onTapGesture {
                        editingKeyMap = keyMap
                        editingIndex = index
                    }
                }
            }
        }
        .sheet(item: $editingKeyMap) { _ in
            if let index = editingIndex {
                KeyConfigEditor(keyMap: $stickConfig.keyMaps[index])
            }
        }
    }
}
```

- [ ] **Step 2: Update `KeyMapListView.swift` with full editing support**

The key map list needs a `Binding` to the `KeyConfig` so edits propagate back. We'll change the API to take a binding.

```swift
// JoyMapperSiliconV2/Views/KeyMapListView.swift
import SwiftUI

struct KeyMapListView: View {
    @Binding var keyConfig: KeyConfig
    var isEmpty: Bool

    @State private var editingIndex: Int?

    var body: some View {
        List {
            if !isEmpty {
                Section("Buttons") {
                    ForEach(Array(keyConfig.keyMaps.enumerated()), id: \.element.id) { index, keyMap in
                        HStack {
                            Text(keyMap.button)
                            Spacer()
                            if keyMap.keyCode >= 0 {
                                Text(SpecialKeyName[keyMap.keyCode] ?? "Key \(keyMap.keyCode)")
                                    .foregroundStyle(.secondary)
                            } else if keyMap.mouseButton >= 0 {
                                Text("Mouse \(keyMap.mouseButton)")
                                    .foregroundStyle(.secondary)
                            } else {
                                Text("Not set")
                                    .foregroundStyle(.tertiary)
                            }
                            Toggle("", isOn: $keyConfig.keyMaps[index].isEnabled)
                                .labelsHidden()
                        }
                        .contentShape(Rectangle())
                        .onTapGesture { editingIndex = index }
                    }
                }

                if keyConfig.leftStick != nil {
                    StickConfigView(
                        stickConfig: Binding(
                            get: { keyConfig.leftStick ?? .defaultConfig() },
                            set: { keyConfig.leftStick = $0 }
                        ),
                        label: "Left Stick"
                    )
                }

                if keyConfig.rightStick != nil {
                    StickConfigView(
                        stickConfig: Binding(
                            get: { keyConfig.rightStick ?? .defaultConfig() },
                            set: { keyConfig.rightStick = $0 }
                        ),
                        label: "Right Stick"
                    )
                }
            } else {
                Text("Select a controller and app config")
                    .foregroundStyle(.secondary)
            }
        }
        .sheet(item: $editingIndex) { index in
            KeyConfigEditor(keyMap: $keyConfig.keyMaps[index])
        }
    }
}

extension Int: @retroactive Identifiable {
    public var id: Int { self }
}
```

- [ ] **Step 3: Update `ContentView.swift` to pass bindings for editing**

The `ContentView` needs to provide a `Binding<KeyConfig>` that writes back to the `@Shared` controller profiles. Replace the computed `selectedKeyConfig` with a binding approach.

```swift
// JoyMapperSiliconV2/Views/ContentView.swift
import SwiftUI
import Sharing

struct ContentView: View {
    @Environment(AppModel.self) private var appModel

    @State private var selectedControllerID: String?
    @State private var selectedAppConfigID: UUID?

    private var profileIndex: Int? {
        appModel.controllerProfiles.firstIndex { $0.id == selectedControllerID }
    }

    var body: some View {
        @Bindable var appModel = appModel

        VStack(spacing: 0) {
            AccessibilityBanner()

            HSplitView {
                ControllerListView(selectedControllerID: $selectedControllerID)
                    .frame(minWidth: 160, idealWidth: 200)

                VSplitView {
                    AppListView(
                        controllerID: selectedControllerID,
                        selectedAppConfigID: $selectedAppConfigID
                    )
                    .frame(minHeight: 100, idealHeight: 150)

                    if let profileIdx = profileIndex {
                        if let appConfigID = selectedAppConfigID,
                           let appIdx = appModel.controllerProfiles[profileIdx].appConfigs.firstIndex(where: { $0.id == appConfigID }) {
                            KeyMapListView(
                                keyConfig: appModel.$controllerProfiles[profileIdx].appConfigs[appIdx].keyConfig,
                                isEmpty: false
                            )
                            .frame(minHeight: 200)
                        } else {
                            KeyMapListView(
                                keyConfig: appModel.$controllerProfiles[profileIdx].defaultKeyConfig,
                                isEmpty: false
                            )
                            .frame(minHeight: 200)
                        }
                    } else {
                        KeyMapListView(
                            keyConfig: .constant(KeyConfig(keyMaps: [])),
                            isEmpty: true
                        )
                        .frame(minHeight: 200)
                    }
                }
            }
        }
        .frame(minWidth: 700, minHeight: 500)
    }
}
```

**Note:** The `appModel.$controllerProfiles` binding syntax works because `@Shared` provides projected bindings. If this doesn't compile directly, the binding will need to go through `appModel.$controllerProfiles.withLock` or a helper on `AppModel` that returns the appropriate `Binding<KeyConfig>`. Adjust as needed during implementation.

- [ ] **Step 4: Build to verify**

Verify that tapping a key map row opens the editor sheet, and changes are reflected in the list and auto-persisted to disk.

- [ ] **Step 5: Commit**

```bash
git add JoyMapperSiliconV2/Views/
git commit -m "feat: wire up key map editing with bindings and StickConfigView"
```

---

## Task 10: Copy/Paste support for KeyConfig

**Files:**
- Create: `JoyMapperSiliconV2/Utilities/KeyConfigClipboard.swift`

- [ ] **Step 1: Create `KeyConfigClipboard.swift`**

```swift
// JoyMapperSiliconV2/Utilities/KeyConfigClipboard.swift
import AppKit

enum KeyConfigClipboard {
    static let pasteboardType = NSPasteboard.PasteboardType("com.elliotfiske.JoyMapperSilicon.KeyConfig")

    static func copy(_ keyConfig: KeyConfig) {
        guard let data = try? JSONEncoder().encode(keyConfig) else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setData(data, forType: pasteboardType)
    }

    static func paste() -> KeyConfig? {
        guard let data = NSPasteboard.general.data(forType: pasteboardType) else { return nil }
        return try? JSONDecoder().decode(KeyConfig.self, from: data)
    }

    static func canPaste() -> Bool {
        NSPasteboard.general.data(forType: pasteboardType) != nil
    }
}
```

- [ ] **Step 2: Build to verify**

- [ ] **Step 3: Commit**

```bash
git add JoyMapperSiliconV2/Utilities/KeyConfigClipboard.swift
git commit -m "feat: add KeyConfig copy/paste via NSPasteboard"
```

---

## Task 11: AppListView — add/remove per-app configs

**Files:**
- Modify: `JoyMapperSiliconV2/Views/AppListView.swift`

- [ ] **Step 1: Update `AppListView.swift` with add/remove functionality**

```swift
// JoyMapperSiliconV2/Views/AppListView.swift
import SwiftUI

struct AppListView: View {
    @Environment(AppModel.self) private var appModel
    var controllerID: String?
    @Binding var selectedAppConfigID: UUID?

    private var profile: ControllerProfile? {
        appModel.controllerProfiles.first { $0.id == controllerID }
    }

    var body: some View {
        VStack(spacing: 0) {
            List(selection: $selectedAppConfigID) {
                if profile != nil {
                    Text("Default")
                        .tag(nil as UUID?)

                    ForEach(profile?.appConfigs ?? []) { appConfig in
                        HStack {
                            let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: appConfig.bundleID)
                            let icon = appURL.flatMap { NSWorkspace.shared.icon(forFile: $0.path) }
                            if let icon {
                                Image(nsImage: icon)
                                    .resizable()
                                    .frame(width: 20, height: 20)
                            }
                            Text(appConfig.displayName)
                        }
                        .tag(appConfig.id as UUID?)
                    }
                }
            }

            HStack {
                Button(action: addApp) {
                    Image(systemName: "plus")
                }
                .disabled(profile == nil)

                Button(action: removeApp) {
                    Image(systemName: "minus")
                }
                .disabled(selectedAppConfigID == nil)

                Spacer()
            }
            .padding(4)
        }
    }

    private func addApp() {
        guard let profile else { return }

        let panel = NSOpenPanel()
        panel.message = "Choose an app to add"
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canCreateDirectories = false
        panel.canChooseFiles = true
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")

        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            guard let bundle = Bundle(url: url),
                  let info = bundle.infoDictionary,
                  let bundleID = info["CFBundleIdentifier"] as? String else { return }

            // Don't add duplicates
            guard !profile.appConfigs.contains(where: { $0.bundleID == bundleID }) else { return }

            let displayName = FileManager.default.displayName(atPath: url.path)
            let hasLeftStick = profile.type == .JoyConL || profile.type == .ProController
            let hasRightStick = profile.type == .JoyConR || profile.type == .ProController

            let newConfig = AppConfig(
                bundleID: bundleID,
                displayName: displayName,
                keyConfig: KeyConfig(
                    keyMaps: [],
                    leftStick: hasLeftStick ? .defaultConfig() : nil,
                    rightStick: hasRightStick ? .defaultConfig() : nil
                )
            )

            appModel.$controllerProfiles.withLock { profiles in
                guard let index = profiles.firstIndex(where: { $0.id == controllerID }) else { return }
                profiles[index].appConfigs.append(newConfig)
            }
        }
    }

    private func removeApp() {
        guard let appConfigID = selectedAppConfigID else { return }

        appModel.$controllerProfiles.withLock { profiles in
            guard let index = profiles.firstIndex(where: { $0.id == controllerID }) else { return }
            profiles[index].appConfigs.removeAll { $0.id == appConfigID }
        }
        selectedAppConfigID = nil
    }
}
```

- [ ] **Step 2: Build to verify**

- [ ] **Step 3: Commit**

```bash
git add JoyMapperSiliconV2/Views/AppListView.swift
git commit -m "feat: add per-app config add/remove in AppListView"
```

---

## Task 12: Final integration — verify end-to-end flow

**Files:** No new files. This task is verification only.

- [ ] **Step 1: Build the app**

```bash
cd /Users/efiske/conductor/workspaces/JoyMapperSilicon/marseille-v1
tuist generate --no-open
```

Then build via Xcode or xcodebuild.

- [ ] **Step 2: Manual smoke test**

Verify:
1. App launches as a dock app (no menu bar icon)
2. Window shows 3-pane layout with accessibility banner if needed
3. If a controller is paired: it appears in the left pane, "Default" appears in the app list
4. Selecting a controller shows its default key config (empty buttons list initially)
5. Adding an app via the + button opens the file picker
6. The `controllers.json` file is created in `~/Library/Application Support/JoyMapperSilicon/`

- [ ] **Step 3: Commit any final fixes**

```bash
git add -A
git commit -m "fix: integration fixes from smoke testing"
```

(Only if there were fixes needed.)
