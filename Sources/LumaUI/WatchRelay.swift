import LumaCore
#if os(iOS)
import WatchConnectivity
#endif

// Platform-neutral so the Mac test suite covers it.
extension HomeStore {
    var watchSnapshot: WatchSnapshot {
        WatchSnapshot(
            lights: devices.map { .init(id: $0.id, name: $0.name, room: $0.room, power: $0.power, brightness: $0.brightness, rgb: $0.rgb, online: $0.online, canDim: $0.supports("brightness")) },
            scenes: home.scenes.map { .init(id: $0.id, name: $0.name, symbol: $0.symbol) },
            runningSceneID: runningSceneID, demo: demo)
    }

    /// Runs a watch request through the same paths as the phone's own controls.
    func handleWatch(_ request: WatchRequest) {
        switch request {
        case .power(let ids, let on):
            let known = devices.filter { $0.supports("powerSwitch") && (ids.isEmpty || ids.contains($0.id)) }.map(\.id)
            perform(.power(on), ids: known)
        case .brightness(let id, let value):
            guard devices.contains(where: { $0.id == id && $0.supports("brightness") }) else { return }
            perform(.brightness(min(max(value, 1), 100)), ids: [id])
        case .runScene(let id):
            guard let scene = home.scenes.first(where: { $0.id == id }) else { return }
            do { try runScene(scene) } catch { log("Watch: \(error.localizedDescription)", error: true) }
        case .stopScene:
            stopScene()
        case .refresh:
            break
        }
    }
}

#if os(iOS)
/// Sends the home to the Apple Watch app and runs its requests. iOS wakes Luma
/// in the background for a watch message, so the phone needn't be open.
final class WatchRelay: NSObject, WCSessionDelegate {
    private weak var store: HomeStore?

    func start(_ store: HomeStore) {
        guard WCSession.isSupported() else { return }
        self.store = store
        WCSession.default.delegate = self
        WCSession.default.activate()
    }

    func publish(_ snapshot: WatchSnapshot) {
        let session = WCSession.default
        guard WCSession.isSupported(), session.activationState == .activated, session.isWatchAppInstalled,
              let context = try? snapshot.encoded() else { return }
        try? session.updateApplicationContext(context)
    }

    nonisolated func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: (any Error)?) {
        Task { @MainActor in if let store = self.store { self.publish(store.watchSnapshot) } }
    }
    nonisolated func sessionWatchStateDidChange(_ session: WCSession) {
        Task { @MainActor in if let store = self.store { self.publish(store.watchSnapshot) } }
    }
    nonisolated func sessionDidBecomeInactive(_ session: WCSession) {}
    nonisolated func sessionDidDeactivate(_ session: WCSession) { session.activate() }

    nonisolated func session(_ session: WCSession, didReceiveMessage message: [String: Any], replyHandler: @escaping ([String: Any]) -> Void) {
        guard let request = WatchRequest.decode(message) else { replyHandler([:]); return }
        let reply = SendableReply(replyHandler)
        Task { @MainActor in
            guard let store = self.store else { reply([:]); return }
            store.handleWatch(request)
            reply((try? store.watchSnapshot.encoded()) ?? [:])
        }
    }
}

/// WatchConnectivity's reply handler isn't marked Sendable.
private nonisolated struct SendableReply: @unchecked Sendable {
    let send: ([String: Any]) -> Void
    init(_ send: @escaping ([String: Any]) -> Void) { self.send = send }
    func callAsFunction(_ value: [String: Any]) { send(value) }
}
#endif
