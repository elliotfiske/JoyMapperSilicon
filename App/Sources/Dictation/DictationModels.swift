import Foundation

/// One dictation, from the moment recording started. Saved as soon as speech recognition
/// finishes, and again once the cleanup pass is done, so nothing is lost if a later step fails.
struct DictationRecord: Codable, Equatable, Identifiable, Sendable {
    var id: UUID
    var startedAt: Date
    var duration: TimeInterval = 0
    /// The app that was in front when recording started: where the text goes.
    var appName: String?
    var appBundleID: String?
    /// The microphone it was recorded from.
    var inputDevice: String?
    /// What started it: "hotkey", "joycon", "panel".
    var trigger: String
    /// What on-device recognition heard.
    var rawText: String = ""
    /// Claude's cleaned-up version, if the cleanup pass ran and succeeded.
    var correctedText: String?
    var correctionError: String?
    var correctionMilliseconds: Int?
    var correctionModel: String?
    /// What was (or would have been) pasted.
    var finalText: String = ""
    var pasted = false
    /// The recording, relative to the audio folder.
    var audioFileName: String?
    /// How many on-screen symbols and dictionary terms were offered as hints.
    var hintCount = 0

    var displayText: String {
        if !finalText.isEmpty { return finalText }
        return rawText
    }
}

/// How the user started recording, which decides how it stops.
enum DictationMode: String, Equatable, Sendable {
    /// Stops when the key or button is released.
    case hold
    /// Stops on the next press.
    case toggle
}

/// Anything that can start, stop or paste dictation: keyboard hotkeys, Joy-Con buttons, the panel.
enum DictationCommand: Equatable, Sendable {
    case holdStarted(source: String)
    case holdEnded
    /// Another key was pressed while the hold key was down: the user was typing a shortcut.
    case holdCancelled
    case toggle(source: String)
    case pasteLast
}

/// A Joy-Con button can trigger these instead of a key.
enum DictationAction: String, Codable, Sendable, CaseIterable, Hashable {
    case holdToTalk
    case toggleDictation
    case pasteLastDictation

    var displayName: String {
        switch self {
        case .holdToTalk: "Hold to dictate"
        case .toggleDictation: "Start/stop dictation"
        case .pasteLastDictation: "Paste last dictation"
        }
    }
}

/// A word or phrase speech recognition tends to get wrong, with how it should be written.
struct DictionaryEntry: Codable, Equatable, Identifiable, Sendable {
    var id: UUID
    /// The right spelling: "Life360", "CoreBluetooth", "Jiobit".
    var term: String
    /// What it's often heard as, comma-separated: "life three sixty, life 360".
    var heardAs: String = ""
    /// Where it came from: "local", or "shared" for the team sheet.
    var source: String = "local"
}

struct DictationSettings: Codable, Equatable, Sendable {
    /// The company LLM gateway base URL. Requests go to `<base>/v1/messages`. Kept out of the
    /// repo: it lives in this file in Application Support, and the key lives in the Keychain.
    var gatewayURL = ""
    var model = "claude-sonnet-5-5"
    /// Gateways vary in which `anthropic-version` they accept.
    var apiVersion = "2023-06-01"
    var cleanupEnabled = true
    /// Give up on cleanup after this long and paste what recognition heard.
    var cleanupTimeout: TimeInterval = 12
    var pasteAutomatically = true
    /// Hold Right Option to talk.
    var holdKeyEnabled = true
    /// ⌃⌥Space starts and stops; ⌃⌥V pastes the last dictation.
    var toggleKeysEnabled = true
    /// The microphone's Core Audio UID; empty means the system default input.
    var inputDeviceUID = ""
    /// Read symbol names from the frontmost window to help recognition and cleanup.
    var screenContextEnabled = true
    /// A published-CSV URL for the team dictionary (Google Sheets: File → Share → Publish to web).
    var sharedDictionaryURL = ""

    var isGatewayConfigured: Bool { !gatewayURL.trimmingCharacters(in: .whitespaces).isEmpty }

    /// Whether to run the cleanup pass at all. The test stub counts as configured.
    var runsCleanup: Bool {
        let isStubbed = ProcessInfo.processInfo.environment[CleanupService.stubEnvironmentKey] != nil
        return cleanupEnabled && (isGatewayConfigured || isStubbed)
    }
}
