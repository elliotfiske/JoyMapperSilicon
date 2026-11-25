import AVFoundation
import Foundation
import Speech

/// One recording: microphone audio goes to a file on disk and to on-device speech recognition at
/// the same time. `liveText` updates as words are recognized, before they're final.
///
/// With `JOYMAPPER_DICTATION_AUDIO_FILE=<path>` it reads that file instead of the microphone, so
/// tests (and you, with `say -o`) can dictate without speaking.
final class SpeechSession: @unchecked Sendable {
    enum SessionError: LocalizedError {
        case microphoneDenied
        case noAudioFormat
        case noInputDevice

        var errorDescription: String? {
            switch self {
            case .microphoneDenied: "Microphone access is off. Turn it on in System Settings → Privacy & Security → Microphone."
            case .noAudioFormat: "Speech recognition has no usable audio format."
            case .noInputDevice: "No microphone found."
            }
        }
    }

    static let audioFileEnvironmentKey = "JOYMAPPER_DICTATION_AUDIO_FILE"

    let liveText: AsyncStream<String>
    private let liveContinuation: AsyncStream<String>.Continuation
    private let analyzer: SpeechAnalyzer
    private let transcriber: DictationTranscriber
    private let inputContinuation: AsyncStream<AnalyzerInput>.Continuation?
    private let engine: AVAudioEngine?
    private var recordingFile: AVAudioFile?
    private var resultsTask: Task<Void, Never>?
    private var analysisTask: Task<Void, Never>?
    private let startedAt = Date()
    private let lock = NSLock()
    private var finalized = ""
    private var volatile = ""
    private var resultCount = 0

    private init(
        analyzer: SpeechAnalyzer,
        transcriber: DictationTranscriber,
        engine: AVAudioEngine?,
        inputContinuation: AsyncStream<AnalyzerInput>.Continuation?
    ) {
        self.analyzer = analyzer
        self.transcriber = transcriber
        self.engine = engine
        self.inputContinuation = inputContinuation
        (liveText, liveContinuation) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(1))
    }

    /// `hints` are words recognition should favor: dictionary terms and on-screen symbols.
    static func start(hints: [String], recordingTo audioURL: URL) async throws -> SpeechSession {
        let locale = await DictationTranscriber.supportedLocale(equivalentTo: Locale.current)
            ?? Locale(identifier: "en-US")
        let transcriber = DictationTranscriber(
            locale: locale,
            contentHints: [],
            transcriptionOptions: [.punctuation],
            reportingOptions: [.volatileResults],
            attributeOptions: []
        )
        if let install = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            Log.dictation.info("Making sure the speech model for \(locale.identifier) is installed")
            try await install.downloadAndInstall()
        }

        let analyzer = SpeechAnalyzer(modules: [transcriber])
        let context = AnalysisContext()
        context.contextualStrings = [.general: Array(hints.prefix(Self.maxHints))]
        try await analyzer.setContext(context)

        if let path = ProcessInfo.processInfo.environment[audioFileEnvironmentKey] {
            return try await startFromFile(URL(filePath: path), analyzer: analyzer, transcriber: transcriber, recordingTo: audioURL)
        }
        return try await startFromMicrophone(analyzer: analyzer, transcriber: transcriber, recordingTo: audioURL)
    }

    /// Recognition slows down and gets worse past a few hundred hints.
    static let maxHints = 150

    // MARK: - Microphone

    private static func startFromMicrophone(
        analyzer: SpeechAnalyzer,
        transcriber: DictationTranscriber,
        recordingTo audioURL: URL
    ) async throws -> SpeechSession {
        guard await AVCaptureDevice.requestAccess(for: .audio) else { throw SessionError.microphoneDenied }
        guard let analyzerFormat = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else {
            throw SessionError.noAudioFormat
        }

        let engine = AVAudioEngine()
        let input = engine.inputNode
        let micFormat = input.outputFormat(forBus: 0)
        guard micFormat.sampleRate > 0 else { throw SessionError.noInputDevice }

        let (inputs, continuation) = AsyncStream.makeStream(of: AnalyzerInput.self)
        let session = SpeechSession(analyzer: analyzer, transcriber: transcriber, engine: engine, inputContinuation: continuation)
        session.recordingFile = try AVAudioFile(forWriting: audioURL, settings: micFormat.settings)
        session.listenForResults()

        let converter = AVAudioConverter(from: micFormat, to: analyzerFormat)
        input.installTap(onBus: 0, bufferSize: 4096, format: micFormat) { [weak session] buffer, _ in
            guard let session else { return }
            try? session.recordingFile?.write(from: buffer)
            guard let converted = Self.convert(buffer, with: converter, to: analyzerFormat) else { return }
            continuation.yield(AnalyzerInput(buffer: converted))
        }
        engine.prepare()
        try engine.start()
        try await analyzer.start(inputSequence: inputs)
        Log.dictation.info("Recording from \(Int(micFormat.sampleRate)) Hz microphone into \(audioURL.lastPathComponent)")
        return session
    }

    private static func convert(_ buffer: AVAudioPCMBuffer, with converter: AVAudioConverter?, to format: AVAudioFormat) -> AVAudioPCMBuffer? {
        guard let converter else { return buffer }
        let ratio = format.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 16
        guard let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { return nil }
        var consumed = false
        var error: NSError?
        converter.convert(to: output, error: &error) { _, status in
            if consumed {
                status.pointee = .noDataNow
                return nil
            }
            consumed = true
            status.pointee = .haveData
            return buffer
        }
        return error == nil ? output : nil
    }

    // MARK: - File (tests)

    private static func startFromFile(
        _ fileURL: URL,
        analyzer: SpeechAnalyzer,
        transcriber: DictationTranscriber,
        recordingTo audioURL: URL
    ) async throws -> SpeechSession {
        Log.dictation.notice("Dictating from \(fileURL.path) instead of the microphone")
        try? FileManager.default.copyItem(at: fileURL, to: audioURL)
        let session = SpeechSession(analyzer: analyzer, transcriber: transcriber, engine: nil, inputContinuation: nil)
        session.listenForResults()
        let file = try AVAudioFile(forReading: fileURL)
        session.analysisTask = Task {
            do {
                _ = try await analyzer.analyzeSequence(from: file)
                Log.dictation.info("Finished reading \(fileURL.lastPathComponent)")
            } catch {
                Log.dictation.error("Couldn't analyze \(fileURL.lastPathComponent): \(error.localizedDescription)")
            }
        }
        return session
    }

    // MARK: - Results

    private func listenForResults() {
        resultsTask = Task { [weak self] in
            guard let self else { return }
            do {
                for try await result in transcriber.results {
                    let text = String(result.text.characters)
                    lock.lock()
                    if result.isFinal {
                        finalized += text
                        volatile = ""
                    } else {
                        volatile = text
                    }
                    let live = finalized + volatile
                    resultCount += 1
                    let count = resultCount
                    lock.unlock()
                    if count == 1 { Log.dictation.info("First words recognized") }
                    liveContinuation.yield(live)
                }
            } catch {
                Log.dictation.error("Speech recognition failed: \(error.localizedDescription)")
            }
        }
    }

    /// Stops recording, waits for recognition to finish the last words, and returns the text.
    func stop() async -> (text: String, duration: TimeInterval) {
        if let engine {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
        }
        inputContinuation?.finish()
        recordingFile = nil
        await analysisTask?.value
        do {
            try await analyzer.finalizeAndFinishThroughEndOfInput()
        } catch {
            Log.dictation.error("Couldn't finish recognition: \(error.localizedDescription)")
        }
        await resultsTask?.value
        liveContinuation.finish()
        lock.lock()
        let text = (finalized + volatile).trimmingCharacters(in: .whitespacesAndNewlines)
        let count = resultCount
        lock.unlock()
        Log.dictation.info("Recognition finished after \(count) results")
        return (text, Date().timeIntervalSince(startedAt))
    }

    /// Throws the recording away without waiting for recognition.
    func cancel() async {
        if let engine {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
        }
        inputContinuation?.finish()
        analysisTask?.cancel()
        await analyzer.cancelAndFinishNow()
        resultsTask?.cancel()
        liveContinuation.finish()
    }
}
