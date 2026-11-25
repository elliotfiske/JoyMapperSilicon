import ComposableArchitecture
import XCTest
@testable import JoyMapperSilicon

extension DictationSettings {
    static var withGateway: DictationSettings {
        var settings = DictationSettings()
        settings.gatewayURL = "https://gateway.test"
        return settings
    }
}

@MainActor
final class DictationFeatureTests: XCTestCase {
    private final class Recorder: @unchecked Sendable {
        let lock = NSLock()
        var saved: [DictationRecord] = []
        var inserted: [String] = []
        var cleanRequests: [CleanupRequest] = []
        var hints: [[String]] = []

        func record(_ body: (Recorder) -> Void) {
            lock.lock()
            body(self)
            lock.unlock()
        }
    }

    private func makeStore(
        recorder: Recorder,
        settings: DictationSettings = .withGateway,
        recognized: String = "um the joy con manager",
        clean: @escaping @Sendable (CleanupRequest) async throws -> CleanupResult = { request in
            CleanupResult(text: "The JoyConManager", model: "claude-sonnet-5-5", milliseconds: 420)
        }
    ) -> TestStoreOf<DictationFeature> {
        var state = DictationFeature.State()
        state.$settings.withLock { $0 = settings }
        state.$dictionary.withLock { $0 = [DictionaryEntry(id: UUID(1), term: "Life360", heardAs: "life three sixty")] }
        let store = TestStore(initialState: state) {
            DictationFeature()
        } withDependencies: {
            $0.uuid = .incrementing
            $0.date.now = Date(timeIntervalSince1970: 1_000)
            $0.continuousClock = ImmediateClock()
            $0.system.frontmostApp = { FrontmostApp(bundleID: "dev.zed.Zed", name: "Zed") }
            $0.dictation.audioFileName = { "\($0.uuidString).caf" }
            $0.dictation.begin = { _, hints, _ in
                recorder.record { $0.hints.append(hints) }
                return AsyncStream { continuation in
                    continuation.yield(.audioStarted(device: "Test mic"))
                    continuation.yield(.level(0.4))
                    continuation.yield(.text("um the"))
                    continuation.yield(.text("um the joy con"))
                    continuation.finish()
                }
            }
            $0.dictation.finish = { (recognized, 2.5) }
            // Parakeet not loaded: the final text is Apple's.
            $0.dictation.transcribeRecording = { _ in nil }
            $0.dictation.screenContext = {
                ScreenContext(appName: "Zed", bundleID: "dev.zed.Zed", windowTitle: "hyderabad — AppDelegate.swift", symbols: ["JoyConManager"])
            }
            $0.dictation.clean = { request, _ in
                recorder.record { $0.cleanRequests.append(request) }
                return try await clean(request)
            }
            $0.dictation.saveRecord = { record in recorder.record { $0.saved.append(record) } }
            $0.dictation.insert = { text in recorder.record { $0.inserted.append(text) } }
        }
        store.exhaustivity = .off(showSkippedAssertions: false)
        return store
    }

    func testHoldDictatesCleansUpAndPastes() async {
        let recorder = Recorder()
        let store = makeStore(recorder: recorder)

        await store.send(.command(.holdStarted(source: "joycon")))
        await store.receive(\.beginRecording)
        await store.receive(\.screenContextRead)
        await store.receive(\.recordingStarted) {
            $0.phase = .listening
            $0.inputDeviceName = "Test mic"
        }
        await store.receive(\.inputLevel) { $0.inputLevel = 0.4 }
        await store.receive(\.liveText) { $0.liveText = "um the" }

        await store.send(.command(.holdEnded)) { $0.phase = .recognizing }
        await store.receive(\.recognized) { $0.phase = .cleaning }
        await store.receive(\.cleaned) { $0.phase = .done }
        await store.receive(\.inserted)
        await store.receive(\.collapse) { $0.phase = .idle }

        XCTAssertEqual(recorder.inserted, ["The JoyConManager"])
        let request = recorder.cleanRequests.first
        XCTAssertEqual(request?.rawText, "um the joy con manager")
        XCTAssertEqual(request?.symbols, ["JoyConManager"])
        XCTAssertEqual(request?.dictionary.map(\.term), ["Life360"])
        XCTAssertEqual(recorder.hints.first, ["Life360"], "first dictation in an app: dictionary terms only")

        // Saved after recognition, then after cleanup, then after pasting.
        let final = store.state.history.first
        XCTAssertEqual(final?.rawText, "um the joy con manager")
        XCTAssertEqual(final?.correctedText, "The JoyConManager")
        XCTAssertEqual(final?.finalText, "The JoyConManager")
        XCTAssertEqual(final?.pasted, true)
        XCTAssertEqual(final?.appName, "Zed")
        XCTAssertEqual(final?.inputDevice, "Test mic")
        XCTAssertGreaterThanOrEqual(recorder.saved.count, 3)
        XCTAssertEqual(store.state.symbolCache["dev.zed.Zed"], ["JoyConManager"])
    }

    func testParakeetTextReplacesApplesAndIsWhatGetsCleanedUp() async {
        let recorder = Recorder()
        let store = makeStore(recorder: recorder)
        store.dependencies.dictation.transcribeRecording = { _ in "Um, the JoyConManager." }
        await store.send(.command(.toggle(source: "hotkey")))
        await store.receive(\.recordingStarted)
        await store.send(.command(.toggle(source: "hotkey")))
        await store.receive(\.cleaned)
        await store.receive(\.inserted)
        XCTAssertEqual(recorder.cleanRequests.first?.rawText, "Um, the JoyConManager.")
        let record = store.state.history.first
        XCTAssertEqual(record?.recognizer, "parakeet-v2")
        XCTAssertEqual(record?.liveText, "um the joy con manager")
    }

    func testEmptyParakeetResultKeepsApplesText() async {
        let recorder = Recorder()
        let store = makeStore(recorder: recorder)
        store.dependencies.dictation.transcribeRecording = { _ in "" }
        await store.send(.command(.toggle(source: "hotkey")))
        await store.receive(\.recordingStarted)
        await store.send(.command(.toggle(source: "hotkey")))
        await store.receive(\.cleaned)
        XCTAssertEqual(recorder.cleanRequests.first?.rawText, "um the joy con manager")
        XCTAssertEqual(store.state.history.first?.recognizer, "apple")
    }

    func testCleanupFailurePastesWhatWasHeard() async {
        let recorder = Recorder()
        let store = makeStore(recorder: recorder, clean: { _ in throw CleanupError.http(503, "down") })
        await store.send(.command(.toggle(source: "hotkey")))
        await store.receive(\.recordingStarted)
        await store.send(.command(.toggle(source: "hotkey")))
        await store.receive(\.cleaned)
        await store.receive(\.inserted)
        XCTAssertEqual(recorder.inserted, ["um the joy con manager"])
        XCTAssertEqual(store.state.history.first?.correctionError, "Gateway returned 503: down")
    }

    func testWithoutAGatewayItPastesRawText() async {
        let recorder = Recorder()
        let store = makeStore(recorder: recorder, settings: DictationSettings())
        await store.send(.command(.toggle(source: "panel")))
        await store.receive(\.recordingStarted)
        await store.send(.stopTapped)
        await store.receive(\.inserted)
        XCTAssertEqual(recorder.cleanRequests, [])
        XCTAssertEqual(recorder.inserted, ["um the joy con manager"])
    }

    func testTypingAShortcutWhileHoldingCancelsButKeepsTheRecord() async {
        let recorder = Recorder()
        let store = makeStore(recorder: recorder)
        store.dependencies.dictation.discard = {}
        await store.send(.command(.holdStarted(source: "hotkey")))
        await store.receive(\.recordingStarted)
        await store.send(.command(.holdCancelled))
        await store.receive(\.cancelTapped) { $0.phase = .idle }
        XCTAssertEqual(recorder.inserted, [])
        XCTAssertEqual(store.state.history.first?.correctionError, "cancelled")
    }

    func testLoginRequiredShowsTheWarningAndLaterDictationsSkipCleanup() async {
        let recorder = Recorder()
        let store = makeStore(recorder: recorder, clean: { _ in throw CleanupError.loginRequired })
        await store.send(.command(.toggle(source: "hotkey")))
        await store.receive(\.recordingStarted)
        await store.send(.command(.toggle(source: "hotkey")))
        await store.receive(\.cleaned) { $0.needsLogin = true }
        await store.receive(\.inserted)
        XCTAssertEqual(recorder.inserted, ["um the joy con manager"])

        await store.receive(\.collapse)
        await store.send(.command(.toggle(source: "hotkey")))
        await store.receive(\.recordingStarted)
        await store.send(.command(.toggle(source: "hotkey")))
        await store.receive(\.inserted)
        XCTAssertEqual(recorder.cleanRequests.count, 1, "no second cleanup attempt until signed in")
        XCTAssertEqual(recorder.inserted.count, 2)
    }

    func testNothingHeardDoesNotPaste() async {
        let recorder = Recorder()
        let store = makeStore(recorder: recorder, recognized: "")
        await store.send(.command(.toggle(source: "panel")))
        await store.receive(\.recordingStarted)
        await store.send(.stopTapped)
        await store.receive(\.recognized) { $0.phase = .failed("Didn't catch anything") }
        XCTAssertEqual(recorder.inserted, [])
        XCTAssertEqual(store.state.history.count, 1)
    }

    func testPasteLastUsesTheNewestFinishedDictation() async {
        let recorder = Recorder()
        var state = DictationFeature.State()
        state.history = [
            DictationRecord(id: UUID(2), startedAt: Date(timeIntervalSince1970: 20), trigger: "hotkey", finalText: ""),
            DictationRecord(id: UUID(1), startedAt: Date(timeIntervalSince1970: 10), trigger: "hotkey", finalText: "older text"),
        ]
        let store = TestStore(initialState: state) { DictationFeature() } withDependencies: {
            $0.dictation.insert = { text in recorder.record { $0.inserted.append(text) } }
        }
        store.exhaustivity = .off(showSkippedAssertions: false)
        await store.send(.command(.pasteLast))
        await store.receive(\.pasteLastTapped)
        await store.finish()
        XCTAssertEqual(recorder.inserted, ["older text"])
    }

    func testSharedDictionaryReplacesOnlySharedTerms() async {
        var state = DictationFeature.State()
        state.$settings.withLock { $0.sharedDictionaryURL = "https://sheets.test/pub?output=csv" }
        state.$dictionary.withLock {
            $0 = [
                DictionaryEntry(id: UUID(1), term: "Mine"),
                DictionaryEntry(id: UUID(2), term: "OldShared", source: "shared"),
            ]
        }
        let store = TestStore(initialState: state) { DictationFeature() } withDependencies: {
            $0.dictation.fetchSharedDictionary = { _ in [DictionaryEntry(id: UUID(3), term: "Jiobit", source: "shared")] }
        }
        store.exhaustivity = .off(showSkippedAssertions: false)
        await store.send(.refreshSharedDictionaryTapped)
        await store.receive(\.sharedDictionaryFetched)
        XCTAssertEqual(store.state.dictionary.map(\.term), ["Mine", "Jiobit"])
    }
}

final class CleanupServiceTests: XCTestCase {
    func testEndpointURL() {
        XCTAssertEqual(CleanupService.endpointURL("https://gw.test")?.absoluteString, "https://gw.test/v1/messages")
        XCTAssertEqual(CleanupService.endpointURL("https://gw.test/")?.absoluteString, "https://gw.test/v1/messages")
        XCTAssertEqual(CleanupService.endpointURL("https://gw.test/v1")?.absoluteString, "https://gw.test/v1/messages")
        XCTAssertEqual(CleanupService.endpointURL("https://gw.test/anthropic/v1/messages")?.absoluteString, "https://gw.test/anthropic/v1/messages")
    }

    func testSonnetRequestTurnsThinkingOffAtLowEffort() {
        let request = CleanupRequest(rawText: "hi", appName: "Zed", windowTitle: nil, dictionary: [], symbols: [])
        let body = CleanupService.body(for: request, model: "claude-sonnet-5-5")
        XCTAssertEqual((body["thinking"] as? [String: String])?["type"], "between_tools")
        XCTAssertEqual((body["output_config"] as? [String: String])?["effort"], "low")
        XCTAssertNil(body["temperature"])

        let haiku = CleanupService.body(for: request, model: "claude-haiku-5-5")
        XCTAssertNil(haiku["thinking"], "between_tools is Sonnet 5.5 only")
    }

    func testUserMessageWrapsDictationAndListsHints() {
        let request = CleanupRequest(
            rawText: "check the joy con manager",
            appName: "Xcode",
            windowTitle: "AppDelegate.swift",
            dictionary: [DictionaryEntry(id: UUID(), term: "Life360", heardAs: "life three sixty")],
            symbols: ["JoyConManager", "NSWindowController"]
        )
        let message = CleanupService.userMessage(for: request)
        XCTAssertTrue(message.contains("App: Xcode (window: AppDelegate.swift)"))
        XCTAssertTrue(message.contains("- Life360 (often heard as: life three sixty)"))
        XCTAssertTrue(message.contains("JoyConManager, NSWindowController"))
        XCTAssertTrue(message.hasSuffix("<dictation>\ncheck the joy con manager\n</dictation>"))
    }

    func testParsesTextAndSkipsThinkingBlocks() throws {
        let json = #"{"content":[{"type":"thinking","thinking":""},{"type":"text","text":"  The JoyConManager.\n"}],"stop_reason":"end_turn"}"#
        XCTAssertEqual(try CleanupService.parse(Data(json.utf8)), "The JoyConManager.")
    }

    func testRefusalIsAnError() {
        let json = #"{"content":[],"stop_reason":"refusal","stop_details":{"type":"refusal","category":"cyber"}}"#
        XCTAssertThrowsError(try CleanupService.parse(Data(json.utf8))) { error in
            XCTAssertEqual(error as? CleanupError, .refused("cyber"))
        }
    }
}

final class ScreenContextTests: XCTestCase {
    func testExtractsIdentifiersMostFrequentFirst() {
        let text = """
        final class GameController { let manager = JoyConManager() }
        JoyConManager.shared.connectHandler = { controller in }
        // open AppDelegate.swift and read the HTTP response from Life360 servers
        the and with some plain words here
        """
        let symbols = ScreenContext.extractSymbols(from: text)
        XCTAssertEqual(symbols.first, "JoyConManager")
        XCTAssertTrue(symbols.contains("GameController"))
        XCTAssertTrue(symbols.contains("connectHandler"))
        XCTAssertTrue(symbols.contains("AppDelegate.swift"))
        XCTAssertTrue(symbols.contains("Life360"))
        XCTAssertTrue(symbols.contains("HTTP"))
        XCTAssertFalse(symbols.contains("plain"))
        XCTAssertFalse(symbols.contains("final"))
    }

    func testIgnoresCapitalizedPlainWords() {
        XCTAssertFalse(ScreenContext.looksLikeSymbol("Hello"))
        XCTAssertTrue(ScreenContext.looksLikeSymbol("snake_case_name"))
        XCTAssertTrue(ScreenContext.looksLikeSymbol("my-component.tsx"))
    }
}

final class SharedDictionaryTests: XCTestCase {
    func testParsesCSVWithHeaderAndQuotes() {
        let csv = #"""
        Term,Heard as
        Life360,"life three sixty, life 360"
        Jiobit,
        "Tile ""Mate""",tile mate
        """#
        let entries = SharedDictionary.parse(csv: csv)
        XCTAssertEqual(entries.map(\.term), ["Life360", "Jiobit", "Tile \"Mate\""])
        XCTAssertEqual(entries.first?.heardAs, "life three sixty, life 360")
        XCTAssertTrue(entries.allSatisfy { $0.source == "shared" })
    }
}

final class ObjCExceptionCatcherTests: XCTestCase {
    func testCatchesARaisedException() {
        let exception = JMCatchException {
            NSException(name: .invalidArgumentException, reason: "format mismatch", userInfo: nil).raise()
        }
        XCTAssertEqual(exception?.reason, "format mismatch")
    }

    func testReturnsNilWhenNothingIsRaised() {
        var ran = false
        XCTAssertNil(JMCatchException { ran = true })
        XCTAssertTrue(ran)
    }
}

final class GatewayAuthTests: XCTestCase {
    private func jwt(exp: TimeInterval) -> String {
        let payload = try! JSONSerialization.data(withJSONObject: ["sub": "me@example.com", "exp": exp])
        let encoded = payload.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        return "eyJhbGciOiJub25lIn0.\(encoded).sig"
    }

    func testReadsTheLastLineOfOutputAsTheToken() {
        XCTAssertEqual(GatewayAuth.token(fromOutput: "abc.def.ghi\n"), "abc.def.ghi")
        XCTAssertEqual(GatewayAuth.token(fromOutput: "\n  tok  \n\n"), "tok")
        XCTAssertNil(GatewayAuth.token(fromOutput: ""))
        XCTAssertNil(GatewayAuth.token(fromOutput: "Opening browser for login"))
    }

    func testReadsJWTExpiry() {
        let expiry = Date(timeIntervalSince1970: 2_000_000_000)
        XCTAssertEqual(GatewayAuth.expiry(ofJWT: jwt(exp: expiry.timeIntervalSince1970)), expiry)
        XCTAssertNil(GatewayAuth.expiry(ofJWT: "not-a-jwt"))
    }

    func testQuietRunsTurnOffTheBrowserAndAddConfiguredVariables() {
        var settings = DictationSettings()
        settings.tokenCommandQuietEnvironment = "HELPER_NO_NOTIFY=1  OTHER=a=b junk"
        let environment = GatewayAuth.quietEnvironment(settings)
        XCTAssertEqual(environment["BROWSER"], "/usr/bin/true")
        XCTAssertEqual(environment["HELPER_NO_NOTIFY"], "1")
        XCTAssertEqual(environment["OTHER"], "a=b")
        XCTAssertNil(environment["junk"])
    }

    func testFetchesQuietlyAndCachesUntilNearExpiry() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "gateway-auth-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let counter = directory.appending(path: "runs")
        let script = directory.appending(path: "helper.sh")
        let token = jwt(exp: Date().addingTimeInterval(3600).timeIntervalSince1970)
        // Counts its runs, and refuses to work unless the browser is off (a quiet run).
        try """
        #!/bin/sh
        echo x >> "\(counter.path)"
        [ "$BROWSER" = "/usr/bin/true" ] || exit 3
        echo "progress on stderr" >&2
        echo "\(token)"
        """.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)

        var settings = DictationSettings()
        settings.tokenCommand = script.path
        let auth = GatewayAuth()
        let first = try await auth.credential(settings: settings)
        let second = try await auth.credential(settings: settings)
        XCTAssertEqual(first, token)
        XCTAssertEqual(second, token)
        let runs = try String(contentsOf: counter, encoding: .utf8).split(separator: "\n").count
        XCTAssertEqual(runs, 1, "the cached token is reused")
    }

    func testQuietRunStopsAsSoonAsTheHelperWantsABrowser() async throws {
        var settings = DictationSettings()
        settings.tokenCommand = "echo 'Opening browser for login...' >&2; sleep 30; echo token"
        let started = Date()
        do {
            _ = try await GatewayAuth().credential(settings: settings)
            XCTFail("expected loginRequired")
        } catch {
            XCTAssertEqual(error as? CleanupError, .loginRequired)
        }
        XCTAssertLessThan(Date().timeIntervalSince(started), 5, "didn't wait out the helper")
    }

    func testFailingHelperMeansLoginRequired() async {
        var settings = DictationSettings()
        settings.tokenCommand = "exit 1"
        do {
            _ = try await GatewayAuth().credential(settings: settings)
            XCTFail("expected loginRequired")
        } catch {
            XCTAssertEqual(error as? CleanupError, .loginRequired)
        }
    }
}

final class DictationSettingsTests: XCTestCase {
    func testOldSettingsFilesKeepTheirValues() throws {
        let old = #"{"gatewayURL":"https://gateway.test","model":"claude-sonnet-5-5"}"#
        let settings = try JSONDecoder().decode(DictationSettings.self, from: Data(old.utf8))
        XCTAssertEqual(settings.gatewayURL, "https://gateway.test")
        XCTAssertEqual(settings.inputDeviceUID, "")
        XCTAssertTrue(settings.holdKeyEnabled)
    }
}
