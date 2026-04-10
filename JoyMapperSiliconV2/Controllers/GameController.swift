// JoyMapperSiliconV2/Controllers/GameController.swift
import AppKit
@preconcurrency import JoyConSwift
import InputMethodKit
import Observation

@MainActor
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
            Task { @MainActor in self?.handleButtonPress(button: button) }
        }
        controller.buttonReleaseHandler = { [weak self] button in
            Task { @MainActor in
                guard self?.isEnabled == true else { return }
                self?.handleButtonRelease(button: button)
            }
        }
        controller.leftStickHandler = { [weak self] newDir, oldDir in
            Task { @MainActor in
                guard self?.isEnabled == true else { return }
                self?.handleLeftStick(newDirection: newDir, oldDirection: oldDir)
            }
        }
        controller.rightStickHandler = { [weak self] newDir, oldDir in
            Task { @MainActor in
                guard self?.isEnabled == true else { return }
                self?.handleRightStick(newDirection: newDir, oldDirection: oldDir)
            }
        }
        controller.leftStickPosHandler = { [weak self] pos in
            Task { @MainActor in
                guard self?.isEnabled == true else { return }
                self?.handleLeftStickPos(pos: pos)
            }
        }
        controller.rightStickPosHandler = { [weak self] pos in
            Task { @MainActor in
                guard self?.isEnabled == true else { return }
                self?.handleRightStickPos(pos: pos)
            }
        }
        controller.batteryChangeHandler = { [weak self] _, _ in
            Task { @MainActor in self?.updateControllerIcon() }
        }
        controller.isChargingChangeHandler = { [weak self] _ in
            Task { @MainActor in self?.updateControllerIcon() }
        }

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
        let source = CGEventSource(stateID: .hidSystemState)

        if config.keyCode >= 0 {
            metaKeyEvent(config: config, keyDown: true)

            if let systemKey = systemDefinedKey[config.keyCode] {
                let mousePos = NSEvent.mouseLocation
                let flags = NSEvent.ModifierFlags(rawValue: 0x0a00)
                let data1 = Int(Int32(systemKey << 16) | 0x0a00)
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

    func releaseKey(config: KeyMap) {
        let source = CGEventSource(stateID: .hidSystemState)

        if config.keyCode >= 0 {
            if let systemKey = systemDefinedKey[config.keyCode] {
                let mousePos = NSEvent.mouseLocation
                let flags = NSEvent.ModifierFlags(rawValue: 0x0b00)
                let data1 = Int(Int32(systemKey << 16) | 0x0b00)
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
            Task { @MainActor in
                guard let self, let lastAccess = self.lastAccess else { return }
                let now = Date()
                let disconnectTime: TimeInterval = 30 * 60
                if now.timeIntervalSince(lastAccess) > disconnectTime {
                    self.disconnect()
                }
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

// MARK: - Battery localization

extension JoyCon.BatteryStatus {
    static let stringMap: [JoyCon.BatteryStatus: String] = [
        .empty: "Empty", .critical: "Critical", .low: "Low",
        .medium: "Medium", .full: "Full", .unknown: "Unknown",
    ]

    var string: String { Self.stringMap[self] ?? "Unknown" }
    var localizedString: String { NSLocalizedString(string, comment: "BatteryStatus") }
}
