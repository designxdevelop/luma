import SwiftUI
import Observation
import WatchConnectivity
import LumaCore

@main struct LumaWatchApp: App {
    @State private var model = WatchModel()
    var body: some Scene {
        WindowGroup { HomeView(model: model).tint(Color(red: 1, green: 0.64, blue: 0.28)) }
    }
}

/// The phone's home, mirrored. Every action is a request to the iPhone app,
/// which controls the lights and replies with the updated home.
@MainActor @Observable final class WatchModel: NSObject, WCSessionDelegate {
    var snapshot: WatchSnapshot?
    var problem: String?
    /// `--demo`: sample home on the watch alone, no iPhone involved.
    private var localDemo = false

    override init() {
        super.init()
        if ProcessInfo.processInfo.arguments.contains("--demo") { snapshot = .sample; localDemo = true; return }
        guard WCSession.isSupported() else { problem = "Watch connectivity isn't available."; return }
        WCSession.default.delegate = self
        WCSession.default.activate()
    }

    func send(_ request: WatchRequest) {
        if localDemo { snapshot?.apply(request); return }
        // Show the result right away; the phone's reply replaces it.
        snapshot?.apply(request)
        guard WCSession.default.isReachable, let message = try? request.encoded() else {
            problem = "Open Luma on your iPhone, then try again."; return
        }
        WCSession.default.sendMessage(message, replyHandler: { reply in
            let next = WatchSnapshot.decode(reply)
            Task { @MainActor in if let next { self.snapshot = next }; self.problem = nil }
        }, errorHandler: { error in
            Task { @MainActor in self.problem = error.localizedDescription }
        })
    }

    nonisolated func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: (any Error)?) {
        let context = WatchSnapshot.decode(session.receivedApplicationContext)
        Task { @MainActor in
            if let context { self.snapshot = context }
            if let error { self.problem = error.localizedDescription }
            // The phone may have nothing to send yet; ask instead of waiting.
            if self.snapshot == nil, WCSession.default.isReachable { self.send(.refresh) }
        }
    }
    nonisolated func sessionReachabilityDidChange(_ session: WCSession) {
        Task { @MainActor in if self.snapshot == nil, WCSession.default.isReachable { self.send(.refresh) } }
    }
    nonisolated func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) {
        let next = WatchSnapshot.decode(applicationContext)
        Task { @MainActor in if let next { self.snapshot = next; self.problem = nil } }
    }
}

extension WatchSnapshot {
    /// Optimistic local copy of a request's effect.
    mutating func apply(_ request: WatchRequest) {
        switch request {
        case .power(let ids, let on): for i in lights.indices where ids.isEmpty || ids.contains(lights[i].id) { lights[i].power = on }
        case .brightness(let id, let value): if let i = lights.firstIndex(where: { $0.id == id }) { lights[i].brightness = value }
        case .runScene(let id): runningSceneID = id
        case .stopScene: runningSceneID = nil
        case .refresh: break
        }
    }

    static let sample = WatchSnapshot(
        lights: [
            .init(id: "demo-desk", name: "Desk lights", room: "Office", power: true, brightness: 80, rgb: 0xFFB866, online: true, canDim: true),
            .init(id: "demo-sofa", name: "Behind the sofa", room: "Living room", power: true, brightness: 55, rgb: 0x9B6BFF, online: true, canDim: true),
            .init(id: "demo-bed", name: "Bedside", room: "Bedroom", power: false, brightness: 25, rgb: 0xFFC58B, online: true, canDim: true)
        ],
        scenes: [.init(id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!, name: "Evening unwind", symbol: "moon.stars"),
                 .init(id: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!, name: "Focus time", symbol: "sun.max")],
        demo: true)
}

struct HomeView: View {
    let model: WatchModel
    var body: some View {
        NavigationStack {
            List {
                if let problem = model.problem {
                    Label(problem, systemImage: "iphone.slash").font(.footnote).foregroundStyle(.secondary)
                }
                if let home = model.snapshot {
                    if home.lights.isEmpty {
                        Text("Add lights in Luma on your iPhone.").foregroundStyle(.secondary)
                    } else {
                        HStack {
                            Button { model.send(.power(ids: [], on: true)) } label: { Label("On", systemImage: "lightbulb.max") }
                            Button { model.send(.power(ids: [], on: false)) } label: { Label("Off", systemImage: "lightbulb.slash") }
                        }
                        .buttonStyle(.bordered)
                        .listRowBackground(Color.clear)
                    }
                    if !home.scenes.isEmpty {
                        Section("Scenes") {
                            ForEach(home.scenes) { scene in
                                let running = home.runningSceneID == scene.id
                                Button { model.send(running ? .stopScene : .runScene(scene.id)) } label: {
                                    Label(scene.name, systemImage: running ? "stop.fill" : scene.symbol)
                                }
                                .accessibilityLabel(running ? "Stop \(scene.name)" : "Run \(scene.name)")
                            }
                        }
                    }
                    if !home.lights.isEmpty {
                        Section("Lights") {
                            ForEach(home.lights) { light in
                                NavigationLink { LightView(model: model, id: light.id) } label: { LightRow(light: light) }
                            }
                        }
                    }
                } else if model.problem == nil {
                    ProgressView("Waiting for iPhone…")
                }
            }
            .navigationTitle("Luma")
        }
    }
}

struct LightRow: View {
    let light: WatchSnapshot.Light
    var body: some View {
        HStack {
            Circle().fill(light.power == true ? Color(rgb: light.rgb ?? 0xFFB866) : .gray.opacity(0.4)).frame(width: 12, height: 12)
            VStack(alignment: .leading) {
                Text(light.name).lineLimit(1)
                Text(light.online == false ? "Offline" : light.power == true ? "On · \(light.brightness ?? 100)%" : "Off")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

struct LightView: View {
    let model: WatchModel
    let id: String
    var body: some View {
        if let light = model.snapshot?.lights.first(where: { $0.id == id }) {
            ScrollView {
                VStack(spacing: 12) {
                    Toggle("Power", isOn: Binding(get: { light.power == true }, set: { model.send(.power(ids: [id], on: $0)) }))
                    if light.canDim {
                        Text("\(light.brightness ?? 100)%").font(.title2.monospacedDigit())
                        // Digital Crown or taps; the phone collapses rapid changes to the latest value.
                        Slider(value: Binding(get: { Double(light.brightness ?? 100) }, set: { model.send(.brightness(id: id, value: Int($0))) }),
                               in: 1...100, step: 5) { Text("Brightness") }
                    }
                }
            }
            .navigationTitle(light.name)
        } else {
            Text("This light is no longer available.").foregroundStyle(.secondary)
        }
    }
}

private extension Color {
    init(rgb: Int) { self.init(red: Double((rgb >> 16) & 255) / 255, green: Double((rgb >> 8) & 255) / 255, blue: Double(rgb & 255) / 255) }
}
