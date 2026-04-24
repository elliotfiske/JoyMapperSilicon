// JoyMapperSiliconV2/Models/KeyMap.swift
import Foundation

struct KeyMap: Codable, Identifiable, Equatable, Hashable {
    var id: UUID = UUID()
    var button: String
    var keyCode: Int = -1
    var modifiers: Int = 0
    var mouseButton: Int = -1
    var isEnabled: Bool = true
}
