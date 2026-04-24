// JoyMapperSiliconV2/Models/KeyConfig.swift
import Foundation

struct KeyConfig: Codable, Equatable {
    var keyMaps: [KeyMap]
    var leftStick: StickConfig?
    var rightStick: StickConfig?
}
