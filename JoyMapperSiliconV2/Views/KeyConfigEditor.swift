// JoyMapperSiliconV2/Views/KeyConfigEditor.swift
import SwiftUI
import InputMethodKit

struct KeyConfigEditor: View {
    @Binding var keyMap: KeyMap
    @Environment(\.dismiss) private var dismiss

    private let keyOptions: [(code: Int, name: String)] = {
        var options = SpecialKeyName.map { (code: $0.key, name: $0.value) }
        options.sort { $0.name < $1.name }
        return options
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Edit Mapping: \(keyMap.button)")
                .font(.headline)

            Toggle("Enabled", isOn: $keyMap.isEnabled)

            GroupBox("Keyboard") {
                VStack(alignment: .leading, spacing: 8) {
                    Picker("Key", selection: $keyMap.keyCode) {
                        Text("None").tag(-1)
                        ForEach(keyOptions, id: \.code) { option in
                            Text(option.name).tag(option.code)
                        }
                    }

                    HStack {
                        Text("Modifiers:")
                        let modifiers = Binding(
                            get: { NSEvent.ModifierFlags(rawValue: UInt(keyMap.modifiers)) },
                            set: { keyMap.modifiers = Int($0.rawValue) }
                        )
                        Toggle("⇧", isOn: flagBinding(modifiers, flag: .shift))
                        Toggle("⌃", isOn: flagBinding(modifiers, flag: .control))
                        Toggle("⌥", isOn: flagBinding(modifiers, flag: .option))
                        Toggle("⌘", isOn: flagBinding(modifiers, flag: .command))
                    }
                    .toggleStyle(.checkbox)
                }
                .padding(4)
            }

            GroupBox("Mouse") {
                Picker("Mouse Button", selection: $keyMap.mouseButton) {
                    Text("None").tag(-1)
                    Text("Left Click").tag(0)
                    Text("Right Click").tag(1)
                    Text("Middle Click").tag(2)
                    Text("Button 4").tag(3)
                    Text("Button 5").tag(4)
                }
                .padding(4)
            }

            HStack {
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding()
        .frame(width: 350)
    }

    private func flagBinding(_ flags: Binding<NSEvent.ModifierFlags>, flag: NSEvent.ModifierFlags) -> Binding<Bool> {
        Binding(
            get: { flags.wrappedValue.contains(flag) },
            set: { isOn in
                if isOn {
                    flags.wrappedValue.insert(flag)
                } else {
                    flags.wrappedValue.remove(flag)
                }
            }
        )
    }
}
