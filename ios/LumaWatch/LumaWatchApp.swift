import SwiftUI
import Observation
import WatchConnectivity
import LumaCore

@main struct LumaWatchApp: App {
    @State private var model = WatchModel()
    var body: some Scene {
        WindowGroup { HomeView(model: model).tint(.lumaAccent) }
    }
}

/// The phone's home, mirrored. Every action is a request to the iPhone app,
/// which controls the lights and replies with the updated home. `state` keeps
/// the phone's last report apart from requests still in flight.
@MainActor @Observable final class WatchModel: NSObject, WCSessionDelegate {
    private(set) var state = WatchState()
    /// Set once the phone has stayed out of reach for a few seconds with no home.
    private(set) var gaveUpWaiting = false
    private(set) var unavailable: String?
    /// `--demo`: sample home on the watch alone. `--demo-fail` / `--demo-pending` /
    /// `--demo-unreachable` exercise those states without an iPhone or lights.
    private let demo: Set<String>

    var home: WatchSnapshot? { state.display }
    /// Controls send only while the phone can answer.
    var canSend: Bool { state.reachable && home != nil }

    override init() {
        demo = Set(ProcessInfo.processInfo.arguments.filter { $0.hasPrefix("--demo") })
        super.init()
        if !demo.isEmpty {
            state = WatchState(report: .sample, reachable: !demo.contains("--demo-unreachable"))
            state.receive(.sample)
            return
        }
        guard WCSession.isSupported() else { unavailable = "Watch connectivity isn't available."; return }
        WCSession.default.delegate = self
        WCSession.default.activate()
        Task { try? await Task.sleep(for: .seconds(5)); gaveUpWaiting = true }
    }

    func send(_ request: WatchRequest) {
        guard state.reachable || request == .refresh else { return }
        let nonce = state.begin(request)
        if !demo.isEmpty { return demoReply(nonce, request) }
        guard let message = try? request.encoded() else { return state.fail(nonce, message: "Couldn't encode the request.") }
        // @Sendable: WatchConnectivity calls these on its own queue, not the main actor.
        WCSession.default.sendMessage(message, replyHandler: { @Sendable reply in
            let next = WatchSnapshot.decode(reply)
            Task { @MainActor in self.state.succeed(nonce, reply: next) }
        }, errorHandler: { @Sendable error in
            let message = error.localizedDescription
            Task { @MainActor in self.failed(nonce, message) }
        })
    }

    /// Values shown while the phone is out of reach are its last report.
    func label(_ status: String) -> String { state.reachable ? status : "Last known: \(status)" }

    func retry() { if let request = state.failure?.request { send(request) } }

    /// Try again on "iPhone not reachable": a re-check, not a send.
    func recheck() {
        gaveUpWaiting = false
        if state.setReachable(WCSession.default.isReachable) || state.reachable { send(.refresh) }
        Task { try? await Task.sleep(for: .seconds(5)); gaveUpWaiting = true }
    }

    private func failed(_ nonce: Int, _ message: String) {
        state.fail(nonce, message: message)
        guard let failure = state.failure, failure.nonce == nonce else { return }
        Task { try? await Task.sleep(for: .seconds(4)); if state.failure == failure { state.clearFailure() } }
    }

    private func demoReply(_ nonce: Int, _ request: WatchRequest) {
        if demo.contains("--demo-pending") { return }
        Task {
            try? await Task.sleep(for: .milliseconds(700))
            if demo.contains("--demo-fail") { return failed(nonce, "The iPhone didn't answer.") }
            var next = state.report ?? .sample
            next.apply(request)
            state.succeed(nonce, reply: next)
        }
    }

    private func reachabilityChanged(_ reachable: Bool) {
        // Ask for a fresh home every time the phone comes back, not only when there is none.
        if state.setReachable(reachable) { send(.refresh) }
    }

    nonisolated func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: (any Error)?) {
        let context = WatchSnapshot.decode(session.receivedApplicationContext)
        let reachable = session.isReachable
        let problem = error?.localizedDescription
        Task { @MainActor in
            if let context { self.state.receive(context) }
            if let problem { self.unavailable = problem }
            self.reachabilityChanged(reachable)
            #if DEBUG
            // QA hook: exercise watch → phone without tapping the watch UI.
            if ProcessInfo.processInfo.arguments.contains("--relay-check-all-off") { self.send(.power(ids: [], on: false)) }
            #endif
        }
    }
    nonisolated func sessionReachabilityDidChange(_ session: WCSession) {
        let reachable = session.isReachable
        Task { @MainActor in self.reachabilityChanged(reachable) }
    }
    nonisolated func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) {
        let next = WatchSnapshot.decode(applicationContext)
        Task { @MainActor in if let next { self.state.receive(next) } }
    }
}

extension WatchSnapshot {
    static let sample = WatchSnapshot(
        lights: [
            .init(id: "demo-desk", name: "Desk lights", room: "Office", power: true, brightness: 80, rgb: 0xFFB866, online: true, canDim: true),
            .init(id: "demo-shelf", name: "Bookshelf accent strip by the window", room: "Office", power: false, brightness: 40, rgb: 0x66C2FF, online: false, canDim: true),
            .init(id: "demo-sofa", name: "Behind the sofa", room: "Living room", power: true, brightness: 55, rgb: 0x9B6BFF, online: true, canDim: true),
            .init(id: "demo-plug", name: "Floor lamp plug", room: "Living room", power: false, brightness: nil, rgb: nil, online: true, canDim: false),
            .init(id: "demo-bed", name: "Bedside", room: "Bedroom", power: false, brightness: 25, rgb: 0xFFC58B, online: true, canDim: true),
            .init(id: "demo-porch", name: "Porch", room: "", power: nil, brightness: nil, rgb: nil, online: true, canDim: false)
        ],
        scenes: [.init(id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!, name: "Evening unwind", symbol: "moon.stars"),
                 .init(id: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!, name: "Focus time", symbol: "sun.max")],
        demo: true)
}

// MARK: - Home

private enum WatchDestination: Hashable { case room(String), light(String) }

struct HomeView: View {
    let model: WatchModel
    @State private var path: [WatchDestination] = []
    var body: some View {
        NavigationStack(path: $path) {
            List {
                ConnectionRows(model: model)
                if let home = model.home {
                    if home.lights.isEmpty {
                        Text("Add lights in Luma on your iPhone.").foregroundStyle(.secondary)
                    } else {
                        if !home.scenes.isEmpty {
                            NavigationLink { ScenesView(model: model) } label: {
                                DiscLabel(title: "Scenes", status: home.runningSceneID == nil ? "Run or stop" : "One running",
                                          symbol: "play.fill", tint: .lumaAccent, filled: false)
                            }
                        }
                        Section("Rooms") {
                            ForEach(WatchState.rooms(home.lights)) { room in RoomRow(model: model, room: room) { path.append(.room(room.name)) } }
                        }
                        Section {
                            // Secondary on purpose: room discs and All off are the main controls.
                            Button { model.send(.power(ids: [], on: true)) } label: { Label("All on", systemImage: "lightbulb.max") }
                                .disabled(!model.canSend || model.state.isPending(.power(ids: [], on: true)))
                        } footer: { ReportFooter(model: model) }
                    }
                }
            }
            .navigationDestination(for: WatchDestination.self) { destination in
                switch destination {
                case .room(let name): RoomView(model: model, name: name) { path.append(.light($0)) }
                case .light(let id): LightView(model: model, id: id)
                }
            }
            .navigationTitle("Luma")
            .toolbar {
                if model.home?.lights.isEmpty == false {
                    ToolbarItem(placement: .topBarTrailing) {
                        let sending = model.state.isPending(.power(ids: [], on: false))
                        Button { model.send(.power(ids: [], on: false)) } label: {
                            if sending { ProgressView() } else { Image(systemName: "power") }
                        }
                        .tint(.lumaAccentFill)
                        .disabled(!model.canSend || sending)
                        .accessibilityLabel(sending ? "Turning all off" : "All off")
                    }
                }
            }
        }
    }
}

/// First open, reconnecting, unreachable and failure rows. Copy never claims live state.
struct ConnectionRows: View {
    let model: WatchModel
    var body: some View {
        if let unavailable = model.unavailable {
            Label(unavailable, systemImage: "applewatch.slash").font(.footnote).foregroundStyle(.secondary)
        } else if model.home == nil {
            if model.gaveUpWaiting && !model.state.reachable {
                VStack(alignment: .leading, spacing: 6) {
                    Label("iPhone not reachable", systemImage: "iphone.slash").font(.headline)
                    Text("Keep your iPhone nearby with Luma installed.").font(.footnote).foregroundStyle(.secondary)
                    Button("Try again") { model.recheck() }
                }
            } else {
                ProgressView("Connecting to iPhone…")
            }
        } else if !model.state.reachable {
            Label("Reconnecting…", systemImage: "arrow.triangle.2.circlepath")
                .font(.footnote).foregroundStyle(Color.lumaWarning)
        }
        if let failure = model.state.failure {
            Button { model.retry() } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Label("Didn’t change", systemImage: "exclamationmark.triangle").foregroundStyle(Color.lumaWarning)
                    Text("Tap to try again").font(.footnote).foregroundStyle(.secondary)
                }
            }
            .disabled(!model.canSend)
            .accessibilityHint(failure.message)
        }
    }
}

struct ReportFooter: View {
    let model: WatchModel
    var body: some View {
        if model.home?.demo == true {
            Text("Demo home")
        } else if let at = model.state.reportedAt {
            Text("Last iPhone report \(at, style: .time)")
        }
    }
}

struct RoomRow: View {
    let model: WatchModel
    let room: WatchState.Room
    let open: () -> Void
    var body: some View {
        let online = room.lights.filter { $0.online != false }
        let anyOn = online.contains { $0.power == true }
        let pending = online.contains { model.state.isPending(light: $0.id) }
        HStack(spacing: 8) {
            PowerDisc(on: anyOn, tint: online.first { $0.power == true }.flatMap(\.rgb).map(Color.init(rgb:)) ?? .lumaAccent,
                      pending: pending, offline: online.isEmpty) {
                model.send(.power(ids: online.map(\.id), on: !anyOn))
            }
            .disabled(!model.canSend || online.isEmpty || pending)
            .accessibilityLabel(online.isEmpty ? "\(room.name), offline" : "Turn \(anyOn ? "off" : "on") \(room.name)")
            Button(action: open) {
                RowText(title: room.name, status: pending ? (anyOn ? "Turning on…" : "Turning off…")
                         : model.label(online.isEmpty ? "Offline" : anyOn ? "On" : "Off"))
                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading).contentShape(Rectangle())
            }.buttonStyle(.plain)
        }
    }
}

// MARK: - Room

struct RoomView: View {
    let model: WatchModel
    let name: String
    let openLight: (String) -> Void
    var body: some View {
        let lights = model.home.map { WatchState.rooms($0.lights) }?.first { $0.name == name }?.lights ?? []
        List {
            ConnectionRows(model: model)
            if lights.isEmpty { Text("No lights in this room now.").foregroundStyle(.secondary) }
            ForEach(lights) { light in LightRow(model: model, light: light) { openLight(light.id) } }
        }
        .navigationTitle(name)
    }
}

struct LightRow: View {
    let model: WatchModel
    let light: WatchSnapshot.Light
    let open: () -> Void
    var body: some View {
        let offline = light.online == false
        let pending = model.state.isPending(light: light.id)
        HStack(spacing: 8) {
            PowerDisc(on: light.power == true, tint: light.tint, pending: pending, offline: offline) {
                model.send(.power(ids: [light.id], on: light.power != true))
            }
            .disabled(!model.canSend || offline || pending)
            .accessibilityLabel(offline ? "\(light.name), offline" : "Turn \(light.power == true ? "off" : "on") \(light.name)")
            if offline {
                RowText(title: light.name, status: "Offline").foregroundStyle(.secondary)
                    .accessibilityElement(children: .combine).accessibilityValue("Offline")
            } else {
                Button(action: open) {
                    RowText(title: light.name, status: pending ? (light.power == true ? "Turning on…" : "Turning off…") : model.label(light.statusText))
                        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading).contentShape(Rectangle())
                }.buttonStyle(.plain)
            }
        }
    }
}

// MARK: - Light

struct LightView: View {
    let model: WatchModel
    let id: String
    @Environment(\.dismiss) private var dismiss
    /// The crown's value while turning; sent when the crown rests.
    @State private var crown = 50.0
    @State private var turning = false
    /// The crown only drives a focused view; focus the ring on open.
    @FocusState private var ringFocused: Bool

    var body: some View {
        if let light = model.home?.lights.first(where: { $0.id == id }) {
            let pending = model.state.isPending(light: id)
            let failed = model.state.failure.map { $0.request.affects(light: id) } ?? false
            ScrollView {
                VStack(spacing: 10) {
                    if !model.state.reachable { ConnectionRows(model: model) }
                    if light.canDim && light.online != false {
                        let shown = turning ? WatchState.clampBrightness(crown) : (light.brightness ?? 100)
                        ZStack {
                            Circle().stroke(Color.lumaControl, lineWidth: 8)
                            Circle().trim(from: 0, to: Double(shown) / 100)
                                .stroke(light.power == true ? light.tint : .gray, style: .init(lineWidth: 8, lineCap: .round))
                                .rotationEffect(.degrees(-90))
                            VStack(spacing: 0) {
                                Text("\(shown)%").font(.system(.title, design: .rounded, weight: .bold).monospacedDigit())
                                    .minimumScaleFactor(0.6).lineLimit(1)
                                Text(failed ? "Didn’t change" : pending ? "Updating…" : model.state.reachable ? "Brightness" : "Last known")
                                    .font(.footnote).foregroundStyle(failed ? Color.lumaWarning : pending ? Color.lumaAccent : .secondary)
                            }
                            .padding(.horizontal, 12)
                        }
                        .frame(maxWidth: 130).aspectRatio(1, contentMode: .fit)
                        .focusable(model.canSend)
                        .focused($ringFocused)
                        // watchOS 9+ SDK API: detents by 5, send once the crown rests.
                        .digitalCrownRotation(detent: $crown, from: 0, through: 100, by: 5, sensitivity: .medium,
                                              isContinuous: false, isHapticFeedbackEnabled: true,
                                              onChange: { _ in turning = true },
                                              onIdle: { commit(light) })
                        .accessibilityElement()
                        .accessibilityLabel("Brightness")
                        .accessibilityValue("\(shown) percent")
                        .accessibilityAdjustableAction { direction in
                            let step = direction == .increment ? 5 : direction == .decrement ? -5 : 0
                            send(brightness: Double((light.brightness ?? 100) + step))
                        }
                    }
                    if failed {
                        Button { model.retry() } label: { Label("Try again", systemImage: "arrow.clockwise") }
                            .tint(.lumaWarning).disabled(!model.canSend)
                    }
                    Button { model.send(.power(ids: [id], on: light.power != true)) } label: {
                        Label(light.online == false ? "Offline" : light.power == nil ? "Unknown" : light.power == true ? "On" : "Off",
                              systemImage: "power")
                            .frame(maxWidth: .infinity)
                    }
                    .tint(light.power == true ? light.tint : .lumaControl)
                    .disabled(!model.canSend || pending || light.online == false)
                    .accessibilityLabel("Power")
                    .accessibilityValue(light.power == nil ? "Unknown" : light.power == true ? "On" : "Off")
                }
            }
            .navigationTitle(light.name)
            .onAppear { crown = Double(light.brightness ?? 100); ringFocused = true }
            .onChange(of: light.brightness) { if !turning { crown = Double(light.brightness ?? 100) } }
        } else {
            VStack(spacing: 8) {
                Image(systemName: "lightbulb.slash").font(.title2).foregroundStyle(.secondary)
                Text("Light not found").font(.headline)
                Text("It’s no longer in the iPhone home.").font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
                Button("Back to Home") { dismiss() }
            }
        }
    }

    private func commit(_ light: WatchSnapshot.Light) {
        guard turning else { return }
        turning = false
        if WatchState.clampBrightness(crown) != light.brightness { send(brightness: crown) }
    }
    private func send(brightness: Double) {
        guard model.canSend else { return }
        model.send(.brightness(id: id, value: WatchState.clampBrightness(brightness)))
    }
}

// MARK: - Scenes

struct ScenesView: View {
    let model: WatchModel
    var body: some View {
        let home = model.home
        let busy = model.state.scenePending
        List {
            ConnectionRows(model: model)
            ForEach(home?.scenes ?? []) { scene in
                let running = home?.runningSceneID == scene.id
                let blocked = home?.runningSceneID != nil && !running
                Button { model.send(running ? .stopScene : .runScene(scene.id)) } label: {
                    DiscLabel(title: scene.name,
                              status: busy ? "Updating…" : running ? "Running · Stop" : blocked ? "Stop the running one first" : "Run",
                              symbol: running ? "stop.fill" : scene.symbol, tint: .lumaAccent, filled: running)
                }
                .listRowBackground(running ? RoundedRectangle(cornerRadius: 18).stroke(Color.lumaAccent, lineWidth: 2) : nil)
                .disabled(!model.canSend || busy || blocked)
                .opacity(blocked ? 0.5 : 1)
                .accessibilityLabel(running ? "Stop \(scene.name)" : "Run \(scene.name)")
            }
        }
        .navigationTitle("Scenes")
    }
}

// MARK: - Pieces

struct PowerDisc: View {
    let on: Bool, tint: Color, pending: Bool, offline: Bool
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            ZStack {
                if offline {
                    Circle().strokeBorder(Color.lumaDanger, style: .init(lineWidth: 2, dash: [4, 3]))
                } else {
                    Circle().fill(on ? tint : .lumaControl)
                }
                if pending { ProgressView().scaleEffect(0.6) } else {
                    Image(systemName: offline ? "wifi.slash" : "power").font(.footnote.weight(.bold))
                        .foregroundStyle(offline ? Color.lumaDanger : on ? .black : .secondary)
                }
            }
            .frame(width: 34, height: 34)
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

struct RowText: View {
    let title: String, status: String
    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title).font(.headline).lineLimit(2)
            Text(status).font(.footnote).foregroundStyle(.secondary)
        }
    }
}

struct DiscLabel: View {
    let title: String, status: String, symbol: String, tint: Color, filled: Bool
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: symbol).font(.footnote.weight(.bold))
                .foregroundStyle(filled ? .black : tint)
                .frame(width: 34, height: 34).background(Circle().fill(filled ? tint : .lumaControl))
            RowText(title: title, status: status)
        }
    }
}

extension WatchSnapshot.Light {
    var tint: Color { rgb.map(Color.init(rgb:)) ?? .lumaAccent }
    /// Phrased from the iPhone's report; not a hardware confirmation.
    var statusText: String {
        guard online != false else { return "Offline" }
        switch power {
        case true?: return canDim ? "On · \(brightness ?? 100)%" : "On"
        case false?: return "Off"
        case nil: return "Unknown"
        }
    }
}

private extension Color {
    init(rgb: Int) { self.init(red: Double((rgb >> 16) & 255) / 255, green: Double((rgb >> 8) & 255) / 255, blue: Double(rgb & 255) / 255) }
    // Theme.swift dark values (not in the watch target).
    static let lumaAccent = Color(rgb: 0xFFA347)
    static let lumaAccentFill = Color(rgb: 0xB95500)
    static let lumaWarning = Color(rgb: 0xFFB340)
    static let lumaDanger = Color(rgb: 0xFF6961)
    static let lumaControl = Color(rgb: 0x2C2C2E)
}
