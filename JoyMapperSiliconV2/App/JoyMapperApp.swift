import SwiftUI

@main
struct JoyMapperApp: App {
    @State private var appModel = AppModel()

    var body: some Scene {
        Window("JoyMapper Silicon", id: "settings") {
            ContentView()
                .environment(appModel)
        }
    }
}
