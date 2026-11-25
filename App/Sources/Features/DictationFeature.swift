import ComposableArchitecture
import Foundation

extension SharedKey where Self == FileStorageKey<DictationSettings>.Default {
    static var dictationSettings: Self {
        Self[.fileStorage(Storage.directory.appending(path: "dictation-settings.json")), default: DictationSettings()]
    }
}

extension SharedKey where Self == FileStorageKey<IdentifiedArrayOf<DictionaryEntry>>.Default {
    static var dictionary: Self {
        Self[.fileStorage(Storage.directory.appending(path: "dictionary.json")), default: []]
    }
}

/// Voice dictation: record → live transcript → Claude cleanup → paste, saving every step.
@Reducer
struct DictationFeature {
    enum Phase: Equatable, Sendable {
        case idle
        /// Waiting for the microphone and speech model.
        case starting
        case listening
        /// Recording stopped; recognition is finishing the last words.
        case recognizing
        case cleaning
        /// Showing the result for a moment before the panel collapses.
        case done
        case failed(String)

        var isRecording: Bool { self == .starting || self == .listening }
        var isBusy: Bool { self != .idle && self != .done && !isFailed }
        var isFailed: Bool {
            if case .failed = self { return true }
            return false
        }
    }

    @ObservableState
    struct State: Equatable {
        @Shared(.dictationSettings) var settings
        @Shared(.dictionary) var dictionary
        var phase: Phase = .idle
        var mode: DictationMode?
        var liveText = ""
        /// 0…1, for the panel's meter while listening.
        var inputLevel: Float = 0
        /// The microphone the current recording uses.
        var inputDeviceName: String?
        var microphones: [AudioInputDevice] = []
        /// The dictation in progress (or just finished).
        var current: DictationRecord?
        var history: IdentifiedArrayOf<DictationRecord> = []
        var hasGatewayKey = false
        var recognizerStatus: ParakeetRecognizer.Status = .notLoaded
        /// The token helper needs the user to sign in; cleanup is skipped until they do.
        var needsLogin = false
        var isLoggingIn = false
        var hotkeysActive = false
        /// Symbols last read from each app, used as recognition hints for the next dictation
        /// there while the fresh read runs.
        var symbolCache: [String: [String]] = [:]
        var screenContext: ScreenContext?
        var gatewayStatus: String?
        var sharedDictionaryStatus: String?
        var historySearch = ""

        var filteredHistory: [DictationRecord] {
            let query = historySearch.trimmingCharacters(in: .whitespaces)
            guard !query.isEmpty else { return Array(history) }
            return history.filter { record in
                record.displayText.localizedCaseInsensitiveContains(query)
                    || record.rawText.localizedCaseInsensitiveContains(query)
                    || (record.appName ?? "").localizedCaseInsensitiveContains(query)
            }
        }
    }

    enum Action: Equatable, BindableAction {
        case binding(BindingAction<State>)
        case task
        case hotkeysStarted(Bool)
        case command(DictationCommand)
        case beginRecording(mode: DictationMode, source: String)
        case recordingStarted(device: String)
        case inputLevel(Float)
        case refreshMicrophones
        case recordingFailed(String)
        case liveText(String)
        case screenContextRead(ScreenContext)
        case stopTapped
        case cancelTapped
        case recognized(text: String, duration: TimeInterval, liveText: String, recognizer: String)
        case recognizerStatus(ParakeetRecognizer.Status)
        case cleaned(TaskResult<CleanupResult>)
        case inserted
        case collapse
        case pasteLastTapped
        case copyTapped(DictationRecord.ID)
        case revealAudioTapped(DictationRecord.ID)
        case gatewayKeySaved(String)
        case testGatewayTapped
        case logInTapped
        case loginNeeded
        case loggedIn(TaskResult<Bool>)
        case gatewayTested(String)
        case addDictionaryEntry(term: String, heardAs: String)
        case removeDictionaryEntry(DictionaryEntry.ID)
        case refreshSharedDictionaryTapped
        case sharedDictionaryFetched(TaskResult<[DictionaryEntry]>)
    }

    @Dependency(\.dictation) var dictation
    @Dependency(\.system) var system
    @Dependency(\.continuousClock) var clock
    @Dependency(\.uuid) var uuid
    @Dependency(\.date.now) var now

    enum CancelID { case session, collapse, hotkeys, recognizer }

    var body: some ReducerOf<Self> {
        BindingReducer()
        Reduce { state, action in
            switch action {
            case .binding(\.settings):
                let options = HotkeyMonitor.Options(holdKey: state.settings.holdKeyEnabled, toggleKeys: state.settings.toggleKeysEnabled)
                return .merge(
                    .run { _ in _ = await dictation.startHotkeys(options) },
                    state.recognizerStatus == .ready ? .none : prepareRecognizerIfNeeded(state.settings)
                )

            case .binding:
                return .none

            case .task:
                state.history = IdentifiedArray(uniqueElements: dictation.loadHistory())
                state.hasGatewayKey = dictation.hasGatewayKey()
                let options = HotkeyMonitor.Options(holdKey: state.settings.holdKeyEnabled, toggleKeys: state.settings.toggleKeysEnabled)
                let sharedURL = URL(string: state.settings.sharedDictionaryURL)
                Log.dictation.notice("Dictation ready: \(state.history.count) past dictations, gateway \(state.settings.isGatewayConfigured ? "set" : "not set"), auth \(state.settings.usesTokenCommand ? "token command" : (state.hasGatewayKey ? "saved key" : "missing"))")
                return .merge(
                    .run { send in
                        for await command in dictation.commands() {
                            await send(.command(command))
                        }
                    },
                    // The hotkey tap needs Accessibility, which may be granted later.
                    .run { send in
                        while true {
                            if await dictation.startHotkeys(options) {
                                await send(.hotkeysStarted(true))
                                return
                            }
                            try await clock.sleep(for: .seconds(3))
                        }
                    }
                    .cancellable(id: CancelID.hotkeys),
                    sharedURL == nil ? .none : .send(.refreshSharedDictionaryTapped),
                    prepareRecognizerIfNeeded(state.settings)
                )

            case let .hotkeysStarted(isOn):
                state.hotkeysActive = isOn
                return .none

            case let .command(command):
                return handle(command, state: &state)

            case let .beginRecording(mode, source):
                return beginRecording(mode: mode, source: source, state: &state)

            case let .recordingStarted(device):
                guard state.phase == .starting else { return .none }
                state.phase = .listening
                state.inputDeviceName = device
                return .none

            case let .inputLevel(level):
                guard state.phase.isRecording else { return .none }
                state.inputLevel = level
                return .none

            case .refreshMicrophones:
                state.microphones = dictation.inputDevices()
                return .none

            case let .recordingFailed(message):
                Log.dictation.error("Recording failed: \(message)")
                state.phase = .failed(message)
                if var record = state.current {
                    record.correctionError = "recording failed: \(message)"
                    save(record, in: &state)
                }
                return collapseLater(after: .seconds(4))

            case let .liveText(text):
                guard state.phase.isRecording || state.phase == .recognizing else { return .none }
                state.liveText = text
                return .none

            case let .screenContextRead(context):
                state.screenContext = context
                if let bundleID = context.bundleID {
                    state.symbolCache[bundleID] = context.symbols
                }
                let hintCount = context.symbols.count + state.dictionary.count
                state.current?.hintCount = hintCount
                return .none

            case .stopTapped:
                return stopRecording(&state)

            case .cancelTapped:
                guard state.phase.isBusy else {
                    state.phase = .idle
                    return .cancel(id: CancelID.collapse)
                }
                if var record = state.current {
                    record.correctionError = "cancelled"
                    record.rawText = state.liveText
                    save(record, in: &state)
                }
                Log.dictation.notice("Dictation cancelled")
                state.phase = .idle
                state.liveText = ""
                return .merge(.cancel(id: CancelID.session), .run { _ in await dictation.discard() })

            case let .recognized(text, duration, liveText, recognizer):
                return recognized(text: text, duration: duration, liveText: liveText, recognizer: recognizer, state: &state)

            case let .recognizerStatus(status):
                state.recognizerStatus = status
                return .none

            case let .cleaned(.success(result)):
                state.needsLogin = false
                guard var record = state.current else { return .none }
                record.correctedText = result.text
                record.correctionMilliseconds = result.milliseconds
                record.correctionModel = result.model
                Log.dictation.notice("Cleaned up in \(result.milliseconds) ms with \(result.model)")
                return deliver(result.text, record: &record, state: &state)

            case let .cleaned(.failure(error)):
                if (error as? CleanupError) == .loginRequired {
                    state.needsLogin = true
                }
                guard var record = state.current else { return .none }
                let message = error.localizedDescription
                record.correctionError = message
                Log.dictation.error("Cleanup failed, pasting what was heard: \(message)")
                return deliver(record.rawText, record: &record, state: &state)

            case .inserted:
                guard var record = state.current else { return .none }
                record.pasted = true
                save(record, in: &state)
                return .none

            case .collapse:
                if state.phase == .done || state.phase.isFailed {
                    state.phase = .idle
                    state.liveText = ""
                }
                return .none

            case .pasteLastTapped:
                let last = state.history.first { !$0.finalText.isEmpty }
                guard let text = last?.finalText else { return .none }
                Log.dictation.info("Pasting the last dictation again (\(text.count) characters)")
                return .run { _ in await dictation.insert(text) }

            case let .copyTapped(id):
                guard let text = state.history[id: id]?.displayText else { return .none }
                return .run { _ in dictation.copy(text) }

            case let .revealAudioTapped(id):
                guard let name = state.history[id: id]?.audioFileName else { return .none }
                return .run { _ in dictation.revealAudio(name) }

            case let .gatewayKeySaved(key):
                let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
                state.hasGatewayKey = !trimmed.isEmpty
                state.gatewayStatus = trimmed.isEmpty ? "Key removed" : "Key saved to the Keychain"
                return .run { _ in dictation.saveGatewayKey(trimmed) }

            case .testGatewayTapped:
                state.gatewayStatus = "Testing…"
                let settings = state.settings
                let request = CleanupRequest(
                    rawText: "um so the joy con manager uh calls the connect handler",
                    appName: "Test",
                    windowTitle: nil,
                    dictionary: [],
                    symbols: ["JoyConManager", "connectHandler"]
                )
                return .run { send in
                    do {
                        let result = try await dictation.clean(request, settings)
                        await send(.gatewayTested("OK in \(result.milliseconds) ms: “\(result.text)”"))
                    } catch CleanupError.loginRequired {
                        await send(.loginNeeded)
                        await send(.gatewayTested("Log in again to turn on Claude cleanup."))
                    } catch {
                        await send(.gatewayTested("Failed: \(error.localizedDescription)"))
                    }
                }

            case .loginNeeded:
                state.needsLogin = true
                return .none

            case .logInTapped:
                guard !state.isLoggingIn else { return .none }
                state.isLoggingIn = true
                state.gatewayStatus = "Waiting for you to sign in in the browser…"
                let settings = state.settings
                return .run { send in
                    await send(.loggedIn(TaskResult {
                        try await dictation.logIn(settings)
                        return true
                    }))
                }

            case .loggedIn(.success):
                state.isLoggingIn = false
                state.needsLogin = false
                state.gatewayStatus = "Signed in; cleanup is on"
                return .none

            case let .loggedIn(.failure(error)):
                state.isLoggingIn = false
                state.gatewayStatus = "Sign-in didn't finish: \(error.localizedDescription)"
                return .none

            case let .gatewayTested(message):
                state.gatewayStatus = message
                Log.dictation.notice("Gateway test: \(message)")
                return .none

            case let .addDictionaryEntry(term, heardAs):
                let trimmedTerm = term.trimmingCharacters(in: .whitespaces)
                guard !trimmedTerm.isEmpty else { return .none }
                let entry = DictionaryEntry(id: uuid(), term: trimmedTerm, heardAs: heardAs.trimmingCharacters(in: .whitespaces))
                state.$dictionary.withLock { _ = $0.append(entry) }
                return .none

            case let .removeDictionaryEntry(id):
                state.$dictionary.withLock { _ = $0.remove(id: id) }
                return .none

            case .refreshSharedDictionaryTapped:
                guard let url = URL(string: state.settings.sharedDictionaryURL), url.scheme != nil else {
                    state.sharedDictionaryStatus = "Set a published-CSV URL first"
                    return .none
                }
                state.sharedDictionaryStatus = "Downloading…"
                return .run { send in
                    await send(.sharedDictionaryFetched(TaskResult { try await dictation.fetchSharedDictionary(url) }))
                }

            case let .sharedDictionaryFetched(.success(entries)):
                state.$dictionary.withLock { dictionary in
                    dictionary.removeAll { $0.source == "shared" }
                    for entry in entries { dictionary.append(entry) }
                }
                state.sharedDictionaryStatus = "\(entries.count) shared terms"
                Log.dictation.notice("Shared dictionary: \(entries.count) terms")
                return .none

            case let .sharedDictionaryFetched(.failure(error)):
                state.sharedDictionaryStatus = "Couldn't download: \(error.localizedDescription)"
                return .none
            }
        }
    }

    // MARK: - Commands

    private func handle(_ command: DictationCommand, state: inout State) -> Effect<Action> {
        Log.dictation.info("Command: \(command)")
        switch command {
        case let .holdStarted(source):
            guard !state.phase.isBusy else { return .none }
            return .send(.beginRecording(mode: .hold, source: source))

        case .holdEnded:
            guard state.mode == .hold, state.phase.isRecording else { return .none }
            return stopRecording(&state)

        case .holdCancelled:
            guard state.mode == .hold, state.phase.isRecording else { return .none }
            return .send(.cancelTapped)

        case let .toggle(source):
            if state.phase.isRecording { return stopRecording(&state) }
            guard !state.phase.isBusy else { return .none }
            return .send(.beginRecording(mode: .toggle, source: source))

        case .pasteLast:
            return .send(.pasteLastTapped)
        }
    }

    // MARK: - Recording

    private func beginRecording(mode: DictationMode, source: String, state: inout State) -> Effect<Action> {
        let id = uuid()
        state.phase = .starting
        state.mode = mode
        state.liveText = ""
        state.inputLevel = 0
        state.inputDeviceName = nil
        state.screenContext = nil
        state.current = DictationRecord(
            id: id,
            startedAt: now,
            trigger: source,
            audioFileName: dictation.audioFileName(id)
        )
        let dictionaryTerms = state.dictionary.map(\.term)
        let settings = state.settings
        let cache = state.symbolCache
        let deviceUID = settings.inputDeviceUID
        Log.dictation.notice("Recording (\(mode.rawValue), from \(source))")

        return .merge(
            .cancel(id: CancelID.collapse),
            .run { send in
                let app = await system.frontmostApp()
                let cachedSymbols = app.flatMap { cache[$0.bundleID] } ?? []
                let hints = dictionaryTerms + cachedSymbols
                do {
                    let updates = try await dictation.begin(id, hints, deviceUID)
                    for await update in updates {
                        switch update {
                        case let .audioStarted(device): await send(.recordingStarted(device: device))
                        case let .level(level): await send(.inputLevel(level))
                        case let .text(text): await send(.liveText(text))
                        }
                    }
                } catch {
                    await send(.recordingFailed(error.localizedDescription))
                }
            }
            .cancellable(id: CancelID.session, cancelInFlight: true),
            .run { send in
                guard settings.screenContextEnabled else { return }
                await send(.screenContextRead(dictation.screenContext()))
            }
        )
    }

    private func prepareRecognizerIfNeeded(_ settings: DictationSettings) -> Effect<Action> {
        guard settings.recognizer == .parakeet else { return .none }
        return .run { send in
            await send(.recognizerStatus(.loading))
            await send(.recognizerStatus(dictation.prepareRecognizer()))
        }
        .cancellable(id: CancelID.recognizer, cancelInFlight: true)
    }

    private func stopRecording(_ state: inout State) -> Effect<Action> {
        guard state.phase.isRecording else { return .none }
        state.phase = .recognizing
        let usesParakeet = state.settings.recognizer == .parakeet
        let id = state.current?.id
        return .run { send in
            let (appleText, duration) = await dictation.finish()
            var text = appleText
            var engine = "apple"
            if usesParakeet, let id {
                let started = Date()
                do {
                    if let parakeet = try await dictation.transcribeRecording(id) {
                        let milliseconds = Int(Date().timeIntervalSince(started) * 1000)
                        Log.dictation.info("Parakeet: \(parakeet.count) characters in \(milliseconds) ms (Apple heard \(appleText.count))")
                        // An empty Parakeet result on audio Apple understood is more likely a miss
                        // than silence; keep Apple's.
                        if !parakeet.isEmpty || appleText.isEmpty {
                            text = parakeet
                            engine = "parakeet-v2"
                        }
                    } else {
                        Log.dictation.info("Parakeet isn't loaded yet; using Apple's text")
                    }
                } catch {
                    Log.dictation.error("Parakeet failed, using Apple's text: \(error.localizedDescription)")
                }
            }
            await send(.recognized(text: text, duration: duration, liveText: appleText, recognizer: engine))
        }
    }

    private func recognized(text: String, duration: TimeInterval, liveText: String, recognizer: String, state: inout State) -> Effect<Action> {
        guard var record = state.current else { return .none }
        let app = state.screenContext
        record.rawText = text
        record.recognizer = recognizer
        record.liveText = liveText == text ? nil : liveText
        record.duration = duration
        record.appName = app?.appName
        record.appBundleID = app?.bundleID
        record.inputDevice = state.inputDeviceName
        state.liveText = text
        // Saved now, before anything else can fail.
        save(record, in: &state)
        Log.dictation.notice("Heard \(text.count) characters in \(String(format: "%.1f", duration)) s")

        guard !text.isEmpty else {
            state.phase = .failed("Didn't catch anything")
            return collapseLater(after: .seconds(2))
        }
        let settings = state.settings
        // Until the user signs in again, paste right away instead of waiting on the helper.
        guard settings.runsCleanup, !state.needsLogin else {
            return deliver(text, record: &record, state: &state)
        }
        state.phase = .cleaning
        let request = CleanupRequest(
            rawText: text,
            appName: app?.appName,
            windowTitle: app?.windowTitle,
            dictionary: Array(state.dictionary),
            symbols: app?.symbols ?? []
        )
        return .run { send in
            await send(.cleaned(TaskResult { try await dictation.clean(request, settings) }))
        }
        .cancellable(id: CancelID.session)
    }

    /// Saves the final text, pastes it, and shows it for a moment.
    private func deliver(_ text: String, record: inout DictationRecord, state: inout State) -> Effect<Action> {
        record.finalText = text
        save(record, in: &state)
        state.liveText = text
        state.phase = .done
        let pastes = state.settings.pasteAutomatically
        let target = record.appBundleID
        return .merge(
            .run { send in
                guard pastes else { return }
                // Don't paste into this app's own window (e.g. the history list).
                guard target != AppFeature.ownBundleID else { return }
                await dictation.insert(text)
                await send(.inserted)
            },
            collapseLater(after: .seconds(3))
        )
    }

    private func collapseLater(after duration: Duration) -> Effect<Action> {
        .run { send in
            try await clock.sleep(for: duration)
            await send(.collapse)
        }
        .cancellable(id: CancelID.collapse, cancelInFlight: true)
    }

    private func save(_ record: DictationRecord, in state: inout State) {
        state.current = record
        if state.history[id: record.id] != nil {
            state.history[id: record.id] = record
        } else {
            state.history.insert(record, at: 0)
        }
        dictation.saveRecord(record)
    }
}
