import AppKit
import Carbon.HIToolbox
import ComposableArchitecture
import SwiftUI

struct BindingEditorView: View {
    @Bindable var store: StoreOf<BindingEditorFeature>

    var body: some View {
        ScrollView {
        VStack(alignment: .leading, spacing: 14) {
            Text("\(store.controllerName): \(store.target.displayName)")
                .font(.headline)
                .accessibilityIdentifier("editor-title")

            HStack {
                Text("Does:")
                Text(store.binding.displayString)
                    .font(.title3.monospaced())
                    .accessibilityIdentifier("editor-current")
                Spacer()
                Button("Clear") { store.send(.clearTapped) }
                    .accessibilityIdentifier("editor-clear")
            }

            GroupBox("Key") {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Button(store.isRecording ? "Press a key…" : "Record key") {
                            store.send(.recordTapped)
                        }
                        .accessibilityIdentifier("editor-record")
                        Text("or pick one:").foregroundStyle(.secondary)
                        TextField("Search keys", text: $store.searchText)
                            .textFieldStyle(.roundedBorder)
                            .accessibilityIdentifier("editor-search")
                    }
                    List(selection: Binding(
                        get: { store.binding.keyCode },
                        set: { store.send(.keySelected($0)) }
                    )) {
                        Text("No key").tag(Int?.none)
                        ForEach(store.matchingKeys, id: \.code) { key in
                            Text(key.name)
                                .tag(Int?.some(key.code))
                                .accessibilityIdentifier("editor-key-\(key.code)")
                        }
                    }
                    .frame(height: 200)
                    .accessibilityIdentifier("editor-key-list")

                    HStack(spacing: 14) {
                        Text("Modifiers:")
                        ForEach(Modifiers.ordered, id: \.0.rawValue) { modifier, symbol in
                            Toggle(symbol, isOn: Binding(
                                get: { store.binding.modifiers.contains(modifier) },
                                set: { _ in store.send(.modifierToggled(modifier)) }
                            ))
                            .toggleStyle(.checkbox)
                            .accessibilityIdentifier("editor-modifier-\(modifier.rawValue)")
                        }
                    }
                }
                .padding(4)
            }

            GroupBox("Dictation") {
                Picker("Action", selection: Binding(
                    get: { store.binding.action },
                    set: { store.send(.actionSelected($0)) }
                )) {
                    Text("None").tag(DictationAction?.none)
                    ForEach(DictationAction.allCases, id: \.self) { action in
                        Text(action.displayName).tag(DictationAction?.some(action))
                    }
                }
                .padding(4)
                .accessibilityIdentifier("editor-action")
            }

            GroupBox("Mouse") {
                Picker("Mouse button", selection: Binding(
                    get: { store.binding.mouseButton },
                    set: { store.send(.mouseButtonSelected($0)) }
                )) {
                    Text("None").tag(MouseButton?.none)
                    ForEach(MouseButton.allCases, id: \.self) { button in
                        Text(button.displayName).tag(MouseButton?.some(button))
                    }
                }
                .padding(4)
                .accessibilityIdentifier("editor-mouse")
            }

            HStack {
                Spacer()
                Button("Cancel") { store.send(.cancelTapped) }
                    .keyboardShortcut(.cancelAction)
                    .accessibilityIdentifier("editor-cancel")
                Button("Save") { store.send(.saveTapped) }
                    .keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier("editor-save")
            }
        }
        .padding(14)
        }
        .background(KeyRecorder(isRecording: store.isRecording) { code, modifiers in
            store.send(.keyRecorded(code: code, modifiers: modifiers))
        })
    }
}

/// While recording, takes the next key-down in this app (including ⌘ combinations and Escape)
/// instead of letting it act.
private struct KeyRecorder: NSViewRepresentable {
    let isRecording: Bool
    let onKey: (Int, Modifiers) -> Void

    func makeNSView(context: Context) -> NSView { NSView() }

    func updateNSView(_ view: NSView, context: Context) {
        context.coordinator.onKey = onKey
        context.coordinator.setRecording(isRecording)
    }

    static func dismantleNSView(_ view: NSView, coordinator: Coordinator) {
        coordinator.setRecording(false)
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        var onKey: ((Int, Modifiers) -> Void)?
        private var monitor: Any?

        func setRecording(_ isOn: Bool) {
            if isOn, monitor == nil {
                monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                    self?.onKey?(Int(event.keyCode), Self.modifiers(event.modifierFlags))
                    return nil
                }
            } else if !isOn, let monitor {
                NSEvent.removeMonitor(monitor)
                self.monitor = nil
            }
        }

        private static func modifiers(_ flags: NSEvent.ModifierFlags) -> Modifiers {
            var result: Modifiers = []
            if flags.contains(.shift) { result.insert(.shift) }
            if flags.contains(.control) { result.insert(.control) }
            if flags.contains(.option) { result.insert(.option) }
            if flags.contains(.command) { result.insert(.command) }
            return result
        }
    }
}
