import Foundation
import Testing
@testable import BackgroundDriver
import BackgroundDriverClient

/// The client against the real HTTP server, with a canned handler in place of the app.
struct DriverClientTests {
    final class Requests: @unchecked Sendable {
        private let lock = NSLock()
        private var all: [HTTPRequest] = []
        func append(_ request: HTTPRequest) { lock.withLock { all.append(request) } }
        var last: HTTPRequest? { lock.withLock { all.last } }
    }

    private func serve(_ handler: @escaping @Sendable (HTTPRequest) -> HTTPResponse) throws -> (DriverClient, Requests, HTTPServer) {
        let requests = Requests()
        let server = try HTTPServer(port: 0) { request in
            requests.append(request)
            return handler(request)
        }
        let port = try server.start()
        return (DriverClient(endpoint: Endpoint(port: port, token: "secret", pid: getpid())), requests, server)
    }

    @Test func sendsTheTokenAndQuery() throws {
        let status = Status(pid: 7, active: false, hidden: false, frontmost: "com.example.other", keyWindow: nil)
        let (client, requests, server) = try serve { request in
            request.path == "/status" ? .json(status) : .json([Element]())
        }
        defer { server.stop() }

        #expect(try client.status() == status)
        #expect(requests.last?.headers["authorization"] == "Bearer secret")

        _ = try client.elements(prefix: "roster-", window: "Standup — Team")
        #expect(requests.last?.path == "/elements")
        #expect(requests.last?.query == ["id": "roster-", "window": "Standup — Team"])
    }

    @Test func postsJSONBodies() throws {
        let (client, requests, server) = try serve { _ in .json(["ok": true]) }
        defer { server.stop() }

        try client.click(Target(id: "start-standup", count: 2))
        let body = try JSONDecoder().decode(Target.self, from: #require(requests.last?.body))
        #expect(requests.last?.method == "POST")
        #expect(body == Target(id: "start-standup", count: 2))
    }

    @Test func aMissingElementIsNil() throws {
        let (client, _, server) = try serve { _ in .error("no element nope", status: 404) }
        defer { server.stop() }

        #expect(try client.element("nope") == nil)
    }

    @Test func otherErrorsCarryTheServersMessage() throws {
        let (client, _, server) = try serve { _ in .error("bad token", status: 401) }
        defer { server.stop() }

        #expect(throws: DriverError(status: 401, message: "bad token")) { try client.click(Target(id: "x")) }
    }
}
