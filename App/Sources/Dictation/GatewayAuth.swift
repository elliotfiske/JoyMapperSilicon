import Foundation

/// Gets the credential for the LLM gateway: either a static key saved in the Keychain, or a
/// short-lived token printed by a helper command (e.g. an SSO login script that caches and
/// renews its own token).
///
/// The helper is only ever run quietly: no browser, no dialogs, with a short timeout. If that
/// can't produce a token, cleanup reports `loginRequired`, and the UI offers a Log in button,
/// which is the only thing that runs the helper interactively. The token is kept in memory
/// only, and fetched again shortly before it expires.
actor GatewayAuth {
    static let shared = GatewayAuth()

    private var cached: (token: String, expiresAt: Date)?

    /// Tokens without a readable expiry are reused for this long.
    private static let defaultLifetime: TimeInterval = 30 * 60
    /// Fetch a new token when the cached one has less than this left.
    private static let renewalMargin: TimeInterval = 5 * 60
    static let quietTimeout: TimeInterval = 20
    /// Long enough to finish a browser and MFA sign-in.
    static let interactiveTimeout: TimeInterval = 200

    func credential(settings: DictationSettings) async throws -> String {
        guard settings.usesTokenCommand else {
            guard let key = GatewayKeychain.read(), !key.isEmpty else { throw CleanupError.missingKey }
            return key
        }
        if let cached, cached.expiresAt.timeIntervalSinceNow > Self.renewalMargin {
            return cached.token
        }
        return try await fetch(settings: settings, interactive: false)
    }

    /// After a 401: forget the token so the next request fetches a fresh one.
    func invalidate() {
        cached = nil
    }

    /// Runs the helper. `interactive` lets it open a browser for sign-in; only the Log in
    /// button asks for that.
    @discardableResult
    func fetch(settings: DictationSettings, interactive: Bool) async throws -> String {
        let mode = interactive ? "interactively" : "quietly"
        Log.dictation.info("Getting a gateway token \(mode)")
        let started = Date()
        let result = try await Self.run(
            command: settings.tokenCommand,
            environment: interactive ? [:] : Self.quietEnvironment(settings),
            timeout: interactive ? Self.interactiveTimeout : Self.quietTimeout,
            stopWhenAskingForBrowser: !interactive
        )
        let elapsed = Int(Date().timeIntervalSince(started) * 1000)
        guard result.status == 0, let token = Self.token(fromOutput: result.output) else {
            let why = result.wantedBrowser ? ", it wanted to sign in" : (result.timedOut ? ", timed out" : "")
            Log.dictation.error("Token helper didn't produce a token \(mode) (exit \(result.status), \(elapsed) ms\(why)); login needed")
            throw CleanupError.loginRequired
        }
        let expiry = Self.expiry(ofJWT: token) ?? Date().addingTimeInterval(Self.defaultLifetime)
        cached = (token, expiry)
        let minutes = Int(expiry.timeIntervalSinceNow / 60)
        Log.dictation.notice("Got a gateway token \(mode) in \(elapsed) ms; valid for \(minutes) more minutes")
        return token
    }

    /// Quiet runs: no browser (Python's `webbrowser` and most scripts honor `BROWSER`), plus
    /// whatever the helper needs to skip its own dialogs, from settings.
    static func quietEnvironment(_ settings: DictationSettings) -> [String: String] {
        var environment = ["BROWSER": "/usr/bin/true"]
        for pair in settings.tokenCommandQuietEnvironment.split(whereSeparator: \.isWhitespace) {
            let parts = pair.split(separator: "=", maxSplits: 1).map(String.init)
            guard parts.count == 2, !parts[0].isEmpty else { continue }
            environment[parts[0]] = parts[1]
        }
        return environment
    }

    /// The last non-empty line of stdout: helpers print only the token there.
    static func token(fromOutput output: String) -> String? {
        let lines = output.split(whereSeparator: \.isNewline)
        let last = lines.last { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        let token = last.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
        let looksValid = !token.isEmpty && !token.contains(" ")
        return looksValid ? token : nil
    }

    /// The `exp` claim of a JWT, if it is one.
    static func expiry(ofJWT token: String) -> Date? {
        let parts = token.split(separator: ".")
        guard parts.count == 3 else { return nil }
        var payload = String(parts[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while payload.count % 4 != 0 { payload += "=" }
        guard let data = Data(base64Encoded: payload),
              let claims = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let exp = claims["exp"] as? Double
        else { return nil }
        return Date(timeIntervalSince1970: exp)
    }

    struct RunResult {
        var status: Int32
        var output: String
        var timedOut: Bool
        /// Stopped early because it said it was opening a browser to sign in.
        var wantedBrowser = false
    }

    /// Runs `command` through the login shell's PATH. Stdout is captured and never logged.
    /// Stderr is only watched, never logged: helpers print progress there, not tokens. With
    /// `stopWhenAskingForBrowser`, a line mentioning a browser ends a quiet run right away
    /// instead of after the timeout (the helper would wait minutes for a sign-in).
    static func run(
        command: String,
        environment: [String: String],
        timeout: TimeInterval,
        stopWhenAskingForBrowser: Bool = false
    ) async throws -> RunResult {
        try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            process.executableURL = URL(filePath: "/bin/zsh")
            process.arguments = ["-lc", command]
            process.environment = ProcessInfo.processInfo.environment.merging(environment) { _, new in new }
            let stdout = Pipe()
            process.standardOutput = stdout
            let stderr = Pipe()
            process.standardError = stderr
            process.standardInput = FileHandle.nullDevice

            let timedOut = LockedFlag()
            let wantedBrowser = LockedFlag()
            stderr.fileHandleForReading.readabilityHandler = { handle in
                let chunk = String(decoding: handle.availableData, as: UTF8.self)
                guard stopWhenAskingForBrowser, chunk.localizedCaseInsensitiveContains("browser") else { return }
                guard process.isRunning, !wantedBrowser.value else { return }
                wantedBrowser.set()
                Self.terminateTree(process)
            }
            process.terminationHandler = { finished in
                stderr.fileHandleForReading.readabilityHandler = nil
                let data = stdout.fileHandleForReading.readDataToEndOfFile()
                continuation.resume(returning: RunResult(
                    status: finished.terminationStatus,
                    output: String(decoding: data, as: UTF8.self),
                    timedOut: timedOut.value,
                    wantedBrowser: wantedBrowser.value
                ))
            }
            do {
                try process.run()
            } catch {
                continuation.resume(throwing: error)
                return
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                guard process.isRunning else { return }
                timedOut.set()
                Self.terminateTree(process)
            }
        }
    }
}

extension GatewayAuth {
    /// Stops the helper and anything it started (a sign-in listener would otherwise keep
    /// running and hold the helper's lock, making the next Log in wait for it).
    static func terminateTree(_ process: Process) {
        let pkill = Process()
        pkill.executableURL = URL(filePath: "/usr/bin/pkill")
        pkill.arguments = ["-TERM", "-P", String(process.processIdentifier)]
        try? pkill.run()
        pkill.waitUntilExit()
        process.terminate()
    }
}

private final class LockedFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var flag = false
    var value: Bool { lock.lock(); defer { lock.unlock() }; return flag }
    func set() { lock.lock(); flag = true; lock.unlock() }
}
