import Carbon.HIToolbox
import XCTest
@testable import JoyMapperSilicon

final class RecordingPoster: EventPoster, @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [SyntheticEvent] = []

    func post(_ event: SyntheticEvent) {
        lock.lock()
        storage.append(event)
        lock.unlock()
    }

    var events: [SyntheticEvent] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func reset() {
        lock.lock()
        storage = []
        lock.unlock()
    }
}

final class MappingEngineTests: XCTestCase {
    private let id = "R"
    private var poster: RecordingPoster!
    private var engine: MappingEngine!

    override func setUp() {
        poster = RecordingPoster()
        engine = MappingEngine(poster: poster, usesTimer: false)
    }

    private func configure(_ config: MappingConfig, enabled: Bool = true) {
        engine.apply(MappingSnapshot(isEnabled: enabled, configs: [id: config]))
    }

    private func press(_ buttons: Set<ControllerButton>, stick: StickVector = .zero) {
        engine.process(ControllerInput(buttons: buttons, stick: stick), from: id)
    }

    func testButtonPressesAndReleasesKey() {
        configure(MappingConfig(buttons: [.a: .key(kVK_Return)]))
        press([.a])
        press([])
        XCTAssertEqual(poster.events, [
            .key(code: kVK_Return, down: true, modifiers: []),
            .key(code: kVK_Return, down: false, modifiers: []),
        ])
    }

    func testHoldingAButtonDoesNotRepeat() {
        configure(MappingConfig(buttons: [.a: .key(kVK_Return)]))
        press([.a])
        press([.a])
        press([.a])
        XCTAssertEqual(poster.events.count, 1)
    }

    func testModifiedKeyPressesModifierFirstAndReleasesItLast() {
        configure(MappingConfig(buttons: [.plus: .key(kVK_Tab, [.command])]))
        press([.plus])
        press([])
        // Like a real keyboard, the ⌘ key-down already carries the ⌘ flag.
        XCTAssertEqual(poster.events, [
            .key(code: kVK_Command, down: true, modifiers: [.command]),
            .key(code: kVK_Tab, down: true, modifiers: [.command]),
            .key(code: kVK_Tab, down: false, modifiers: [.command]),
            .key(code: kVK_Command, down: false, modifiers: []),
        ])
    }

    func testSharedModifierStaysDownUntilLastBindingReleases() {
        // Hold ⌘ on R, then ⌘Tab on Plus: releasing Plus must not lift ⌘.
        configure(MappingConfig(buttons: [
            .r: KeyBinding(modifiers: [.command]),
            .plus: .key(kVK_Tab, [.command]),
        ]))
        press([.r])
        press([.r, .plus])
        press([.r])
        let releasedCommand = poster.events.contains(.key(code: kVK_Command, down: false, modifiers: []))
        XCTAssertFalse(releasedCommand)
        press([])
        XCTAssertEqual(poster.events.last, .key(code: kVK_Command, down: false, modifiers: []))
    }

    func testMouseButtonAndDragWhileHeld() {
        var config = MappingConfig(buttons: [.zr: .mouse(.left)])
        config.stick = StickConfig(mode: .mouse, speed: 10, deadzone: 0.1)
        configure(config)
        press([.zr], stick: StickVector(x: 1, y: 0))
        engine.tick(dt: 1.0 / 60)
        press([])
        XCTAssertEqual(poster.events.first, .mouseButton(.left, down: true, modifiers: []))
        guard case let .mouseMove(dx, dy, dragging) = poster.events[1] else {
            return XCTFail("expected a move, got \(poster.events)")
        }
        XCTAssertEqual(dx, 10, accuracy: 0.001)
        XCTAssertEqual(dy, 0, accuracy: 0.001)
        XCTAssertEqual(dragging, .left)
        XCTAssertEqual(poster.events.last, .mouseButton(.left, down: false, modifiers: []))
    }

    func testStickUpMovesPointerUpOnScreen() {
        configure(MappingConfig(stick: StickConfig(mode: .mouse, speed: 10, deadzone: 0)))
        press([], stick: StickVector(x: 0, y: 1))
        engine.tick(dt: 1.0 / 60)
        guard case let .mouseMove(_, dy, _) = poster.events.first else { return XCTFail("no move") }
        XCTAssertLessThan(dy, 0, "screen y grows downward")
    }

    func testDeadzoneSuppressesDrift() {
        configure(MappingConfig(stick: StickConfig(mode: .mouse, speed: 25, deadzone: 0.15)))
        press([], stick: StickVector(x: 0.1, y: -0.05))
        engine.tick(dt: 1.0 / 60)
        XCTAssertEqual(poster.events, [])
    }

    func testScrollAccumulatesFractions() {
        configure(MappingConfig(stick: StickConfig(mode: .scroll, speed: 1, deadzone: 0)))
        // 0.5 tilt → shaped 0.25 → 0.125 px per tick: nothing until it adds up to a pixel.
        press([], stick: StickVector(x: 0, y: -0.5))
        for _ in 0..<7 { engine.tick(dt: 1.0 / 60) }
        XCTAssertEqual(poster.events, [])
        engine.tick(dt: 1.0 / 60)
        XCTAssertEqual(poster.events, [.scroll(dx: 0, dy: 1)])
    }

    func testStickKeysUseEightWayDirections() {
        var stick = StickConfig(mode: .keys, deadzone: 0.2)
        stick.directions = [.up: .key(kVK_ANSI_W), .right: .key(kVK_ANSI_D)]
        configure(MappingConfig(stick: stick))

        press([], stick: StickVector(x: 0.7, y: 0.7))
        let down = Set(poster.events)
        XCTAssertEqual(down, [
            .key(code: kVK_ANSI_W, down: true, modifiers: []),
            .key(code: kVK_ANSI_D, down: true, modifiers: []),
        ])

        poster.reset()
        press([], stick: StickVector(x: 0, y: 0.9))
        XCTAssertEqual(poster.events, [.key(code: kVK_ANSI_D, down: false, modifiers: [])])

        poster.reset()
        press([], stick: .zero)
        XCTAssertEqual(poster.events, [.key(code: kVK_ANSI_W, down: false, modifiers: [])])
    }

    func testTurningMappingsOffReleasesHeldKeysAndBlocksNewOnes() {
        let config = MappingConfig(buttons: [.a: .key(kVK_Return), .b: .key(kVK_Escape)])
        configure(config)
        press([.a])
        configure(config, enabled: false)
        XCTAssertEqual(poster.events.last, .key(code: kVK_Return, down: false, modifiers: []))

        poster.reset()
        press([.a, .b])
        press([])
        XCTAssertEqual(poster.events, [])
    }

    func testChangingConfigWhileHeldReleasesWithTheOldBinding() {
        configure(MappingConfig(buttons: [.a: .key(kVK_Return)]))
        press([.a])
        configure(MappingConfig(buttons: [.a: .key(kVK_Space)]))
        XCTAssertEqual(poster.events.last, .key(code: kVK_Return, down: false, modifiers: []))

        // Still held: the new binding waits for the next press.
        poster.reset()
        press([.a])
        XCTAssertEqual(poster.events, [])
        press([])
        press([.a])
        XCTAssertEqual(poster.events, [.key(code: kVK_Space, down: true, modifiers: [])])
    }

    func testDisconnectReleasesEverything() {
        configure(MappingConfig(buttons: [.zr: .mouse(.left)]))
        press([.zr])
        engine.disconnect(id)
        XCTAssertEqual(poster.events.last, .mouseButton(.left, down: false, modifiers: []))
    }

    func testMediaKeysGoOutAsSystemKeys() {
        configure(MappingConfig(buttons: [.home: .key(SpecialKey.play)]))
        press([.home])
        press([])
        XCTAssertEqual(poster.events, [
            .systemKey(type: 16, down: true),
            .systemKey(type: 16, down: false),
        ])
    }

    func testUnmappedControllerDoesNothing() {
        engine.apply(MappingSnapshot(isEnabled: true, configs: [:]))
        press([.a])
        XCTAssertEqual(poster.events, [])
    }
}
