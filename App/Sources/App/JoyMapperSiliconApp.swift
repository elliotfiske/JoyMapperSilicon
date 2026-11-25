#if DEBUG
import BackgroundDriver
#endif
import AppKit
import ComposableArchitecture
import SwiftUI

/// A Dock app on purpose: no menu bar extra. Clicking the Dock icon opens the configuration
/// window; closing the window leaves the app running so the mappings keep working.
@main
struct JoyMapperSiliconApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Window("JoyMapper Silicon", id: "main") {
            if let store = AppDelegate.store {
                RootView(store: store)
            } else {
                Text("Running unit tests")
            }
        }
        .defaultSize(width: 980, height: 680)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    @MainActor private var dictationPanel: FloatingDictationPanel?

    /// `nil` while hosting unit tests: they build their own stores with test dependencies.
    @MainActor static let store: StoreOf<AppFeature>? = {
        let isHostingTests = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
        guard !isHostingTests else { return nil }
        return Store(initialState: AppFeature.State()) { AppFeature() }
    }()

    @MainActor
    func applicationDidFinishLaunching(_ notification: Notification) {
        guard let store = Self.store else { return }
        Log.app.notice("Launched \(Bundle.main.bundlePath) pid \(ProcessInfo.processInfo.processIdentifier)")
        // Started here, not from the window, so controllers keep working with the window closed.
        store.send(.task)
        dictationPanel = FloatingDictationPanel(store: store.scope(state: \.dictation, action: \.dictation))
        #if DEBUG
        // Lets tests and scripts drive the app without the real mouse (scripts/driver.sh).
        do {
            try BackgroundDriver.start()
        } catch {
            Log.app.error("BackgroundDriver didn't start: \(error)")
        }
        #endif
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    /// Clicking the Dock icon with the window closed brings it back.
    @MainActor
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        Log.app.info("Reopen (visible windows: \(hasVisibleWindows))")
        if !hasVisibleWindows {
            WindowOpener.shared.openMain()
        }
        return true
    }
}

/// SwiftUI only hands out `openWindow` inside views, so the window stores it here for the Dock
/// reopen path to use after the window has closed.
@MainActor
final class WindowOpener {
    static let shared = WindowOpener()
    var open: (() -> Void)?

    func openMain() {
        if let window = NSApp.windows.first(where: { $0.identifier?.rawValue == "main" && !$0.isVisible && $0.canBecomeMain }) {
            window.makeKeyAndOrderFront(nil)
        } else {
            open?()
        }
        NSApp.activate()
    }
}
