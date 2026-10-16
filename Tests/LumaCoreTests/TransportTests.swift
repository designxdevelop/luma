import Foundation
import Testing
@testable import LumaCore

private struct MockResponse: Sendable {
    let status: Int
    let body: String
    init(_ body: String, status: Int = 200) { self.body = body; self.status = status }
}

/// URLProtocol callbacks are synchronous and may run on different session queues.
private final class MockRegistry: @unchecked Sendable {
    private let lock = NSLock()
    private var fixtures: [String: [MockResponse]] = [:]
    private var requests: [String: [(URLRequest, ContinuousClock.Instant)]] = [:]
    func install(_ fixtures: [MockResponse], for id: String) {
        lock.withLock { self.fixtures[id] = fixtures; requests[id] = [] }
    }
    func respond(to request: URLRequest) -> MockResponse {
        lock.withLock {
            let id = request.value(forHTTPHeaderField: "X-Luma-Test") ?? ""
            requests[id, default: []].append((request, .now))
            guard var queue = fixtures[id], !queue.isEmpty else { return MockResponse("{}", status: 500) }
            let response = queue.removeFirst()
            fixtures[id] = queue
            return response
        }
    }
    func recorded(_ id: String) -> [(URLRequest, ContinuousClock.Instant)] { lock.withLock { requests[id] ?? [] } }
    func remove(_ id: String) { lock.withLock { fixtures[id] = nil; requests[id] = nil } }
}

private final class MockGoveeProtocol: URLProtocol, @unchecked Sendable {
    static let registry = MockRegistry()
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        var captured = request
        if captured.httpBody == nil, let stream = captured.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var body = Data()
            var buffer = [UInt8](repeating: 0, count: 4096)
            while true {
                let count = stream.read(&buffer, maxLength: buffer.count)
                guard count > 0 else { break }
                body.append(contentsOf: buffer.prefix(count))
            }
            captured.httpBody = body
        }
        let fixture = Self.registry.respond(to: captured)
        guard let url = request.url, let response = HTTPURLResponse(url: url, statusCode: fixture.status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"]) else { return }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(fixture.body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

private struct CloudFixture {
    let id = UUID().uuidString
    let session: URLSession
    init(_ responses: [MockResponse]) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockGoveeProtocol.self]
        configuration.httpAdditionalHeaders = ["X-Luma-Test": id]
        session = URLSession(configuration: configuration)
        MockGoveeProtocol.registry.install(responses, for: id)
    }
    func finish() { session.invalidateAndCancel(); MockGoveeProtocol.registry.remove(id) }
    var requests: [(URLRequest, ContinuousClock.Instant)] { MockGoveeProtocol.registry.recorded(id) }
    var cloud: GoveeCloud { GoveeCloud(apiKey: "test-api-key", session: session) }
}

@Test func cloudDeviceListPreservesAdvertisedCapabilitiesAndFiltersNonLights() async throws {
    let fixture = CloudFixture([MockResponse(#"{"code":200,"data":[{"device":"lamp","sku":"H6008","deviceName":"Desk","type":"devices.types.light","capabilities":[{"type":"devices.capabilities.range","instance":"brightness","parameters":{"dataType":"INTEGER","range":{"min":1,"max":100}}}]},{"device":"heater","sku":"H7130","type":"devices.types.heater","capabilities":[]}]}"#)])
    defer { fixture.finish() }
    let lights = try await fixture.cloud.devices()
    #expect(lights.count == 1)
    #expect(lights.first?.name == "Desk")
    #expect(lights.first?.capabilities.first?.parameters?["range"]?["max"]?.number == 100)
    #expect(fixture.requests.first?.0.httpMethod == "GET")
    #expect(fixture.requests.first?.0.url?.absoluteString == "https://openapi.api.govee.com/router/api/v1/user/devices")
    #expect(fixture.requests.first?.0.value(forHTTPHeaderField: "Govee-API-Key") == "test-api-key")
}

@Test(arguments: [MockResponse(#"{"code":401}"#, status: 401), MockResponse(#"{"code":400,"message":"failed"}"#), MockResponse(#"{"data":[]}"#)])
private func cloudRejectsHTTPAndApplicationErrors(response: MockResponse) async {
    let fixture = CloudFixture([response]); defer { fixture.finish() }
    await #expect(throws: (any Error).self) { try await fixture.cloud.devices() }
}

@Test func cloudControlUsesCapabilityEnvelopeAndDoesNotRetry() async throws {
    let fixture = CloudFixture([MockResponse(#"{"code":200}"#)]); defer { fixture.finish() }
    try await fixture.cloud.control(device: LightDevice(id: "lamp", sku: "H6008", name: "Desk"), command: .rgb(0x112233))
    let request = try #require(fixture.requests.first?.0)
    let body = try JSONDecoder().decode(JSONValue.self, from: #require(request.httpBody))
    #expect(request.httpMethod == "POST")
    #expect(request.url?.path == "/router/api/v1/device/control")
    #expect(body["payload"]?["device"]?.string == "lamp")
    #expect(body["payload"]?["capability"]?["instance"]?.string == "colorRgb")
    #expect(body["payload"]?["capability"]?["value"]?.number == 0x112233)
    #expect(body["requestId"]?.string.flatMap(UUID.init(uuidString:)) != nil)
    #expect(fixture.requests.count == 1)
}

@Test func cloudOfflineStateDoesNotOverwriteLastKnownValues() async throws {
    let fixture = CloudFixture([MockResponse(#"{"code":200,"payload":{"device":"lamp","sku":"H6008","capabilities":[{"instance":"online","state":{"value":false}},{"instance":"brightness","state":{"value":99}}]}}"#)])
    defer { fixture.finish() }
    let before = LightDevice(id: "lamp", sku: "H6008", name: "Desk", brightness: 20)
    let state = try await fixture.cloud.state(for: before)
    #expect(state.online == false)
    #expect(state.brightness == 20)
    #expect(state.lastSeen == nil)
}

@Test func cloudStateParsesCurrentCapabilities() async throws {
    let fixture = CloudFixture([MockResponse(#"{"code":200,"payload":{"device":"lamp","sku":"H6008","capabilities":[{"instance":"online","state":{"value":true}},{"instance":"brightness","state":{"value":63}},{"instance":"powerSwitch","state":{"value":1}},{"instance":"colorRgb","state":{"value":1122867}},{"instance":"colorTemperatureK","state":{"value":2700}}]}}"#)])
    defer { fixture.finish() }
    let state = try await fixture.cloud.state(for: LightDevice(id: "lamp", sku: "H6008", name: "Desk"))
    #expect(state.online == true && state.power == true)
    #expect(state.brightness == 63 && state.rgb == 0x112233 && state.colorTemperature == 2700)
    #expect(state.lastSeen != nil)
}

@Test func cloudRejectsMismatchedDeviceState() async {
    let fixture = CloudFixture([MockResponse(#"{"code":200,"payload":{"device":"other","capabilities":[]}}"#)]); defer { fixture.finish() }
    await #expect(throws: (any Error).self) { try await fixture.cloud.state(for: LightDevice(id: "lamp", sku: "H6008", name: "Desk")) }
}

@Test func cloudReturnsDIYSchema() async throws {
    let fixture = CloudFixture([MockResponse(#"{"code":200,"payload":{"capabilities":[{"type":"devices.capabilities.diy_color_setting","instance":"diyScene","parameters":{"dataType":"ENUM","options":[{"name":"Christmas","value":8216931}]}}]}}"#)])
    defer { fixture.finish() }
    let scenes = try await fixture.cloud.scenes(for: LightDevice(id: "lamp", sku: "H6008", name: "Desk"), diy: true)
    #expect(scenes.first?.parameters?["options"]?.array?.first?["value"]?.number == 8216931)
    #expect(fixture.requests.first?.0.url?.path == "/router/api/v1/device/diy-scenes")
}

@Test func cloudSerializesAndPacesConcurrentCommandsPerDevice() async throws {
    let fixture = CloudFixture([MockResponse(#"{"code":200}"#), MockResponse(#"{"code":200}"#)]); defer { fixture.finish() }
    let cloud = fixture.cloud
    let device = LightDevice(id: "lamp", sku: "H6008", name: "Desk")
    async let first: Void = cloud.control(device: device, command: .power(true))
    async let second: Void = cloud.control(device: device, command: .brightness(50))
    _ = try await (first, second)
    let requests = fixture.requests
    #expect(requests.count == 2)
    if requests.count == 2 { #expect(requests[0].1.duration(to: requests[1].1) >= .milliseconds(990)) }
}

@Test func lanDiscoveryCarriesIdentityButNoInventedState() throws {
    let data = Data(#"{"msg":{"cmd":"scan","data":{"ip":"192.168.1.23","device":"AA:BB","sku":"H6008"}}}"#.utf8)
    guard case .discovery(let light) = try LANPacket.parse(data, sourceIP: "192.168.1.23") else { Issue.record("Expected discovery"); return }
    #expect(light.id == "AA:BB" && light.ip == "192.168.1.23")
    #expect(light.power == nil && light.brightness == nil)
    #expect(throws: (any Error).self) { try LANPacket.parse(data, sourceIP: "192.168.1.24") }
}

@Test func lanStatusIsParsedSeparatelyFromDiscovery() throws {
    let data = Data(#"{"msg":{"cmd":"devStatus","data":{"onOff":1,"brightness":45,"color":{"r":17,"g":34,"b":51},"colorTemInKelvin":0}}}"#.utf8)
    guard case .status(let status) = try LANPacket.parse(data, sourceIP: "192.168.1.23") else { Issue.record("Expected status"); return }
    #expect(status.power && status.brightness == 45 && status.rgb == 0x112233 && status.kelvin == 0)
}

@Test(arguments: [CapabilityCommand.brightness(0), .brightness(101), .kelvin(1999), .rgb(-1), .init(type: "wrong", instance: "powerSwitch", value: .number(1)), .init(type: "devices.capabilities.dynamic_scene", instance: "lightScene", value: .number(1))])
func lanRejectsUnsupportedValues(command: CapabilityCommand) {
    #expect(throws: (any Error).self) { try LANPacket.control(command) }
}

@Test func lanColorPacketsUseDocumentedRGBAndKelvinSemantics() throws {
    let rgb = try JSONDecoder().decode(JSONValue.self, from: LANPacket.control(.rgb(0x112233)))
    #expect(rgb["msg"]?["cmd"]?.string == "colorwc")
    #expect(rgb["msg"]?["data"]?["color"]?["r"]?.number == 17)
    #expect(rgb["msg"]?["data"]?["color"]?["g"]?.number == 34)
    #expect(rgb["msg"]?["data"]?["color"]?["b"]?.number == 51)
    #expect(rgb["msg"]?["data"]?["colorTemInKelvin"]?.number == 0)
    let white = try JSONDecoder().decode(JSONValue.self, from: LANPacket.control(.kelvin(2700)))
    #expect(white["msg"]?["data"]?["colorTemInKelvin"]?.number == 2700)
}

@Test func lanRejectsMalformedOversizedAndOutOfRangeStatus() {
    let malformed = Data(#"{"msg":{"cmd":"devStatus","data":{"onOff":1,"brightness":999}}}"#.utf8)
    #expect(throws: (any Error).self) { try LANPacket.parse(malformed, sourceIP: "192.168.1.23") }
    #expect(throws: (any Error).self) { try LANPacket.parse(Data(repeating: 32, count: 8193), sourceIP: "192.168.1.23") }
    #expect(!LANPacket.isUnicastIPv4("239.255.255.250"))
    #expect(!LANPacket.isUnicastIPv4("127.0.0.1"))
    #expect(!LANPacket.isUnicastIPv4("example.com"))
}

@Test func cloudPacesRepeatedStateReadsAtThirtyPerMinute() async throws {
    let body = #"{"code":200,"payload":{"capabilities":[{"instance":"online","state":{"value":true}}]}}"#
    let fixture = CloudFixture([MockResponse(body), MockResponse(body)]); defer { fixture.finish() }
    let cloud = fixture.cloud
    let device = LightDevice(id: "lamp", sku: "H6008", name: "Desk")
    _ = try await cloud.state(for: device)
    _ = try await cloud.state(for: device)
    let requests = fixture.requests
    #expect(requests.count == 2)
    if requests.count == 2 { #expect(requests[0].1.duration(to: requests[1].1) >= .milliseconds(1990)) }
}

@Test func cancelledCloudCommandIsNotSentWhileQueued() async throws {
    let fixture = CloudFixture([MockResponse(#"{"code":200}"#)]); defer { fixture.finish() }
    let cloud = fixture.cloud
    let device = LightDevice(id: "lamp", sku: "H6008", name: "Desk")
    try await cloud.control(device: device, command: .power(true))
    let queued = Task { try await cloud.control(device: device, command: .power(false)) }
    queued.cancel()
    await #expect(throws: CancellationError.self) { try await queued.value }
    #expect(fixture.requests.count == 1)
}
