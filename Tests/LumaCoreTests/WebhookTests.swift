import Foundation
import Testing
@testable import LumaCore

struct WebhookTests {
    private let token = "unit-test-bearer"

    private func request(_ method: String = "POST", path: String = "/v1/scenes/test/run", body: Data = Data("{}".utf8), additional: String = "", authorization: String? = "Bearer unit-test-bearer") -> Data {
        var head = "\(method) \(path) HTTP/1.1\r\nHost: localhost\r\n"
        if let authorization { head += "Authorization: \(authorization)\r\n" }
        if method == "POST" { head += "Content-Type: application/json\r\nContent-Length: \(body.count)\r\n" }
        head += additional + "\r\n"
        var data = Data(head.utf8)
        if method == "POST" { data.append(body) }
        return data
    }

    private func failureStatus(_ bytes: Data) -> Int? {
        var parser = WebhookHTTPParser(token: token)
        if case .failure(let response) = parser.append(bytes) { return response.status }
        return nil
    }

    @Test func splitFramesPreserveUTF8BodyBytes() throws {
        let body = Data("{\"name\":\"Café 💡\"}".utf8)
        let data = request(body: body)
        // Every possible split includes splits inside the CRLF boundary and UTF-8 scalars.
        for split in 1..<data.count {
            var parser = WebhookHTTPParser(token: token)
            guard case .incomplete = parser.append(Data(data.prefix(split))) else {
                Issue.record("Request completed before its full body at split \(split)")
                continue
            }
            guard case .request(let result) = parser.append(Data(data.dropFirst(split))) else {
                Issue.record("Split request failed at \(split)")
                continue
            }
            #expect(result.method == "POST")
            #expect(result.path == "/v1/scenes/test/run")
            #expect(result.body == body)
        }
    }

    @Test func rejectsMissingAndIncorrectAuthenticationBeforeBodyArrives() {
        for authorization in [nil, "Bearer wrong", "Bearer unit-test-bearer-more", "Basic unit-test-bearer"] {
            var parser = WebhookHTTPParser(token: token)
            let bytes = request(body: Data(repeating: 32, count: 500), authorization: authorization)
            let headers = bytes.range(of: Data("\r\n\r\n".utf8))!
            guard case .failure(let response) = parser.append(Data(bytes[..<headers.upperBound])) else {
                Issue.record("Unauthorized request was allowed to wait for its body")
                continue
            }
            #expect(response.status == 401)
        }
        #expect(failureStatus(request("GET", path: "/health", authorization: nil)) == 401)
        #expect(failureStatus(request(path: "/health?token=unit-test-bearer")) == 400)
    }

    @Test(arguments: ["-1", "+2", "2,2", "2 2", "1x", "", "999999999999999999999999999999"])
    func rejectsMalformedContentLength(_ value: String) {
        let bytes = Data("POST / HTTP/1.1\r\nHost: localhost\r\nAuthorization: Bearer \(token)\r\nContent-Type: application/json\r\nContent-Length: \(value)\r\n\r\n{}".utf8)
        #expect(failureStatus(bytes) == 400)
    }

    @Test func rejectsSmugglingAndUnsupportedRequests() {
        #expect(failureStatus(request(additional: "content-length: 2\r\n")) == 400)
        #expect(failureStatus(request(additional: "Transfer-Encoding: chunked\r\n")) == 400)
        #expect(failureStatus(request(additional: "Expect: 100-continue\r\n")) == 400)
        #expect(failureStatus(request(additional: " Host: injected\r\n")) == 400)
        #expect(failureStatus(request("OPTIONS")) == 405)
        #expect(failureStatus(request("DELETE")) == 405)
        #expect(failureStatus(request() + request("GET")) == 400)
        let contentType = Data("POST / HTTP/1.1\r\nHost: localhost\r\nAuthorization: Bearer \(token)\r\nContent-Type: text/plain\r\nContent-Length: 2\r\n\r\n{}".utf8)
        #expect(failureStatus(contentType) == 415)
    }

    @Test func enforcesHeaderAndBodyLimitsBeforeBufferingWholeRequest() {
        var parser = WebhookHTTPParser(token: token)
        let partial = Data("GET / HTTP/1.1\r\nX-Padding: ".utf8) + Data(repeating: 65, count: WebhookHTTPParser.headerLimit)
        guard case .failure(let response) = parser.append(partial) else {
            Issue.record("Unterminated oversized headers accepted")
            return
        }
        #expect(response.status == 431)
        let bigBody = Data("POST / HTTP/1.1\r\nHost: localhost\r\nAuthorization: Bearer \(token)\r\nContent-Type: application/json\r\nContent-Length: 65537\r\n\r\n".utf8)
        #expect(failureStatus(bigBody) == 413)

        var maximum = WebhookHTTPParser(token: token)
        let body = Data(repeating: 32, count: WebhookHTTPParser.bodyLimit)
        guard case .request(let parsed) = maximum.append(request(body: body)) else {
            Issue.record("Maximum-sized valid body rejected")
            return
        }
        #expect(parsed.body.count == 65536)
    }

    @Test @MainActor func loopbackHTTPRequiresAuthAndDispatchesOnlyValidRequests() async throws {
        let server = WebhookServer()
        var received: [WebhookRequest] = []
        var state = "Waiting for listener"
        try server.start(port: 0, allowLAN: false, token: token, handler: { request in
            received.append(request)
            return .init(status: 200, json: .object(["ok": .bool(true)]))
        }, onState: { state = $0 })
        defer { server.stop() }
        for _ in 0..<100 where server.boundPort == nil { try await Task.sleep(for: .milliseconds(10)) }
        let port = try #require(server.boundPort, "Loopback server did not become ready: \(state)")
        let url = try #require(URL(string: "http://127.0.0.1:\(port)/v1/test"))
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 3
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        var authorized = URLRequest(url: url)
        authorized.httpMethod = "POST"
        authorized.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        authorized.setValue("application/json", forHTTPHeaderField: "Content-Type")
        authorized.httpBody = Data("{\"brightness\":42}".utf8)
        let (body, response) = try await session.data(for: authorized)
        #expect((response as? HTTPURLResponse)?.statusCode == 200)
        #expect(try JSONDecoder().decode(JSONValue.self, from: body)["ok"] == .bool(true))
        #expect(received.count == 1)
        #expect(received.first?.body == authorized.httpBody)
        var unauthorized = authorized
        unauthorized.setValue(nil, forHTTPHeaderField: "Authorization")
        let (_, denied) = try await session.data(for: unauthorized)
        #expect((denied as? HTTPURLResponse)?.statusCode == 401)
        #expect(received.count == 1)
        #expect((denied as? HTTPURLResponse)?.value(forHTTPHeaderField: "Access-Control-Allow-Origin") == nil)
    }
}
