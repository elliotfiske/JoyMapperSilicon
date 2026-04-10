# Bluetooth Connection Debug UI

## Problem

Controllers that are paired and connected in macOS Bluetooth settings sometimes don't appear as connected in JoyMapperSilicon. The HID handshake has multiple steps (match, type query, initialization, calibration) where a controller can get stuck, but the current UI only shows "Connected" or nothing — no visibility into what went wrong.

## Solution

Two additions:

1. **Descriptive status labels** on each controller cell showing the current connection state and error reason.
2. **Collapsible log panel** at the bottom of the main window streaming timestamped HID lifecycle events.

---

## 1. Controller Cell Label States

Update `ControllerViewItem` label to show the full connection state instead of binary connected/empty.

| `ConnectionDisplayState` | Label text |
|---|---|
| `.disconnected` | "" (empty) |
| `.connecting` | "Connecting..." |
| `.connected` | "Connected" |
| `.error` | "Error: {reason}" |

Error reasons map from `ConnectionError`:
- `.typeQueryFailed(retryCount:)` → "type query failed (retry {n})"
- `.typeQueryTimeout` → "type query timeout"
- `.initializationTimeout` → "initialization timeout"
- `.reseizeFailed` → "reseize failed"
- `.communicationFailure` → "communication failure"

### Changes required

- **`GameController`**: Add `var lastConnectionError: ConnectionError?` property. Set it in `AppDelegate.handleConnectionState` when receiving `.error(...)`.
- **`GameController`**: Add a computed `statusText: String` property that returns the label string based on `connectionDisplayState` and `lastConnectionError`.
- **`ViewController+NSCollectionViewDelegate`**: Replace the current binary label logic with `controller.statusText`.

---

## 2. ConnectionLog Singleton

A simple in-memory log that the rest of the app writes to.

### API

```swift
class ConnectionLog {
    static let shared = ConnectionLog()

    /// Append a timestamped log entry
    func log(_ message: String, device: String? = nil)

    /// Return all log entries as a single newline-joined string
    func copyAll() -> String
}
```

### Format

Each entry is a pre-formatted string:

```
[12:34:56.789] [8A3B2C1D] Pro Controller matched
[12:34:56.789] [unknown] Device matched (no serial)
[12:34:57.001] HID manager opened, scanning for devices
```

- Timestamp: `HH:mm:ss.SSS` wall clock
- Device ID: truncated serial ID, or "unknown" if empty. Omitted entirely for system-level messages (no brackets).
- Message: free-form string

### Storage

- `[String]` array, append-only
- No max size cap (a session produces a few hundred lines at most)
- Posts `Notification.Name.connectionLogUpdated` on each append so the UI can react

---

## 3. Collapsible Log Panel

### Layout

Inserted programmatically in `ViewController.viewDidLoad`, wrapping the existing storyboard content and the new log panel in a vertical `NSSplitView`. Same pattern as the existing accessibility banner insertion.

```
+--------------------------------------------------+
|  [Accessibility banner - existing]               |
+--------------------------------------------------+
|                                                  |
|  [Existing split view: controllers | apps/keys]  |
|                                                  |
+--------------------------------------------------+
|  Connection Log  [Copy Log] [v collapse toggle]  |  <- header bar
|  [12:34:56.789] [8A3B2C1D] Pro Controller matched|  <- NSTextView
|  [12:34:57.001] [8A3B2C1D] Type query sent       |
+--------------------------------------------------+
```

### Components

- **Outer `NSSplitView`** (vertical): top item = existing main content, bottom item = log panel
- **Header bar** (`NSView`): contains "Connection Log" label, "Copy Log" button (calls `ConnectionLog.shared.copyAll()` → pasteboard), collapse/expand toggle button
- **Log body**: `NSScrollView` containing a non-editable `NSTextView` with monospaced font. Auto-scrolls to bottom on new entries.
- **Collapse behavior**: toggle button hides/shows the log body `NSScrollView`. When collapsed, only the header bar is visible. Default state: collapsed.
- **Expanded height**: ~150-200pt

### Updating

`ViewController` observes `.connectionLogUpdated`. On notification, appends the new entry to the text view and scrolls to bottom.

---

## 4. Instrumentation Points

### JoyConSwift framework layer

Since JoyConSwift is a separate framework, it cannot reference `ConnectionLog` directly. Add a logging closure on `JoyConManager`:

```swift
public var logHandler: ((_ message: String, _ deviceSerial: String?) -> Void)?
```

Instrumentation sites in `JoyConManager.swift`:

| Location | Message |
|---|---|
| `run()` after `IOHIDManagerOpen` | "HID manager opened, scanning for devices" |
| `handleMatch` | "Device matched" |
| `sendTypeQueryWithTimeout` | "Type query sent" |
| `handleControllerType` (success) | "Controller type identified: {type}" |
| `handleControllerType` (unknown) | "Unknown controller type byte: 0x{hex}" |
| `handleMatchingTimeout` | "Type query timeout, retry {n}" |
| Re-seize path | "Attempting re-seize" / "Re-seize failed" |
| `handleRemove` | "Device removed" |

Instrumentation sites in `Controller.swift`:

| Location | Message |
|---|---|
| `readInitializeData` start | "Reading controller color..." |
| After color read | "Reading calibration..." |
| `readInitializeData` completion | "Initialization complete" |
| Error handler | "Communication error: {detail}" |

### App layer (AppDelegate)

Wire `manager.logHandler` to `ConnectionLog.shared.log(...)` in `applicationDidFinishLaunching`.

Additional direct `ConnectionLog` calls in `AppDelegate`:

| Location | Message |
|---|---|
| `connectController` (existing match) | "Controller connected: {type} ({serialID})" |
| `addController` (new) | "New controller added: {type} ({serialID})" |
| `disconnectController` | "Controller disconnected: {serialID}" |
| `handleConnectionState` | "State changed to {state} for {serialID}" |

---

## Files Modified

- `Vendor/JoyConSwift/Sources/JoyConManager.swift` — add `logHandler`, instrument lifecycle
- `Vendor/JoyConSwift/Sources/Controller.swift` — instrument init handshake
- `JoyKeyMapper/DataModels/GameController.swift` — add `lastConnectionError`, `statusText`
- `JoyKeyMapper/Views/ControllerList/ViewController+NSCollectionViewDelegate.swift` — use `statusText`
- `JoyKeyMapper/Misc/Notifications.swift` — add `.connectionLogUpdated`
- `JoyKeyMapper/AppDelegate.swift` — wire `logHandler`, add log calls

## Files Created

- `JoyKeyMapper/DataModels/ConnectionLog.swift` — singleton log class
- `JoyKeyMapper/Views/ConnectionLogPanelView.swift` — collapsible log panel view
