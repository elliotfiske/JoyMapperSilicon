import AVFAudio
import FluidAudio
import Foundation
import Speech
import WhisperKit

// Runs every saved dictation recording through several speech recognizers and writes a
// side-by-side HTML report. Usage:
//
//     swift run -c release SpeechBakeoff [output.html] [--limit N]
//
// Reads ~/Library/Application Support/JoyMapperSilicon/Dictation (history.jsonl + Audio/) and
// the dictionary. Models download on first run into ~/Library/Caches/SpeechBakeoff.

setvbuf(stdout, nil, _IOLBF, 0)

// MARK: - Inputs

struct Recording {
    var id: String
    var startedAt: String
    var device: String
    var audio: URL
    var appleLive: String
    var cleaned: String
}

let support = FileManager.default.homeDirectoryForCurrentUser
    .appending(path: "Library/Application Support/JoyMapperSilicon")
let dictationDirectory = support.appending(path: "Dictation")
let cacheDirectory = FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/Caches/SpeechBakeoff")
try FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)

let arguments = Array(CommandLine.arguments.dropFirst())
let outputPath = arguments.first { !$0.hasPrefix("--") && Int($0) == nil } ?? "bakeoff.html"
let limit = arguments.firstIndex(of: "--limit").flatMap { Int(arguments[$0 + 1]) }

func loadRecordings() throws -> [Recording] {
    let text = try String(contentsOf: dictationDirectory.appending(path: "history.jsonl"), encoding: .utf8)
    var latest: [String: [String: Any]] = [:]
    for line in text.split(separator: "\n") {
        guard let row = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
              let id = row["id"] as? String else { continue }
        latest[id] = row
    }
    let rows = latest.values.sorted { ($0["startedAt"] as? String ?? "") > ($1["startedAt"] as? String ?? "") }
    return rows.compactMap { row in
        guard let name = row["audioFileName"] as? String else { return nil }
        let audio = dictationDirectory.appending(path: "Audio/\(name)")
        guard FileManager.default.fileExists(atPath: audio.path) else { return nil }
        // Skip recordings that are too short to say anything.
        guard let file = try? AVAudioFile(forReading: audio), Double(file.length) / file.fileFormat.sampleRate > 0.8 else { return nil }
        return Recording(
            id: row["id"] as? String ?? "",
            startedAt: row["startedAt"] as? String ?? "",
            device: row["inputDevice"] as? String ?? "?",
            audio: audio,
            appleLive: row["rawText"] as? String ?? "",
            cleaned: row["correctedText"] as? String ?? ""
        )
    }
}

/// Dictionary terms: the same hints the app gives every recognizer. (On-screen symbols weren't
/// saved per recording, so they're left out for every engine alike.)
func loadHints() -> [String] {
    guard let data = try? Data(contentsOf: support.appending(path: "dictionary.json")),
          let entries = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return [] }
    return entries.compactMap { $0["term"] as? String }
}

// MARK: - Engines

struct Output {
    var text: String
    var seconds: Double
}

protocol Engine {
    var name: String { get }
    var detail: String { get }
    func transcribe(_ recording: Recording, samples16k: [Float]) async throws -> String
}

struct AppleEngine: Engine {
    let hints: [String]
    var name: String { "Apple SpeechAnalyzer" }
    var detail: String { "built into macOS; dictionary terms as contextual strings" }

    func transcribe(_ recording: Recording, samples16k: [Float]) async throws -> String {
        let locale = await DictationTranscriber.supportedLocale(equivalentTo: Locale(identifier: "en-US")) ?? Locale(identifier: "en-US")
        let transcriber = DictationTranscriber(locale: locale, contentHints: [], transcriptionOptions: [.punctuation], reportingOptions: [], attributeOptions: [])
        if let install = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            try await install.downloadAndInstall()
        }
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        let context = AnalysisContext()
        context.contextualStrings = [.general: hints]
        try await analyzer.setContext(context)
        let collector = Task {
            var text = ""
            for try await result in transcriber.results where result.isFinal {
                text += String(result.text.characters)
            }
            return text
        }
        let file = try AVAudioFile(forReading: recording.audio)
        _ = try await analyzer.analyzeSequence(from: file)
        try await analyzer.finalizeAndFinishThroughEndOfInput()
        return try await collector.value.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

final class WhisperEngine: Engine {
    let whisper: WhisperKit
    let model: String
    let promptTokens: [Int]?
    var name: String { "Whisper \(model)" }
    var detail: String { "WhisperKit; dictionary terms as the decoder prompt" }

    init(model: String, hints: [String]) async throws {
        self.model = model
        let config = WhisperKitConfig(
            model: model,
            downloadBase: cacheDirectory.appending(path: "whisperkit"),
            verbose: false,
            logLevel: .error
        )
        let kit = try await WhisperKit(config)
        whisper = kit
        let prompt = hints.isEmpty ? nil : " " + hints.joined(separator: ", ")
        // Whisper reads the prompt as preceding text; special tokens must be left out.
        let tokenizer = kit.tokenizer
        let firstSpecial = tokenizer?.specialTokens.specialTokenBegin ?? Int.max
        promptTokens = prompt.flatMap { text in
            tokenizer?.encode(text: text).filter { $0 < firstSpecial }
        }
    }

    func transcribe(_ recording: Recording, samples16k: [Float]) async throws -> String {
        let options = DecodingOptions(language: "en", promptTokens: promptTokens)
        let results = await whisper.transcribe(audioArrays: [samples16k], decodeOptions: options)
        let texts = (results.first ?? nil)?.map(\.text) ?? []
        return texts.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

final class ParakeetEngine: Engine {
    let manager: AsrManager
    let label: String
    var name: String { "Parakeet \(label)" }
    var detail: String { "FluidAudio; no vocabulary hints (boosting needs a separate CTC model)" }

    init(version: AsrModelVersion, label: String) async throws {
        self.label = label
        let models = try await AsrModels.downloadAndLoad(to: cacheDirectory.appending(path: "parakeet-\(label)"), version: version)
        manager = AsrManager(config: .default)
        try await manager.loadModels(models)
    }

    func transcribe(_ recording: Recording, samples16k: [Float]) async throws -> String {
        var state = TdtDecoderState.make()
        let result = try await manager.transcribe(samples16k, decoderState: &state)
        return result.text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - Run

var recordings = try loadRecordings()
if let limit { recordings = Array(recordings.prefix(limit)) }
let hints = loadHints()
print("\(recordings.count) recordings, \(hints.count) dictionary terms")

var engines: [Engine] = [AppleEngine(hints: hints)]
for (label, make) in [
    ("Parakeet v2 (English)", { try await ParakeetEngine(version: .v2, label: "v2 English") as Engine }),
    ("Parakeet Ultra", { try await ParakeetEngine(version: .ultra, label: "Ultra") as Engine }),
    ("Whisper large-v3-turbo", { try await WhisperEngine(model: "large-v3-v20240930_turbo", hints: hints) as Engine }),
] as [(String, () async throws -> Engine)] {
    print("Loading \(label) (first run downloads it)…")
    let started = Date()
    do {
        engines.append(try await make())
        print(String(format: "  ready in %.0f s", Date().timeIntervalSince(started)))
    } catch {
        print("  couldn't load: \(error)")
    }
}

let converter = AudioConverter()
var table: [[Output?]] = []
for (index, recording) in recordings.enumerated() {
    let samples = (try? converter.resampleAudioFile(recording.audio)) ?? []
    let seconds = Double(samples.count) / 16000
    print(String(format: "[%d/%d] %@ (%.1f s, %@)", index + 1, recordings.count, recording.id.prefix(8) as CVarArg, seconds, recording.device))
    var row: [Output?] = []
    for engine in engines {
        let started = Date()
        do {
            let text = try await engine.transcribe(recording, samples16k: samples)
            row.append(Output(text: text, seconds: Date().timeIntervalSince(started)))
            print("  \(engine.name): \(text)")
        } catch {
            row.append(Output(text: "error: \(error)", seconds: 0))
            print("  \(engine.name): error \(error)")
        }
    }
    table.append(row)
}

// MARK: - Report

func escape(_ text: String) -> String {
    text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
        .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\n", with: "<br>")
}

var html = """
<!doctype html><meta charset="utf-8"><title>Speech recognizer comparison</title>
<style>
body { font: 14px -apple-system, sans-serif; margin: 24px; color: #222; }
table { border-collapse: collapse; width: 100%; }
th, td { border: 1px solid #ddd; padding: 8px; vertical-align: top; text-align: left; }
th { background: #f5f5f5; position: sticky; top: 0; }
td.meta { color: #777; font-size: 12px; white-space: nowrap; }
.time { color: #999; font-size: 11px; display: block; margin-top: 4px; }
.cleaned { color: #2a6; }
audio { width: 180px; }
tr.focus { background: #fffbe6; }
@media (prefers-color-scheme: dark) { body { background: #1e1e1e; color: #ddd; } th { background: #2a2a2a; } th, td { border-color: #444; } tr.focus { background: #3a3520; } }
</style>
<h1>Speech recognizer comparison</h1>
<p>\(recordings.count) of your saved dictations, newest first. Each engine got the same \(hints.count) dictionary terms as hints, except Parakeet, which got none. The highlighted row is the “scroll speed” recording. Times are per recording on this Mac, after the model was loaded.</p>
<table><tr><th>Recording</th>
"""
for engine in engines { html += "<th>\(escape(engine.name))<br><span class=time>\(escape(engine.detail))</span></th>" }
html += "<th>What the app pasted (Apple live + Claude)</th></tr>\n"
for (recording, row) in zip(recordings, table) {
    let isFocus = recording.appleLive.lowercased().contains("squirrel")
    html += "<tr class=\"\(isFocus ? "focus" : "")\"><td class=meta>\(escape(String(recording.startedAt.prefix(16)).replacingOccurrences(of: "T", with: " ")))<br>\(escape(recording.device))<br><audio controls preload=none src=\"file://\(recording.audio.path)\"></audio></td>"
    for output in row {
        guard let output else { html += "<td></td>"; continue }
        html += "<td>\(escape(output.text))<span class=time>\(String(format: "%.2f s", output.seconds))</span></td>"
    }
    html += "<td class=cleaned>\(escape(recording.cleaned.isEmpty ? recording.appleLive : recording.cleaned))</td></tr>\n"
}
html += "</table>\n"

var totals = "<h2>Speed</h2><ul>"
for (column, engine) in engines.enumerated() {
    let times = table.compactMap { $0[column]?.seconds }.filter { $0 > 0 }
    let average = times.isEmpty ? 0 : times.reduce(0, +) / Double(times.count)
    totals += "<li>\(escape(engine.name)): \(String(format: "%.2f", average)) s average per recording</li>"
}
html += totals + "</ul>"
try html.write(toFile: outputPath, atomically: true, encoding: .utf8)
print("Wrote \(outputPath)")
