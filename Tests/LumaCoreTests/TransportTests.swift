import Foundation
import Testing
@testable import LumaCore

private struct MockResponse: Sendable {
    let status: Int
    let body: String
    var error: URLError.Code?
    init(_ body: String, status: Int = 200) { self.body = body; self.status = status }
    static func failure(_ code: URLError.Code) -> MockResponse { var response = MockResponse(""); response.error = code; return response }
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
        if let code = fixture.error { client?.urlProtocol(self, didFailWithError: URLError(code)); return }
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

@Test func cloudDeviceListPreservesAdvertisedCapabilitiesAndTagsNonLights() async throws {
    let fixture = CloudFixture([MockResponse(#"{"code":200,"data":[{"device":"lamp","sku":"H6008","deviceName":"Desk","type":"devices.types.light","capabilities":[{"type":"devices.capabilities.range","instance":"brightness","parameters":{"dataType":"INTEGER","range":{"min":1,"max":100}}}]},{"device":"heater","sku":"H7130","type":"devices.types.heater","capabilities":[]}]}"#)])
    defer { fixture.finish() }
    let lights = try await fixture.cloud.devices()
    #expect(lights.count == 2)
    #expect(lights.first?.name == "Desk" && lights.first?.deviceType == nil)
    #expect(lights.last?.deviceType == "devices.types.heater")
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

@Test func cloudReadRetriesOnceAfterTimeoutWithPacing() async throws {
    let body = #"{"code":200,"payload":{"capabilities":[{"instance":"online","state":{"value":true}}]}}"#
    let fixture = CloudFixture([.failure(.timedOut), MockResponse(body)]); defer { fixture.finish() }
    let updated = try await fixture.cloud.state(for: LightDevice(id: "lamp", sku: "H6008", name: "Desk"))
    #expect(updated.online == true)
    let requests = fixture.requests
    #expect(requests.count == 2)
    if requests.count == 2 { #expect(requests[0].1.duration(to: requests[1].1) >= .milliseconds(1990)) }
}

@Test func cloudReadTimeoutTwiceReportsActionableRedactedError() async throws {
    let fixture = CloudFixture([.failure(.timedOut), .failure(.timedOut)]); defer { fixture.finish() }
    do {
        _ = try await fixture.cloud.devices()
        Issue.record("Expected a timeout")
    } catch {
        let text = error.localizedDescription
        #expect(text.contains("no response for 20 seconds while listing devices after 2 attempts"))
        #expect(text.contains("URLError -1001"))
        #expect(!text.contains("test-api-key"))
    }
    #expect(fixture.requests.count == 2)
}

@Test func cloudCommandTimeoutIsNeverRetried() async throws {
    let fixture = CloudFixture([.failure(.timedOut), MockResponse(#"{"code":200}"#)]); defer { fixture.finish() }
    let device = LightDevice(id: "secret-lamp-id", sku: "H6008", name: "Bedroom")
    do {
        try await fixture.cloud.control(device: device, command: .power(true))
        Issue.record("Expected a timeout")
    } catch {
        let text = error.localizedDescription
        #expect(text.contains("may or may not have applied it; it was not retried"))
        #expect(!text.contains("secret-lamp-id") && !text.contains("Bedroom") && !text.contains("test-api-key"))
    }
    #expect(fixture.requests.count == 1)
}

@Test func cloudReadDoesNotRetryHTTPOrNonTransientFailures() async throws {
    let fixture = CloudFixture([MockResponse("{}", status: 500), .failure(.badServerResponse), MockResponse(#"{"code":200,"data":[]}"#)]); defer { fixture.finish() }
    let cloud = fixture.cloud
    await #expect(throws: LumaError.self) { _ = try await cloud.devices() }
    #expect(fixture.requests.count == 1)
    await #expect(throws: LumaError.self) { _ = try await cloud.devices() }
    #expect(fixture.requests.count == 2)
}

@Test func cancellingDuringReadRetryWaitSendsNoSecondRequest() async throws {
    let fixture = CloudFixture([.failure(.timedOut), MockResponse(#"{"code":200,"data":[]}"#)]); defer { fixture.finish() }
    let cloud = fixture.cloud
    let read = Task { try await cloud.devices() }
    for _ in 0..<200 where fixture.requests.isEmpty { try await Task.sleep(for: .milliseconds(5)) }
    #expect(fixture.requests.count == 1)
    read.cancel()
    await #expect(throws: CancellationError.self) { _ = try await read.value }
    try await Task.sleep(for: .milliseconds(2100))
    #expect(fixture.requests.count == 1)
}

@Test func cloudStateReadsDreamViewOnlyWhenReported() async throws {
    let fixture = CloudFixture([
        MockResponse(#"{"code":200,"payload":{"capabilities":[{"instance":"online","state":{"value":true}},{"instance":"dreamViewToggle","state":{"value":1}}]}}"#),
        MockResponse(#"{"code":200,"payload":{"capabilities":[{"instance":"online","state":{"value":true}},{"instance":"dreamViewToggle","state":{"value":""}}]}}"#)
    ])
    defer { fixture.finish() }
    let device = LightDevice(id: "tv", sku: "H6097", name: "TV")
    #expect(try await fixture.cloud.state(for: device).dreamView == true)
    #expect(try await fixture.cloud.state(for: device).dreamView == nil)
}

@Test func dreamViewUsesAdvertisedToggleAndMovieSceneEndsWithSync() throws {
    let toggle = Capability(type: "devices.capabilities.toggle", instance: "dreamViewToggle", parameters: .object([
        "dataType": .string("ENUM"), "options": .array([.object(["name": .string("on"), "value": .number(1)]), .object(["name": .string("off"), "value": .number(0)])])
    ]))
    let tv = LightDevice(id: "tv", sku: "H6097", name: "TV", capabilities: [.init(type: "devices.capabilities.on_off", instance: "powerSwitch"), toggle])
    #expect(try DreamView.command(on: false, for: tv) == .init(type: "devices.capabilities.toggle", instance: "dreamViewToggle", value: .number(0)))
    let scene = try DreamView.movieScene(for: tv)
    #expect(scene.steps.map(\.command.instance) == ["powerSwitch", "dreamViewToggle"])
    #expect(scene.steps.last?.command.value == .number(1))
    try CommandValidation.validateScene(scene, devices: [tv])
    #expect(throws: (any Error).self) { try DreamView.command(on: true, for: LightDevice(id: "lamp", sku: "H6008", name: "Lamp")) }
}

@Test func goveeHomeImportPlansRoomsWithoutCreatingLights() throws {
    let file = #"""
    {"status":200,"data":{"groups":[{"groupId":7,"groupName":"  Den  "},{"groupId":8,"groupName":""}],"devices":[
        {"device":"aa:bb","sku":"H6097","deviceName":"TV","groupId":7,"deviceExt":{"secret":"ignored"}},
        {"device":"CC:DD","sku":"H6008","deviceName":"Lamp","groupId":7},
        {"device":"EE:FF","sku":"H6008","deviceName":"Desk","groupId":99},
        {"device":"11:22","sku":"H6008","deviceName":"Hall","groupId":7},
        {"device":"33:44","sku":"H6008","deviceName":"New","groupId":7}]}}
    """#
    let entries = try GoveeHomeImport.parse(Data(file.utf8))
    #expect(entries.first?.room == "Den")
    let devices = [
        LightDevice(id: "AA:BB", sku: "H6097", name: "TV"),
        LightDevice(id: "CC:DD", sku: "H6008", name: "Lamp", room: "Office"),
        LightDevice(id: "EE:FF", sku: "H6008", name: "Desk"),
        LightDevice(id: "11:22", sku: "H6199", name: "Other model")
    ]
    let plan = GoveeHomeImport.plan(entries, devices: devices)
    #expect(plan.changes.map(\.deviceID) == ["AA:BB", "CC:DD"])
    #expect(plan.changes.map(\.selectedByDefault) == [true, false])
    #expect(plan.withoutRoom == 1)
    #expect(plan.notInLuma.map(\.name) == ["Hall", "New"])
    #expect(throws: (any Error).self) { try GoveeHomeImport.parse(Data(#"{"status":401,"message":"no"}"#.utf8)) }
    #expect(throws: (any Error).self) { try GoveeHomeImport.parse(Data(#"{"data":{}}"#.utf8)) }
}

@Test func goveeAccountSignsInWithEmailCodeWithoutLeakingSecrets() async throws {
    let fixture = CloudFixture([
        MockResponse(#"{"status":454,"message":"need code for person@example.com"}"#),
        MockResponse(#"{"status":200,"message":"sent"}"#),
        MockResponse(#"{"status":200,"client":{"token":"tok-1","tokenExpireTime":1893456000000,"accountId":1,"topic":"t"}}"#),
        MockResponse(#"{"status":454}"#),
        MockResponse(#"{"status":401,"message":"Incorrect password hunter2"}"#)
    ])
    defer { fixture.finish() }
    let account = GoveeAccount(clientID: "client-1", session: fixture.session)
    #expect(try await account.login(email: "person@example.com", password: "hunter2") == .needsCode)
    let result = try await account.login(email: "person@example.com", password: "hunter2", code: "123456")
    #expect(result == .signedIn(.init(token: "tok-1", expires: Date(timeIntervalSince1970: 1_893_456_000))))
    for code in ["654321", nil] {
        do { _ = try await account.login(email: "person@example.com", password: "hunter2", code: code); Issue.record("expected a failure") }
        catch { #expect(!error.localizedDescription.contains("hunter2") && !error.localizedDescription.contains("654321")) }
    }
    let requests = fixture.requests.map(\.0)
    let seconds = CloudFixture([MockResponse(#"{"status":200,"client":{"token":"tok-2","tokenExpireTime":1893456000}}"#)])
    defer { seconds.finish() }
    // An expiry in seconds would land in 1970; it is dropped rather than expiring a fresh session.
    #expect(try await GoveeAccount(clientID: "c", session: seconds.session).login(email: "e", password: "p") == .signedIn(.init(token: "tok-2", expires: nil)))
    #expect(requests.map { $0.url?.path } == ["/account/rest/account/v2/login", "/account/rest/account/v1/verification", "/account/rest/account/v2/login", "/account/rest/account/v2/login", "/account/rest/account/v2/login"])
    #expect(requests.allSatisfy { $0.value(forHTTPHeaderField: "clientId") == "client-1" && $0.value(forHTTPHeaderField: "clientType") == "1" && $0.value(forHTTPHeaderField: "Authorization") == nil })
    let verify = try JSONDecoder().decode(JSONValue.self, from: requests[1].httpBody ?? Data())
    #expect(verify == .object(["email": .string("person@example.com"), "type": .number(8)]))
    let withCode = try JSONDecoder().decode(JSONValue.self, from: requests[2].httpBody ?? Data())
    #expect(withCode["code"] == .string("123456") && withCode["client"] == .string("client-1"))
}

@Test func goveeAccountDeviceListUsesBearerAndReportsExpiry() async throws {
    let fixture = CloudFixture([MockResponse(#"{"status":200,"data":{"devices":[],"groups":[]}}"#), MockResponse("{}", status: 401), MockResponse("", status: 302)])
    defer { fixture.finish() }
    let account = GoveeAccount(clientID: "c", session: fixture.session)
    #expect(try GoveeHomeImport.parse(try await account.deviceList(token: "tok")).isEmpty)
    #expect(fixture.requests.first?.0.value(forHTTPHeaderField: "Authorization") == "Bearer tok")
    await #expect(throws: GoveeAccount.SessionExpired.self) { try await account.deviceList(token: "tok") }
    await #expect(throws: LumaError.self) { try await account.deviceList(token: "tok") }
}

@Test func goveeHomeImportReadsBluetoothIdentity() throws {
    // Shape from a live account: deviceSettings is a JSON-encoded string with secrets beside the identity.
    let settings = #"{\"bleName\":\"ihoment_H6097_ABCD\",\"address\":\"AA:BB:CC:DD:EE:FF\",\"secretCode\":\"s3cret\",\"topic\":\"secret-topic\",\"supportEnc\":true}"#
    let file = #"{"status":200,"data":{"groups":[],"devices":[{"device":"tv","sku":"H6097","deviceName":"TV","versionSoft":"1.00.03","deviceExt":{"deviceSettings":"\#(settings)","lastDeviceData":"{\"online\":true}"}}]}}"#
    let entry = try #require(GoveeHomeImport.parse(Data(file.utf8)).first)
    #expect(entry.bleName == "ihoment_H6097_ABCD" && entry.bleAddress == "AA:BB:CC:DD:EE:FF" && entry.firmware == "1.00.03")
    #expect(!String(describing: entry).contains("s3cret") && !String(describing: entry).contains("secret-topic"))
    let plan = GoveeHomeImport.plan([entry], devices: [LightDevice(id: "TV", sku: "H6097", name: "TV")])
    #expect(plan.matched["TV"]?.bleName == entry.bleName)
}

// Synthetic copies of the live general-control/list and automations shapes (2026-11-02).
let groupsFixture = #"{"status":200,"message":"success","data":{"list":[{"groupId":11,"sceneFeastId":22,"name":"Bedroom Dream View","type":10,"enable":1,"deviceCount":2,"isBasedGroup":0,"existCard":1,"devices":null,"createTime":null,"mainDevice":{"bleName":"ihoment_H6097_ABCD","device":"aa:bb","deviceName":"TV","sku":"H6097","versionHard":"3.05.01","versionSoft":"1.00.03"}},{"groupId":12,"sceneFeastId":0,"name":"Kitchen","type":1,"enable":0,"mainDevice":null}]}}"#
let automationsFixture = #"{"status":200,"message":"success","data":{"autoExecs":[{"groupId":5,"name":"Good Night","enable":1,"cmdType":161,"failure":0,"groupSort":0,"schedule":{"type":2,"timerType":0,"preset":1,"presetId":0,"isExpire":0,"repeat":[1,2,3,4,5,6,7],"times":[{"hour":22,"minute":0},{"hour":25,"minute":0}],"startDate":{"day":null,"month":null,"year":null},"endDate":{"day":null,"month":null,"year":null},"skus":[{"sku":"H6056","deviceName":"Bars","subDevice":"","isFeast":0,"feastId":0,"feastName":"","feastType":0,"goodsType":52,"spec":""},{"sku":"H6097","deviceName":"","subDevice":"","isFeast":1,"feastId":22,"feastName":"Bedroom Dream View","feastType":1,"goodsType":273,"spec":""}]}},{"groupId":6,"name":"Good Morning","enable":0,"schedule":{"repeat":[2],"times":[{"hour":7,"minute":0}],"skus":[{"sku":"H6056","deviceName":"Bars"}]}}]}}"#

@Test func goveeHomeGroupsAndAutomationsParseObservedShapes() throws {
    let groups = try GoveeHomeImport.parseGroups(Data(groupsFixture.utf8))
    #expect(groups.map(\.name) == ["Bedroom Dream View", "Kitchen"])
    #expect(groups[0].isDreamView && groups[0].enabled && groups[0].reportedLightCount == 2 && groups[0].mainDevice == "aa:bb" && groups[0].mainSKU == "H6097")
    #expect(!groups[1].isDreamView && !groups[1].enabled && groups[1].mainDevice == nil)
    let autos = try GoveeHomeImport.parseAutomations(Data(automationsFixture.utf8))
    #expect(autos.map(\.name) == ["Good Night", "Good Morning"])
    #expect(autos[0].times == [.init(hour: 22, minute: 0)] && autos[0].everyDay && autos[0].enabled)
    #expect(autos[0].targets == [.init(sku: "H6056", name: "Bars", isDreamView: false), .init(sku: "H6097", name: "Bedroom Dream View", isDreamView: true)])
    #expect(!autos[1].everyDay && !autos[1].enabled)
    #expect(throws: (any Error).self) { try GoveeHomeImport.parseGroups(Data(#"{"status":500}"#.utf8)) }
    #expect(throws: (any Error).self) { try GoveeHomeImport.parseAutomations(Data("<html>".utf8)) }
}

@Test func scheduleConflictsNeedSameMinuteSameLightAndBothEnabled() throws {
    let autos = try GoveeHomeImport.parseAutomations(Data(automationsFixture.utf8))
    let bars = LightDevice(id: "B", sku: "H6056", name: "Bars"), lamp = LightDevice(id: "L", sku: "H6008", name: "Lamp")
    let night = LightScene(name: "Night", steps: [.init(deviceID: "B", command: .power(false))])
    let lampOnly = LightScene(name: "Lamp", steps: [.init(deviceID: "L", command: .power(false))])
    let schedules = [SceneSchedule(sceneID: night.id, hour: 22, minute: 0), SceneSchedule(sceneID: night.id, hour: 22, minute: 1),
                     SceneSchedule(sceneID: lampOnly.id, hour: 22, minute: 0), SceneSchedule(sceneID: night.id, hour: 22, minute: 0, enabled: false),
                     SceneSchedule(sceneID: night.id, hour: 7, minute: 0)] // Good Morning is off in Govee Home
    let found = GoveeHomeImport.conflicts(autos, schedules: schedules, scenes: [night, lampOnly], devices: [bars, lamp])
    #expect(found == [.init(automation: "Good Night", scheduleID: schedules[0].id, light: "Bars")])
}

@Test func goveeAccountGroupAndAutomationReadsAreBearerGets() async throws {
    let fixture = CloudFixture([MockResponse(groupsFixture), MockResponse(automationsFixture), MockResponse("{}", status: 403)])
    defer { fixture.finish() }
    let account = GoveeAccount(clientID: "c", session: fixture.session)
    #expect(try GoveeHomeImport.parseGroups(await account.groups(token: "tok")).count == 2)
    #expect(try GoveeHomeImport.parseAutomations(await account.automations(token: "tok")).count == 2)
    await #expect(throws: GoveeAccount.SessionExpired.self) { try await account.groups(token: "tok") }
    let requests = fixture.requests.map(\.0)
    #expect(requests.map { $0.url?.path } == ["/bff-app/v1/general-control/list", "/bff-app/v1/ecology/resource/automations", "/bff-app/v1/general-control/list"])
    #expect(requests[0].url?.query == "filterEmpty=false")
    #expect(requests.allSatisfy { $0.httpMethod == "GET" && $0.httpBody == nil && $0.value(forHTTPHeaderField: "Authorization") == "Bearer tok" })
}

@Test func compatibilityReportOmitsIdentityAndNetworkDetails() {
    let caps = [Capability(type: "devices.capabilities.on_off", instance: "powerSwitch"),
                Capability(type: "devices.capabilities.segment_color_setting", instance: "segmentedColorRgb", parameters: .object(["dataType": .string("STRUCT")]))]
    let devices = [LightDevice(id: "AA:BB:CC", sku: "H6097", name: "Bedroom TV", room: "Bedroom", ip: "192.168.1.40", capabilities: caps),
                   LightDevice(id: "DD:EE:FF", sku: "H6097", name: "Office TV", ip: "192.168.1.41", capabilities: caps),
                   LightDevice(id: "demo", sku: "Demo", name: "Sample", isDemo: true)]
    let text = CompatibilityReport.text(for: devices, app: "Luma test")
    for secret in ["AA:BB", "DD:EE", "Bedroom", "Office", "192.168", "Sample"] { #expect(!text.contains(secret)) }
    #expect(text.components(separatedBy: "H6097 · cloud + LAN").count == 2) // identical models listed once
    #expect(text.contains("Luma controls: powerSwitch") && text.contains("segmentedColorRgb (segment_color_setting, STRUCT)") && text.contains("up to 7 members"))
}
