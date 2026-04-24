// JoyMapperSiliconV2/Models/AppConfig.swift
import Foundation

struct AppConfig: Codable, Identifiable, Equatable {
    var id: UUID = UUID()
    var bundleID: String
    var displayName: String
    var keyConfig: KeyConfig
}
