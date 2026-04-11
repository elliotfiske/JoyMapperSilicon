// JoyMapperSiliconV2/Views/KeyMapListView.swift
import SwiftUI

struct KeyMapListView: View {
    @Binding var keyConfig: KeyConfig
    var isEmpty: Bool

    @State private var editingIndex: Int?

    var body: some View {
        List {
            if !isEmpty {
                Section("Buttons") {
                    ForEach(Array(keyConfig.keyMaps.enumerated()), id: \.element.id) { index, keyMap in
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
                            Toggle("", isOn: $keyConfig.keyMaps[index].isEnabled)
                                .labelsHidden()
                        }
                        .contentShape(Rectangle())
                        .onTapGesture { editingIndex = index }
                    }
                }

                if keyConfig.leftStick != nil {
                    StickConfigView(
                        stickConfig: Binding(
                            get: { keyConfig.leftStick ?? .defaultConfig() },
                            set: { keyConfig.leftStick = $0 }
                        ),
                        label: "Left Stick"
                    )
                }

                if keyConfig.rightStick != nil {
                    StickConfigView(
                        stickConfig: Binding(
                            get: { keyConfig.rightStick ?? .defaultConfig() },
                            set: { keyConfig.rightStick = $0 }
                        ),
                        label: "Right Stick"
                    )
                }
            } else {
                Text("Select a controller and app config")
                    .foregroundStyle(.secondary)
            }
        }
        .sheet(item: $editingIndex) { index in
            KeyConfigEditor(keyMap: $keyConfig.keyMaps[index])
        }
    }
}
