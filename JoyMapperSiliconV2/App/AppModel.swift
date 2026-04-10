// JoyMapperSiliconV2/App/AppModel.swift
import AppKit
@preconcurrency import JoyConSwift
import Observation
import Sharing

@MainActor
@Observable
class AppModel {
    let manager = JoyConManager()

    @ObservationIgnored
    @Shared(.fileStorage(
        URL.applicationSupportDirectory
            .appendingPathComponent("JoyMapperSilicon", isDirectory: true)
            .appendingPathComponent("controllers.json")
    ))
    var controllerProfiles: [ControllerProfile] = []

    var controllers: [GameController] = []

    private nonisolated(unsafe) var workspaceObserver: Any?

    init() {
        manager.connectHandler = { [weak self] controller in
            DispatchQueue.main.async { self?.connectController(controller) }
        }
        manager.disconnectHandler = { [weak self] controller in
            DispatchQueue.main.async { self?.disconnectController(controller) }
        }
        manager.connectionStateHandler = { [weak self] device, state in
            DispatchQueue.main.async { self?.handleConnectionState(device: device, state: state) }
        }

        // Hydrate GameControllers from saved profiles
        for profile in controllerProfiles {
            let gc = makeGameController(for: profile)
            controllers.append(gc)
        }

        _ = manager.runAsync()

        workspaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil, queue: .main
        ) { [weak self] notification in
            guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  let bundleID = app.bundleIdentifier else { return }
            MainActor.assumeIsolated {
                resetMetaKeyState()
                self?.controllers.forEach { $0.switchApp(bundleID: bundleID) }
            }
        }
    }

    deinit {
        if let observer = workspaceObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
    }

    // MARK: - Controller Lifecycle

    private func connectController(_ hidController: JoyConSwift.Controller) {
        let serialID = hidController.serialID

        if let existing = controllers.first(where: { $0.serialID == serialID }) {
            existing.controller = hidController
            existing.connectionState = .connected
            existing.startTimer()
            updateProfileColors(serialID: serialID, from: existing)
            return
        }

        let profile = ControllerProfile.create(serialID: serialID, type: hidController.type)
        $controllerProfiles.withLock { $0.append(profile) }

        let gc = makeGameController(for: profile)
        gc.controller = hidController
        gc.connectionState = .connected
        gc.startTimer()
        controllers.append(gc)

        updateProfileColors(serialID: serialID, from: gc)
    }

    private func disconnectController(_ hidController: JoyConSwift.Controller) {
        guard let gc = controllers.first(where: { $0.serialID == hidController.serialID }) else { return }
        gc.controller = nil
        gc.connectionState = .disconnected
        gc.updateControllerIcon()
    }

    private func handleConnectionState(device: IOHIDDevice, state: ConnectionState) {
        let serialID = IOHIDDeviceGetProperty(device, kIOHIDSerialNumberKey as CFString) as? String ?? ""

        switch state {
        case .matching, .initializing:
            if let gc = controllers.first(where: { $0.serialID == serialID && !serialID.isEmpty }) {
                gc.connectionState = .connecting
            }
        case .connected:
            break
        case .error(let error):
            NSLog("Connection error for %@: %@", serialID, String(describing: error))
            if let gc = controllers.first(where: { $0.serialID == serialID && !serialID.isEmpty }) {
                gc.connectionState = .error
            }
        }
    }

    func removeController(_ gc: GameController) {
        gc.disconnect()
        $controllerProfiles.withLock { profiles in
            profiles.removeAll { $0.id == gc.serialID }
        }
        controllers.removeAll { $0.serialID == gc.serialID }
    }

    // MARK: - Helpers

    private func makeGameController(for profile: ControllerProfile) -> GameController {
        let serialID = profile.id
        return GameController(serialID: serialID, profile: profile) { [weak self] in
            self?.controllerProfiles.first { $0.id == serialID }
        }
    }

    private func updateProfileColors(serialID: String, from gc: GameController) {
        $controllerProfiles.withLock { profiles in
            guard let index = profiles.firstIndex(where: { $0.id == serialID }) else { return }
            profiles[index].controllerType = gc.type.rawValue
            profiles[index].bodyColor = CodableColor(gc.bodyColor)
            profiles[index].buttonColor = CodableColor(gc.buttonColor)
            if let lg = gc.leftGripColor { profiles[index].leftGripColor = CodableColor(lg) }
            if let rg = gc.rightGripColor { profiles[index].rightGripColor = CodableColor(rg) }
        }
    }
}
