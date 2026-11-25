import ComposableArchitecture
import SwiftUI

struct RootView: View {
    @Bindable var store: StoreOf<AppFeature>
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        NavigationSplitView {
            ControllerSidebar(store: store)
                .navigationSplitViewColumnWidth(min: 220, ideal: 250)
        } detail: {
            VStack(spacing: 0) {
                StatusBar(store: store)
                Divider()
                if let profile = store.selectedProfile {
                    ProfileDetailView(store: store, profile: profile)
                } else {
                    EmptyControllersView(store: store)
                }
            }
        }
        // An inspector, not a sheet: it stays in the main window, so it works while another
        // app is in front (and BackgroundDriver can drive it).
        .inspector(isPresented: Binding(
            get: { store.editor != nil },
            set: { isPresented in if !isPresented { store.send(.editor(.dismiss)) } }
        )) {
            if let editorStore = store.scope(state: \.editor, action: \.editor.presented) {
                BindingEditorView(store: editorStore)
                    .inspectorColumnWidth(min: 340, ideal: 380, max: 480)
            }
        }
        .onAppear {
            WindowOpener.shared.open = { openWindow(id: "main") }
        }
    }
}

/// The top strip: the on/off switch, and anything that's stopping mappings from working.
struct StatusBar: View {
    let store: StoreOf<AppFeature>

    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 16) {
                Toggle(isOn: Binding(
                    get: { store.settings.mappingsEnabled },
                    set: { store.send(.mappingsToggled($0)) }
                )) {
                    Text("Enable mappings").font(.headline)
                }
                .toggleStyle(.switch)
                .accessibilityIdentifier("mappings-toggle")

                Spacer()

                if let app = store.frontmostApp {
                    Label("In front: \(app.name)", systemImage: "macwindow")
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("frontmost-app")
                }

                Label(store.bluetooth.displayText, systemImage: bluetoothSymbol)
                    .foregroundStyle(store.bluetooth.isUsable ? Color.secondary : Color.red)
                    .accessibilityIdentifier("bluetooth-status")
            }

            if !store.accessibilityTrusted {
                HStack {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.yellow)
                    Text("JoyMapper Silicon needs Accessibility permission to send keys and clicks. Without it, presses do nothing.")
                    Spacer()
                    Button("Grant…") { store.send(.requestAccessibilityTapped) }
                    Button("Open Settings") { store.send(.openAccessibilitySettingsTapped) }
                }
                .padding(8)
                .background(.yellow.opacity(0.15), in: RoundedRectangle(cornerRadius: 6))
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("accessibility-banner")
            }
        }
        .padding(12)
    }

    private var bluetoothSymbol: String {
        store.bluetooth.isUsable ? "dot.radiowaves.left.and.right" : "exclamationmark.triangle"
    }
}

struct ControllerSidebar: View {
    let store: StoreOf<AppFeature>

    var body: some View {
        List(selection: Binding(
            get: { store.selectedControllerID },
            set: { store.send(.controllerSelected($0)) }
        )) {
            Section("Controllers") {
                ForEach(store.profiles) { profile in
                    ControllerRow(
                        profile: profile,
                        phase: store.state.phase(for: profile.id),
                        battery: store.batteries[profile.id]
                    )
                    .tag(profile.id)
                    // A List only changes selection on clicks into the focused window. This
                    // also selects on the first click from another app (and from BackgroundDriver).
                    .contentShape(Rectangle())
                    .onTapGesture { store.send(.controllerSelected(profile.id)) }
                }
            }
            Section("Settings") {
                Toggle("Open at login", isOn: Binding(
                    get: { store.launchAtLogin },
                    set: { store.send(.launchAtLoginToggled($0)) }
                ))
                .accessibilityIdentifier("launch-at-login-toggle")
                Toggle("Log raw reports", isOn: Binding(
                    get: { store.settings.logRawReports },
                    set: { store.send(.rawLoggingToggled($0)) }
                ))
                .accessibilityIdentifier("raw-logging-toggle")
                Button("Show log file") { store.send(.revealLogsTapped) }
                    .buttonStyle(.link)
                    .accessibilityIdentifier("reveal-logs")
            }
        }
        .accessibilityIdentifier("controller-list")
    }
}

struct ControllerRow: View {
    let profile: ControllerProfile
    let phase: ConnectionPhase
    let battery: Double?

    var body: some View {
        HStack(spacing: 10) {
            JoyConGlyph(kind: profile.kind, isConnected: phase.isConnected)
            VStack(alignment: .leading, spacing: 2) {
                Text(profile.name).font(.body)
                HStack(spacing: 6) {
                    Circle().fill(statusColor).frame(width: 7, height: 7)
                    Text(phase.displayText)
                    if let battery, phase.isConnected {
                        Text("· \(Int((battery * 100).rounded()))%")
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("controller-row-\(profile.id)")
    }

    private var statusColor: Color {
        switch phase {
        case .ready: .green
        case .connecting, .initializing: .orange
        case .failed: .red
        case .disconnected: .gray
        }
    }
}

/// A small Joy-Con drawn from the original app's artwork.
struct JoyConGlyph: View {
    let kind: ControllerKind
    let isConnected: Bool

    var body: some View {
        let prefix = kind == .joyCon2Left ? "joycon_left" : "joycon_right"
        ZStack {
            Image("\(prefix)_body").resizable().renderingMode(.template)
                .foregroundStyle(kind == .joyCon2Left ? Color.cyan : Color.pink)
            Image("\(prefix)_button").resizable().renderingMode(.template)
                .foregroundStyle(Color(white: 0.2))
            Image("\(prefix)_base").resizable()
        }
        .aspectRatio(contentMode: .fit)
        .frame(width: 22, height: 36)
        .opacity(isConnected ? 1 : 0.4)
    }
}

struct EmptyControllersView: View {
    let store: StoreOf<AppFeature>

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "gamecontroller").font(.system(size: 44)).foregroundStyle(.secondary)
            Text("No controllers yet").font(.title2)
            Text("Hold the small sync button on the rail side of a Joy-Con 2 until its lights sweep. It connects on its own.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 380)
            if store.isScanning {
                ProgressView().controlSize(.small)
                Text("Looking for Joy-Con 2s…").font(.caption).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityIdentifier("empty-state")
    }
}
