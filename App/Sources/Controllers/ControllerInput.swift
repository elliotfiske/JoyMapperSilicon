import Foundation

/// One decoded input report: what's held down and where the stick is.
struct ControllerInput: Equatable, Sendable {
    var buttons: Set<ControllerButton> = []
    /// -1…1 on each axis, +y up, after centering. Not yet dead-zoned.
    var stick: StickVector = .zero

    static let idle = ControllerInput()
}

struct StickVector: Equatable, Sendable {
    var x: Double
    var y: Double

    static let zero = StickVector(x: 0, y: 0)

    var magnitude: Double { (x * x + y * y).squareRoot() }
}

/// What the UI shows for a connected controller, sent at a much lower rate than reports arrive.
struct InputPreview: Equatable, Sendable {
    var controllerID: String
    var buttons: Set<ControllerButton>
    var stick: StickVector
}

enum BluetoothState: String, Equatable, Sendable {
    case unknown
    case poweredOn
    case poweredOff
    case unauthorized
    case unsupported

    var isUsable: Bool { self == .poweredOn }

    var displayText: String {
        switch self {
        case .unknown: "Bluetooth: starting…"
        case .poweredOn: "Bluetooth on"
        case .poweredOff: "Bluetooth is off"
        case .unauthorized: "Bluetooth access denied"
        case .unsupported: "Bluetooth LE unsupported"
        }
    }
}

/// How far along a controller is, from first sighting to sending input.
enum ConnectionPhase: Equatable, Sendable {
    case disconnected
    case connecting
    /// Connected; running the setup commands.
    case initializing
    case ready
    case failed(String)

    var displayText: String {
        switch self {
        case .disconnected: "Not connected"
        case .connecting: "Connecting…"
        case .initializing: "Setting up…"
        case .ready: "Connected"
        case let .failed(message): "Failed: \(message)"
        }
    }

    var isConnected: Bool {
        switch self {
        case .initializing, .ready: true
        default: false
        }
    }
}

/// What the controller layer tells the rest of the app. Input reports don't come through here:
/// they go straight to the mapping engine, and only throttled previews reach the store.
enum ControllerEvent: Equatable, Sendable {
    case bluetooth(BluetoothState)
    case scanning(Bool)
    /// A Joy-Con 2 was seen advertising (in pairing mode or reconnecting).
    case discovered(id: String, kind: ControllerKind)
    case phase(id: String, kind: ControllerKind, ConnectionPhase)
    /// 0…1, if the controller reports it.
    case battery(id: String, level: Double)
}
