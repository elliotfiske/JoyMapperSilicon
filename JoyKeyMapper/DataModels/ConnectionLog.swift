//
//  ConnectionLog.swift
//  JoyKeyMapper
//

import Foundation

class ConnectionLog {
    static let shared = ConnectionLog()

    private var entries: [String] = []
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
        entries.append(entry)
        NotificationCenter.default.post(name: .connectionLogUpdated, object: entry)
    }

    func copyAll() -> String {
        return entries.joined(separator: "\n")
    }
}
