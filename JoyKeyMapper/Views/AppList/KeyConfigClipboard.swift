//
//  KeyConfigClipboard.swift
//  JoyKeyMapper
//
//  Clipboard serialization for copy/pasting controller configurations.
//

import AppKit

let keyConfigPasteboardType = NSPasteboard.PasteboardType("com.joymappersilicon.keyconfig")

struct KeyMapData: Codable {
    let button: String
    let keyCode: Int16
    let modifiers: Int32
    let mouseButton: Int16
    let isEnabled: Bool
}

struct StickConfigData: Codable {
    let type: String
    let speed: Float
    let keyMaps: [KeyMapData]
}

struct KeyConfigClipboardData: Codable {
    let keyMaps: [KeyMapData]
    let leftStick: StickConfigData?
    let rightStick: StickConfigData?

    init(from keyConfig: KeyConfig) {
        var maps: [KeyMapData] = []
        keyConfig.keyMaps?.enumerateObjects { (obj, _) in
            guard let keyMap = obj as? KeyMap else { return }
            maps.append(KeyMapData(
                button: keyMap.button ?? "",
                keyCode: keyMap.keyCode,
                modifiers: keyMap.modifiers,
                mouseButton: keyMap.mouseButton,
                isEnabled: keyMap.isEnabled
            ))
        }
        self.keyMaps = maps

        if let leftStick = keyConfig.leftStick {
            self.leftStick = StickConfigData(from: leftStick)
        } else {
            self.leftStick = nil
        }

        if let rightStick = keyConfig.rightStick {
            self.rightStick = StickConfigData(from: rightStick)
        } else {
            self.rightStick = nil
        }
    }
}

extension StickConfigData {
    init(from stickConfig: StickConfig) {
        self.type = stickConfig.type ?? StickType.None.rawValue
        self.speed = stickConfig.speed
        var maps: [KeyMapData] = []
        stickConfig.keyMaps?.enumerateObjects { (obj, _) in
            guard let keyMap = obj as? KeyMap else { return }
            maps.append(KeyMapData(
                button: keyMap.button ?? "",
                keyCode: keyMap.keyCode,
                modifiers: keyMap.modifiers,
                mouseButton: keyMap.mouseButton,
                isEnabled: keyMap.isEnabled
            ))
        }
        self.keyMaps = maps
    }
}
