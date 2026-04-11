// JoyMapperSiliconV2/Views/AppListView.swift
import SwiftUI
import UniformTypeIdentifiers

struct AppListView: View {
    @Environment(AppModel.self) private var appModel
    var controllerID: String?
    @Binding var selectedAppConfigID: UUID?

    private var profile: ControllerProfile? {
        appModel.controllerProfiles.first { $0.id == controllerID }
    }

    var body: some View {
        VStack(spacing: 0) {
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

            HStack {
                Button(action: addApp) {
                    Image(systemName: "plus")
                }
                .disabled(profile == nil)

                Button(action: removeApp) {
                    Image(systemName: "minus")
                }
                .disabled(selectedAppConfigID == nil)

                Spacer()
            }
            .padding(4)
        }
    }

    private func addApp() {
        guard let profile else { return }

        let panel = NSOpenPanel()
        panel.message = "Choose an app to add"
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canCreateDirectories = false
        panel.canChooseFiles = true
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")

        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            guard let bundle = Bundle(url: url),
                  let info = bundle.infoDictionary,
                  let bundleID = info["CFBundleIdentifier"] as? String else { return }

            // Don't add duplicates
            guard !profile.appConfigs.contains(where: { $0.bundleID == bundleID }) else { return }

            let displayName = FileManager.default.displayName(atPath: url.path)
            let hasLeftStick = profile.type == .JoyConL || profile.type == .ProController
            let hasRightStick = profile.type == .JoyConR || profile.type == .ProController

            let newConfig = AppConfig(
                bundleID: bundleID,
                displayName: displayName,
                keyConfig: KeyConfig(
                    keyMaps: [],
                    leftStick: hasLeftStick ? .defaultConfig() : nil,
                    rightStick: hasRightStick ? .defaultConfig() : nil
                )
            )

            appModel.$controllerProfiles.withLock { profiles in
                guard let index = profiles.firstIndex(where: { $0.id == controllerID }) else { return }
                profiles[index].appConfigs.append(newConfig)
            }
        }
    }

    private func removeApp() {
        guard let appConfigID = selectedAppConfigID else { return }

        appModel.$controllerProfiles.withLock { profiles in
            guard let index = profiles.firstIndex(where: { $0.id == controllerID }) else { return }
            profiles[index].appConfigs.removeAll { $0.id == appConfigID }
        }
        selectedAppConfigID = nil
    }
}
