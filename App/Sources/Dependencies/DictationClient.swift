import AppKit
import ComposableArchitecture
import Foundation

/// Dictation, as the store sees it. The live value keeps the one active recording inside, so
/// nothing non-Equatable ends up in state.
struct DictationClient: Sendable {
    /// Hotkeys, Joy-Con buttons and simulated commands, merged.
    var commands: @Sendable () -> AsyncStream<DictationCommand>
    /// Starts listening for hotkeys. False until Accessibility is granted.
    var startHotkeys: @Sendable (HotkeyMonitor.Options) async -> Bool
    /// Starts recording from `deviceUID` (empty: the system default). The stream carries the
    /// live transcript, the input level, and when audio actually began.
    var begin: @Sendable (_ id: UUID, _ hints: [String], _ deviceUID: String) async throws -> AsyncStream<SpeechUpdate>
    /// Connected microphones, for the picker.
    var inputDevices: @Sendable () -> [AudioInputDevice]
    /// Stops recording and returns what was recognized.
    var finish: @Sendable () async -> (text: String, duration: TimeInterval)
    var discard: @Sendable () async -> Void
    /// Reads names off the frontmost window. Slow-ish (up to a few hundred ms).
    var screenContext: @Sendable () async -> ScreenContext
    var clean: @Sendable (CleanupRequest, DictationSettings) async throws -> CleanupResult
    /// Pastes into the frontmost app.
    var insert: @Sendable (String) async -> Void
    var copy: @Sendable (String) -> Void
    var loadHistory: @Sendable () -> [DictationRecord]
    var saveRecord: @Sendable (DictationRecord) -> Void
    var audioFileName: @Sendable (UUID) -> String
    var revealAudio: @Sendable (String) -> Void
    var hasGatewayKey: @Sendable () -> Bool
    /// Runs the token helper interactively (it may open a browser to sign in).
    var logIn: @Sendable (DictationSettings) async throws -> Void
    var saveGatewayKey: @Sendable (String) -> Void
    /// Downloads the team dictionary: a CSV with the term in column A and "heard as" in column B.
    var fetchSharedDictionary: @Sendable (URL) async throws -> [DictionaryEntry]
}

/// The live dictation pieces: history on disk, the hotkey tap, the active recording, and where
/// Joy-Con actions come in.
final class DictationRuntime: @unchecked Sendable {
    static let shared = DictationRuntime()

    let history = DictationHistory(directory: Storage.directory.appending(path: "Dictation", directoryHint: .isDirectory))
    let hotkeys = HotkeyMonitor()
    private let lock = NSLock()
    private var session: SpeechSession?
    private let (commandStream, commandContinuation) = AsyncStream.makeStream(of: DictationCommand.self, bufferingPolicy: .bufferingNewest(20))
    private var forwardingHotkeys = false

    /// Turns a Joy-Con dictation action into a command.
    func handle(_ action: DictationAction, down: Bool) {
        switch (action, down) {
        case (.holdToTalk, true): commandContinuation.yield(.holdStarted(source: "joycon"))
        case (.holdToTalk, false): commandContinuation.yield(.holdEnded)
        case (.toggleDictation, true): commandContinuation.yield(.toggle(source: "joycon"))
        case (.pasteLastDictation, true): commandContinuation.yield(.pasteLast)
        default: break
        }
    }

    var commands: AsyncStream<DictationCommand> {
        lock.lock()
        defer { lock.unlock() }
        if !forwardingHotkeys {
            forwardingHotkeys = true
            let hotkeyCommands = hotkeys.commands
            let continuation = commandContinuation
            Task {
                for await command in hotkeyCommands { continuation.yield(command) }
            }
        }
        return commandStream
    }

    init() {
        // Logged so a "switched mics and it stopped hearing me" report shows what changed.
        AudioDevices.observeChanges {
            let name = AudioDevices.defaultInput().map { "\($0.name) (\($0.transport))" } ?? "none"
            Log.dictation.notice("Audio devices changed; default input is now \(name)")
        }
    }

    func begin(id: UUID, hints: [String], deviceUID: String) async throws -> AsyncStream<SpeechUpdate> {
        await discard()
        let newSession = try await SpeechSession.start(
            hints: hints,
            deviceUID: deviceUID.isEmpty ? nil : deviceUID,
            recordingTo: history.audioURL(for: id)
        )
        lock.lock()
        session = newSession
        lock.unlock()
        return newSession.updates
    }

    func finish() async -> (text: String, duration: TimeInterval) {
        lock.lock()
        let current = session
        session = nil
        lock.unlock()
        guard let current else { return ("", 0) }
        return await current.stop()
    }

    func discard() async {
        lock.lock()
        let current = session
        session = nil
        lock.unlock()
        await current?.cancel()
    }
}

extension DictationClient: DependencyKey {
    static var liveValue: DictationClient {
        let runtime = DictationRuntime.shared
        return DictationClient(
            commands: { runtime.commands },
            startHotkeys: { options in
                await MainActor.run { runtime.hotkeys.start(options: options) }
            },
            begin: { id, hints, deviceUID in try await runtime.begin(id: id, hints: hints, deviceUID: deviceUID) },
            inputDevices: { AudioDevices.inputs() },
            finish: { await runtime.finish() },
            discard: { await runtime.discard() },
            screenContext: {
                let app = await MainActor.run { NSWorkspace.shared.frontmostApplication }
                return await Task.detached { ScreenContext.capture(from: app) }.value
            },
            clean: { request, settings in
                try await CleanupService.clean(request, settings: settings, auth: .shared)
            },
            insert: { text in await LiveRuntime.shared.insertText(text) },
            copy: { text in
                Task { @MainActor in
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                }
            },
            loadHistory: { runtime.history.load() },
            saveRecord: { runtime.history.save($0) },
            audioFileName: { runtime.history.audioURL(for: $0).lastPathComponent },
            revealAudio: { name in
                let url = runtime.history.audioDirectory.appending(path: name)
                Task { @MainActor in NSWorkspace.shared.activateFileViewerSelecting([url]) }
            },
            hasGatewayKey: { GatewayKeychain.read()?.isEmpty == false },
            logIn: { settings in try await GatewayAuth.shared.fetch(settings: settings, interactive: true) },
            saveGatewayKey: { GatewayKeychain.write($0) },
            fetchSharedDictionary: { url in
                let (data, _) = try await URLSession.shared.data(from: url)
                return SharedDictionary.parse(csv: String(decoding: data, as: UTF8.self))
            }
        )
    }

    static let testValue = DictationClient(
        commands: unimplemented("DictationClient.commands", placeholder: AsyncStream { $0.finish() }),
        startHotkeys: unimplemented("DictationClient.startHotkeys", placeholder: false),
        begin: unimplemented("DictationClient.begin", placeholder: AsyncStream { $0.finish() }),
        inputDevices: { [] },
        finish: unimplemented("DictationClient.finish", placeholder: ("", 0)),
        discard: unimplemented("DictationClient.discard"),
        screenContext: unimplemented("DictationClient.screenContext", placeholder: .empty),
        clean: unimplemented("DictationClient.clean", placeholder: CleanupResult(text: "", model: "", milliseconds: 0)),
        insert: unimplemented("DictationClient.insert"),
        copy: unimplemented("DictationClient.copy"),
        loadHistory: unimplemented("DictationClient.loadHistory", placeholder: []),
        saveRecord: unimplemented("DictationClient.saveRecord"),
        audioFileName: { "\($0.uuidString).caf" },
        revealAudio: unimplemented("DictationClient.revealAudio"),
        hasGatewayKey: unimplemented("DictationClient.hasGatewayKey", placeholder: false),
        logIn: unimplemented("DictationClient.logIn"),
        saveGatewayKey: unimplemented("DictationClient.saveGatewayKey"),
        fetchSharedDictionary: unimplemented("DictationClient.fetchSharedDictionary", placeholder: [])
    )
}

extension DependencyValues {
    var dictation: DictationClient {
        get { self[DictationClient.self] }
        set { self[DictationClient.self] = newValue }
    }
}

enum SharedDictionary {
    /// Column A: the term. Column B (optional): what it's heard as. A first row starting with
    /// "term" is a header and skipped. Handles quoted cells with commas.
    static func parse(csv: String) -> [DictionaryEntry] {
        var entries: [DictionaryEntry] = []
        for (index, line) in csv.split(whereSeparator: \.isNewline).enumerated() {
            let cells = cells(in: String(line))
            guard let term = cells.first?.trimmingCharacters(in: .whitespaces), !term.isEmpty else { continue }
            if index == 0, term.lowercased() == "term" { continue }
            let heardAs = cells.count > 1 ? cells[1].trimmingCharacters(in: .whitespaces) : ""
            entries.append(DictionaryEntry(id: UUID(), term: term, heardAs: heardAs, source: "shared"))
        }
        return entries
    }

    private static func cells(in line: String) -> [String] {
        var cells: [String] = []
        var current = ""
        var inQuotes = false
        var characters = Array(line)
        var index = 0
        while index < characters.count {
            let character = characters[index]
            if character == "\"" {
                let isEscapedQuote = inQuotes && index + 1 < characters.count && characters[index + 1] == "\""
                if isEscapedQuote {
                    current.append("\"")
                    index += 1
                } else {
                    inQuotes.toggle()
                }
            } else if character == ",", !inQuotes {
                cells.append(current)
                current = ""
            } else {
                current.append(character)
            }
            index += 1
        }
        cells.append(current)
        characters.removeAll()
        return cells
    }
}
