import AppKit
@_exported import BackgroundDriverModels
import os

/// Starts the in-app driver. Call it once at launch (debug builds only: anyone holding the
/// token can click around the app):
///
/// ```swift
/// #if DEBUG
/// try? BackgroundDriver.start()
/// #endif
/// ```
///
/// The endpoint (port, token, pid) is written to `~/Library/Caches/<bundle id>/background-driver.json`
/// for scripts that attach to a running app. A test that launches the app can choose the port,
/// token, and file with the variables in `Endpoint.Environment`.
public enum BackgroundDriver {
    public struct Configuration: Sendable {
        /// 0 picks a free port.
        public var port: UInt16
        public var token: String
        /// Where to publish the endpoint; `nil` to skip.
        public var endpointFile: URL?

        public init(port: UInt16 = 0, token: String = UUID().uuidString, endpointFile: URL? = Self.defaultEndpointFile) {
            self.port = port
            self.token = token
            self.endpointFile = endpointFile
        }

        public static var defaultEndpointFile: URL? {
            Bundle.main.bundleIdentifier.map(Endpoint.defaultFile(bundleIdentifier:))
        }

        /// Reads the variables in `Endpoint.Environment`.
        public static func fromEnvironment(_ environment: [String: String] = ProcessInfo.processInfo.environment) -> Configuration {
            var configuration = Configuration()
            if let port = environment[Endpoint.Environment.port].flatMap(UInt16.init) { configuration.port = port }
            if let token = environment[Endpoint.Environment.token], !token.isEmpty { configuration.token = token }
            if let file = environment[Endpoint.Environment.endpointFile], !file.isEmpty {
                configuration.endpointFile = URL(filePath: file)
            }
            return configuration
        }
    }

    static let log = Logger(subsystem: Bundle.main.bundleIdentifier ?? "BackgroundDriver", category: "BackgroundDriver")
    @MainActor private static var server: HTTPServer?

    /// Starts listening on loopback and returns where. Calling it again returns an error.
    @MainActor @discardableResult
    public static func start(_ configuration: Configuration = .fromEnvironment()) throws -> Endpoint {
        guard server == nil else { throw StartError.alreadyRunning }
        AlwaysVisible.install()
        let router = Router(token: configuration.token)
        let server = try HTTPServer(port: configuration.port) { request in await router.handle(request) }
        let port = try server.start()
        self.server = server
        let endpoint = Endpoint(port: port, token: configuration.token, pid: ProcessInfo.processInfo.processIdentifier)
        if let file = configuration.endpointFile {
            try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? JSONEncoder().encode(endpoint).write(to: file, options: .atomic)
        }
        log.notice("Background driver listening on 127.0.0.1:\(port)")
        return endpoint
    }

    public enum StartError: Error { case alreadyRunning }
}
