// JoyMapperSiliconV2/Views/KeyMapListView.swift
import SwiftUI

struct KeyMapListView: View {
    var keyConfig: KeyConfig?

    var body: some View {
        List {
            if let keyConfig {
                Section("Buttons") {
                    ForEach(keyConfig.keyMaps) { keyMap in
                        HStack {
                            Text(keyMap.button)
                            Spacer()
                            if keyMap.keyCode >= 0 {
                                Text(SpecialKeyName[keyMap.keyCode] ?? "Key \(keyMap.keyCode)")
                                    .foregroundStyle(.secondary)
                            } else if keyMap.mouseButton >= 0 {
                                Text("Mouse \(keyMap.mouseButton)")
                                    .foregroundStyle(.secondary)
                            } else {
                                Text("Not set")
                                    .foregroundStyle(.tertiary)
                            }
                        }
                    }
                }

                if let leftStick = keyConfig.leftStick {
                    Section("Left Stick") {
                        Text("Type: \(leftStick.type.rawValue)")
                    }
                }

                if let rightStick = keyConfig.rightStick {
                    Section("Right Stick") {
                        Text("Type: \(rightStick.type.rawValue)")
                    }
                }
            } else {
                Text("Select a controller and app config")
                    .foregroundStyle(.secondary)
            }
        }
    }
}
