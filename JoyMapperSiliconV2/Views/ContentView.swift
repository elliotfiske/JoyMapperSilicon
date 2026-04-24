// JoyMapperSiliconV2/Views/ContentView.swift
import SwiftUI
import Sharing

struct ContentView: View {
    @Environment(AppModel.self) private var appModel

    @State private var selectedControllerID: String?
    @State private var selectedAppConfigID: UUID?

    private var profileIndex: Int? {
        appModel.controllerProfiles.firstIndex { $0.id == selectedControllerID }
    }

    private var keyConfigBinding: Binding<KeyConfig>? {
        guard let pIdx = profileIndex else { return nil }

        if let appConfigID = selectedAppConfigID,
           let aIdx = appModel.controllerProfiles[pIdx].appConfigs.firstIndex(where: { $0.id == appConfigID }) {
            return Binding(
                get: { appModel.controllerProfiles[pIdx].appConfigs[aIdx].keyConfig },
                set: { newValue in
                    appModel.$controllerProfiles.withLock { profiles in
                        profiles[pIdx].appConfigs[aIdx].keyConfig = newValue
                    }
                }
            )
        }

        return Binding(
            get: { appModel.controllerProfiles[pIdx].defaultKeyConfig },
            set: { newValue in
                appModel.$controllerProfiles.withLock { profiles in
                    profiles[pIdx].defaultKeyConfig = newValue
                }
            }
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            AccessibilityBanner()

            HSplitView {
                ControllerListView(selectedControllerID: $selectedControllerID)
                    .frame(minWidth: 160, idealWidth: 200)

                VSplitView {
                    AppListView(
                        controllerID: selectedControllerID,
                        selectedAppConfigID: $selectedAppConfigID
                    )
                    .frame(minHeight: 100, idealHeight: 150)

                    if let binding = keyConfigBinding {
                        KeyMapListView(keyConfig: binding, isEmpty: false)
                            .frame(minHeight: 200)
                    } else {
                        KeyMapListView(keyConfig: .constant(KeyConfig(keyMaps: [])), isEmpty: true)
                            .frame(minHeight: 200)
                    }
                }
            }
        }
        .frame(minWidth: 700, minHeight: 500)
    }
}
