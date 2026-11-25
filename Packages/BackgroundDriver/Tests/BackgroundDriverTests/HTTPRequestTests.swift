import Foundation
import Testing
@testable import BackgroundDriver

struct HTTPRequestTests {
    @Test func parsesAGetWithQueryAndHeaders() throws {
        let raw = "GET /elements?id=roster-&window=Standup HTTP/1.1\r\nHost: 127.0.0.1\r\nAuthorization: Bearer abc\r\n\r\n"
        let request = try #require(try HTTPRequest.parse(Data(raw.utf8)))
        #expect(request.method == "GET")
        #expect(request.path == "/elements")
        #expect(request.query == ["id": "roster-", "window": "Standup"])
        #expect(request.headers["authorization"] == "Bearer abc")
        #expect(request.body.isEmpty)
    }

    @Test func waitsForTheWholeBody() throws {
        let head = "POST /click HTTP/1.1\r\nContent-Length: 10\r\n\r\n"
        #expect(try HTTPRequest.parse(Data((head + "{\"id\":").utf8)) == nil)
        let request = try #require(try HTTPRequest.parse(Data((head + "{\"id\":\"a\"}").utf8)))
        #expect(String(decoding: request.body, as: UTF8.self) == "{\"id\":\"a\"}")
    }

    @Test func waitsForTheEndOfTheHeaders() throws {
        #expect(try HTTPRequest.parse(Data("GET /status HTTP/1.1\r\nHost: x".utf8)) == nil)
    }

    @Test func rejectsAGarbledRequestLine() {
        #expect(throws: HTTPRequest.ParseError.self) { try HTTPRequest.parse(Data("nonsense\r\n\r\n".utf8)) }
    }
}

struct KeyTests {
    @Test func namedKeysAndCharacters() {
        #expect(Key("space") == Key(code: 49, characters: " "))
        #expect(Key("Right")?.code == 124)
        #expect(Key(",") == Key(code: 43, characters: ","))
        #expect(Key("R") == Key(code: 15, characters: "r"))
        #expect(Key("f13") == nil)
    }
}
