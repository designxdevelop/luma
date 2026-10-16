import Foundation
import Testing
import LumaCore
@testable import Luma

private struct InteractionReply: Sendable {
    var body = #"{"code":200}"#
    var status = 200
    var held = false
    static func state(brightness: Int = 100, power: Bool = false, held: Bool = false) -> Self {
        .init(body: "{\"code\":200,\"payload\":{\"device\":\"interaction-lamp\",\"sku\":\"H6008\",\"capabilities\":[{\"instance\":\"online\",\"state\":{\"value\":true}},{\"instance\":\"brightness\",\"state\":{\"value\":\(brightness)}},{\"instance\":\"powerSwitch\",\"state\":{\"value\":\(power ? 1 : 0)}}]}}", held: held)
    }
}

/// Each test has its own session ID. Gates hold actual URLSession responses, so
/// assertions run at known network boundaries rather than guessed sleep times.
private final class InteractionScript: @unchecked Sendable {
    private let lock = NSLock()
    private var replies: [InteractionReply]
    private var requests: [URLRequest] = []
    private var heldResponses: [Int: @Sendable () -> Void] = [:]
    private var observers: [(Int, CheckedContinuation<Void, Never>)] = []
    init(_ replies: [InteractionReply]) { self.replies = replies }
    func receive(_ request: URLRequest, deliver: @escaping @Sendable (InteractionReply) -> Void) {
        let result = lock.withLock { () -> (InteractionReply, Bool, [CheckedContinuation<Void, Never>]) in
            let index = requests.count
            requests.append(request)
            let reply = index < replies.count ? replies[index] : InteractionReply(status: 500)
            if reply.held { heldResponses[index] = { deliver(reply) } }
            let ready = observers.filter { $0.0 <= requests.count }.map(\.1)
            observers.removeAll { $0.0 <= requests.count }
            return (reply, reply.held, ready)
        }
        for observer in result.2 { observer.resume() }
        if !result.1 { deliver(result.0) }
    }
    func waitForRequestCount(_ count: Int) async {
        await withCheckedContinuation { continuation in
            let ready = lock.withLock { () -> Bool in
                if requests.count >= count { return true }
                observers.append((count, continuation)); return false
            }
            if ready { continuation.resume() }
        }
    }
    func release(_ index: Int) { lock.withLock { heldResponses.removeValue(forKey: index) }?() }
    var commands: [JSONValue] {
        lock.withLock {
            requests.filter { $0.url?.path.hasSuffix("/control") == true }.compactMap {
                guard let body = $0.httpBody else { return nil }
                return (try? JSONDecoder().decode(JSONValue.self, from: body))?["payload"]?["capability"]
            }
        }
    }
}

private final class InteractionRegistry: @unchecked Sendable {
    private let lock = NSLock()
    private var scripts: [String: InteractionScript] = [:]
    func install(_ script: InteractionScript, id: String) { lock.withLock { scripts[id] = script } }
    func script(for request: URLRequest) -> InteractionScript? {
        lock.withLock { scripts[request.value(forHTTPHeaderField: "X-Luma-Interaction-Test") ?? ""] }
    }
    func remove(_ id: String) { _ = lock.withLock { scripts.removeValue(forKey: id) } }
}

private final class InteractionProtocol: URLProtocol, @unchecked Sendable {
    static let registry = InteractionRegistry()
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        var captured = request
        if captured.httpBody == nil, let stream = captured.httpBodyStream {
            stream.open(); defer { stream.close() }
            var body = Data()
            var buffer = [UInt8](repeating: 0, count: 4096)
            while true {
                let count = stream.read(&buffer, maxLength: buffer.count)
                guard count > 0 else { break }
                body.append(contentsOf: buffer.prefix(count))
            }
            captured.httpBody = body
        }
        Self.registry.script(for: captured)?.receive(captured) { [self] reply in
            guard let url = request.url,
                  let response = HTTPURLResponse(url: url, statusCode: reply.status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"]) else { return }
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(reply.body.utf8))
            client?.urlProtocolDidFinishLoading(self)
        }
    }
    override func stopLoading() {}
}

@MainActor private struct InteractionFixture {
    let id = UUID().uuidString
    let script: InteractionScript
    let session: URLSession
    let store: HomeStore
    init(_ replies: [InteractionReply]) {
        script = InteractionScript(replies)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [InteractionProtocol.self]
        configuration.httpAdditionalHeaders = ["X-Luma-Interaction-Test": id]
        session = URLSession(configuration: configuration)
        InteractionProtocol.registry.install(script, id: id)
        store = HomeStore(demo: true, cloud: GoveeCloud(apiKey: "fake-interaction-key-\(id)", session: session))
        store.home.devices = [.init(id: "interaction-lamp", sku: "H6008", name: "Test light", capabilities: [
            .init(type: "devices.capabilities.on_off", instance: "powerSwitch"),
            .init(type: "devices.capabilities.range", instance: "brightness")
        ], power: false, brightness: 100, online: true)]
        store.notice = nil
    }
    func finish() { store.shutdown(); session.invalidateAndCancel(); InteractionProtocol.registry.remove(id) }
    func perform(_ command: CapabilityCommand) { store.perform(command, ids: ["interaction-lamp"]) }
    func waitUntilSettled() async {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while store.controlStatus(for: "interaction-lamp") != nil, ContinuousClock.now < deadline { await Task.yield() }
        #expect(store.controlStatus(for: "interaction-lamp") == nil)
    }
}

@MainActor struct ControlInteractionTests {
    @Test(.timeLimit(.minutes(1))) func delayedFortyPercentTelemetryCannotUndoNewHundredPercentRequest() async {
        let fixture = InteractionFixture([.init(), .state(brightness: 40, held: true), .init(), .state()])
        defer { fixture.finish() }
        fixture.perform(.brightness(40))
        await fixture.script.waitForRequestCount(2)
        fixture.perform(.brightness(100))
        #expect(fixture.store.devices.first?.brightness == 100)
        #expect(fixture.store.home.devices.first?.brightness == 100)
        fixture.script.release(1)
        await fixture.script.waitForRequestCount(3)
        #expect(fixture.store.devices.first?.brightness == 100)
        #expect(fixture.store.home.devices.first?.brightness == 100)
        await fixture.script.waitForRequestCount(4)
        await fixture.waitUntilSettled()
        #expect(fixture.store.devices.first?.brightness == 100)
        #expect(fixture.script.commands.compactMap { $0["value"]?.number } == [40, 100])
    }

    @Test(.timeLimit(.minutes(1))) func delayedLANCallbackCannotUndoNewerConfirmedBrightness() async throws {
        let fixture = InteractionFixture([.init(), .state(held: true)])
        defer { fixture.finish() }
        fixture.store.home.devices[0].brightness = 40
        let sending = Task { try await fixture.store.send(.brightness(100), to: "interaction-lamp") }
        await fixture.script.waitForRequestCount(2)
        #expect(fixture.store.controlStatus(for: "interaction-lamp") == "Waiting for light…")
        #expect(fixture.store.home.devices.first?.brightness == 40)

        // Simulate the GoveeLAN callback contract. This documentation-only IP is
        // attached after the cloud write starts; no real LAN transport is used.
        let confirmation = LightDevice(id: "INTERACTION-LAMP", sku: "H6008", name: "LAN callback", ip: "192.0.2.1", brightness: 100, online: true)
        fixture.store.merge(confirmation)
        #expect(fixture.store.controlStatus(for: "interaction-lamp") == nil)
        #expect(fixture.store.home.devices.first?.brightness == 100)

        var delayed = confirmation
        delayed.id = "Interaction-Lamp"
        delayed.brightness = 40
        fixture.store.merge(delayed)
        #expect(fixture.store.devices.count == 1)
        #expect(fixture.store.devices.first?.brightness == 100)
        #expect(fixture.store.home.devices.first?.brightness == 100)

        fixture.script.release(1)
        try await sending.value
        #expect(fixture.store.devices.first?.brightness == 100)
        #expect(fixture.store.home.devices.first?.brightness == 100)
    }

    @Test(.timeLimit(.minutes(1))) func rapidPowerToggleUsesRequestedStateOnEveryClick() async {
        let fixture = InteractionFixture([.init(held: true), .init(), .state()])
        defer { fixture.finish() }
        fixture.perform(.power(true))
        #expect(fixture.store.devices.first?.power == true)
        #expect(fixture.store.home.devices.first?.power == false)
        await fixture.script.waitForRequestCount(1)
        // The view computes its next toggle from the same projected device list.
        fixture.perform(.power(!(fixture.store.devices.first?.power ?? false)))
        #expect(fixture.store.devices.first?.power == false)
        #expect(fixture.store.controlStatus(for: "interaction-lamp") != nil)
        fixture.script.release(0)
        await fixture.script.waitForRequestCount(3)
        await fixture.waitUntilSettled()
        #expect(fixture.store.devices.first?.power == false)
        #expect(fixture.script.commands.compactMap { $0["value"]?.number } == [1, 0])
    }

    @Test(.timeLimit(.minutes(1))) func unsentSliderEditsCoalesceAndLatestValueIsSentLast() async {
        let fixture = InteractionFixture([.init(held: true), .init(), .state()])
        defer { fixture.finish() }
        fixture.perform(.brightness(40))
        await fixture.script.waitForRequestCount(1)
        fixture.perform(.brightness(50)); fixture.perform(.brightness(60)); fixture.perform(.brightness(100))
        #expect(fixture.store.devices.first?.brightness == 100)
        #expect(fixture.script.commands.count == 1)
        fixture.script.release(0)
        await fixture.script.waitForRequestCount(3)
        await fixture.waitUntilSettled()
        #expect(fixture.script.commands.compactMap { $0["value"]?.number } == [40, 100])
        #expect(fixture.store.home.devices.first?.brightness == 100)
    }

    @Test(.timeLimit(.minutes(1))) func queuedDifferentCapabilitiesRetainOrderAndBothConfirm() async {
        let fixture = InteractionFixture([.init(held: true), .init(), .init(), .state(power: true)])
        defer { fixture.finish() }
        fixture.perform(.brightness(40))
        await fixture.script.waitForRequestCount(1)
        fixture.perform(.power(true)); fixture.perform(.brightness(100))
        fixture.script.release(0)
        await fixture.script.waitForRequestCount(4)
        await fixture.waitUntilSettled()
        #expect(fixture.script.commands.compactMap { $0["instance"]?.string } == ["brightness", "powerSwitch", "brightness"])
        #expect(fixture.script.commands.compactMap { $0["value"]?.number } == [40, 1, 100])
        #expect(fixture.store.home.devices.first?.power == true)
        #expect(fixture.store.home.devices.first?.brightness == 100)
    }

    @Test(.timeLimit(.minutes(1))) func failedLatestWriteRestoresReportedStateAndShowsFailure() async {
        let fixture = InteractionFixture([.init(status: 500, held: true)])
        defer { fixture.finish() }
        fixture.perform(.brightness(40))
        #expect(fixture.store.devices.first?.brightness == 40)
        #expect(fixture.store.home.devices.first?.brightness == 100)
        await fixture.script.waitForRequestCount(1)
        fixture.script.release(0)
        await fixture.waitUntilSettled()
        #expect(fixture.store.devices.first?.brightness == 100)
        #expect(fixture.store.notice?.contains("500") == true)
    }

    @Test(.timeLimit(.minutes(1))) func cancelledExplicitSendIsNeverTransmittedFromQueue() async {
        let fixture = InteractionFixture([.init(held: true), .state(brightness: 60)])
        defer { fixture.finish() }
        fixture.perform(.brightness(60))
        await fixture.script.waitForRequestCount(1)
        let queued = Task { try await fixture.store.send(.brightness(40), to: "interaction-lamp") }
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while fixture.store.devices.first?.brightness != 40, ContinuousClock.now < deadline { await Task.yield() }
        #expect(fixture.store.devices.first?.brightness == 40)
        queued.cancel()
        fixture.script.release(0)
        await #expect(throws: CancellationError.self) { try await queued.value }
        #expect(fixture.script.commands.compactMap { $0["value"]?.number } == [60])
        #expect(fixture.store.devices.first?.brightness != 40)
    }

    @Test(.timeLimit(.minutes(1))) func failedOldWriteCannotClearNewerPendingRequest() async {
        let fixture = InteractionFixture([.init(status: 500, held: true), .init(held: true), .state()])
        defer { fixture.finish() }
        fixture.perform(.brightness(40))
        await fixture.script.waitForRequestCount(1)
        fixture.perform(.brightness(100))
        fixture.script.release(0)
        await fixture.script.waitForRequestCount(2)
        #expect(fixture.store.devices.first?.brightness == 100)
        #expect(fixture.store.controlStatus(for: "interaction-lamp") != nil)
        #expect(fixture.store.notice == nil)
        fixture.script.release(1)
        await fixture.script.waitForRequestCount(3)
        await fixture.waitUntilSettled()
        #expect(fixture.store.devices.first?.brightness == 100)
        #expect(fixture.store.notice == nil)
    }
}
