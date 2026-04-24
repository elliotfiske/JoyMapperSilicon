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
