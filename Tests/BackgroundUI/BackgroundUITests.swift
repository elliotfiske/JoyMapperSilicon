import BackgroundDriverClient
import XCTest

/// Drives a fresh copy of the app in the background. It never activates, never touches the real
/// mouse or keyboard, and uses:
/// - simulated Joy-Cons (`JOYMAPPER_SIMULATED_CONTROLLERS`), pressed through distributed notifications,
/// - a temporary data folder (`JOYMAPPER_DATA_DIR`), so your mappings are untouched,
/// - an event log (`JOYMAPPER_EVENT_LOG`) instead of real key presses, so nothing types into the
///   app you're using. The tests read it to check the whole controller → mapping → event path.
final class BackgroundUITests: XCTestCase {
    private var app: LaunchedApp!
    private var driver: DriverClient { app.client }
    private var workDirectory: URL!
    private var eventLog: URL { workDirectory.appending(path: "events.jsonl") }
    private var speechFile: URL { workDirectory.appending(path: "speech.aiff") }
    private static let spokenSentence = "Please check the connect handler on the main thread."

    private let left = "SIM-joyCon2Left"
    private let right = "SIM-joyCon2Right"

    private var appURL: URL {
        Bundle(for: Self.self).bundleURL.deletingLastPathComponent().appending(component: "JoyMapperSilicon.app")
    }

    override func setUpWithError() throws {
        workDirectory = FileManager.default.temporaryDirectory.appending(path: "joymapper-e2e-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: workDirectory, withIntermediateDirectories: true)
        try speak(Self.spokenSentence, to: speechFile)
        app = try LaunchedApp.launch(appURL, environment: [
            "JOYMAPPER_SIMULATED_CONTROLLERS": "joyCon2Left,joyCon2Right",
            "JOYMAPPER_DATA_DIR": workDirectory.path,
            "JOYMAPPER_EVENT_LOG": eventLog.path,
            // Dictation reads this file instead of the microphone, and cleanup is stubbed.
            "JOYMAPPER_DICTATION_AUDIO_FILE": speechFile.path,
            "JOYMAPPER_CLEANUP_STUB": "1",
        ])
        try waitFor("both simulated controllers connected") {
            let rows = try self.driver.elements(prefix: "controller-row-")
            return rows.count == 2 && rows.allSatisfy { $0.value.contains("Connected") }
        }
    }

    override func tearDown() {
        app?.terminate()
        if let workDirectory { try? FileManager.default.removeItem(at: workDirectory) }
    }

    // MARK: - Tests

    func testStaysInTheBackground() throws {
        let status = try driver.status()
        XCTAssertFalse(status.active, "the app activated itself and took focus")
    }

    func testButtonPressShowsLiveAndPostsStarterBinding() throws {
        try select(right)
        XCTAssertEqual(try text("binding-value-a"), "Return")

        simulate(right, buttons: ["a"])
        try waitFor("A shows as pressed") { try self.label("pressed-a") == "pressed" }
        simulate(right, buttons: [])
        try waitFor("A shows as released") { try self.label("pressed-a") == "released" }

        try waitFor("Return down and up recorded") {
            let keys = self.recordedKeys()
            return keys.contains(Key(code: 36, down: true, modifiers: 0))
                && keys.contains(Key(code: 36, down: false, modifiers: 0))
        }
    }

    func testRecordingANewBindingChangesWhatTheButtonSends() throws {
        try select(right)
        try driver.click(Target(id: "edit-a"))
        try waitFor("editor open") { try self.driver.element("editor-record") != nil }

        try driver.click(Target(id: "editor-record"))
        try driver.key(KeyPress(key: "k", modifiers: ["command"]))
        try waitFor("recorded ⌘K") { try self.text("editor-current") == "⌘K" }
        try driver.click(Target(id: "editor-save"))
        try waitFor("row shows ⌘K") { try self.text("binding-value-a") == "⌘K" }

        simulate(right, buttons: ["a"])
        simulate(right, buttons: [])
        // kVK_ANSI_K = 40, with ⌘ (Modifiers.command = 8), wrapped in ⌘ down/up.
        try waitFor("⌘K recorded") {
            let keys = self.recordedKeys()
            return keys.contains(Key(code: 40, down: true, modifiers: 8))
                && keys.contains(Key(code: 55, down: false, modifiers: 0))
        }
    }

    func testTurningMappingsOffStopsEvents() throws {
        try driver.click(Target(id: "mappings-toggle"))
        try waitFor("toggle off") { try self.value("mappings-toggle") == "0" }

        simulate(right, buttons: ["a"])
        simulate(right, buttons: [])
        simulate(left, buttons: ["zl"])
        simulate(left, buttons: [])
        Thread.sleep(forTimeInterval: 0.5)
        XCTAssertEqual(recordedEvents().count, 0, "events were posted while mappings were off")

        try driver.click(Target(id: "mappings-toggle"))
        try waitFor("toggle on") { try self.value("mappings-toggle") == "1" }
        simulate(left, buttons: ["zl"])
        simulate(left, buttons: [])
        try waitFor("left click recorded once mappings are back on") {
            self.recordedEvents().contains { $0["mouseButton"] != nil }
        }
    }

    func testLeftStickMovesThePointer() throws {
        simulate(left, buttons: [], x: 1, y: 0)
        try waitFor("pointer moves to the right") {
            self.recordedEvents().contains { event in
                guard let move = event["mouseMove"] as? [String: Any] else { return false }
                return (move["dx"] as? Double ?? 0) > 0
            }
        }
        simulate(left, buttons: [], x: 0, y: 0)
    }

    func testHoldingCDictatesIntoTheFrontmostApp() throws {
        // The starter R mapping holds C to talk.
        simulate(right, buttons: ["c"])
        try waitFor("panel shows the live transcript", timeout: 10) {
            try self.text("dictation-live-text")?.localizedCaseInsensitiveContains("connect handler") == true
        }
        XCTAssertTrue(try text("dictation-state")?.hasPrefix("Listening") == true)
        simulate(right, buttons: [])

        try waitFor("cleaned-up text pasted", timeout: 10) {
            self.recordedEvents().contains { event in
                guard let insert = event["insertText"] as? [String: Any] else { return false }
                let text = insert["_0"] as? String ?? ""
                return text.hasPrefix("[clean] ") && text.localizedCaseInsensitiveContains("connect handler")
            }
        }
        try waitFor("panel says it pasted") { try self.text("dictation-state") == "Pasted" }

        // Saved to history, and Home (paste last) pastes it again.
        try driver.click(Target(id: "sidebar-history"))
        try waitFor("history lists it") { try !self.driver.elements(prefix: "history-row-").isEmpty }
        simulate(right, buttons: ["home"])
        simulate(right, buttons: [])
        try waitFor("pasted a second time") {
            self.recordedEvents().filter { $0["insertText"] != nil }.count == 2
        }

        let history = try String(contentsOf: workDirectory.appending(path: "Dictation/history.jsonl"), encoding: .utf8)
        XCTAssertTrue(history.contains("connect handler"))
        let audio = try FileManager.default.contentsOfDirectory(atPath: workDirectory.appending(path: "Dictation/Audio").path)
        XCTAssertEqual(audio.count, 1, "the recording is kept")
    }

    func testDisconnectedControllerShowsAsNotConnected() throws {
        simulateDisconnect(left)
        try waitFor("left shows not connected") {
            try self.driver.element("controller-row-\(self.left)")?.element.value.contains("Not connected") == true
        }
    }

    // MARK: - Helpers

    private func speak(_ sentence: String, to url: URL) throws {
        let say = Process()
        say.executableURL = URL(filePath: "/usr/bin/say")
        say.arguments = ["-o", url.path, sentence]
        try say.run()
        say.waitUntilExit()
    }

    private func select(_ controllerID: String) throws {
        try driver.click(Target(id: "controller-row-\(controllerID)"))
        let expectedName = controllerID == right ? "Joy-Con 2 (R)" : "Joy-Con 2 (L)"
        try waitFor("\(controllerID) selected") { try self.text("profile-name") == expectedName }
    }

    private func simulate(_ id: String, buttons: [String], x: Double = 0, y: Double = 0) {
        post(["id": id, "buttons": buttons.joined(separator: ","), "x": "\(x)", "y": "\(y)"])
        // Each notification is one input report; give the app a beat between them.
        Thread.sleep(forTimeInterval: 0.1)
    }

    private func simulateDisconnect(_ id: String) {
        post(["id": id, "action": "disconnect"])
    }

    private func post(_ info: [String: String]) {
        DistributedNotificationCenter.default().postNotificationName(
            Notification.Name("com.elliotfiske.JoyMapperSilicon.simulate"),
            object: nil,
            userInfo: info,
            deliverImmediately: true
        )
    }

    private func label(_ id: String) throws -> String? { try driver.element(id)?.element.label }
    private func value(_ id: String) throws -> String? { try driver.element(id)?.element.value }

    /// SwiftUI puts text in `label` for some elements and `value` for others. Searches every
    /// window, including the floating dictation panel (`element(_:)` looks at one window).
    private func text(_ id: String) throws -> String? {
        let matches = try driver.elements(prefix: id).filter { $0.identifier == id }
        guard let element = matches.first else { return nil }
        return element.value.isEmpty ? element.label : element.value
    }

    private struct Key: Equatable {
        var code: Int
        var down: Bool
        var modifiers: Int
    }

    private func recordedEvents() -> [[String: Any]] {
        guard let text = try? String(contentsOf: eventLog, encoding: .utf8) else { return [] }
        return text.split(separator: "\n").compactMap { line in
            try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any]
        }
    }

    private func recordedKeys() -> [Key] {
        recordedEvents().compactMap { event in
            guard let key = event["key"] as? [String: Any] else { return nil }
            return Key(
                code: key["code"] as? Int ?? -1,
                down: key["down"] as? Bool ?? false,
                modifiers: key["modifiers"] as? Int ?? -1
            )
        }
    }

    private func waitFor(
        _ description: String,
        timeout: TimeInterval = 5,
        file: StaticString = #filePath,
        line: UInt = #line,
        _ condition: @escaping () throws -> Bool
    ) throws {
        let deadline = Date().addingTimeInterval(timeout)
        var lastError: Error?
        while Date() < deadline {
            do {
                if try condition() { return }
            } catch {
                lastError = error
            }
            Thread.sleep(forTimeInterval: 0.1)
        }
        let tree = (try? driver.tree()) ?? "(no tree)"
        let events = recordedEvents().map { "\($0)" }.joined(separator: "\n")
        XCTFail("Timed out waiting for: \(description). Last error: \(lastError.map { "\($0)" } ?? "none")\nEvents:\n\(events)\nTree:\n\(tree)", file: file, line: line)
        throw XCTSkip("stopping after timeout")
    }
}
