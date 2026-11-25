import Foundation

/// Every dictation ever made, in an append-only JSON-lines file, plus one audio file per
/// recording. Nothing here deletes: a record is saved again (a new line with the same ID) when it
/// changes, and loading keeps the newest line per ID.
///
///     ~/Library/Application Support/JoyMapperSilicon/Dictation/history.jsonl
///     ~/Library/Application Support/JoyMapperSilicon/Dictation/Audio/<id>.caf
final class DictationHistory: @unchecked Sendable {
    let directory: URL
    var audioDirectory: URL { directory.appending(path: "Audio", directoryHint: .isDirectory) }
    private var fileURL: URL { directory.appending(path: "history.jsonl") }
    private let queue = DispatchQueue(label: "JoyMapperSilicon.DictationHistory")
    private let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()
    private let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    init(directory: URL) {
        self.directory = directory
        try? FileManager.default.createDirectory(at: audioDirectory, withIntermediateDirectories: true)
    }

    func audioURL(for id: UUID) -> URL {
        audioDirectory.appending(path: "\(id.uuidString).caf")
    }

    func save(_ record: DictationRecord) {
        queue.sync {
            guard let data = try? encoder.encode(record) else { return }
            let line = data + Data("\n".utf8)
            if let handle = try? FileHandle(forWritingTo: fileURL) {
                _ = try? handle.seekToEnd()
                handle.write(line)
                try? handle.close()
            } else {
                try? line.write(to: fileURL)
            }
        }
    }

    /// Newest first.
    func load() -> [DictationRecord] {
        queue.sync {
            guard let text = try? String(contentsOf: fileURL, encoding: .utf8) else { return [] }
            var latest: [UUID: DictationRecord] = [:]
            for line in text.split(separator: "\n") {
                guard let record = try? decoder.decode(DictationRecord.self, from: Data(line.utf8)) else { continue }
                latest[record.id] = record
            }
            return latest.values.sorted { $0.startedAt > $1.startedAt }
        }
    }
}
