import Foundation

/// The controllers the app understands. Each Joy-Con is its own controller with its own mappings.
enum ControllerKind: String, Codable, Sendable, CaseIterable, Hashable {
    case joyCon2Left
    case joyCon2Right

    /// The USB-style product ID Joy-Con 2s put in their Bluetooth LE advertisement.
    var productID: UInt16 {
        switch self {
        case .joyCon2Right: 0x2066
        case .joyCon2Left: 0x2067
        }
    }

    init?(productID: UInt16) {
        let match = Self.allCases.first { $0.productID == productID }
        guard let match else { return nil }
        self = match
    }

    var displayName: String {
        switch self {
        case .joyCon2Left: "Joy-Con 2 (L)"
        case .joyCon2Right: "Joy-Con 2 (R)"
        }
    }

    /// The buttons on this controller, in the order the editor lists them.
    var buttons: [ControllerButton] {
        switch self {
        case .joyCon2Left:
            [.up, .down, .left, .right, .l, .zl, .minus, .capture, .leftStick, .leftSL, .leftSR]
        case .joyCon2Right:
            [.a, .b, .x, .y, .r, .zr, .plus, .home, .c, .rightStick, .rightSL, .rightSR]
        }
    }
}

enum ControllerButton: String, Codable, Sendable, CaseIterable, Hashable, CodingKeyRepresentable {
    // Joy-Con 2 (L)
    case up, down, left, right
    case l, zl, minus, capture, leftStick
    case leftSL, leftSR
    // Joy-Con 2 (R)
    case a, b, x, y
    case r, zr, plus, home, c, rightStick
    case rightSL, rightSR

    var displayName: String {
        switch self {
        case .up: "↑"
        case .down: "↓"
        case .left: "←"
        case .right: "→"
        case .l: "L"
        case .zl: "ZL"
        case .minus: "−"
        case .capture: "Capture"
        case .leftStick: "Stick click"
        case .leftSL: "SL"
        case .leftSR: "SR"
        case .a: "A"
        case .b: "B"
        case .x: "X"
        case .y: "Y"
        case .r: "R"
        case .zr: "ZR"
        case .plus: "+"
        case .home: "Home"
        case .c: "C"
        case .rightStick: "Stick click"
        case .rightSL: "SL"
        case .rightSR: "SR"
        }
    }
}

enum StickDirection: String, Codable, Sendable, CaseIterable, Hashable, CodingKeyRepresentable {
    case up, down, left, right

    var displayName: String {
        switch self {
        case .up: "Stick ↑"
        case .down: "Stick ↓"
        case .left: "Stick ←"
        case .right: "Stick →"
        }
    }
}
