import ComposableArchitecture
import SwiftUI

/// Dictation settings: the gateway, hotkeys, and the dictionary.
struct DictationSettingsView: View {
    @Bindable var store: StoreOf<DictationFeature>
    @State private var keyDraft = ""
    @State private var newTerm = ""
    @State private var newHeardAs = ""

    var body: some View {
        Form {
            Section("Microphone") {
                Picker("Record from", selection: $store.settings.inputDeviceUID) {
                    Text("System default").tag("")
                    ForEach(store.microphones) { mic in
                        Text(mic.isBluetooth ? "\(mic.name) (Bluetooth)" : mic.name).tag(mic.uid)
                    }
                    let chosen = store.settings.inputDeviceUID
                    if !chosen.isEmpty, !store.microphones.contains(where: { $0.uid == chosen }) {
                        Text("Disconnected microphone (using the default)").tag(chosen)
                    }
                }
                .accessibilityIdentifier("dictation-microphone")
                Text("Pick one mic to keep dictation from following the system default around. Bluetooth headsets such as AirPods switch into a call mode when their mic opens, which takes a moment and lowers the sound quality; the panel turns red once audio is actually coming in.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .onAppear { store.send(.refreshMicrophones) }

            Section("Shortcuts") {
                Toggle("Hold Right ⌥ to dictate", isOn: $store.settings.holdKeyEnabled)
                    .accessibilityIdentifier("dictation-hold-key")
                Toggle("⌃⌥Space starts and stops · ⌃⌥V pastes the last dictation", isOn: $store.settings.toggleKeysEnabled)
                    .accessibilityIdentifier("dictation-toggle-keys")
                LabeledContent("Status") {
                    Text(store.hotkeysActive ? "Listening for shortcuts" : "Waiting for Accessibility permission")
                        .foregroundStyle(store.hotkeysActive ? Color.secondary : Color.orange)
                }
                Text("Joy-Con buttons can dictate too: pick a Dictation action in a button's editor. The starter R mapping holds C to talk and pastes the last dictation with Home.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Cleanup with Claude") {
                Toggle("Clean up with Claude before pasting", isOn: $store.settings.cleanupEnabled)
                    .accessibilityIdentifier("dictation-cleanup-toggle")
                TextField("Gateway URL", text: $store.settings.gatewayURL, prompt: Text("https://your-company-gateway"))
                    .accessibilityIdentifier("dictation-gateway-url")
                TextField("Model", text: $store.settings.model)
                    .accessibilityIdentifier("dictation-model")
                TextField("anthropic-version header", text: $store.settings.apiVersion)
                HStack {
                    SecureField(store.hasGatewayKey ? "Key saved (enter a new one to replace it)" : "Gateway key", text: $keyDraft)
                        .accessibilityIdentifier("dictation-gateway-key")
                    Button("Save key") {
                        store.send(.gatewayKeySaved(keyDraft))
                        keyDraft = ""
                    }
                    .disabled(keyDraft.isEmpty)
                }
                HStack {
                    Button("Test") { store.send(.testGatewayTapped) }
                        .accessibilityIdentifier("dictation-test-gateway")
                    if let status = store.gatewayStatus {
                        Text(status)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                            .accessibilityIdentifier("dictation-gateway-status")
                    }
                }
                Stepper("Give up after \(Int(store.settings.cleanupTimeout)) s and paste what was heard",
                        value: $store.settings.cleanupTimeout, in: 3...30)
                Toggle("Paste automatically", isOn: $store.settings.pasteAutomatically)
                Toggle("Read names from the frontmost window", isOn: $store.settings.screenContextEnabled)
                Text("The key is stored in your Keychain. The URL and settings are stored in ~/Library/Application Support/JoyMapperSilicon, not in the repo.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Dictionary") {
                HStack {
                    TextField("Term", text: $newTerm, prompt: Text("Life360"))
                        .accessibilityIdentifier("dictionary-term")
                    TextField("Often heard as", text: $newHeardAs, prompt: Text("life three sixty"))
                        .accessibilityIdentifier("dictionary-heard-as")
                    Button("Add") {
                        store.send(.addDictionaryEntry(term: newTerm, heardAs: newHeardAs))
                        newTerm = ""
                        newHeardAs = ""
                    }
                    .disabled(newTerm.trimmingCharacters(in: .whitespaces).isEmpty)
                    .accessibilityIdentifier("dictionary-add")
                }
                ForEach(store.dictionary) { entry in
                    HStack {
                        Text(entry.term).bold()
                        if !entry.heardAs.isEmpty {
                            Text("← \(entry.heardAs)").foregroundStyle(.secondary)
                        }
                        Spacer()
                        if entry.source == "shared" {
                            Text("shared").font(.caption).foregroundStyle(.secondary)
                        } else {
                            Button("Remove") { store.send(.removeDictionaryEntry(entry.id)) }
                                .buttonStyle(.link)
                        }
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("dictionary-entry-\(entry.term)")
                }
                TextField("Team sheet (published CSV URL)", text: $store.settings.sharedDictionaryURL,
                          prompt: Text("Google Sheets → File → Share → Publish to web → CSV"))
                HStack {
                    Button("Refresh shared terms") { store.send(.refreshSharedDictionaryTapped) }
                    if let status = store.sharedDictionaryStatus {
                        Text(status).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .accessibilityIdentifier("dictation-settings")
    }
}

/// Every dictation, newest first, searchable. Nothing is ever deleted.
struct DictationHistoryView: View {
    @Bindable var store: StoreOf<DictationFeature>

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                TextField("Search everything you've dictated", text: $store.historySearch)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityIdentifier("history-search")
                Text("\(store.filteredHistory.count) of \(store.history.count)")
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            .padding(12)
            Divider()
            List(store.filteredHistory) { record in
                HistoryRow(store: store, record: record)
            }
            .accessibilityIdentifier("history-list")
        }
    }
}

private struct HistoryRow: View {
    let store: StoreOf<DictationFeature>
    let record: DictationRecord

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(record.startedAt, format: .dateTime.month().day().hour().minute())
                if let app = record.appName { Text("· \(app)") }
                Text("· \(String(format: "%.0f", record.duration)) s")
                if record.pasted { Text("· pasted") }
                if let error = record.correctionError {
                    Text("· \(error)").foregroundStyle(.orange).lineLimit(1)
                }
                Spacer()
                Button("Copy") { store.send(.copyTapped(record.id)) }
                    .buttonStyle(.link)
                if record.audioFileName != nil {
                    Button("Audio") { store.send(.revealAudioTapped(record.id)) }
                        .buttonStyle(.link)
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            Text(record.displayText.isEmpty ? "(nothing recognized)" : record.displayText)
                .textSelection(.enabled)
            if let corrected = record.correctedText, corrected != record.rawText {
                Text("Heard: \(record.rawText)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("history-row-\(record.id.uuidString)")
    }
}
