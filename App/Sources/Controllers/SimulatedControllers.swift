import Foundation

/// Fake controllers for the background UI tests, so they can run without hardware.
///
/// Launch with `JOYMAPPER_SIMULATED_CONTROLLERS=joyCon2Left,joyCon2Right`; they connect at start
/// with the IDs `SIM-joyCon2Left` and `SIM-joyCon2Right`. Drive them with a distributed
/// notification named `com.elliotfiske.JoyMapperSilicon.simulate`:
///
///     ["id": "SIM-joyCon2Right", "buttons": "a,zr", "x": "0.5", "y": "0"]   // new input state
///     ["id": "SIM-joyCon2Right", "action": "disconnect"]
///
/// See `scripts/simulate.sh`.
final class SimulatedControllers: NSObject, @unchecked Sendable {
    static let notificationName = Notification.Name("com.elliotfiske.JoyMapperSilicon.simulate")
    static let environmentKey = "JOYMAPPER_SIMULATED_CONTROLLERS"

    private let kinds: [ControllerKind]
    private let engine: MappingEngine
    private let continuation: AsyncStream<ControllerEvent>.Continuation
    let events: AsyncStream<ControllerEvent>

    init(kinds: [ControllerKind], engine: MappingEngine) {
        self.kinds = kinds
        self.engine = engine
        (events, continuation) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(200))
        super.init()
    }

    static func kindsFromEnvironment() -> [ControllerKind]? {
        guard let value = ProcessInfo.processInfo.environment[environmentKey] else { return nil }
        let names = value.split(separator: ",").map(String.init)
        return names.compactMap(ControllerKind.init(rawValue:))
    }

    static func id(for kind: ControllerKind) -> String { "SIM-\(kind.rawValue)" }

    func start() {
        Log.app.notice("Using simulated controllers: \(kinds.map(\.rawValue).joined(separator: ", "))")
        // A background app only gets distributed notifications right away if it asks for them.
        DistributedNotificationCenter.default().addObserver(
            self,
            selector: #selector(handle(_:)),
            name: Self.notificationName,
            object: nil,
            suspensionBehavior: .deliverImmediately
        )
        continuation.yield(.bluetooth(.poweredOn))
        continuation.yield(.scanning(true))
        for kind in kinds {
            let id = Self.id(for: kind)
            continuation.yield(.discovered(id: id, kind: kind))
            continuation.yield(.phase(id: id, kind: kind, .ready))
            continuation.yield(.battery(id: id, level: 0.8))
        }
    }

    func disconnect(_ id: String) {
        guard let kind = kinds.first(where: { Self.id(for: $0) == id }) else { return }
        engine.controllerDisconnected(id)
        continuation.yield(.phase(id: id, kind: kind, .disconnected))
    }

    @objc private func handle(_ notification: Notification) {
        let info = notification.userInfo as? [String: String] ?? [:]
        guard let id = info["id"] else { return }
        guard let kind = kinds.first(where: { Self.id(for: $0) == id }) else { return }

        switch info["action"] {
        case "disconnect":
            disconnect(id)
        case "connect":
            continuation.yield(.phase(id: id, kind: kind, .ready))
        default:
            let names = (info["buttons"] ?? "").split(separator: ",").map(String.init)
            let buttons = Set(names.compactMap(ControllerButton.init(rawValue:)))
            let x = Double(info["x"] ?? "") ?? 0
            let y = Double(info["y"] ?? "") ?? 0
            Log.input.info("Simulated \(id): buttons [\(names.joined(separator: ","))] stick (\(x), \(y))")
            engine.receive(ControllerInput(buttons: buttons, stick: StickVector(x: x, y: y)), from: id)
        }
    }
}
