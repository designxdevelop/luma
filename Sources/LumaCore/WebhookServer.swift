import Foundation
import Network

public struct WebhookRequest: Sendable {
    public let method: String
    public let path: String
    public let body: Data
    public init(method: String, path: String, body: Data) {
        self.method = method
        self.path = path
        self.body = body
    }
}

public struct WebhookResponse: Sendable {
    public let status: Int
    public let body: Data
    public init(status: Int, body: Data) {
        self.status = (100...599).contains(status) ? status : 500
        self.body = body
    }
    public init(status: Int, json: JSONValue) {
        self.status = (100...599).contains(status) ? status : 500
        self.body = (try? JSONEncoder().encode(json)) ?? Data("null".utf8)
    }
    static func error(_ status: Int, _ message: String) -> Self {
        .init(status: status, json: .object(["error": .string(message)]))
    }
    var wireData: Data {
        let reason = switch status {
        case 200: "OK"
        case 202: "Accepted"
        case 400: "Bad Request"
        case 401: "Unauthorized"
        case 404: "Not Found"
        case 405: "Method Not Allowed"
        case 408: "Request Timeout"
        case 411: "Length Required"
        case 413: "Content Too Large"
        case 415: "Unsupported Media Type"
        case 431: "Request Header Fields Too Large"
        case 503: "Service Unavailable"
        default: "Response"
        }
        var bytes = Data("HTTP/1.1 \(status) \(reason)\r\nContent-Type: application/json; charset=utf-8\r\nContent-Length: \(body.count)\r\nConnection: close\r\nCache-Control: no-store\r\nX-Content-Type-Options: nosniff\r\n\r\n".utf8)
        bytes.append(body)
        return bytes
    }
}

/// A bounded, single-request HTTP/1.1 parser. No network or actor state is needed to test it.
struct WebhookHTTPParser: Sendable {
    static let headerLimit = 16 * 1024
    static let bodyLimit = 64 * 1024
    enum Result: Sendable {
        case incomplete
        case request(WebhookRequest)
        case failure(WebhookResponse)
    }
    private struct Head: Sendable {
        let method: String
        let path: String
        let bodyLength: Int
    }
    private let token: [UInt8]
    private var buffer = Data()
    private var head: Head?
    private var finished = false

    init(token: String) { self.token = Array(token.utf8) }

    mutating func append(_ bytes: Data) -> Result {
        guard !finished else { return .failure(.error(400, "Only one request is allowed")) }
        // Bound allocation even if a caller supplies a whole oversized frame.
        guard bytes.count <= Self.headerLimit + Self.bodyLimit - buffer.count else {
            return fail(head == nil ? 431 : 413, "Request too large")
        }
        buffer.append(bytes)
        if head == nil {
            guard let separator = buffer.range(of: Data([13, 10, 13, 10])) else {
                if buffer.count > Self.headerLimit { return fail(431, "Headers too large") }
                return .incomplete
            }
            guard separator.upperBound <= Self.headerLimit else { return fail(431, "Headers too large") }
            let header = buffer[..<separator.lowerBound]
            guard header.allSatisfy({ $0 == 9 || $0 == 10 || $0 == 13 || (32...126).contains($0) }),
                  let text = String(data: header, encoding: .ascii) else { return fail(400, "Invalid headers") }
            let lines = text.components(separatedBy: "\r\n")
            let first = (lines.first ?? "").split(separator: " ", omittingEmptySubsequences: false)
            guard first.count == 3, first[2] == "HTTP/1.1" else { return fail(400, "HTTP/1.1 required") }
            let method = String(first[0])
            let path = String(first[1])
            guard path.hasPrefix("/"), !path.hasPrefix("//"),
                  !path.contains("?"), !path.contains("#"), !path.contains("\\"),
                  path.utf8.allSatisfy({ (33...126).contains($0) }) else {
                return fail(400, "Use an absolute path without a query string")
            }
            var fields: [String: String] = [:]
            let nameCharacters = Set("!#$%&'*+-.^_`|~0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ".utf8)
            for line in lines.dropFirst() {
                guard let colon = line.firstIndex(of: ":"), colon != line.startIndex else { return fail(400, "Malformed header") }
                let name = String(line[..<colon])
                guard name.utf8.allSatisfy({ nameCharacters.contains($0) }) else { return fail(400, "Invalid header name") }
                let key = name.lowercased()
                guard fields[key] == nil else { return fail(400, "Duplicate header") }
                let value = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
                guard value.utf8.allSatisfy({ $0 == 9 || (32...126).contains($0) }) else { return fail(400, "Invalid header value") }
                fields[key] = value
            }
            guard let host = fields["host"], !host.isEmpty,
                  !host.contains(","), !host.contains(" "), !host.contains("\t") else { return fail(400, "Host required") }
            guard fields["transfer-encoding"] == nil, fields["expect"] == nil,
                  fields["upgrade"] == nil, fields["trailer"] == nil else { return fail(400, "Unsupported HTTP framing") }
            var length = 0
            if let value = fields["content-length"] {
                guard !value.isEmpty, value.utf8.allSatisfy({ (48...57).contains($0) }),
                      let count = Int(value) else { return fail(400, "Invalid Content-Length") }
                guard count <= Self.bodyLimit else { return fail(413, "Body too large") }
                length = count
            }
            guard Self.constantTimeEqual(Array((fields["authorization"] ?? "").utf8), Array("Bearer ".utf8) + token),
                  !token.isEmpty else { return fail(401, "Bearer authentication required") }
            guard method == "GET" || method == "POST" else { return fail(405, "Use GET or POST") }
            if method == "POST" {
                guard fields["content-length"] != nil else { return fail(411, "Content-Length required") }
                let contentType = (fields["content-type"] ?? "").split(separator: ";", omittingEmptySubsequences: false)
                guard contentType.first?.trimmingCharacters(in: .whitespaces).lowercased() == "application/json" else {
                    return fail(415, "Content-Type must be application/json")
                }
                for parameter in contentType.dropFirst() {
                    let normalized = parameter.trimmingCharacters(in: .whitespaces).lowercased().replacingOccurrences(of: "\"", with: "")
                    guard normalized == "charset=utf-8" else { return fail(415, "Only UTF-8 JSON is supported") }
                }
            } else if length != 0 { return fail(400, "GET body is not supported") }
            head = Head(method: method, path: path, bodyLength: length)
            buffer.removeSubrange(..<separator.upperBound)
        }
        guard let head else { return .incomplete }
        guard buffer.count <= head.bodyLength else { return fail(400, "Trailing bytes or pipelined requests are not supported") }
        guard buffer.count == head.bodyLength else { return .incomplete }
        finished = true
        return .request(.init(method: head.method, path: head.path, body: buffer))
    }

    private mutating func fail(_ status: Int, _ message: String) -> Result {
        finished = true
        buffer.removeAll(keepingCapacity: false)
        return .failure(.error(status, message))
    }

    private static func constantTimeEqual(_ lhs: [UInt8], _ rhs: [UInt8]) -> Bool {
        var difference = UInt(lhs.count ^ rhs.count)
        for index in 0..<max(lhs.count, rhs.count) {
            let a = index < lhs.count ? lhs[index] : 0
            let b = index < rhs.count ? rhs[index] : 0
            difference |= UInt(a ^ b)
        }
        return difference == 0
    }
}

/// HTTP is intentionally loopback-only unless LAN access is explicitly enabled.
/// LAN callers must use a trusted network or an authenticated HTTPS tunnel.
@MainActor public final class WebhookServer {
    public private(set) var boundPort: UInt16?
    private var listener: NWListener?
    private var clients: [UUID: WebhookClient] = [:]
    private let clientLimit = 16

    public init() {}

    public func start(port: UInt16, allowLAN: Bool, token: String,
                      handler: @escaping @MainActor (WebhookRequest) async -> WebhookResponse,
                      onState: @escaping @MainActor (String) -> Void) throws {
        guard !token.isEmpty, token.utf8.allSatisfy({ (33...126).contains($0) }) else {
            throw LumaError.message("Webhook token must contain visible ASCII characters")
        }
        stop()
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: NWEndpoint.Host(allowLAN ? "0.0.0.0" : "127.0.0.1"), port: NWEndpoint.Port(rawValue: port)!)
        let listener = try NWListener(using: parameters)
        self.listener = listener
        listener.stateUpdateHandler = { [weak self, weak listener] state in
            Task { @MainActor in
                guard let self, let listener, self.listener === listener else { return }
                switch state {
                case .ready:
                    self.boundPort = listener.port?.rawValue
                    onState("listening on \(allowLAN ? "LAN" : "localhost"):\(self.boundPort ?? port)")
                case .failed(let error):
                    self.stop()
                    onState("Webhook server failed: \(error.localizedDescription)")
                default: break
                }
            }
        }
        listener.newConnectionHandler = { [weak self, weak listener] connection in
            Task { @MainActor in
                guard let self, let listener, self.listener === listener else { connection.cancel(); return }
                guard self.clients.count < self.clientLimit else { connection.cancel(); return }
                let id = UUID()
                let client = WebhookClient(connection: connection, token: token, handler: handler) { [weak self] in
                    self?.clients.removeValue(forKey: id)
                }
                self.clients[id] = client
                client.start()
            }
        }
        listener.start(queue: .main)
    }

    public func stop() {
        listener?.cancel()
        listener = nil
        boundPort = nil
        let pending = Array(clients.values)
        clients.removeAll()
        for client in pending { client.close() }
    }
}

@MainActor private final class WebhookClient {
    private let connection: NWConnection
    private var parser: WebhookHTTPParser
    private let handler: @MainActor (WebhookRequest) async -> WebhookResponse
    private let onClose: @MainActor () -> Void
    private var timeout: Task<Void, Never>?
    private var operation: Task<Void, Never>?
    private var responding = false
    private var closed = false

    init(connection: NWConnection, token: String,
         handler: @escaping @MainActor (WebhookRequest) async -> WebhookResponse,
         onClose: @escaping @MainActor () -> Void) {
        self.connection = connection
        self.parser = WebhookHTTPParser(token: token)
        self.handler = handler
        self.onClose = onClose
    }

    func start() {
        connection.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in
                switch state {
                case .failed, .cancelled: self?.close()
                default: break
                }
            }
        }
        connection.start(queue: .main)
        timeout = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(10)) } catch { return }
            self?.close()
        }
        receive()
    }

    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] bytes, _, complete, error in
            Task { @MainActor in
                guard let self, !self.closed, !self.responding else { return }
                let result = self.parser.append(bytes ?? Data())
                switch result {
                case .incomplete:
                    if complete || error != nil { self.respond(.error(400, "Incomplete request")) }
                    else { self.receive() }
                case .failure(let response): self.respond(response)
                case .request(let request):
                    self.responding = true
                    self.operation = Task { [weak self, handler = self.handler] in
                        guard !Task.isCancelled else { return }
                        let response = await handler(request)
                        guard let self, !self.closed, !Task.isCancelled else { return }
                        self.send(response)
                    }
                }
            }
        }
    }

    private func respond(_ response: WebhookResponse) {
        guard !closed, !responding else { return }
        responding = true
        send(response)
    }

    private func send(_ response: WebhookResponse) {
        connection.send(content: response.wireData, completion: .contentProcessed { [weak self] _ in
            Task { @MainActor in self?.close() }
        })
    }

    func close() {
        guard !closed else { return }
        closed = true
        timeout?.cancel()
        timeout = nil
        operation?.cancel()
        operation = nil
        connection.stateUpdateHandler = nil
        connection.cancel()
        onClose()
    }
}
