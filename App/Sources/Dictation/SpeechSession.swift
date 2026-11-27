import AVFoundation
import Foundation
import Speech

/// What a recording reports while it runs.
enum SpeechUpdate: Equatable, Sendable {
    /// The microphone delivered its first audio. Bluetooth headsets take a moment to switch on
    /// their mic, so the panel only says "Listening" from here.
    case audioStarted(device: String)
    /// Input loudness, 0…1, about 10 times a second.
    case level(Float)
    /// Everything recognized so far, final words plus the guess at the current ones.
    case text(String)
    /// How long since the last voice, about once a second.
    case silence(TimeInterval)
}

/// One recording: microphone audio goes to a file on disk and to on-device speech recognition at
/// the same time. `updates` carries the live transcript, the input level, and when audio began.
///
/// With `JOYMAPPER_DICTATION_AUDIO_FILE=<path>` it reads that file instead of the microphone, so
/// tests (and you, with `say -o`) can dictate without speaking.
final class SpeechSession: @unchecked Sendable {
    enum SessionError: LocalizedError {
        case microphoneDenied
        case noAudioFormat
        case noInputDevice
        case couldNotSelectDevice(String, OSStatus)

        var errorDescription: String? {
            switch self {
            case .microphoneDenied: "Microphone access is off. Turn it on in System Settings → Privacy & Security → Microphone."
            case .noAudioFormat: "Speech recognition has no usable audio format."
            case .noInputDevice: "No microphone found."
            case let .couldNotSelectDevice(name, status): "Couldn't record from \(name) (error \(status))."
            }
        }
    }

    static let audioFileEnvironmentKey = "JOYMAPPER_DICTATION_AUDIO_FILE"

    let updates: AsyncStream<SpeechUpdate>
    private let updateContinuation: AsyncStream<SpeechUpdate>.Continuation
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
    // Input statistics, for the log line at the end and the level meter.
    private var deviceName = "audio file"
    private var firstAudioAt: Date?
    private var peak: Float = 0
    private var sumSquares: Double = 0
    private var sampleCount = 0
    private var lastLevelAt = Date.distantPast
    private var configurationObserver: NSObjectProtocol?
    // Silence: detected per tap buffer, used for the "still there?" nudge and to shorten long
    // pauses in the saved file. Touched only from the tap (one thread at a time) and `stop`.
    private var voiceDetector = VoiceActivityDetector()
    private var trimmer = SilenceTrimmer<AVAudioPCMBuffer>()
    private var lastVoiceAt = Date()
    private var lastSilenceReportAt = Date.distantPast
    private var analyzerFormat: AVAudioFormat?
    /// Set once `stop` or `cancel` begins, so a late reconfiguration doesn't restart the mic.
    private var isStopping = false
    /// Where the engine is started, restarted and stopped, one thing at a time.
    private let audioQueue = DispatchQueue(label: "JoyMapperSilicon.SpeechSession.audio")

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
        (updates, updateContinuation) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(8))
    }

    /// `hints` are words recognition should favor: dictionary terms and on-screen symbols.
    /// `deviceUID` picks the microphone; nil or a disconnected one means the system default.
    static func start(hints: [String], deviceUID: String?, recordingTo audioURL: URL) async throws -> SpeechSession {
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
        return try await startFromMicrophone(deviceUID: deviceUID, analyzer: analyzer, transcriber: transcriber, recordingTo: audioURL)
    }

    /// Recognition slows down and gets worse past a few hundred hints.
    static let maxHints = 150

    // MARK: - Microphone

    private static func startFromMicrophone(
        deviceUID: String?,
        analyzer: SpeechAnalyzer,
        transcriber: DictationTranscriber,
        recordingTo audioURL: URL
    ) async throws -> SpeechSession {
        guard await AVCaptureDevice.requestAccess(for: .audio) else { throw SessionError.microphoneDenied }
        guard let analyzerFormat = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else {
            throw SessionError.noAudioFormat
        }

        // Pick the device explicitly instead of trusting AVAudioEngine's idea of the default:
        // it can keep using a microphone the system has already switched away from.
        guard let device = AudioDevices.resolve(uid: deviceUID) else { throw SessionError.noInputDevice }
        let engine = AVAudioEngine()
        if let unit = engine.inputNode.audioUnit {
            let status = AudioDevices.setDevice(device.id, on: unit)
            guard status == noErr else { throw SessionError.couldNotSelectDevice(device.name, status) }
        }

        let (inputs, continuation) = AsyncStream.makeStream(of: AnalyzerInput.self)
        let session = SpeechSession(analyzer: analyzer, transcriber: transcriber, engine: engine, inputContinuation: continuation)
        session.deviceName = device.name
        session.analyzerFormat = analyzerFormat
        // The archive is kept at full quality (48 kHz float, mono), whatever rate the mic runs
        // at, so the file's format stays fixed when the mic's changes mid-recording. The
        // recognizer gets its own 16 kHz copy. The file's processing format must match the
        // buffers written to it exactly.
        session.recordingFile = try AVAudioFile(
            forWriting: audioURL,
            settings: Self.archiveFormat.settings,
            commonFormat: Self.archiveFormat.commonFormat,
            interleaved: Self.archiveFormat.isInterleaved
        )
        session.listenForResults()

        // Bluetooth headsets change sample rate when their mic opens (AirPods drop to 16 or
        // 24 kHz call mode), and devices come and go. Each time, AVAudioEngine stops and the tap's
        // format no longer matches, so the tap is rebuilt and the engine started again. Startup
        // and restarts all run on one serial queue: starting the engine from two threads at once
        // fails with -10868 (format not supported).
        session.configurationObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil
        ) { [weak session] _ in
            guard let session else { return }
            session.audioQueue.async {
                guard !session.isStopping else { return }
                if let format = session.startEngineRetrying() {
                    Log.dictation.notice("Microphone reconfigured (now \(Int(format.sampleRate)) Hz × \(format.channelCount)); recording continues")
                } else {
                    Log.dictation.error("Microphone changed mid-recording and didn't come back")
                }
            }
        }

        let started: AVAudioFormat? = await withCheckedContinuation { done in
            session.audioQueue.async { done.resume(returning: session.startEngineRetrying()) }
        }
        guard let tapFormat = started else {
            await session.cancel()
            throw SessionError.noInputDevice
        }
        try await analyzer.start(inputSequence: inputs)
        Log.dictation.info("Recording from \(device.name) (\(device.transport), device \(Int(device.nominalSampleRate)) Hz, tap \(Int(tapFormat.sampleRate)) Hz × \(tapFormat.channelCount)) into \(audioURL.lastPathComponent)")
        return session
    }

    /// Taps the input in the format the hardware delivers right now. AVAudioEngine raises an
    /// Objective-C exception (which Swift can't catch) if the tap format's sample rate doesn't
    /// match the hardware's, so the format is read fresh every time, never cached. Returns nil
    /// when the device has no usable format at the moment (mid-switch).
    ///
    /// Bluetooth devices can still be mid-switch when the format is read, so the rates can
    /// disagree anyway; the exception is caught and reported as nil.
    @discardableResult
    private func installTap() -> AVAudioFormat? {
        guard let engine, let analyzerFormat else { return nil }
        let input = engine.inputNode
        let hardwareFormat = input.inputFormat(forBus: 0)
        guard hardwareFormat.sampleRate > 0, hardwareFormat.channelCount > 0 else { return nil }
        let toAnalyzer = Self.makeConverter(from: hardwareFormat, to: analyzerFormat)
        let archiveFormat = Self.archiveFormat
        let needsArchiveConversion = hardwareFormat != archiveFormat
        let toArchive = needsArchiveConversion ? Self.makeConverter(from: hardwareFormat, to: archiveFormat) : nil
        let continuation = inputContinuation
        let tapBlock: AVAudioNodeTapBlock = { [weak self] buffer, _ in
            guard let self else { return }
            let isVoice = self.measure(buffer)
            let archived = needsArchiveConversion ? Self.convert(buffer, with: toArchive, to: archiveFormat) : buffer
            if let archived, archived.frameLength > 0 {
                self.archive(archived, isVoice: isVoice)
            }
            guard let converted = Self.convert(buffer, with: toAnalyzer, to: analyzerFormat),
                  converted.frameLength > 0
            else { return }
            continuation?.yield(AnalyzerInput(buffer: converted))
        }
        let exception = JMCatchException {
            input.installTap(onBus: 0, bufferSize: 4096, format: hardwareFormat, block: tapBlock)
        }
        if let exception {
            let reason = exception.reason ?? exception.name.rawValue
            Log.dictation.error("Couldn't tap the microphone at \(Int(hardwareFormat.sampleRate)) Hz × \(hardwareFormat.channelCount): \(reason)")
            return nil
        }
        return hardwareFormat
    }

    /// (Re)installs the tap and starts the engine, retrying for about two seconds: long enough
    /// for AirPods to finish switching to call mode. Runs on `audioQueue` only.
    private func startEngineRetrying() -> AVAudioFormat? {
        dispatchPrecondition(condition: .onQueue(audioQueue))
        guard let engine else { return nil }
        for attempt in 1...10 {
            guard !isStopping else { return nil }
            engine.stop()
            engine.inputNode.removeTap(onBus: 0)
            if let format = installTap() {
                engine.prepare()
                do {
                    try engine.start()
                    return format
                } catch {
                    Log.dictation.error("Couldn't start the microphone at \(Int(format.sampleRate)) Hz (attempt \(attempt)): \(error.localizedDescription)")
                }
            } else {
                Log.dictation.info("Microphone not ready (attempt \(attempt)); retrying")
            }
            Thread.sleep(forTimeInterval: 0.2)
        }
        return nil
    }

    /// Writes to the saved file, minus the middle of any silence longer than 30 s.
    private func archive(_ buffer: AVAudioPCMBuffer, isVoice: Bool) {
        let seconds = Double(buffer.frameLength) / buffer.format.sampleRate
        for chunk in trimmer.add(buffer, seconds: seconds, isVoice: isVoice) {
            try? recordingFile?.write(from: chunk)
        }
    }

    /// Tracks loudness for the meter and the end-of-recording log line, notices the first real
    /// audio (Bluetooth mics deliver zeros while they switch on), and reports silence. Returns
    /// whether the buffer holds voice.
    @discardableResult
    private func measure(_ buffer: AVAudioPCMBuffer) -> Bool {
        guard let samples = buffer.floatChannelData?[0] else { return false }
        let count = Int(buffer.frameLength)
        var bufferPeak: Float = 0
        var bufferSum: Double = 0
        for index in 0..<count {
            let value = samples[index]
            bufferPeak = max(bufferPeak, abs(value))
            bufferSum += Double(value * value)
        }
        let now = Date()
        lock.lock()
        peak = max(peak, bufferPeak)
        sumSquares += bufferSum
        sampleCount += count
        let isFirstAudio = firstAudioAt == nil && bufferPeak > 0.0005
        if isFirstAudio { firstAudioAt = now }
        let levelDue = now.timeIntervalSince(lastLevelAt) > 0.1
        if levelDue { lastLevelAt = now }
        let name = deviceName
        lock.unlock()

        if isFirstAudio {
            let wait = Int(now.timeIntervalSince(startedAt) * 1000)
            Log.dictation.info("First audio from \(name) after \(wait) ms")
            updateContinuation.yield(.audioStarted(device: name))
        }
        let rms = count > 0 ? Float((bufferSum / Double(count)).squareRoot()) : 0
        if levelDue {
            // Speech sits around 0.02–0.2 RMS; stretch it so the meter moves.
            updateContinuation.yield(.level(min(rms * 8, 1)))
        }

        // Before the first real audio there's nothing to judge.
        guard firstAudioAt != nil else { return false }
        let isVoice = voiceDetector.isVoice(rms: rms)
        if isVoice { lastVoiceAt = now }
        if now.timeIntervalSince(lastSilenceReportAt) >= 1 {
            lastSilenceReportAt = now
            updateContinuation.yield(.silence(now.timeIntervalSince(lastVoiceAt)))
        }
        return isVoice
    }

    /// Full quality, mono: what the saved recording is stored as.
    static let archiveFormat = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 1)!

    /// Best resampling quality: the default aliases when going down to 16 kHz, which sounds
    /// buzzy and can't help recognition.
    private static func makeConverter(from input: AVAudioFormat, to output: AVAudioFormat) -> AVAudioConverter? {
        let converter = AVAudioConverter(from: input, to: output)
        converter?.sampleRateConverterQuality = AVAudioQuality.max.rawValue
        converter?.sampleRateConverterAlgorithm = AVSampleRateConverterAlgorithm_Mastering
        return converter
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
        session.updateContinuation.yield(.audioStarted(device: "audio file"))
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
                    updateContinuation.yield(.text(live))
                }
            } catch {
                Log.dictation.error("Speech recognition failed: \(error.localizedDescription)")
            }
        }
    }

    /// Stops recording, waits for recognition to finish the last words, and returns the text.
    func stop() async -> (text: String, duration: TimeInterval) {
        isStopping = true
        removeObserver()
        if let engine {
            audioQueue.sync {
                engine.inputNode.removeTap(onBus: 0)
                engine.stop()
            }
        }
        inputContinuation?.finish()
        // The tap is gone, so nothing else touches the trimmer now.
        for chunk in trimmer.finish() {
            try? recordingFile?.write(from: chunk)
        }
        if trimmer.trimmedSeconds > 0 {
            Log.dictation.info("Left \(Int(trimmer.trimmedSeconds)) s of silence out of the saved recording")
        }
        recordingFile = nil
        await analysisTask?.value
        do {
            try await analyzer.finalizeAndFinishThroughEndOfInput()
        } catch {
            Log.dictation.error("Couldn't finish recognition: \(error.localizedDescription)")
        }
        await resultsTask?.value
        updateContinuation.finish()
        removeObserver()
        lock.lock()
        let text = (finalized + volatile).trimmingCharacters(in: .whitespacesAndNewlines)
        let count = resultCount
        let summary = statsSummary()
        lock.unlock()
        Log.dictation.info("Recognition finished after \(count) results. \(summary)")
        return (text, Date().timeIntervalSince(startedAt))
    }

    /// "MacBook Pro Microphone: first audio 310 ms, peak 0.39, RMS 0.051". Call with `lock` held.
    private func statsSummary() -> String {
        guard engine != nil else { return "Source: audio file" }
        let rms = sampleCount > 0 ? (sumSquares / Double(sampleCount)).squareRoot() : 0
        let firstAudio = firstAudioAt.map { "\(Int($0.timeIntervalSince(startedAt) * 1000)) ms" } ?? "never"
        var summary = String(format: "\(deviceName): first audio \(firstAudio), peak %.3f, RMS %.4f", peak, rms)
        if peak < 0.01 { summary += " (nearly silent: wrong or muted microphone?)" }
        return summary
    }

    private func removeObserver() {
        if let configurationObserver {
            NotificationCenter.default.removeObserver(configurationObserver)
            self.configurationObserver = nil
        }
    }

    /// Throws the recording away without waiting for recognition.
    func cancel() async {
        isStopping = true
        removeObserver()
        if let engine {
            audioQueue.sync {
                engine.inputNode.removeTap(onBus: 0)
                engine.stop()
            }
        }
        inputContinuation?.finish()
        analysisTask?.cancel()
        await analyzer.cancelAndFinishNow()
        resultsTask?.cancel()
        updateContinuation.finish()
        removeObserver()
    }
}
