//
//  ConnectionLog.swift
//  JoyKeyMapper
//

import Foundation

class ConnectionLog {
    static let shared = ConnectionLog()

    private var entries: [String] = []
    private let queue = DispatchQueue(label: "com.joymapper.connectionlog")
    private let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

    private init() {}

    func log(_ message: String, device: String? = nil) {
        let timestamp = dateFormatter.string(from: Date())
        let deviceTag: String
        if let device = device, !device.isEmpty {
            let truncated = String(device.suffix(8))
            deviceTag = " [\(truncated)]"
        } else if device != nil {
            deviceTag = " [unknown]"
        } else {
            deviceTag = ""
        }
        let entry = "[\(timestamp)]\(deviceTag) \(message)"
        queue.async {
            self.entries.append(entry)
            DispatchQueue.main.async {
                NotificationCenter.default.post(name: .connectionLogUpdated, object: entry)
            }
        }
    }

    func allEntries() -> [String] {
        return queue.sync { entries }
    }

    func copyAll() -> String {
        return queue.sync { entries.joined(separator: "\n") }
    }
}
