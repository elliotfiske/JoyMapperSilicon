// JoyMapperSiliconV2/Views/AppListView.swift
import SwiftUI

struct AppListView: View {
    @Environment(AppModel.self) private var appModel
    var controllerID: String?
    @Binding var selectedAppConfigID: UUID?

    private var profile: ControllerProfile? {
        appModel.controllerProfiles.first { $0.id == controllerID }
    }

    var body: some View {
        List(selection: $selectedAppConfigID) {
            if profile != nil {
                Text("Default")
                    .tag(nil as UUID?)

                ForEach(profile?.appConfigs ?? []) { appConfig in
                    HStack {
                        if let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: appConfig.bundleID) {
                            let icon = NSWorkspace.shared.icon(forFile: appURL.path)
                            Image(nsImage: icon)
                                .resizable()
                                .frame(width: 20, height: 20)
                        }
                        Text(appConfig.displayName)
                    }
                    .tag(appConfig.id as UUID?)
                }
            }
        }
    }
}
