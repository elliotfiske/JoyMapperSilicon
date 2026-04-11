// JoyMapperSiliconV2/Views/ControllerListView.swift
import SwiftUI

struct ControllerListView: View {
    @Environment(AppModel.self) private var appModel
    @Binding var selectedControllerID: String?

    var body: some View {
        List(selection: $selectedControllerID) {
            ForEach(appModel.controllers, id: \.serialID) { controller in
                HStack {
                    if let icon = controller.icon {
                        Image(nsImage: icon)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(width: 48, height: 48)
                    }
                    VStack(alignment: .leading) {
                        Text(controller.type.rawValue)
                            .font(.headline)
                        Text(controller.connectionState == .connected ? "Connected" : "Disconnected")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .tag(controller.serialID)
            }
        }
    }
}
