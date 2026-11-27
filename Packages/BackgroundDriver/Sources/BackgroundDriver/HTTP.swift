import Foundation
import Network

/// Just enough HTTP/1.1 for a local test client: one request per connection, `Content-Length`
/// bodies, no chunking or keep-alive.
struct HTTPRequest: Sendable, Equatable {
    var method: String
    var path: String
    var query: [String: String]
    /// Header names are lowercased.
    var headers: [String: String]
    var body: Data

    enum ParseError: Error { case malformed }

    /// Parses a complete request, or returns `nil` if `data` doesn't hold all of it yet.
    static func parse(_ data: Data) throws -> HTTPRequest? {
        guard let headerEnd = data.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        guard let head = String(data: data[..<headerEnd.lowerBound], encoding: .utf8) else { throw ParseError.malformed }
        let lines = head.components(separatedBy: "\r\n")
        let requestLine = lines[0].split(separator: " ")
        guard requestLine.count >= 2, let components = URLComponents(string: String(requestLine[1])) else {
            throw ParseError.malformed
        }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            headers[line[..<colon].lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        let length = Int(headers["content-length"] ?? "0") ?? 0
        let body = data[headerEnd.upperBound...]
        guard body.count >= length else { return nil }
        var query: [String: String] = [:]
        for item in components.queryItems ?? [] { query[item.name] = item.value ?? "" }
        return HTTPRequest(
            method: String(requestLine[0]),
            path: components.path,
            query: query,
            headers: headers,
            body: Data(body.prefix(length))
        )
    }
}

struct HTTPResponse: Sendable {
    var status: Int
    var contentType: String
    var body: Data

    static func json(_ value: some Encodable, status: Int = 200) -> HTTPResponse {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return HTTPResponse(status: status, contentType: "application/json", body: (try? encoder.encode(value)) ?? Data())
    }

    static func error(_ message: String, status: Int) -> HTTPResponse {
        json(["error": message], status: status)
    }

    func serialized() -> Data {
        let reason = HTTPURLResponse.localizedString(forStatusCode: status).capitalized
        let head = "HTTP/1.1 \(status) \(reason)\r\nContent-Type: \(contentType)\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n"
        return Data(head.utf8) + body
    }
}

/// A loopback-only listener that hands each request to `handler`.
final class HTTPServer: @unchecked Sendable {
    typealias Handler = @Sendable (HTTPRequest) async -> HTTPResponse

    private let listener: NWListener
    private let queue = DispatchQueue(label: "BackgroundDriver.HTTPServer")
    private let handler: Handler

    init(port: UInt16, handler: @escaping Handler) throws {
        let parameters = NWParameters.tcp
        parameters.requiredInterfaceType = .loopback
        parameters.allowLocalEndpointReuse = true
        listener = try NWListener(using: parameters, on: NWEndpoint.Port(rawValue: port) ?? .any)
        self.handler = handler
    }

    /// Starts listening and returns the bound port.
    func start() throws -> UInt16 {
        let ready = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var failure: Error?
        listener.stateUpdateHandler = { state in
            switch state {
            case .ready: ready.signal()
            case .failed(let error): failure = error; ready.signal()
            default: break
            }
        }
        listener.newConnectionHandler = { [weak self] connection in self?.handle(connection) }
        listener.start(queue: queue)
        _ = ready.wait(timeout: .now() + 5)
        if let failure { throw failure }
        return listener.port?.rawValue ?? 0
    }

    func stop() { listener.cancel() }

    private func handle(_ connection: NWConnection) {
        connection.start(queue: queue)
        receive(on: connection, buffer: Data())
    }

    private func receive(on connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            let buffer = buffer + (data ?? Data())
            let request: HTTPRequest?
            do {
                request = try HTTPRequest.parse(buffer)
            } catch {
                return self.send(.error("malformed request", status: 400), on: connection)
            }
            if let request {
                let handler = self.handler
                Task {
                    let response = await handler(request)
                    self.send(response, on: connection)
                }
            } else if isComplete || error != nil {
                connection.cancel()
            } else {
                self.receive(on: connection, buffer: buffer)
            }
        }
    }

    private func send(_ response: HTTPResponse, on connection: NWConnection) {
        connection.send(content: response.serialized(), completion: .contentProcessed { _ in connection.cancel() })
    }
}
