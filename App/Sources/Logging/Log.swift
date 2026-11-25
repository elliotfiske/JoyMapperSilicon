import Foundation
import os

/// Logging for the app. Every line goes to the unified log (subsystem
/// `com.elliotfiske.JoyMapperSilicon`) and to a plain file you can tail:
///
///     tail -f ~/Library/Logs/JoyMapperSilicon/joymapper.log
///     log stream --predicate 'subsystem == "com.elliotfiske.JoyMapperSilicon"' --level debug
///
/// Messages are public: they carry controller IDs and key names, nothing private.
enum Log {
    static let subsystem = "com.elliotfiske.JoyMapperSilicon"

    /// Bluetooth LE: scanning, connecting, GATT discovery, raw reports.
    static let ble = Channel("ble")
    /// Decoded controller input: button presses, stick moves.
    static let input = Channel("input")
    /// What the mapping engine posts: key and mouse events.
    static let mapping = Channel("mapping")
    /// App lifecycle, permissions, frontmost app, settings.
    static let app = Channel("app")
    /// Recording, speech recognition, cleanup, pasting, history.
    static let dictation = Channel("dictation")

    struct Channel: Sendable {
        let category: String
        let logger: Logger

        init(_ category: String) {
            self.category = category
            self.logger = Logger(subsystem: Log.subsystem, category: category)
        }

        func debug(_ message: @autoclosure () -> String) { write(.debug, message()) }
        func info(_ message: @autoclosure () -> String) { write(.info, message()) }
        func notice(_ message: @autoclosure () -> String) { write(.default, message()) }
        func error(_ message: @autoclosure () -> String) { write(.error, message()) }

        private func write(_ level: OSLogType, _ message: String) {
            logger.log(level: level, "\(message, privacy: .public)")
            LogFile.shared.append(level: level, category: category, message: message)
        }
    }
}

/// The plain-text copy of the log. It rotates at 5 MB, keeping one older file.
final class LogFile: @unchecked Sendable {
    static let shared = LogFile()

    static var directory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appending(path: "Library/Logs/JoyMapperSilicon", directoryHint: .isDirectory)
    }

    static var url: URL { directory.appending(path: "joymapper.log") }

    private let queue = DispatchQueue(label: "JoyMapperSilicon.LogFile")
    private var handle: FileHandle?
    private var bytesWritten = 0
    private let maxBytes = 5 * 1024 * 1024
    private let timestamp: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return formatter
    }()

    /// Unit tests don't write the file.
    private let isEnabled = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil

    func append(level: OSLogType, category: String, message: String) {
        guard isEnabled else { return }
        let now = Date()
        queue.async {
            let line = "\(self.timestamp.string(from: now)) [\(category)] \(Self.label(level)) \(message)\n"
            self.write(Data(line.utf8))
        }
    }

    private func write(_ data: Data) {
        if handle == nil { open() }
        if bytesWritten + data.count > maxBytes { rotate() }
        handle?.write(data)
        bytesWritten += data.count
    }

    private func open() {
        let manager = FileManager.default
        try? manager.createDirectory(at: Self.directory, withIntermediateDirectories: true)
        if !manager.fileExists(atPath: Self.url.path) {
            manager.createFile(atPath: Self.url.path, contents: nil)
        }
        handle = try? FileHandle(forWritingTo: Self.url)
        let end = (try? handle?.seekToEnd()) ?? 0
        bytesWritten = Int(end)
    }

    private func rotate() {
        try? handle?.close()
        handle = nil
        let previous = Self.directory.appending(path: "joymapper.1.log")
        try? FileManager.default.removeItem(at: previous)
        try? FileManager.default.moveItem(at: Self.url, to: previous)
        open()
    }

    private static func label(_ level: OSLogType) -> String {
        switch level {
        case .debug: "DEBUG"
        case .info: "INFO "
        case .error, .fault: "ERROR"
        default: "NOTE "
        }
    }
}

extension Data {
    /// "3e 0e 00 …", for logging raw reports.
    var hexString: String {
        map { String(format: "%02x", $0) }.joined(separator: " ")
    }
}
