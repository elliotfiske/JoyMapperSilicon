import Foundation

/// The mappings in force right now: already resolved for the frontmost app.
struct MappingSnapshot: Equatable, Sendable {
    var isEnabled: Bool
    /// Keyed by controller ID.
    var configs: [String: MappingConfig]

    static let disabled = MappingSnapshot(isEnabled: false, configs: [:])
}

/// Turns controller input into keyboard and mouse events.
///
/// Input arrives at report rate (about 30–60 a second) on the Bluetooth queue, so it never goes
/// through the TCA store. The store pushes a `MappingSnapshot` here whenever the mappings, the
/// frontmost app or the on/off switch change.
///
/// Buttons fire on the report where they change. Pointer and scroll movement run on their own
/// 120 Hz tick so the pointer glides instead of stepping at report rate.
final class MappingEngine: @unchecked Sendable {
    /// Where a held binding came from, so it can be released exactly once.
    enum Source: Hashable, Sendable {
        case button(ControllerButton)
        case direction(StickDirection)
    }

    private struct ControllerState {
        var buttons: Set<ControllerButton> = []
        var stick: StickVector = .zero
        var directions: Set<StickDirection> = []
        /// What each held source pressed. Released with the binding it pressed with, even if the
        /// mappings changed since.
        var held: [Source: KeyBinding] = [:]
        var lastPreviewStick: StickVector = .zero
        var lastPreviewTime: Date = .distantPast
    }

    private let poster: EventPoster
    private let queue = DispatchQueue(label: "JoyMapperSilicon.MappingEngine", qos: .userInteractive)
    private var snapshot: MappingSnapshot = .disabled
    private var controllers: [String: ControllerState] = [:]
    /// How many held bindings use each modifier, so a shared modifier stays down until the last
    /// binding using it is released.
    private var modifierCounts: [Int: Int] = [:]
    private var heldMouseButtons: [MouseButton] = []
    private var scrollRemainder = (x: 0.0, y: 0.0)
    private var timer: DispatchSourceTimer?
    private let tickInterval: TimeInterval
    private let usesTimer: Bool

    /// Gets a preview at most 10 times a second per controller, and at once when buttons change.
    var onPreview: (@Sendable (InputPreview) -> Void)?

    init(poster: EventPoster, tickInterval: TimeInterval = 1.0 / 120, usesTimer: Bool = true) {
        self.poster = poster
        self.tickInterval = tickInterval
        self.usesTimer = usesTimer
    }

    // MARK: - Public entry points (thread-safe)

    func update(_ newSnapshot: MappingSnapshot) {
        queue.async { self.apply(newSnapshot) }
    }

    func receive(_ input: ControllerInput, from controllerID: String) {
        queue.async { self.process(input, from: controllerID) }
    }

    func controllerDisconnected(_ controllerID: String) {
        queue.async { self.disconnect(controllerID) }
    }

    /// Runs queued work and waits for it. For tests.
    func sync<T>(_ body: () -> T) -> T {
        queue.sync(execute: body)
    }

    // MARK: - Core logic (on `queue`, or called directly by tests through `sync`)

    func apply(_ newSnapshot: MappingSnapshot) {
        let old = snapshot
        snapshot = newSnapshot
        guard old != newSnapshot else { return }
        Log.mapping.info("Mappings \(newSnapshot.isEnabled ? "on" : "off") for \(newSnapshot.configs.count) controller(s)")

        for id in controllers.keys {
            let configChanged = old.configs[id] != newSnapshot.configs[id]
            let switchedOff = !newSnapshot.isEnabled
            guard configChanged || switchedOff || old.isEnabled != newSnapshot.isEnabled else { continue }
            // Let go of everything so nothing sticks, and don't re-press what's still held: the
            // new mapping takes effect on the next press.
            releaseAll(for: id)
        }
        updateTimer()
    }

    func process(_ input: ControllerInput, from controllerID: String) {
        var state = controllers[controllerID] ?? ControllerState()
        let previous = state.buttons
        logButtonChanges(from: previous, to: input.buttons, controllerID: controllerID)
        state.buttons = input.buttons
        state.stick = input.stick
        controllers[controllerID] = state

        if let config = activeConfig(for: controllerID) {
            for button in input.buttons.subtracting(previous) {
                press(.button(button), binding: config.binding(for: button), controllerID: controllerID)
            }
            if config.stick.mode == .keys {
                updateStickDirections(controllerID: controllerID, stick: config.stick)
            }
        }
        for button in previous.subtracting(input.buttons) {
            release(.button(button), controllerID: controllerID)
        }

        sendPreviewIfNeeded(controllerID: controllerID, buttonsChanged: previous != input.buttons)
        updateTimer()
    }

    func disconnect(_ controllerID: String) {
        releaseAll(for: controllerID)
        controllers[controllerID] = nil
        updateTimer()
    }

    /// Moves the pointer and scrolls for every stick in pointer or scroll mode. `dt` in seconds.
    func tick(dt: TimeInterval) {
        guard snapshot.isEnabled else { return }
        // Speeds are tuned as "per report at 60 reports a second".
        let frames = dt * 60
        for (id, state) in controllers {
            guard let stick = snapshot.configs[id]?.stick else { continue }
            let tilt = Self.shapedTilt(state.stick, deadzone: stick.deadzone)
            guard tilt != .zero else { continue }
            switch stick.mode {
            case .mouse:
                let dx = tilt.x * stick.speed * frames
                let dy = -tilt.y * stick.speed * frames
                poster.post(.mouseMove(dx: dx, dy: dy, dragging: heldMouseButtons.last))
            case .scroll:
                postScroll(dx: tilt.x * stick.speed * frames * 0.5, dy: -tilt.y * stick.speed * frames * 0.5)
            case .none, .keys:
                break
            }
        }
    }

    // MARK: - Pressing and releasing

    private func activeConfig(for controllerID: String) -> MappingConfig? {
        guard snapshot.isEnabled else { return nil }
        return snapshot.configs[controllerID]
    }

    private func press(_ source: Source, binding: KeyBinding, controllerID: String) {
        guard !binding.isEmpty else { return }
        guard controllers[controllerID]?.held[source] == nil else { return }
        controllers[controllerID]?.held[source] = binding
        Log.mapping.info("\(controllerID.prefix(8)) \(Self.describe(source)) → \(binding.displayString) down")

        pressModifiers(binding.modifiers)
        let activeModifiers = currentModifiers()
        if let code = binding.keyCode {
            if let systemType = SpecialKey.systemDefined[code] {
                poster.post(.systemKey(type: systemType, down: true))
            } else {
                poster.post(.key(code: code, down: true, modifiers: activeModifiers))
            }
        }
        if let mouse = binding.mouseButton {
            heldMouseButtons.append(mouse)
            poster.post(.mouseButton(mouse, down: true, modifiers: activeModifiers))
        }
    }

    private func release(_ source: Source, controllerID: String) {
        guard let binding = controllers[controllerID]?.held.removeValue(forKey: source) else { return }
        Log.mapping.info("\(controllerID.prefix(8)) \(Self.describe(source)) → \(binding.displayString) up")

        let activeModifiers = currentModifiers()
        if let mouse = binding.mouseButton {
            if let index = heldMouseButtons.lastIndex(of: mouse) { heldMouseButtons.remove(at: index) }
            poster.post(.mouseButton(mouse, down: false, modifiers: activeModifiers))
        }
        if let code = binding.keyCode {
            if let systemType = SpecialKey.systemDefined[code] {
                poster.post(.systemKey(type: systemType, down: false))
            } else {
                poster.post(.key(code: code, down: false, modifiers: activeModifiers))
            }
        }
        releaseModifiers(binding.modifiers)
    }

    private func releaseAll(for controllerID: String) {
        guard let state = controllers[controllerID] else { return }
        for source in state.held.keys {
            release(source, controllerID: controllerID)
        }
        controllers[controllerID]?.directions = []
    }

    /// Presses the modifier keys in `modifiers` that aren't already down.
    private func pressModifiers(_ modifiers: Modifiers) {
        for (flag, code) in Self.modifierKeys where modifiers.contains(flag) {
            let count = modifierCounts[code, default: 0]
            if count == 0 {
                modifierCounts[code] = 1
                poster.post(.key(code: code, down: true, modifiers: currentModifiers()))
            } else {
                modifierCounts[code] = count + 1
            }
        }
    }

    private func releaseModifiers(_ modifiers: Modifiers) {
        for (flag, code) in Self.modifierKeys.reversed() where modifiers.contains(flag) {
            let count = modifierCounts[code, default: 0]
            if count <= 1 {
                modifierCounts[code] = nil
                poster.post(.key(code: code, down: false, modifiers: currentModifiers()))
            } else {
                modifierCounts[code] = count - 1
            }
        }
    }

    private func currentModifiers() -> Modifiers {
        var result: Modifiers = []
        for (flag, code) in Self.modifierKeys where modifierCounts[code, default: 0] > 0 {
            result.insert(flag)
        }
        return result
    }

    /// kVK_Control, kVK_Option, kVK_Shift, kVK_Command.
    private static let modifierKeys: [(Modifiers, Int)] = [
        (.control, 0x3B), (.option, 0x3A), (.shift, 0x38), (.command, 0x37),
    ]

    // MARK: - Stick

    private func updateStickDirections(controllerID: String, stick: StickConfig) {
        guard let state = controllers[controllerID] else { return }
        let newDirections = Self.directions(for: state.stick, deadzone: stick.deadzone)
        let oldDirections = state.directions
        controllers[controllerID]?.directions = newDirections
        for direction in oldDirections.subtracting(newDirections) {
            release(.direction(direction), controllerID: controllerID)
        }
        for direction in newDirections.subtracting(oldDirections) {
            press(.direction(direction), binding: stick.binding(for: direction), controllerID: controllerID)
        }
    }

    /// Eight-way: a diagonal holds both of its directions.
    static func directions(for stick: StickVector, deadzone: Double) -> Set<StickDirection> {
        let magnitude = stick.magnitude
        guard magnitude > deadzone else { return [] }
        let unitX = stick.x / magnitude
        let unitY = stick.y / magnitude
        // sin(22.5°): outside this band of the axis, the stick counts as pointing that way.
        let threshold = 0.3827
        var result: Set<StickDirection> = []
        if unitY > threshold { result.insert(.up) }
        if unitY < -threshold { result.insert(.down) }
        if unitX > threshold { result.insert(.right) }
        if unitX < -threshold { result.insert(.left) }
        return result
    }

    /// Removes the dead zone, rescales the rest to 0…1, and squares it for fine control near center.
    static func shapedTilt(_ stick: StickVector, deadzone: Double) -> StickVector {
        let magnitude = min(stick.magnitude, 1)
        guard magnitude > deadzone else { return .zero }
        let live = (magnitude - deadzone) / (1 - deadzone)
        let shaped = live * live
        let scale = shaped / stick.magnitude
        return StickVector(x: stick.x * scale, y: stick.y * scale)
    }

    private func postScroll(dx: Double, dy: Double) {
        scrollRemainder.x += dx
        scrollRemainder.y += dy
        let wholeX = scrollRemainder.x.rounded(.towardZero)
        let wholeY = scrollRemainder.y.rounded(.towardZero)
        guard wholeX != 0 || wholeY != 0 else { return }
        scrollRemainder.x -= wholeX
        scrollRemainder.y -= wholeY
        poster.post(.scroll(dx: wholeX, dy: wholeY))
    }

    private func updateTimer() {
        guard usesTimer else { return }
        let needsTimer = snapshot.isEnabled && controllers.contains { id, state in
            guard let stick = snapshot.configs[id]?.stick else { return false }
            let movesPointer = stick.mode == .mouse || stick.mode == .scroll
            return movesPointer && state.stick.magnitude > stick.deadzone
        }
        if needsTimer, timer == nil {
            let source = DispatchSource.makeTimerSource(queue: queue)
            source.schedule(deadline: .now(), repeating: tickInterval, leeway: .milliseconds(1))
            source.setEventHandler { [weak self] in
                guard let self else { return }
                self.tick(dt: self.tickInterval)
            }
            source.resume()
            timer = source
        } else if !needsTimer, let running = timer {
            running.cancel()
            timer = nil
        }
    }

    // MARK: - Previews and logging

    private func sendPreviewIfNeeded(controllerID: String, buttonsChanged: Bool) {
        guard let onPreview, let state = controllers[controllerID] else { return }
        let now = Date()
        let stickMoved = abs(state.stick.x - state.lastPreviewStick.x) > 0.05
            || abs(state.stick.y - state.lastPreviewStick.y) > 0.05
        let dueForStick = stickMoved && now.timeIntervalSince(state.lastPreviewTime) > 0.1
        guard buttonsChanged || dueForStick else { return }
        controllers[controllerID]?.lastPreviewStick = state.stick
        controllers[controllerID]?.lastPreviewTime = now
        onPreview(InputPreview(controllerID: controllerID, buttons: state.buttons, stick: state.stick))
    }

    private func logButtonChanges(from old: Set<ControllerButton>, to new: Set<ControllerButton>, controllerID: String) {
        let pressed = new.subtracting(old)
        let released = old.subtracting(new)
        guard !pressed.isEmpty || !released.isEmpty else { return }
        let pressedNames = pressed.map(\.rawValue).sorted().joined(separator: ",")
        let releasedNames = released.map(\.rawValue).sorted().joined(separator: ",")
        Log.input.info("\(controllerID.prefix(8)) pressed [\(pressedNames)] released [\(releasedNames)]")
    }

    private static func describe(_ source: Source) -> String {
        switch source {
        case let .button(button): button.rawValue
        case let .direction(direction): "stick-\(direction.rawValue)"
        }
    }
}
