import AppKit

/// A fresh copy of an app, launched in the background with its driver on. It's a new instance
/// even if the app is already running, it never activates, and it publishes its endpoint to its
/// own file, so it doesn't disturb the copy you're using or the scripts attached to it.
public final class LaunchedApp: @unchecked Sendable {
    public let application: NSRunningApplication
    public let client: DriverClient
    private let endpointFile: URL

    private init(application: NSRunningApplication, client: DriverClient, endpointFile: URL) {
        self.application = application
        self.client = client
        self.endpointFile = endpointFile
    }

    /// Launches the app at `url` and waits until its driver answers. It gets your environment
    /// plus `environment`, minus what a test runner injects, so a copy launched from a test
    /// doesn't think it's being unit-tested.
    public static func launch(
        _ url: URL,
        environment: [String: String] = [:],
        arguments: [String] = [],
        timeout: TimeInterval = 30
    ) throws -> LaunchedApp {
        let endpointFile = FileManager.default.temporaryDirectory
            .appending(component: "background-driver-\(UUID().uuidString).json")
        let variables = environment.merging([Endpoint.Environment.endpointFile: endpointFile.path]) { _, new in new }
        // Like XCUITest: don't restore the windows an earlier copy left open (or closed), so every
        // launch starts from the app's default windows.
        let allArguments = ["-ApplePersistenceIgnoreState", "YES"] + arguments

        // `open` rather than NSWorkspace: both pass the caller's environment on to the app, but
        // only a child process's environment can have variables taken out. -g: don't activate;
        // -n: a new instance even if one is running.
        let open = Process()
        open.executableURL = URL(filePath: "/usr/bin/open")
        open.arguments = ["-g", "-n"]
            + variables.sorted { $0.key < $1.key }.flatMap { ["--env", "\($0.key)=\($0.value)"] }
            + [url.path]
            + ["--args"] + allArguments
        open.environment = ProcessInfo.processInfo.environment.filter { name, _ in
            !testRunnerPrefixes.contains { name.hasPrefix($0) }
        }
        try open.run()
        open.waitUntilExit()
        guard open.terminationStatus == 0 else {
            throw DriverError(status: 0, message: "open couldn't launch \(url.path) (exit \(open.terminationStatus))")
        }

        let deadline = Date.now.addingTimeInterval(timeout)
        while Date.now < deadline {
            if let client = try? DriverClient.attach(endpointFile: endpointFile),
               let application = NSRunningApplication(processIdentifier: client.endpoint.pid),
               (try? client.status()) != nil {
                return LaunchedApp(application: application, client: client, endpointFile: endpointFile)
            }
            Thread.sleep(forTimeInterval: 0.1)
        }
        throw DriverError(status: 0, message: "\(url.lastPathComponent)'s driver didn't answer within \(Int(timeout))s. Is it a Debug build that starts BackgroundDriver?")
    }

    /// What Xcode's test runner adds to its environment (and swift-dependencies' `isTesting` checks).
    private static let testRunnerPrefixes = ["XCTest", "XCInject", "__XC", "DYLD_"]

    public var isRunning: Bool { !application.isTerminated }

    /// Quits the app, forcing it if it hasn't quit within `timeout`.
    public func terminate(timeout: TimeInterval = 5) {
        defer { try? FileManager.default.removeItem(at: endpointFile) }
        guard isRunning else { return }
        application.terminate()
        let deadline = Date.now.addingTimeInterval(timeout)
        while isRunning, Date.now < deadline { Thread.sleep(forTimeInterval: 0.1) }
        if isRunning { application.forceTerminate() }
    }
}
