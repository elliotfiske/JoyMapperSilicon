// JoyMapperSiliconV2/Views/ContentView.swift
import SwiftUI

struct ContentView: View {
    @Environment(AppModel.self) private var appModel

    var body: some View {
        Text("Controllers: \(appModel.controllers.count)")
            .frame(minWidth: 600, minHeight: 400)
    }
}
