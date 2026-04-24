// JoyMapperSiliconV2/Views/KeyConfigEditor.swift
import SwiftUI
import InputMethodKit

struct KeyConfigEditor: View {
    @Binding var keyMap: KeyMap
    @Environment(\.dismiss) private var dismiss

    private let keyOptions: [(code: Int, name: String)] = {
        // Standard ANSI key codes for letters, numbers, and punctuation
        let ansiKeys: [Int: String] = [
            kVK_ANSI_A: "A", kVK_ANSI_B: "B", kVK_ANSI_C: "C", kVK_ANSI_D: "D",
            kVK_ANSI_E: "E", kVK_ANSI_F: "F", kVK_ANSI_G: "G", kVK_ANSI_H: "H",
            kVK_ANSI_I: "I", kVK_ANSI_J: "J", kVK_ANSI_K: "K", kVK_ANSI_L: "L",
            kVK_ANSI_M: "M", kVK_ANSI_N: "N", kVK_ANSI_O: "O", kVK_ANSI_P: "P",
            kVK_ANSI_Q: "Q", kVK_ANSI_R: "R", kVK_ANSI_S: "S", kVK_ANSI_T: "T",
            kVK_ANSI_U: "U", kVK_ANSI_V: "V", kVK_ANSI_W: "W", kVK_ANSI_X: "X",
            kVK_ANSI_Y: "Y", kVK_ANSI_Z: "Z",
            kVK_ANSI_0: "0", kVK_ANSI_1: "1", kVK_ANSI_2: "2", kVK_ANSI_3: "3",
            kVK_ANSI_4: "4", kVK_ANSI_5: "5", kVK_ANSI_6: "6", kVK_ANSI_7: "7",
            kVK_ANSI_8: "8", kVK_ANSI_9: "9",
            kVK_ANSI_Minus: "-", kVK_ANSI_Equal: "=",
            kVK_ANSI_LeftBracket: "[", kVK_ANSI_RightBracket: "]",
            kVK_ANSI_Semicolon: ";", kVK_ANSI_Quote: "'",
            kVK_ANSI_Comma: ",", kVK_ANSI_Period: ".",
            kVK_ANSI_Slash: "/", kVK_ANSI_Backslash: "\\",
            kVK_ANSI_Grave: "`",
        ]

        var allKeys = SpecialKeyName.merging(ansiKeys) { special, _ in special }
        var options = allKeys.map { (code: $0.key, name: $0.value) }
        options.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
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
