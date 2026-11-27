@_exported import BackgroundDriverModels
import Foundation

public struct DriverError: Error, CustomStringConvertible, Equatable {
    /// The HTTP status, or 0 when the app didn't answer.
    public var status: Int
    public var message: String

    public init(status: Int, message: String) {
        self.status = status
        self.message = message
    }

    public var description: String { status == 0 ? message : "\(status): \(message)" }
}

/// Talks to the driver in a running app. Calls block until the app answers, like XCUITest's,
/// so tests and scripts can use them directly.
public final class DriverClient: Sendable {
    public let endpoint: Endpoint
    private let session: URLSession

    public init(endpoint: Endpoint, timeout: TimeInterval = 15) {
        self.endpoint = endpoint
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = timeout
        session = URLSession(configuration: configuration)
    }

    /// Attaches to a copy that's already running, through the endpoint file it published.
    public static func attach(endpointFile: URL) throws -> DriverClient {
        guard let data = try? Data(contentsOf: endpointFile),
              let endpoint = try? JSONDecoder().decode(Endpoint.self, from: data)
        else { throw DriverError(status: 0, message: "No driver endpoint at \(endpointFile.path); is a Debug build running?") }
        guard kill(endpoint.pid, 0) == 0 else {
            throw DriverError(status: 0, message: "The app that published \(endpointFile.path) (pid \(endpoint.pid)) isn't running.")
        }
        return DriverClient(endpoint: endpoint)
    }

    public static func attach(bundleIdentifier: String) throws -> DriverClient {
        try attach(endpointFile: Endpoint.defaultFile(bundleIdentifier: bundleIdentifier))
    }

    // MARK: - Reading

    public func status() throws -> Status { try decode(get("/status")) }

    public func windows() throws -> [WindowInfo] { try decode(get("/windows")) }

    /// Elements whose identifier starts with `prefix` (all of them if `nil`).
    public func elements(prefix: String? = nil, window: String? = nil) throws -> [Element] {
        try decode(get("/elements", ["id": prefix, "window": window]))
    }

    /// The element with this identifier (inside the one identified by `within`), or `nil`.
    public func element(_ id: String, within: String? = nil, window: String? = nil) throws -> ElementDetail? {
        do {
            return try decode(get("/element", ["id": id, "within": within, "window": window]))
        } catch let error as DriverError where error.status == 404 {
            return nil
        }
    }

    /// The whole accessibility tree as indented text.
    public func tree(window: String? = nil) throws -> String {
        String(decoding: try get("/tree", ["window": window]), as: UTF8.self)
    }

    /// The frontmost matching window as PNG. `method` is `views` (the app draws it) or
    /// `windowserver` (the compositor's copy).
    public func snapshot(window: String? = nil, method: String = "views") throws -> Data {
        try get("/snapshot", ["window": window, "method": method])
    }

    // MARK: - Acting

    public func click(_ target: Target) throws { _ = try post("/click", target) }

    public func hover(_ target: Target) throws { _ = try post("/hover", target) }

    public func key(_ press: KeyPress) throws { _ = try post("/key", press) }

    /// Closes the frontmost matching window, like its close button.
    public func close(window: String? = nil) throws { _ = try post("/close", WindowTarget(window: window)) }

    // MARK: - Transport

    private func get(_ path: String, _ query: [String: String?] = [:]) throws -> Data {
        var components = URLComponents()
        components.queryItems = query.compactMap { name, value in value.map { URLQueryItem(name: name, value: $0) } }
        return try send("GET", path + (components.percentEncodedQuery.map { "?\($0)" } ?? ""), body: nil)
    }

    private func post(_ path: String, _ body: some Encodable) throws -> Data {
        try send("POST", path, body: JSONEncoder().encode(body))
    }

    private func send(_ method: String, _ pathAndQuery: String, body: Data?) throws -> Data {
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(endpoint.port)\(pathAndQuery)")!)
        request.httpMethod = method
        request.httpBody = body
        request.setValue("Bearer \(endpoint.token)", forHTTPHeaderField: "Authorization")

        final class Result: @unchecked Sendable { var value: Swift.Result<(Data, Int), Error>? }
        let result = Result()
        let done = DispatchSemaphore(value: 0)
        session.dataTask(with: request) { data, response, error in
            if let error {
                result.value = .failure(DriverError(status: 0, message: "\(method) \(pathAndQuery): \(error.localizedDescription)"))
            } else {
                result.value = .success((data ?? Data(), (response as? HTTPURLResponse)?.statusCode ?? 0))
            }
            done.signal()
        }.resume()
        done.wait()

        let (data, status) = try result.value!.get()
        guard (200..<300).contains(status) else {
            let message = (try? JSONDecoder().decode(ErrorBody.self, from: data))?.error ?? String(decoding: data, as: UTF8.self)
            throw DriverError(status: status, message: message)
        }
        return data
    }

    private func decode<T: Decodable>(_ data: Data) throws -> T {
        try JSONDecoder().decode(T.self, from: data)
    }
}
