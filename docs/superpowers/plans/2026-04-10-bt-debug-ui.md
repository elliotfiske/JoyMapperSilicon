# Bluetooth Connection Debug UI Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add visible connection state labels and a collapsible log panel to diagnose controllers that appear connected in macOS Bluetooth but fail to complete the HID handshake in the app.

**Architecture:** A `ConnectionLog` singleton collects timestamped messages from both the JoyConSwift framework (via a `logHandler` closure) and the app layer. The main ViewController gets a collapsible log panel at the bottom via an `NSSplitView` wrapper. Controller cell labels show the full `ConnectionDisplayState` including specific error reasons.

**Tech Stack:** AppKit (NSTextView, NSSplitView), JoyConSwift (IOHIDManager)

---

## File Map

| File | Action | Responsibility |
|---|---|---|
| `JoyKeyMapper/DataModels/ConnectionLog.swift` | Create | Singleton log: append entries, notify UI, copy-all |
| `JoyKeyMapper/DataModels/GameController.swift` | Modify | Add `lastConnectionError`, `statusText` computed property |
| `JoyKeyMapper/Misc/Notifications.swift` | Modify | Add `.connectionLogUpdated` |
| `JoyKeyMapper/Views/ControllerList/ViewController+NSCollectionViewDelegate.swift` | Modify | Use `statusText` for label |
| `JoyKeyMapper/Views/ConnectionLogPanelView.swift` | Create | Collapsible log panel with header bar, text view, copy button |
| `JoyKeyMapper/Views/ViewController.swift` | Modify | Insert log panel via NSSplitView, observe log updates |
| `Vendor/JoyConSwift/Sources/JoyConManager.swift` | Modify | Add `logHandler` closure, instrument lifecycle |
| `Vendor/JoyConSwift/Sources/Controller.swift` | Modify | Instrument init handshake via manager's `logHandler` |
| `JoyKeyMapper/AppDelegate.swift` | Modify | Wire `logHandler`, add log calls to connect/disconnect/state handlers |

---

### Task 1: ConnectionLog singleton and notification

**Files:**
- Create: `JoyKeyMapper/DataModels/ConnectionLog.swift`
- Modify: `JoyKeyMapper/Misc/Notifications.swift:11-19`

- [ ] **Step 1: Add `.connectionLogUpdated` notification**

In `JoyKeyMapper/Misc/Notifications.swift`, add one line inside the `Notification.Name` extension:

```swift
    static let connectionLogUpdated = Notification.Name("ConnectionLogUpdated")
```

Add it after the existing `.controllerConnectionFailed` line (line 18).

- [ ] **Step 2: Create ConnectionLog.swift**

Create `JoyKeyMapper/DataModels/ConnectionLog.swift`:

```swift
//
//  ConnectionLog.swift
//  JoyKeyMapper
//

import Foundation

class ConnectionLog {
    static let shared = ConnectionLog()

    private var entries: [String] = []
    private let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

    private init() {}

    func log(_ message: String, device: String? = nil) {
        let timestamp = dateFormatter.string(from: Date())
        let deviceTag: String
        if let device = device, !device.isEmpty {
            let truncated = String(device.suffix(8))
            deviceTag = " [\(truncated)]"
        } else if device != nil {
            deviceTag = " [unknown]"
        } else {
            deviceTag = ""
        }
        let entry = "[\(timestamp)]\(deviceTag) \(message)"
        entries.append(entry)
        NotificationCenter.default.post(name: .connectionLogUpdated, object: entry)
    }

    func copyAll() -> String {
        return entries.joined(separator: "\n")
    }
}
```

- [ ] **Step 3: Commit**

```bash
git add JoyKeyMapper/DataModels/ConnectionLog.swift JoyKeyMapper/Misc/Notifications.swift
git commit -m "feat: add ConnectionLog singleton and notification"
```

---

### Task 2: GameController status text and error storage

**Files:**
- Modify: `JoyKeyMapper/DataModels/GameController.swift:9,60-73`
- Modify: `JoyKeyMapper/Views/ControllerList/ViewController+NSCollectionViewDelegate.swift:11,29-31`

- [ ] **Step 1: Add JoyConSwift import awareness and error storage**

In `JoyKeyMapper/DataModels/GameController.swift`, add `lastConnectionError` property after the `connectionState` property (after line 73):

```swift
    var lastConnectionError: ConnectionError? = nil
```

- [ ] **Step 2: Add statusText computed property**

Add this computed property right after `lastConnectionError`:

```swift
    var statusText: String {
        switch connectionState {
        case .disconnected:
            return ""
        case .connecting:
            return NSLocalizedString("Connecting…", comment: "Controller connecting status")
        case .connected:
            return NSLocalizedString("Connected", comment: "Controller connected status")
        case .error:
            guard let error = lastConnectionError else {
                return NSLocalizedString("Error", comment: "Controller error status")
            }
            switch error {
            case .typeQueryFailed(let retryCount):
                return "Error: type query failed (retry \(retryCount))"
            case .typeQueryTimeout:
                return "Error: type query timeout"
            case .initializationTimeout:
                return "Error: initialization timeout"
            case .reseizeFailed:
                return "Error: reseize failed"
            case .communicationFailure:
                return "Error: communication failure"
            }
        }
    }
```

- [ ] **Step 3: Update collection view delegate to use statusText**

In `JoyKeyMapper/Views/ControllerList/ViewController+NSCollectionViewDelegate.swift`, replace line 11:

```swift
let connected = NSLocalizedString("Connected", comment: "Connected")
```

Remove it (it's now unused). Then replace line 31:

```swift
        controllerItem.label.stringValue = controller.controller != nil ? connected : ""
```

with:

```swift
        controllerItem.label.stringValue = controller.statusText
```

- [ ] **Step 4: Commit**

```bash
git add JoyKeyMapper/DataModels/GameController.swift JoyKeyMapper/Views/ControllerList/ViewController+NSCollectionViewDelegate.swift
git commit -m "feat: show descriptive connection state in controller cell labels"
```

---

### Task 3: Store ConnectionError in AppDelegate handlers

**Files:**
- Modify: `JoyKeyMapper/AppDelegate.swift:177-190,201-213,215-247`

- [ ] **Step 1: Set lastConnectionError in handleConnectionState**

In `JoyKeyMapper/AppDelegate.swift`, in `handleConnectionState` method (line 215), update the `.error` case to store the error on the GameController. Replace lines 237-244:

```swift
        case .error(let error):
            NSLog("Connection error for %@: %@", deviceName, String(describing: error))
            DispatchQueue.main.async {
                if let gameController = self.controllers.first(where: { $0.data.serialID == serialID && !serialID.isEmpty }) {
                    gameController.lastConnectionError = error
                    gameController.connectionState = .error
                }
                NotificationCenter.default.post(name: .controllerConnectionFailed, object: nil)
            }
            AppNotifications.notifyControllerConnectionFailed(deviceName)
```

The only change is adding `gameController.lastConnectionError = error` before setting `connectionState`.

- [ ] **Step 2: Clear lastConnectionError on successful connection**

In `connectController` (line 177), add a line to clear the error when a controller connects successfully. After `gameController.controller = controller` (line 181):

```swift
            gameController.lastConnectionError = nil
            gameController.connectionState = .connected
```

And in `addController` (line 249), after `gameController.controller = controller` (line 253):

```swift
        gameController.lastConnectionError = nil
        gameController.connectionState = .connected
```

These lines already set `.connected`; just add the `lastConnectionError = nil` before them.

- [ ] **Step 3: Commit**

```bash
git add JoyKeyMapper/AppDelegate.swift
git commit -m "feat: store ConnectionError on GameController for UI display"
```

---

### Task 4: Collapsible log panel view

**Files:**
- Create: `JoyKeyMapper/Views/ConnectionLogPanelView.swift`

- [ ] **Step 1: Create ConnectionLogPanelView**

Create `JoyKeyMapper/Views/ConnectionLogPanelView.swift`:

```swift
//
//  ConnectionLogPanelView.swift
//  JoyKeyMapper
//

import AppKit

class ConnectionLogPanelView: NSView {
    private let headerView = NSView()
    private let scrollView = NSScrollView()
    private let textView = NSTextView()
    private let collapseButton = NSButton()
    private var isExpanded = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupViews()
        observeLog()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupViews()
        observeLog()
    }

    private func setupViews() {
        self.translatesAutoresizingMaskIntoConstraints = false

        // Header bar
        headerView.translatesAutoresizingMaskIntoConstraints = false
        headerView.wantsLayer = true
        headerView.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        addSubview(headerView)

        let titleLabel = NSTextField(labelWithString: "Connection Log")
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize, weight: .medium)
        titleLabel.textColor = .secondaryLabelColor
        headerView.addSubview(titleLabel)

        let copyButton = NSButton(title: "Copy Log", target: self, action: #selector(copyLog))
        copyButton.translatesAutoresizingMaskIntoConstraints = false
        copyButton.bezelStyle = .recessed
        copyButton.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        copyButton.setContentHuggingPriority(.required, for: .horizontal)
        headerView.addSubview(copyButton)

        collapseButton.translatesAutoresizingMaskIntoConstraints = false
        collapseButton.bezelStyle = .disclosure
        collapseButton.title = ""
        collapseButton.state = .off
        collapseButton.target = self
        collapseButton.action = #selector(toggleCollapse)
        collapseButton.setContentHuggingPriority(.required, for: .horizontal)
        headerView.addSubview(collapseButton)

        // Scroll view + text view
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder

        textView.isEditable = false
        textView.isSelectable = true
        textView.font = NSFont.monospacedSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
        textView.backgroundColor = NSColor(white: 0.1, alpha: 1.0)
        textView.textColor = NSColor(white: 0.9, alpha: 1.0)
        textView.textContainerInset = NSSize(width: 8, height: 4)
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isRichText = false

        scrollView.documentView = textView
        addSubview(scrollView)

        // Start collapsed
        scrollView.isHidden = true

        // Layout
        NSLayoutConstraint.activate([
            headerView.topAnchor.constraint(equalTo: topAnchor),
            headerView.leadingAnchor.constraint(equalTo: leadingAnchor),
            headerView.trailingAnchor.constraint(equalTo: trailingAnchor),
            headerView.heightAnchor.constraint(equalToConstant: 28),

            collapseButton.leadingAnchor.constraint(equalTo: headerView.leadingAnchor, constant: 6),
            collapseButton.centerYAnchor.constraint(equalTo: headerView.centerYAnchor),

            titleLabel.leadingAnchor.constraint(equalTo: collapseButton.trailingAnchor, constant: 4),
            titleLabel.centerYAnchor.constraint(equalTo: headerView.centerYAnchor),

            copyButton.trailingAnchor.constraint(equalTo: headerView.trailingAnchor, constant: -10),
            copyButton.centerYAnchor.constraint(equalTo: headerView.centerYAnchor),

            scrollView.topAnchor.constraint(equalTo: headerView.bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    private func observeLog() {
        NotificationCenter.default.addObserver(self, selector: #selector(logUpdated(_:)), name: .connectionLogUpdated, object: nil)
    }

    @objc private func logUpdated(_ notification: Notification) {
        guard let entry = notification.object as? String else { return }
        let appendBlock = { [weak self] in
            guard let self = self else { return }
            let storage = self.textView.textStorage!
            let needsNewline = storage.length > 0
            let text = (needsNewline ? "\n" : "") + entry
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.monospacedSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular),
                .foregroundColor: NSColor(white: 0.9, alpha: 1.0)
            ]
            storage.append(NSAttributedString(string: text, attributes: attrs))
            self.textView.scrollToEndOfDocument(nil)
        }
        if Thread.isMainThread {
            appendBlock()
        } else {
            DispatchQueue.main.async(execute: appendBlock)
        }
    }

    @objc private func copyLog() {
        let text = ConnectionLog.shared.copyAll()
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    @objc private func toggleCollapse() {
        isExpanded.toggle()
        scrollView.isHidden = !isExpanded
        collapseButton.state = isExpanded ? .on : .off

        // Notify the enclosing split view to re-layout
        if let splitView = self.superview as? NSSplitView {
            splitView.adjustSubviews()
        }
    }
}
```

- [ ] **Step 2: Commit**

```bash
git add JoyKeyMapper/Views/ConnectionLogPanelView.swift
git commit -m "feat: add collapsible connection log panel view"
```

---

### Task 5: Integrate log panel into ViewController

**Files:**
- Modify: `JoyKeyMapper/Views/ViewController.swift:51-84`

- [ ] **Step 1: Add log panel property**

In `JoyKeyMapper/Views/ViewController.swift`, add a property after the `accessibilityCheckTimer` property (line 52):

```swift
    private var connectionLogPanel: ConnectionLogPanelView?
```

- [ ] **Step 2: Add setupConnectionLogPanel method**

Add this method after the `updateAccessibilityBanner` method (after line 158):

```swift
    private func setupConnectionLogPanel() {
        guard let window = self.view.window else { return }
        guard let contentView = window.contentView else { return }

        // Replace window.contentView with an NSSplitView.
        // The old contentView becomes the top pane; the log panel is the bottom pane.
        let splitView = NSSplitView()
        splitView.isVertical = false  // horizontal split (top/bottom)
        splitView.dividerStyle = .thin

        let oldContentView = contentView
        let logPanel = ConnectionLogPanelView()
        self.connectionLogPanel = logPanel

        splitView.addArrangedSubview(oldContentView)
        splitView.addArrangedSubview(logPanel)

        window.contentView = splitView

        // Set the log panel to its collapsed height (just the header bar)
        splitView.setPosition(splitView.bounds.height - 28, ofDividerAt: 0)

        // Set holding priorities so the log panel stays small and the main content resizes
        splitView.setHoldingPriority(.defaultLow, forSubviewAt: 1)
        splitView.setHoldingPriority(.defaultHigh, forSubviewAt: 0)
    }
```

- [ ] **Step 3: Call setupConnectionLogPanel in viewDidAppear**

Add `viewDidAppear` override after `viewDidLoad` (after line 84):

```swift
    override func viewDidAppear() {
        super.viewDidAppear()
        if connectionLogPanel == nil {
            setupConnectionLogPanel()
        }
    }
```

We use `viewDidAppear` instead of `viewDidLoad` because the window is not available yet in `viewDidLoad`.

- [ ] **Step 4: Commit**

```bash
git add JoyKeyMapper/Views/ViewController.swift
git commit -m "feat: integrate collapsible log panel into main window"
```

---

### Task 6: Add logHandler to JoyConManager and instrument lifecycle

**Files:**
- Modify: `Vendor/JoyConSwift/Sources/JoyConManager.swift:40-103,186-252,280-326`
- Modify: `Vendor/JoyConSwift/Sources/Controller.swift:129,164-194`

- [ ] **Step 1: Add logHandler property to JoyConManager**

In `Vendor/JoyConSwift/Sources/JoyConManager.swift`, add after `connectionStateHandler` (line 65):

```swift
    /// Handler for debug log messages
    public var logHandler: ((_ message: String, _ deviceSerial: String?) -> Void)? = nil
```

- [ ] **Step 2: Add helper to get serial from device**

Add a private helper method after the `init()` (after line 75):

```swift
    private func serialID(for device: IOHIDDevice) -> String? {
        return IOHIDDeviceGetProperty(device, kIOHIDSerialNumberKey as CFString) as? String
    }
```

- [ ] **Step 3: Instrument handleMatch**

In `handleMatch` (line 92), add a log call after setting `matchingControllers[device]` (after line 100):

```swift
        let serial = self.serialID(for: device)
        self.logHandler?("Device matched (HID game pad detected)", serial)
```

- [ ] **Step 4: Instrument handleControllerType**

In `handleControllerType` (line 105), add log calls. After the switch statement creates the controller (after line 136), before `guard let controller = _controller`:

```swift
        if _controller != nil {
            self.logHandler?("Controller type identified: \(_controller!.type.rawValue)", _controller!.serialID)
        } else {
            self.logHandler?("Unknown controller type byte: 0x\(String(format: "%02X", data[0]))", self.serialID(for: device))
        }
```

After `readInitializeData` is called (inside the closure at line 147), add before `connectHandler`:

```swift
            self?.logHandler?("Initialization complete", controller.serialID)
```

So lines 147-150 become:

```swift
        controller.readInitializeData { [weak self] in
            self?.logHandler?("Initialization complete", controller.serialID)
            self?.connectionStateHandler?(device, .connected)
            self?.connectHandler?(controller)
        }
```

Also add a log when initializing starts (after line 146):

```swift
        self.logHandler?("Initializing controller...", controller.serialID)
```

- [ ] **Step 5: Instrument handleRemove**

In `handleRemove` (line 170), add log calls. After the matching-controllers early return (line 174), add:

```swift
        // (existing line) guard let controller = self.controllers[device] else { return }
```

After that guard, add:

```swift
        self.logHandler?("Device removed", controller.serialID)
```

For the matching case (when a matching device is removed before type identification), add before line 172:

```swift
        if self.matchingControllers[device] != nil {
            self.logHandler?("Matching device removed before identification", self.serialID(for: device))
```

- [ ] **Step 6: Instrument sendTypeQueryWithTimeout**

In `sendTypeQueryWithTimeout` (line 186), add a log at the start:

```swift
        self.logHandler?("Sending type query...", self.serialID(for: device))
```

And on failure (after line 191):

```swift
            self.logHandler?("Type query send failed (IOReturn: \(result))", self.serialID(for: device))
```

- [ ] **Step 7: Instrument handleMatchingTimeout and re-seize**

In `handleMatchingTimeout` (line 207), add logs at key points:

After `state.retryCount += 1` (line 210):

```swift
        self.logHandler?("Type query timeout (attempt \(state.retryCount)/\(maxRetries), reseized: \(state.hasReseized))", self.serialID(for: device))
```

Before `IOHIDDeviceClose` for re-seize (line 220):

```swift
            self.logHandler?("Attempting re-seize...", self.serialID(for: device))
```

On re-seize failure (after line 226):

```swift
                    self?.logHandler?("Re-seize failed (IOReturn: \(reopenResult))", self?.serialID(for: device))
```

On final exhaustion (line 244):

```swift
            self.logHandler?("All retry attempts exhausted after re-seize", self.serialID(for: device))
```

- [ ] **Step 8: Instrument run()**

In `run()` (line 280), add a log after `IOHIDManagerOpen` succeeds (after line 316, before `registerDeviceCallback`):

```swift
        self.logHandler?("HID manager opened, scanning for devices", nil)
```

And on failure (after line 314):

```swift
            self.logHandler?("Failed to open HID manager (IOReturn: \(ret))", nil)
```

- [ ] **Step 9: Instrument Controller.readInitializeData**

In `Vendor/JoyConSwift/Sources/Controller.swift`, we need a way for Controller to call the manager's logHandler. Add a log closure property after `errorHandler` (line 129):

```swift
    /// Callback for debug log messages
    var logHandler: ((_ message: String, _ deviceSerial: String?) -> Void)?
```

Then in `readInitializeData` (line 188), instrument:

```swift
    func readInitializeData(_ done: @escaping () -> Void) {
        self.logHandler?("Reading controller color...", self.serialID)
        self.readControllerColor {
            self.logHandler?("Reading calibration...", self.serialID)
            self.readCalibration()
            // TODO: Call done() after readCalibration() is done
            done()
        }
    }
```

- [ ] **Step 10: Wire Controller.logHandler in JoyConManager.handleControllerType**

In `JoyConManager.handleControllerType`, after the controller is created (after `guard let controller = _controller`, line 138), set the log handler:

```swift
        controller.logHandler = self.logHandler
```

- [ ] **Step 11: Commit**

```bash
git add Vendor/JoyConSwift/Sources/JoyConManager.swift Vendor/JoyConSwift/Sources/Controller.swift
git commit -m "feat: instrument JoyConSwift connection lifecycle with logHandler"
```

---

### Task 7: Wire logHandler and add app-layer log calls in AppDelegate

**Files:**
- Modify: `JoyKeyMapper/AppDelegate.swift:39-62,177-247`

- [ ] **Step 1: Wire manager.logHandler**

In `JoyKeyMapper/AppDelegate.swift`, in `applicationDidFinishLaunching` after the existing handler assignments (after line 47, before line 49), add:

```swift
        self.manager.logHandler = { message, deviceSerial in
            ConnectionLog.shared.log(message, device: deviceSerial)
        }
```

- [ ] **Step 2: Add log calls to connectController**

In `connectController` (line 177), add log calls. Inside the `if let gameController` branch (after line 180):

```swift
            ConnectionLog.shared.log("Controller reconnected: \(gameController.type.rawValue)", device: controller.serialID)
```

Inside the `else` branch (the `addController` call, line 188):

```swift
            ConnectionLog.shared.log("New controller discovered", device: controller.serialID)
```

- [ ] **Step 3: Add log calls to disconnectController**

In `disconnectController(_ controller:)` (line 201), inside the `if let gameController` block (after line 204):

```swift
            ConnectionLog.shared.log("Controller disconnected", device: controller.serialID)
```

- [ ] **Step 4: Add log calls to handleConnectionState**

In `handleConnectionState` (line 215), add log calls for each state. After the `deviceName` is computed (after line 224), before the switch:

```swift
        ConnectionLog.shared.log("State: \(String(describing: state))", device: serialID.isEmpty ? nil : serialID)
```

- [ ] **Step 5: Commit**

```bash
git add JoyKeyMapper/AppDelegate.swift
git commit -m "feat: wire logHandler and add connection log calls in AppDelegate"
```

---

### Task 8: Build and verify

- [ ] **Step 1: Build the project**

Use XcodeBuildMCP or `tuist generate --no-open && xcodebuild` to verify the project compiles without errors. New .swift files are auto-included by the glob in `Project.swift`, so no Tuist regeneration should be needed.

```bash
cd /Users/efiske/conductor/workspaces/JoyMapperSilicon/dublin-v1
# Build to verify compilation
xcodebuild -project JoyMapperSilicon.xcodeproj -scheme JoyMapperSilicon -destination 'platform=macOS' build 2>&1 | tail -20
```

If there's a workspace, use that instead of the xcodeproj.

- [ ] **Step 2: Fix any compilation errors**

Address any issues found during the build.

- [ ] **Step 3: Commit any fixes**

```bash
git add -A
git commit -m "fix: resolve compilation issues from BT debug UI integration"
```

---

### Task 9: Manual verification checklist

- [ ] **Step 1: Launch the app and verify the log panel**

1. The bottom of the main window should show a collapsed "Connection Log" header bar
2. Clicking the disclosure triangle should expand to show a dark console-style text area
3. "HID manager opened, scanning for devices" should appear as the first log entry

- [ ] **Step 2: Verify controller status labels**

1. With no controllers connected, cells should show empty labels (same as before)
2. Pair a controller via Bluetooth — cell should briefly show "Connecting..." then "Connected"
3. Disconnect — cell should return to empty

- [ ] **Step 3: Verify Copy Log**

1. Expand the log panel
2. Click "Copy Log"
3. Paste into a text editor — should contain the full timestamped log

- [ ] **Step 4: Final commit and cleanup**

```bash
git add -A
git commit -m "chore: final cleanup for BT debug UI feature"
```
