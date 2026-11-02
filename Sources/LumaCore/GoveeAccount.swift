import Foundation

/// Sign-in to the private Govee Home account API, used only to read the device
/// list (rooms, BLE identity, firmware), control groups (DreamView), and automations. Contract and headers follow two public
/// clients that agree: homebridge-govee @ c7b3037 (`lib/connection/http.js`) and
/// goveetl @ 3890402 (`internal/govee/auth.go`). Govee publishes no contract, so
/// this can change without notice. Nothing here controls lights.
public struct GoveeAccount: Sendable {
    public struct Session: Sendable, Equatable {
        public var token: String
        /// Govee's `tokenExpireTime` when present (milliseconds in the wire format). A live
        /// session (2026-11-02) had none, only `tokenExpireCycle` (unit unknown, not read).
        public var expires: Date?
    }

    public enum LoginResult: Sendable, Equatable {
        case signedIn(Session)
        /// Govee answered 454: it emailed a code; sign in again with it.
        case needsCode
    }

    public static let host = URL(string: "https://app2.govee.com")!
    // ponytail: pinned to homebridge's live-used values; bump when Govee rejects them.
    static let appVersion = "7.4.10"
    static let userAgent = "GoveeHome/7.4.10 (com.ihoment.GoVeeSensor; build:8; iOS 26.5.0) Alamofire/5.11.0"

    private let clientID: String
    private let session: URLSession
    private let host: URL

    /// `clientID` must stay the same between sign-ins, or Govee asks for a code every time.
    public init(clientID: String, session: URLSession = .shared, host: URL = GoveeAccount.host) {
        self.clientID = clientID; self.session = session; self.host = host
    }

    /// When Govee wants a code, this also asks it to email one (`type 8`, as both clients do).
    public func login(email: String, password: String, code: String? = nil) async throws -> LoginResult {
        var body: [String: JSONValue] = ["email": .string(email), "password": .string(password), "client": .string(clientID)]
        if let code, !code.isEmpty { body["code"] = .string(code) }
        let root = try await send("account/rest/account/v2/login", body: .object(body))
        switch root["status"]?.number {
        case 454?:
            guard code?.isEmpty ?? true else { throw LumaError.message("Govee didn't accept that code. Request a new one and try again.") }
            let sent = try await send("account/rest/account/v1/verification", body: .object(["email": .string(email), "type": .number(8)]))
            guard sent["status"]?.number == 200 else { throw LumaError.message("Govee couldn't send a sign-in code. Try again later.") }
            return .needsCode
        case 200?:
            guard let token = root["client"]?["token"]?.string?.trimmingCharacters(in: .whitespaces), !token.isEmpty else {
                throw LumaError.message("Govee returned an incomplete session.")
            }
            // ponytail: milliseconds assumed (unit unverified); a past date is dropped and the server's 401 decides.
            let expires = root["client"]?["tokenExpireTime"]?.number.map { Date(timeIntervalSince1970: $0 / 1000) }.flatMap { $0 > .now ? $0 : nil }
            return .signedIn(Session(token: token, expires: expires))
        case let status?:
            // The server's message is never shown: it can echo account details.
            throw LumaError.message("Govee didn't accept the email or password (status \(Int(status))).")
        case nil:
            throw LumaError.message("Govee returned an unexpected sign-in response.")
        }
    }

    /// Raw `GET /bff-app/v1/device/list` body, for `GoveeHomeImport.parse`.
    public func deviceList(token: String) async throws -> Data { try await get("bff-app/v1/device/list", token: token) }

    /// Raw `GET bff-app/v1/general-control/list` body (goveetl @ 3890402), for `GoveeHomeImport.parseGroups`.
    public func groups(token: String) async throws -> Data {
        try await get("bff-app/v1/general-control/list", query: [URLQueryItem(name: "filterEmpty", value: "false")], token: token)
    }

    /// Raw `GET bff-app/v1/ecology/resource/automations` body (goveetl @ 3890402), for `GoveeHomeImport.parseAutomations`.
    public func automations(token: String) async throws -> Data { try await get("bff-app/v1/ecology/resource/automations", token: token) }

    // ponytail: GET only. Group control and automation edits are private POSTs that act on lights; not implemented.
    private func get(_ path: String, query: [URLQueryItem] = [], token: String) async throws -> Data {
        var request = request(path)
        if !query.isEmpty { request.url?.append(queryItems: query) }
        request.httpMethod = "GET"
        request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
        let (data, status) = try await perform(request)
        if status == 401 || status == 403 { throw SessionExpired() }
        guard (200..<300).contains(status) else { throw LumaError.message("Govee Home request failed (HTTP \(status)).") }
        if let root = try? JSONDecoder().decode(JSONValue.self, from: data), let code = root["status"]?.number, code == 401 { throw SessionExpired() }
        return data
    }

    /// The saved session no longer works; sign in again (refresh isn't implemented).
    public struct SessionExpired: LocalizedError {
        public init() {}
        public var errorDescription: String? { "Your Govee Home sign-in expired. Sign in again." }
    }

    private func send(_ path: String, body: JSONValue) async throws -> JSONValue {
        var request = request(path)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(body)
        let (data, status) = try await perform(request)
        guard (200..<300).contains(status), let root = try? JSONDecoder().decode(JSONValue.self, from: data) else {
            throw LumaError.message("Govee sign-in failed (HTTP \(status)).")
        }
        return root
    }

    private func request(_ path: String) -> URLRequest {
        var request = URLRequest(url: host.appending(path: path), timeoutInterval: 30)
        for (field, value) in ["appVersion": Self.appVersion, "clientId": clientID, "clientType": "1", "iotVersion": "0",
                               "timestamp": String(Int(Date().timeIntervalSince1970 * 1000)), "User-Agent": Self.userAgent] {
            request.setValue(value, forHTTPHeaderField: field)
        }
        return request
    }

    private func perform(_ request: URLRequest) async throws -> (Data, Int) {
        guard request.url?.scheme == "https" || request.url?.host == "localhost" else { throw LumaError.message("Govee sign-in requires HTTPS.") }
        let (data, response) = try await session.data(for: request, delegate: NoRedirects())
        guard let http = response as? HTTPURLResponse else { throw LumaError.message("Govee did not return an HTTP response.") }
        // A redirect would resend the password elsewhere; it arrives here unfollowed.
        if (300..<400).contains(http.statusCode) { throw LumaError.message("Govee redirected the request; Luma stopped it.") }
        guard data.count <= 8 * 1024 * 1024 else { throw LumaError.message("Govee response is too large.") }
        return (data, http.statusCode)
    }
}

private final class NoRedirects: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest) async -> URLRequest? { nil }
}
