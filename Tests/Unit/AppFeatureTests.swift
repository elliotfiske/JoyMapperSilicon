import Carbon.HIToolbox
import ComposableArchitecture
import XCTest
@testable import JoyMapperSilicon

@MainActor
final class AppFeatureTests: XCTestCase {
    private let rightID = "66EC9A1C-A4B6-17C3-8CD2-EE39892864BA"

    /// Records every snapshot the store pushes to the engine.
    private final class SnapshotLog: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [MappingSnapshot] = []
        func append(_ snapshot: MappingSnapshot) { lock.lock(); values.append(snapshot); lock.unlock() }
        var last: MappingSnapshot? { lock.lock(); defer { lock.unlock() }; return values.last }
    }

    private func makeStore(
        snapshots: SnapshotLog = SnapshotLog(),
        initialState: AppFeature.State = AppFeature.State()
    ) -> TestStoreOf<AppFeature> {
        let store = TestStore(initialState: initialState) {
            AppFeature()
        } withDependencies: {
            $0.mappingEngine.update = { snapshots.append($0) }
            $0.uuid = .incrementing
        }
        store.exhaustivity = .off(showSkippedAssertions: false)
        return store
    }

    func testNewControllerGetsAStarterProfileAndIsSelected() async {
        let snapshots = SnapshotLog()
        let store = makeStore(snapshots: snapshots)

        await store.send(.controllerEvent(.phase(id: rightID, kind: .joyCon2Right, .ready))) {
            $0.$profiles.withLock { $0.append(ControllerProfile(id: self.rightID, kind: .joyCon2Right)) }
            $0.connections[self.rightID] = .ready
            $0.selectedControllerID = self.rightID
        }
        await store.finish()
        XCTAssertEqual(snapshots.last?.configs[rightID], .starter(for: .joyCon2Right))
        XCTAssertEqual(snapshots.last?.isEnabled, true)
    }

    func testEditingABindingSavesItToTheDefaults() async {
        let store = makeStore()
        await store.send(.controllerEvent(.phase(id: rightID, kind: .joyCon2Right, .ready)))

        await store.send(.bindingTapped(.button(.a))) {
            $0.editor = BindingEditorFeature.State(
                target: .button(.a),
                controllerName: "Joy-Con 2 (R)",
                binding: .key(kVK_Return)
            )
        }
        await store.send(\.editor.recordTapped) { $0.editor?.isRecording = true }
        await store.send(\.editor.keyRecorded, (code: kVK_ANSI_K, modifiers: [.command])) {
            $0.editor?.isRecording = false
            $0.editor?.binding = .key(kVK_ANSI_K, [.command])
        }
        await store.send(\.editor.saveTapped)
        await store.receive(\.editor.delegate.save)
        await store.receive(\.editor.dismiss) { $0.editor = nil }

        XCTAssertEqual(store.state.profiles[id: rightID]?.defaultConfig.buttons[.a], .key(kVK_ANSI_K, [.command]))
    }

    func testAppOverrideAppliesOnlyWhileThatAppIsInFront() async {
        let snapshots = SnapshotLog()
        let store = makeStore(snapshots: snapshots)
        let zed = FrontmostApp(bundleID: "dev.zed.Zed", name: "Zed")
        await store.send(.controllerEvent(.phase(id: rightID, kind: .joyCon2Right, .ready)))

        await store.send(.appChosen(zed)) {
            $0.selectedScope = .app(UUID(0))
        }
        await store.send(.clearBindingTapped(.button(.a)))
        // Editing the Zed override leaves the defaults alone.
        XCTAssertEqual(store.state.profiles[id: rightID]?.defaultConfig.buttons[.a], .key(kVK_Return))

        await store.send(.frontmostAppChanged(zed))
        await store.finish()
        XCTAssertNil(snapshots.last?.configs[rightID]?.buttons[.a])

        await store.send(.frontmostAppChanged(FrontmostApp(bundleID: "com.apple.Safari", name: "Safari")))
        await store.finish()
        XCTAssertEqual(snapshots.last?.configs[rightID]?.buttons[.a], .key(kVK_Return))
        XCTAssertEqual(store.state.recentApps.map(\.name), ["Safari", "Zed"])
    }

    func testTurningMappingsOffDisablesTheEngine() async {
        let snapshots = SnapshotLog()
        let store = makeStore(snapshots: snapshots)
        await store.send(.mappingsToggled(false)) {
            $0.$settings.withLock { $0.mappingsEnabled = false }
        }
        await store.finish()
        XCTAssertEqual(snapshots.last?.isEnabled, false)
    }

    func testForgettingSelectsAnotherControllerAndDisconnects() async {
        let disconnected = LockIsolated<[String]>([])
        let store = TestStore(initialState: AppFeature.State()) {
            AppFeature()
        } withDependencies: {
            $0.mappingEngine.update = { _ in }
            $0.controllers.disconnect = { id in disconnected.withValue { $0.append(id) } }
        }
        store.exhaustivity = .off(showSkippedAssertions: false)
        await store.send(.controllerEvent(.phase(id: "L", kind: .joyCon2Left, .ready)))
        await store.send(.controllerEvent(.phase(id: "R", kind: .joyCon2Right, .ready)))

        await store.send(.forgetTapped("L")) {
            $0.selectedControllerID = "R"
        }
        await store.finish()
        XCTAssertEqual(store.state.profiles.ids, ["R"])
        XCTAssertEqual(disconnected.value, ["L"])
    }

    func testSystemAppIsNotARecentApp() async {
        let store = makeStore()
        await store.send(.frontmostAppChanged(FrontmostApp(bundleID: AppFeature.ownBundleID, name: "JoyMapper Silicon")))
        XCTAssertEqual(store.state.recentApps, [])
    }
}
