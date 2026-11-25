import FluidAudio
import Foundation

/// The final-pass recognizer: NVIDIA Parakeet TDT 0.6B v2 (English), through FluidAudio on the
/// Neural Engine. It transcribes the saved recording once you stop. Apple's recognizer still
/// draws the live preview while you talk.
///
/// On your saved dictations it was the most accurate of Apple, Parakeet and Whisper, at about
/// 0.1 s a recording (see `Tools/SpeechBakeoff`). English-only on purpose: the multilingual
/// models drifted into other languages on noisy clips.
///
/// The model (about 0.5 GB) downloads on first launch into
/// `~/Library/Application Support/JoyMapperSilicon/Models`, shared by every copy of the app.
actor ParakeetRecognizer {
    static let shared = ParakeetRecognizer()

    enum Status: Equatable, Sendable {
        case notLoaded
        case loading
        case ready
        case failed(String)

        var displayText: String {
            switch self {
            case .notLoaded: "Not loaded"
            case .loading: "Downloading and loading the model (about 0.5 GB the first time)…"
            case .ready: "Ready"
            case let .failed(message): "Couldn't load: \(message)"
            }
        }
    }

    private(set) var status: Status = .notLoaded
    private var manager: AsrManager?
    private var loading: Task<Void, Error>?

    static var modelDirectory: URL {
        URL.applicationSupportDirectory.appending(path: "JoyMapperSilicon/Models/parakeet-tdt-v2", directoryHint: .isDirectory)
    }

    /// Downloads (first time) and loads the model. Safe to call repeatedly.
    func prepare() async throws {
        if manager != nil { return }
        if let loading { return try await loading.value }
        status = .loading
        let task = Task {
            let started = Date()
            Log.dictation.notice("Loading Parakeet v2 from \(Self.modelDirectory.path)")
            let models = try await AsrModels.downloadAndLoad(to: Self.modelDirectory, version: .v2)
            let asr = AsrManager(config: .default)
            try await asr.loadModels(models)
            self.finishLoading(asr, seconds: Date().timeIntervalSince(started))
        }
        loading = task
        do {
            try await task.value
        } catch {
            loading = nil
            status = .failed(error.localizedDescription)
            Log.dictation.error("Parakeet didn't load: \(error.localizedDescription)")
            throw error
        }
    }

    private func finishLoading(_ asr: AsrManager, seconds: TimeInterval) {
        manager = asr
        loading = nil
        status = .ready
        Log.dictation.notice("Parakeet ready in \(String(format: "%.1f", seconds)) s")
    }

    /// Transcribes a saved recording. Nil when the model isn't loaded yet: the caller uses
    /// Apple's text instead rather than waiting on a download.
    func transcribe(_ audio: URL) async throws -> String? {
        guard let manager else { return nil }
        let samples = try AudioConverter().resampleAudioFile(audio)
        guard !samples.isEmpty else { return "" }
        var state = TdtDecoderState.make()
        let result = try await manager.transcribe(samples, decoderState: &state)
        return result.text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
