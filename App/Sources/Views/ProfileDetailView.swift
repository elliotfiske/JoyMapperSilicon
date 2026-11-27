import ComposableArchitecture
import SwiftUI

/// One controller: its connection, which mappings to edit (defaults or an app), and the mappings.
struct ProfileDetailView: View {
    let store: StoreOf<AppFeature>
    let profile: ControllerProfile

    var body: some View {
        let config = store.selectedConfig ?? profile.defaultConfig
        let live = store.liveInput[profile.id]
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                ScopeBar(store: store, profile: profile)
                ButtonsSection(store: store, kind: profile.kind, config: config, pressed: live?.buttons ?? [])
                StickSection(store: store, config: config.stick, live: live?.stick)
            }
            .padding(16)
        }
        .accessibilityIdentifier("profile-detail")
    }

    private var header: some View {
        let phase = store.state.phase(for: profile.id)
        return HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 4) {
                Text(profile.name).font(.title2.bold()).accessibilityIdentifier("profile-name")
                Text("\(profile.kind.displayName) · \(phase.displayText)")
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("profile-status")
            }
            Spacer()
            if phase.isConnected {
                Button("Disconnect") { store.send(.disconnectTapped(profile.id)) }
                    .accessibilityIdentifier("disconnect-button")
            }
            Button("Forget", role: .destructive) { store.send(.forgetTapped(profile.id)) }
                .accessibilityIdentifier("forget-button")
        }
    }
}

/// Picks between the default mappings and per-app overrides, and adds or removes overrides.
struct ScopeBar: View {
    let store: StoreOf<AppFeature>
    let profile: ControllerProfile

    var body: some View {
        HStack(spacing: 10) {
            Text("Mappings for").foregroundStyle(.secondary)
            Picker("Mappings for", selection: Binding(
                get: { store.selectedScope },
                set: { store.send(.scopeSelected($0)) }
            )) {
                Text("All apps (default)").tag(ConfigScope.defaults)
                ForEach(profile.appOverrides) { override in
                    Text(override.appName).tag(ConfigScope.app(override.id))
                }
            }
            .labelsHidden()
            .frame(maxWidth: 240)
            .accessibilityIdentifier("scope-picker")

            Menu("Add app") {
                if !store.recentApps.isEmpty {
                    Section("Recently used") {
                        ForEach(store.recentApps, id: \.bundleID) { app in
                            Button(app.name) { store.send(.addRecentApp(app)) }
                        }
                    }
                }
                Button("Choose…") { store.send(.addAppTapped) }
            }
            .fixedSize()
            .accessibilityIdentifier("add-app-menu")

            if case let .app(overrideID) = store.selectedScope {
                Button("Remove app") { store.send(.removeAppOverrideTapped(overrideID)) }
                    .accessibilityIdentifier("remove-app-button")
            }

            Spacer()

            Button("Reset to starter") { store.send(.resetToStarterTapped) }
                .buttonStyle(.link)
                .accessibilityIdentifier("reset-starter-button")
        }
        activeHint
    }

    /// Says which mappings are live right now, since that depends on the app in front.
    private var activeHint: some View {
        let frontmost = store.frontmostApp
        let override = profile.appOverrides.first { $0.bundleID == frontmost?.bundleID }
        let text: String
        if let override {
            text = "Active now: \(override.appName) mappings"
        } else {
            text = "Active now: default mappings"
        }
        return Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
            .accessibilityIdentifier("active-mappings")
    }
}

struct ButtonsSection: View {
    let store: StoreOf<AppFeature>
    let kind: ControllerKind
    let config: MappingConfig
    let pressed: Set<ControllerButton>

    var body: some View {
        GroupBox("Buttons") {
            VStack(spacing: 0) {
                ForEach(kind.buttons, id: \.self) { button in
                    BindingRow(
                        store: store,
                        target: .button(button),
                        binding: config.binding(for: button),
                        isPressed: pressed.contains(button)
                    )
                    if button != kind.buttons.last { Divider() }
                }
            }
        }
    }
}

struct BindingRow: View {
    let store: StoreOf<AppFeature>
    let target: BindingTarget
    let binding: KeyBinding
    let isPressed: Bool

    var body: some View {
        HStack {
            Circle()
                .fill(isPressed ? Color.accentColor : Color.secondary.opacity(0.2))
                .frame(width: 10, height: 10)
                .accessibilityLabel(isPressed ? "pressed" : "released")
                .accessibilityIdentifier("pressed-\(target.identifier)")
            Text(target.displayName)
                .frame(width: 100, alignment: .leading)
            Text(binding.displayString)
                .font(.body.monospaced())
                .foregroundStyle(binding.isEmpty ? .secondary : .primary)
                .accessibilityIdentifier("binding-value-\(target.identifier)")
            Spacer()
            if !binding.isEmpty {
                Button {
                    store.send(.clearBindingTapped(target))
                } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear")
                .accessibilityIdentifier("clear-\(target.identifier)")
            }
            Button("Change…") { store.send(.bindingTapped(target)) }
                .accessibilityIdentifier("edit-\(target.identifier)")
        }
        .padding(.vertical, 5)
        .padding(.horizontal, 4)
        .background(isPressed ? Color.accentColor.opacity(0.08) : .clear)
    }
}

struct StickSection: View {
    let store: StoreOf<AppFeature>
    let config: StickConfig
    let live: StickVector?

    var body: some View {
        GroupBox("Stick") {
            HStack(alignment: .top, spacing: 20) {
                VStack(alignment: .leading, spacing: 12) {
                    Picker("Stick does", selection: Binding(
                        get: { config.mode },
                        set: { store.send(.stickModeChanged($0)) }
                    )) {
                        ForEach(StickMode.allCases, id: \.self) { mode in
                            Text(mode.displayName).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)
                    .accessibilityIdentifier("stick-mode")

                    if config.mode == .mouse || config.mode == .scroll {
                        HStack {
                            Text("Speed")
                            Slider(value: Binding(
                                get: { config.speed },
                                set: { store.send(.stickSpeedChanged($0)) }
                            ), in: 2...80)
                            .accessibilityIdentifier("stick-speed")
                            Text("\(Int(config.speed))").monospacedDigit().frame(width: 30)
                        }
                    }

                    if config.mode == .keys {
                        VStack(spacing: 0) {
                            ForEach(StickDirection.allCases, id: \.self) { direction in
                                BindingRow(
                                    store: store,
                                    target: .stick(direction),
                                    binding: config.binding(for: direction),
                                    isPressed: false
                                )
                            }
                        }
                    }
                }
                StickDot(vector: live ?? .zero, deadzone: config.deadzone)
            }
        }
    }
}

/// Where the stick is right now, to check it's alive and see the dead zone.
struct StickDot: View {
    let vector: StickVector
    let deadzone: Double

    var body: some View {
        let size: CGFloat = 80
        ZStack {
            Circle().stroke(Color.secondary.opacity(0.4))
            Circle().fill(Color.secondary.opacity(0.12)).frame(width: size * deadzone, height: size * deadzone)
            Circle()
                .fill(Color.accentColor)
                .frame(width: 10, height: 10)
                .offset(x: vector.x * size / 2, y: -vector.y * size / 2)
        }
        .frame(width: size, height: size)
        .accessibilityElement()
        .accessibilityLabel("Stick position")
        .accessibilityValue(String(format: "%.2f, %.2f", vector.x, vector.y))
        .accessibilityIdentifier("stick-position")
    }
}
