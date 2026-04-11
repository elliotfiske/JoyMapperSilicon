// JoyMapperSiliconV2/Views/StickConfigView.swift
import SwiftUI

struct StickConfigView: View {
    @Binding var stickConfig: StickConfig
    var label: String
    @State private var editingIndex: Int?

    var body: some View {
        Section(label) {
            Picker("Type", selection: $stickConfig.type) {
                ForEach(StickType.allCases, id: \.self) { type in
                    Text(type.rawValue).tag(type)
                }
            }

            if stickConfig.type == .mouse || stickConfig.type == .mouseWheel {
                HStack {
                    Text("Speed")
                    Slider(value: $stickConfig.speed, in: 1...100)
                    Text("\(Int(stickConfig.speed))")
                        .monospacedDigit()
                        .frame(width: 30)
                }
            }

            if stickConfig.type == .key {
                ForEach(Array(stickConfig.keyMaps.enumerated()), id: \.element.id) { index, keyMap in
                    HStack {
                        Text(keyMap.button)
                        Spacer()
                        if keyMap.keyCode >= 0 {
                            Text(SpecialKeyName[keyMap.keyCode] ?? "Key \(keyMap.keyCode)")
                                .foregroundStyle(.secondary)
                        } else {
                            Text("Not set")
                                .foregroundStyle(.tertiary)
                        }
                    }
                    .contentShape(Rectangle())
                    .onTapGesture {
                        editingIndex = index
                    }
                }
            }
        }
        .sheet(item: $editingIndex) { index in
            KeyConfigEditor(keyMap: $stickConfig.keyMaps[index])
        }
    }
}

extension Int: @retroactive Identifiable {
    public var id: Int { self }
}
