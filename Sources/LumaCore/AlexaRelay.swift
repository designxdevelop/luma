import Foundation

/// Client for your own Alexa relay (`alexa-relay`). Outbound HTTPS only:
/// Luma long-polls the relay; nothing on this device is exposed to the internet.
public struct AlexaRelayClient: Sendable {
    public struct Event: Codable, Sendable, Equatable {
        public let id: String
        /// `activate` (the routine ran the scene) or `deactivate`.
        public let type: String
        /// Unix seconds, stamped by the relay when Alexa sent the directive.
        public let issuedAt: Double
    }
    public struct Pairing: Codable, Sendable { public let code: String; public let expiresAt: Double }
    /// Events older than this (or this far in the future) are ignored, so a Mac waking
    /// from sleep never flashes for a ring from minutes ago.
    public static let freshness: TimeInterval = 60

    let base: URL
    let token: String
    let session: URLSession

    public init(base: String, token: String, session: URLSession = .shared) throws {
        guard let url = URL(string: base.hasSuffix("/") ? String(base.dropLast()) : base), url.scheme == "https", url.host?.isEmpty == false,
              url.query == nil, url.user == nil else { throw LumaError.message("The relay address must be an https:// URL.") }
        guard token.count >= 32, token.utf8.allSatisfy({ (33...126).contains($0) }) else { throw LumaError.message("Paste the relay token you set when you deployed it.") }
        self.base = url; self.token = token; self.session = session
    }

    /// One long poll (the relay holds it up to ~25 s; `wait: false` answers at once, to check
    /// the connection). Returns only fresh, well-formed events.
    public func next(wait: Bool = true, now: Date = Date()) async throws -> [Event] {
        let (data, status) = try await call("hub/next", body: wait ? #"{"wait":true}"# : #"{"wait":false}"#, timeout: 40)
        guard status != 204 else { return [] }
        let events = try JSONDecoder().decode([String: [Event]].self, from: data)["events"] ?? []
        return events.filter { abs(now.timeIntervalSince1970 - $0.issuedAt) <= Self.freshness && (1...200).contains($0.id.count) && ["activate", "deactivate"].contains($0.type) }
    }
    /// A one-time code to type on the relay's sign-in page when you enable the skill in the Alexa app.
    public func pairingCode() async throws -> Pairing { try JSONDecoder().decode(Pairing.self, from: try await call("hub/pairing-code").0) }
    /// Revokes every Alexa account link on the relay.
    public func unlink() async throws { _ = try await call("hub/unlink") }

    private func call(_ path: String, body: String = "{}", timeout: TimeInterval = 15) async throws -> (Data, Int) {
        var request = URLRequest(url: base.appending(path: path), timeoutInterval: timeout)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(body.utf8)
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        switch status {
        case 200, 204: return (data, status)
        case 401: throw LumaError.message("The relay rejected Luma's token. Check it matches the relay's HUB_TOKEN.")
        default: throw LumaError.message("Relay error \(status).")
        }
    }
}
