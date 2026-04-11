// JoyMapperSiliconV2/Views/ContentView.swift
import SwiftUI

struct ContentView: View {
    @Environment(AppModel.self) private var appModel

    @State private var selectedControllerID: String?
    @State private var selectedAppConfigID: UUID?

    private var selectedProfile: ControllerProfile? {
        appModel.controllerProfiles.first { $0.id == selectedControllerID }
    }

    private var selectedKeyConfig: KeyConfig? {
        guard let profile = selectedProfile else { return nil }
        if let appConfigID = selectedAppConfigID,
           let appConfig = profile.appConfigs.first(where: { $0.id == appConfigID }) {
            return appConfig.keyConfig
        }
        return profile.defaultKeyConfig
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

                    KeyMapListView(keyConfig: selectedKeyConfig)
                        .frame(minHeight: 200)
                }
            }
        }
        .frame(minWidth: 700, minHeight: 500)
    }
}
