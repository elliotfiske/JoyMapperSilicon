import ComposableArchitecture
import Foundation

/// Which mappings the detail pane edits: the controller's defaults, or one app's override.
enum ConfigScope: Hashable, Sendable {
    case defaults
    case app(AppOverride.ID)
}

@Reducer
struct AppFeature {
    @ObservableState
    struct State: Equatable {
        @Shared(.profiles) var profiles
        @Shared(.settings) var settings

        var connections: [String: ConnectionPhase] = [:]
        var batteries: [String: Double] = [:]
        var liveInput: [String: InputPreview] = [:]
        var bluetooth: BluetoothState = .unknown
        var isScanning = false
        var accessibilityTrusted = true
        var launchAtLogin = false
        var frontmostApp: FrontmostApp?
        /// Apps recently in front, newest first, not counting this one. Offered as quick picks when
        /// adding an override.
        var recentApps: [FrontmostApp] = []
        var selectedControllerID: String?
        var selectedScope: ConfigScope = .defaults
        @Presents var editor: BindingEditorFeature.State?

        var selectedProfile: ControllerProfile? {
            selectedControllerID.flatMap { profiles[id: $0] }
        }

        /// The config the detail pane shows and edits.
        var selectedConfig: MappingConfig? {
            guard let profile = selectedProfile else { return nil }
            switch selectedScope {
            case .defaults:
                return profile.defaultConfig
            case let .app(overrideID):
                return profile.appOverrides.first { $0.id == overrideID }?.config
            }
        }

        /// What the engine should use right now: each connected controller's config for the
        /// frontmost app.
        var mappingSnapshot: MappingSnapshot {
            var configs: [String: MappingConfig] = [:]
            for profile in profiles {
                configs[profile.id] = profile.config(forFrontmostApp: frontmostApp?.bundleID)
            }
            return MappingSnapshot(isEnabled: settings.mappingsEnabled, configs: configs)
        }

        func phase(for id: String) -> ConnectionPhase {
            connections[id] ?? .disconnected
        }
    }

    enum Action: Equatable {
        case task
        case controllerEvent(ControllerEvent)
        case inputPreview(InputPreview)
        case frontmostAppChanged(FrontmostApp?)
        case accessibilityChecked(Bool)
        case launchAtLoginChecked(Bool)

        case mappingsToggled(Bool)
        case rawLoggingToggled(Bool)
        case launchAtLoginToggled(Bool)
        case requestAccessibilityTapped
        case openAccessibilitySettingsTapped
        case revealLogsTapped

        case controllerSelected(String?)
        case disconnectTapped(String)
        case forgetTapped(String)
        case renameController(String, name: String)

        case scopeSelected(ConfigScope)
        case addAppTapped
        case addRecentApp(FrontmostApp)
        case appChosen(FrontmostApp?)
        case removeAppOverrideTapped(AppOverride.ID)

        case bindingTapped(BindingTarget)
        case clearBindingTapped(BindingTarget)
        case stickModeChanged(StickMode)
        case stickSpeedChanged(Double)
        case resetToStarterTapped

        case editor(PresentationAction<BindingEditorFeature.Action>)
    }

    @Dependency(\.controllers) var controllers
    @Dependency(\.mappingEngine) var engine
    @Dependency(\.system) var system
    @Dependency(\.continuousClock) var clock
    @Dependency(\.uuid) var uuid

    /// This app's own bundle ID, left out of the recent-apps list.
    static let ownBundleID = "com.elliotfiske.JoyMapperSilicon"

    enum CancelID { case accessibilityPolling }

    var body: some ReducerOf<Self> {
        Reduce { state, action in
            switch action {
            case .task:
                return start(&state)

            case let .controllerEvent(event):
                return handle(event, state: &state)

            case let .inputPreview(preview):
                state.liveInput[preview.controllerID] = preview
                return .none

            case let .frontmostAppChanged(app):
                state.frontmostApp = app
                if let app, app.bundleID != Self.ownBundleID {
                    state.recentApps.removeAll { $0.bundleID == app.bundleID }
                    state.recentApps.insert(app, at: 0)
                    state.recentApps = Array(state.recentApps.prefix(8))
                }
                return .none

            case let .accessibilityChecked(isTrusted):
                guard state.accessibilityTrusted != isTrusted else { return .none }
                state.accessibilityTrusted = isTrusted
                Log.app.notice("Accessibility permission: \(isTrusted ? "granted" : "missing")")
                return .none

            case let .launchAtLoginChecked(isOn):
                state.launchAtLogin = isOn
                return .none

            case let .mappingsToggled(isOn):
                state.$settings.withLock { $0.mappingsEnabled = isOn }
                Log.app.notice("Mappings turned \(isOn ? "on" : "off")")
                return .none

            case let .rawLoggingToggled(isOn):
                state.$settings.withLock { $0.logRawReports = isOn }
                return .run { _ in controllers.setRawReportLogging(isOn) }

            case let .launchAtLoginToggled(isOn):
                return .run { send in
                    do {
                        try system.setLaunchAtLogin(isOn)
                    } catch {
                        Log.app.error("Couldn't change launch at login: \(error.localizedDescription)")
                    }
                    await send(.launchAtLoginChecked(system.isLaunchAtLoginEnabled()))
                }

            case .requestAccessibilityTapped:
                return .run { _ in system.requestAccessibility() }

            case .openAccessibilitySettingsTapped:
                return .run { _ in system.openAccessibilitySettings() }

            case .revealLogsTapped:
                return .run { _ in system.revealLogs() }

            case let .controllerSelected(id):
                state.selectedControllerID = id
                state.selectedScope = .defaults
                return .none

            case let .disconnectTapped(id):
                return .run { _ in controllers.disconnect(id) }

            case let .forgetTapped(id):
                state.$profiles.withLock { _ = $0.remove(id: id) }
                if state.selectedControllerID == id {
                    state.selectedControllerID = state.profiles.first?.id
                    state.selectedScope = .defaults
                }
                Log.app.notice("Forgot controller \(id)")
                return .run { _ in controllers.disconnect(id) }

            case let .renameController(id, name):
                let trimmed = name.trimmingCharacters(in: .whitespaces)
                guard !trimmed.isEmpty else { return .none }
                state.$profiles.withLock { $0[id: id]?.name = trimmed }
                return .none

            case let .scopeSelected(scope):
                state.selectedScope = scope
                return .none

            case .addAppTapped:
                return .run { send in
                    await send(.appChosen(system.chooseApp()))
                }

            case let .addRecentApp(app):
                return .send(.appChosen(app))

            case let .appChosen(app):
                guard let app, let id = state.selectedControllerID else { return .none }
                guard let profile = state.profiles[id: id] else { return .none }
                if let existing = profile.appOverrides.first(where: { $0.bundleID == app.bundleID }) {
                    state.selectedScope = .app(existing.id)
                    return .none
                }
                // Start from the defaults: an override usually changes a button or two.
                let override = AppOverride(id: uuid(), bundleID: app.bundleID, appName: app.name, config: profile.defaultConfig)
                state.$profiles.withLock { $0[id: id]?.appOverrides.append(override) }
                state.selectedScope = .app(override.id)
                Log.app.notice("Added mappings for \(app.name) (\(app.bundleID)) on \(profile.name)")
                return .none

            case let .removeAppOverrideTapped(overrideID):
                guard let id = state.selectedControllerID else { return .none }
                state.$profiles.withLock { $0[id: id]?.appOverrides.removeAll { $0.id == overrideID } }
                if state.selectedScope == .app(overrideID) {
                    state.selectedScope = .defaults
                }
                return .none

            case let .bindingTapped(target):
                guard let profile = state.selectedProfile, let config = state.selectedConfig else { return .none }
                state.editor = BindingEditorFeature.State(
                    target: target,
                    controllerName: profile.name,
                    binding: Self.binding(for: target, in: config)
                )
                return .none

            case let .clearBindingTapped(target):
                updateSelectedConfig(&state) { Self.setBinding(.none, for: target, in: &$0) }
                return .none

            case let .stickModeChanged(mode):
                updateSelectedConfig(&state) { $0.stick.mode = mode }
                return .none

            case let .stickSpeedChanged(speed):
                updateSelectedConfig(&state) { $0.stick.speed = speed }
                return .none

            case .resetToStarterTapped:
                guard let kind = state.selectedProfile?.kind else { return .none }
                updateSelectedConfig(&state) { $0 = .starter(for: kind) }
                return .none

            case let .editor(.presented(.delegate(.save(target, binding)))):
                updateSelectedConfig(&state) { Self.setBinding(binding, for: target, in: &$0) }
                Log.app.info("Bound \(target.identifier) to \(binding.displayString)")
                return .none

            case .editor:
                return .none
            }
        }
        .ifLet(\.$editor, action: \.editor) {
            BindingEditorFeature()
        }
        .onChange(of: \.mappingSnapshot) { _, snapshot in
            Reduce { _, _ in
                .run { _ in engine.update(snapshot) }
            }
        }
    }

    // MARK: - Startup

    private func start(_ state: inout State) -> Effect<Action> {
        Log.app.notice("Starting: \(state.profiles.count) saved controller(s), mappings \(state.settings.mappingsEnabled ? "on" : "off")")
        if state.selectedControllerID == nil {
            state.selectedControllerID = state.profiles.first?.id
        }
        let snapshot = state.mappingSnapshot
        let logRaw = state.settings.logRawReports
        return .merge(
            .run { send in
                engine.update(snapshot)
                controllers.setRawReportLogging(logRaw)
                controllers.start()
                for await event in controllers.events() {
                    await send(.controllerEvent(event))
                }
            },
            .run { send in
                for await preview in engine.previews() {
                    await send(.inputPreview(preview))
                }
            },
            .run { send in
                await send(.frontmostAppChanged(system.frontmostApp()))
                for await app in system.frontmostAppChanges() {
                    await send(.frontmostAppChanged(app))
                }
            },
            .run { send in
                await send(.launchAtLoginChecked(system.isLaunchAtLoginEnabled()))
                // Accessibility can be granted at any time in System Settings, and nothing tells us.
                while true {
                    await send(.accessibilityChecked(system.isAccessibilityTrusted()))
                    try await clock.sleep(for: .seconds(2))
                }
            }
            .cancellable(id: CancelID.accessibilityPolling)
        )
    }

    // MARK: - Controller events

    private func handle(_ event: ControllerEvent, state: inout State) -> Effect<Action> {
        switch event {
        case let .bluetooth(bluetooth):
            state.bluetooth = bluetooth

        case let .scanning(isScanning):
            state.isScanning = isScanning

        case let .discovered(id, kind):
            addProfileIfNeeded(id: id, kind: kind, state: &state)

        case let .phase(id, kind, phase):
            addProfileIfNeeded(id: id, kind: kind, state: &state)
            state.connections[id] = phase
            if !phase.isConnected {
                state.liveInput[id] = nil
            }

        case let .battery(id, level):
            state.batteries[id] = level
        }
        return .none
    }

    private func addProfileIfNeeded(id: String, kind: ControllerKind, state: inout State) {
        if state.profiles[id: id] == nil {
            state.$profiles.withLock { $0.append(ControllerProfile(id: id, kind: kind)) }
            Log.app.notice("New controller: \(kind.displayName) \(id)")
        }
        if state.selectedControllerID == nil {
            state.selectedControllerID = id
        }
    }

    // MARK: - Editing

    private func updateSelectedConfig(_ state: inout State, _ change: (inout MappingConfig) -> Void) {
        guard let id = state.selectedControllerID else { return }
        let scope = state.selectedScope
        state.$profiles.withLock { profiles in
            guard var profile = profiles[id: id] else { return }
            switch scope {
            case .defaults:
                change(&profile.defaultConfig)
            case let .app(overrideID):
                guard let index = profile.appOverrides.firstIndex(where: { $0.id == overrideID }) else { return }
                change(&profile.appOverrides[index].config)
            }
            profiles[id: id] = profile
        }
    }

    static func binding(for target: BindingTarget, in config: MappingConfig) -> KeyBinding {
        switch target {
        case let .button(button): config.binding(for: button)
        case let .stick(direction): config.stick.binding(for: direction)
        }
    }

    static func setBinding(_ binding: KeyBinding, for target: BindingTarget, in config: inout MappingConfig) {
        let stored: KeyBinding? = binding.isEmpty ? nil : binding
        switch target {
        case let .button(button): config.buttons[button] = stored
        case let .stick(direction): config.stick.directions[direction] = stored
        }
    }
}
