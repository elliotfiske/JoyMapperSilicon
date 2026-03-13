# JoyMapperSilicon

macOS app that maps Nintendo Joy-Con and Pro Controller inputs to keyboard/mouse events via Bluetooth HID.

## Architecture

### Layers

1. **JoyConSwift** (`Vendor/JoyConSwift/Sources/`) — Vendored framework. IOHIDManager-based HID device detection and raw report parsing. Controller subclasses: `ProController`, `JoyConL`, `JoyConR`, `SNESController`, `FamicomController1/2`.

2. **GameController** (`JoyKeyMapper/DataModels/GameController.swift`) — Bridges JoyConSwift to macOS input. Registers button/stick handlers, looks up KeyMap configs, dispatches `CGEvent` key/mouse events via `.cghidEventTap`. Handles per-app config switching via `NSWorkspace.didActivateApplicationNotification`.

3. **UI** (`JoyKeyMapper/Views/`) — AppKit with storyboards. Main `ViewController` has three panes: controller collection view (left), app table (top-right), key mapping outline view (bottom-right). `KeyConfigViewController` is the modal editor for individual mappings.

4. **Core Data** (`JoyKeyMapper/DataModels/`) — Persists controller profiles. Entity chain: `ControllerData` → `AppConfig` → `KeyConfig` → `KeyMap`/`StickConfig`. `DataManager` wraps `NSPersistentContainer`.

### Input Flow

```
IOKit HID report → JoyConManager.handleInput
  → Controller.handleFullSensorInput (0x30) or handleFullCommandInput (0x21)
    → ProController.readStandardState (parses button bytes at ptr+2/3/4)
      → Controller.setButtonState (diff against previous state)
        → GameController.buttonPressHandler (lookup KeyMap → CGEvent.post)
```

### Build System

Tuist (`Project.swift`) defines 3 targets:
- **JoyMapperSilicon** — main app (macOS 26.0)
- **JoyMapperSiliconLauncher** — login item helper
- **JoyConSwift** — vendored framework

Sources use globs (`JoyKeyMapper/**/*.swift`), so new .swift files are auto-included.

## Bluetooth Controller & Accessibility Quirks

### Accessibility Permission (CGEvent.post)

`CGEvent.post(tap: .cghidEventTap)` **silently fails** without Accessibility permission. There is no error — events just don't arrive. Check with `AXIsProcessTrusted()`.

**Rebuilding the app invalidates the Accessibility grant** because the code signature changes. After rebuilding:
1. Open System Settings → Privacy & Security → Accessibility
2. Toggle the app off, then back on (or remove and re-add)

Multiple worktrees / build locations create **duplicate stale entries** in the Accessibility list. To clean up:
```bash
tccutil reset Accessibility com.elliotfiske.JoyMapperSilicon
```
Note: `tccutil` clears the TCC database but the System Settings UI may cache stale state. You may need to manually remove/re-add the entry in the UI after resetting.

### HID Reports

- Report ID `0x30` = full sensor input (~60fps), contains buttons + sticks + IMU
- Report ID `0x21` = full command response (ACK/NACK for subcommands)
- Report ID `0x3F` = simple input (basic button state)
- Button bytes are at offsets ptr+2, ptr+3, ptr+4 in standard reports
- Joystick drift can cause constant non-zero reports even when idle

### Controller Connection

Controllers connect via Bluetooth HID. `JoyConManager` uses `IOHIDManager` with matching dictionaries for Nintendo vendor/product IDs. The manager seizes devices and runs input callbacks on a background RunLoop. Initialization sends subcommands to read calibration data, colors, and set input mode to `standardFull`.

## GitHub: Auth Switch for Personal Repo Operations

This repo (`elliotfiske/JoyMapperSilicon`) is owned by a personal GitHub account, but the active `gh` CLI session uses an Enterprise Managed User (`efiske_life360`). To run GitHub operations (create PRs, merge, etc.), temporarily switch accounts:

```bash
gh auth switch --user elliotfiske && <gh command>; gh auth switch --user efiske_life360
```

Note: `gh auth` state is global, so this will affect any other active agents while switched.
