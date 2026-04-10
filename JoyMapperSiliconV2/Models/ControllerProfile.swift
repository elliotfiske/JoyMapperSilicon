// JoyMapperSiliconV2/Models/ControllerProfile.swift
import Foundation
import JoyConSwift

struct ControllerProfile: Codable, Identifiable, Equatable {
    var id: String  // serialID from HID device
    var controllerType: String  // JoyCon.ControllerType.rawValue
    var bodyColor: CodableColor?
    var buttonColor: CodableColor?
    var leftGripColor: CodableColor?
    var rightGripColor: CodableColor?
    var defaultKeyConfig: KeyConfig
    var appConfigs: [AppConfig]

    var type: JoyCon.ControllerType {
        JoyCon.ControllerType(rawValue: controllerType) ?? .unknown
    }

    static func create(serialID: String, type: JoyCon.ControllerType) -> ControllerProfile {
        let hasLeftStick = type == .JoyConL || type == .ProController
        let hasRightStick = type == .JoyConR || type == .ProController

        return ControllerProfile(
            id: serialID,
            controllerType: type.rawValue,
            defaultKeyConfig: KeyConfig(
                keyMaps: [],
                leftStick: hasLeftStick ? .defaultConfig() : nil,
                rightStick: hasRightStick ? .defaultConfig() : nil
            ),
            appConfigs: []
        )
    }
}
