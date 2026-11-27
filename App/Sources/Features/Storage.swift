import ComposableArchitecture
import Foundation

/// App-wide switches, saved next to the profiles.
struct AppSettings: Codable, Equatable, Sendable {
    var mappingsEnabled = true
    /// Logs a raw input report every half second or so, plus every command reply.
    var logRawReports = false
}

enum Storage {
    /// `~/Library/Application Support/JoyMapperSilicon`, or `JOYMAPPER_DATA_DIR` (the background UI
    /// tests point it at a temporary folder so they never touch your mappings).
    static var directory: URL {
        if let override = ProcessInfo.processInfo.environment["JOYMAPPER_DATA_DIR"] {
            return URL(filePath: override, directoryHint: .isDirectory)
        }
        return URL.applicationSupportDirectory.appending(path: "JoyMapperSilicon", directoryHint: .isDirectory)
    }
}

extension SharedKey where Self == FileStorageKey<IdentifiedArrayOf<ControllerProfile>>.Default {
    /// Every controller the app has seen, with its mappings.
    static var profiles: Self {
        Self[.fileStorage(Storage.directory.appending(path: "profiles.json")), default: []]
    }
}

extension SharedKey where Self == FileStorageKey<AppSettings>.Default {
    static var settings: Self {
        Self[.fileStorage(Storage.directory.appending(path: "settings.json")), default: AppSettings()]
    }
}
