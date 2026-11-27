import AppKit
import ApplicationServices
import ComposableArchitecture
import ServiceManagement
import UniformTypeIdentifiers

/// The frontmost app, which picks the per-app mappings.
struct FrontmostApp: Equatable, Sendable {
    var bundleID: String
    var name: String
}

/// macOS services the store needs: permissions, the frontmost app, login items, Finder.
struct SystemClient: Sendable {
    /// Whether this process may post events (Accessibility in Privacy & Security).
    var isAccessibilityTrusted: @Sendable () -> Bool
    /// Shows the system prompt that adds the app to the Accessibility list.
    var requestAccessibility: @Sendable () -> Void
    var openAccessibilitySettings: @Sendable () -> Void
    var frontmostApp: @Sendable () async -> FrontmostApp?
    var frontmostAppChanges: @Sendable () -> AsyncStream<FrontmostApp>
    var isLaunchAtLoginEnabled: @Sendable () -> Bool
    var setLaunchAtLogin: @Sendable (Bool) throws -> Void
    var revealLogs: @Sendable () -> Void
    /// Asks the user to pick an app in /Applications.
    var chooseApp: @Sendable () async -> FrontmostApp?
}

extension SystemClient: DependencyKey {
    static let liveValue = SystemClient(
        isAccessibilityTrusted: { AXIsProcessTrusted() },
        requestAccessibility: {
            let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
            _ = AXIsProcessTrustedWithOptions(options)
        },
        openAccessibilitySettings: {
            let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
            NSWorkspace.shared.open(url)
        },
        frontmostApp: {
            await MainActor.run {
                NSWorkspace.shared.frontmostApplication.flatMap(FrontmostApp.init(running:))
            }
        },
        frontmostAppChanges: {
            AsyncStream { continuation in
                let center = NSWorkspace.shared.notificationCenter
                let observer = center.addObserver(
                    forName: NSWorkspace.didActivateApplicationNotification,
                    object: nil,
                    queue: .main
                ) { notification in
                    let running = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
                    guard let app = running.flatMap(FrontmostApp.init(running:)) else { return }
                    continuation.yield(app)
                }
                let box = UncheckedBox(observer)
                continuation.onTermination = { _ in center.removeObserver(box.value) }
            }
        },
        isLaunchAtLoginEnabled: { SMAppService.mainApp.status == .enabled },
        setLaunchAtLogin: { isOn in
            if isOn {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        },
        revealLogs: {
            NSWorkspace.shared.activateFileViewerSelecting([LogFile.url])
        },
        chooseApp: {
            await MainActor.run {
                let panel = NSOpenPanel()
                panel.directoryURL = URL(filePath: "/Applications")
                panel.allowedContentTypes = [.application]
                panel.allowsMultipleSelection = false
                panel.prompt = "Add"
                panel.message = "Choose an app to give its own mappings."
                guard panel.runModal() == .OK, let url = panel.url else { return nil }
                guard let bundle = Bundle(url: url), let bundleID = bundle.bundleIdentifier else { return nil }
                let name = FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
                return FrontmostApp(bundleID: bundleID, name: name)
            }
        }
    )

    static let testValue = SystemClient(
        isAccessibilityTrusted: unimplemented("SystemClient.isAccessibilityTrusted", placeholder: true),
        requestAccessibility: unimplemented("SystemClient.requestAccessibility"),
        openAccessibilitySettings: unimplemented("SystemClient.openAccessibilitySettings"),
        frontmostApp: unimplemented("SystemClient.frontmostApp", placeholder: nil),
        frontmostAppChanges: unimplemented("SystemClient.frontmostAppChanges", placeholder: AsyncStream { $0.finish() }),
        isLaunchAtLoginEnabled: unimplemented("SystemClient.isLaunchAtLoginEnabled", placeholder: false),
        setLaunchAtLogin: unimplemented("SystemClient.setLaunchAtLogin"),
        revealLogs: unimplemented("SystemClient.revealLogs"),
        chooseApp: unimplemented("SystemClient.chooseApp", placeholder: nil)
    )
}

extension DependencyValues {
    var system: SystemClient {
        get { self[SystemClient.self] }
        set { self[SystemClient.self] = newValue }
    }
}

extension FrontmostApp {
    init?(running app: NSRunningApplication) {
        guard let bundleID = app.bundleIdentifier else { return nil }
        self.init(bundleID: bundleID, name: app.localizedName ?? bundleID)
    }
}

/// Carries a non-Sendable value across a `@Sendable` boundary where it's only used on one thread.
struct UncheckedBox<Value>: @unchecked Sendable {
    let value: Value
    init(_ value: Value) { self.value = value }
}
