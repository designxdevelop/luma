import SwiftUI
import LumaCore

/// Automations › Doorbell alert: choose lights and the look, test it, and connect Alexa.
struct DoorbellAlertSection: View {
    @Bindable var store: HomeStore
    @State private var error: String?
    @State private var relayURL = ""
    @State private var relayToken = ""
    @State private var showLights = false

    private var alert: DoorbellAlertController { store.doorbell }
    private var config: DoorbellAlertConfig { alert.config }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader("Doorbell alert")
            Card {
                VStack(alignment: .leading, spacing: 16) {
                    header
                    HStack(alignment: .firstTextBaseline, spacing: 12) {
                        testButton
                        Text(alert.status).font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                            .accessibilityLabel("Last alert: \(alert.status)")
                    }
                    if let error { InlineMessage(text: error) }
                    Divider()
                    targets
                    look
                    quietHours
                    Divider()
                    alexa
                }
            }
        }
    }

    private func edit(_ change: (inout DoorbellAlertConfig) -> Void) {
        do { try alert.update(change); error = nil } catch { self.error = error.localizedDescription }
    }
    private func binding<T>(_ key: WritableKeyPath<DoorbellAlertConfig, T>) -> Binding<T> {
        Binding(get: { config[keyPath: key] }, set: { value in edit { $0[keyPath: key] = value } })
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "bell.badge.fill").font(.system(size: 24)).foregroundStyle(config.enabled ? Color.accentColor : .secondary).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text("Flash lights when the doorbell rings").font(.system(size: 14, weight: .semibold)).fixedSize(horizontal: false, vertical: true)
                    switch alert.phase {
                    case .idle: StatusPill(text: config.enabled ? "On" : "Off", tint: config.enabled ? .success : .secondary)
                    case .starting, .flashing: StatusPill(text: "Flashing", tint: .warning, busy: true)
                    case .restoring: StatusPill(text: "Restoring", tint: .secondary, busy: true)
                    }
                }
                Text("Slow pulses, then each light goes back to exactly how it was.").font(.system(size: 12)).foregroundStyle(.secondary)
            }
            Spacer(minLength: 12)
            Toggle("Doorbell alert", isOn: binding(\.enabled)).labelsHidden().toggleStyle(.switch)
        }
    }

    @ViewBuilder private var testButton: some View {
        if alert.phase == .idle {
            Button("Test Alert", systemImage: "bell") { alert.test() }.buttonStyle(.bordered).disabled(!config.enabled)
                .help(config.enabled ? "Run the alert now on the chosen lights" : "Turn the alert on first")
        } else {
            Button("Stop", systemImage: "stop.fill") { alert.stop() }.buttonStyle(.bordered)
        }
    }

    private var targets: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Rooms").font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
            Text("Lights in these rooms when the bell rings, so a light you add to a room is included. Appliances are never touched.")
                .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            FlowRooms(rooms: Array(Set(store.lights.map(\.room))).sorted(), selected: Set(config.rooms)) { room, on in
                edit { $0.rooms = on ? $0.rooms + [room] : $0.rooms.filter { $0 != room } }
            }
            DisclosureGroup(isExpanded: $showLights) {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(store.lights) { light in
                        Toggle(isOn: Binding(get: { config.deviceIDs.contains(light.id) }, set: { on in
                            edit { $0.deviceIDs = on ? $0.deviceIDs + [light.id] : $0.deviceIDs.filter { $0 != light.id } }
                        })) { Text("\(light.name) · \(light.room)").font(.system(size: 13)) }
                    }
                }.padding(.top, 6)
            } label: {
                Text("Individual lights (\(config.deviceIDs.count))").font(.system(size: 13, weight: .medium))
            }
        }
    }

    private var look: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                ColorPicker("Alert color", selection: Binding(get: { Color(rgb: config.rgb) }, set: { color in
                    if let rgb = rgbValue(of: color) { edit { $0.rgb = rgb } }
                }), supportsOpacity: false).frame(maxWidth: 220, alignment: .leading)
                Spacer()
            }
            Stepper("Length: \(config.durationSeconds) s", value: binding(\.durationSeconds), in: DoorbellAlertConfig.durationRange, step: 5)
            Stepper("Pulse: one every \(config.pulseSeconds.formatted(.number.precision(.fractionLength(0...1)))) s", value: binding(\.pulseSeconds), in: DoorbellAlertConfig.pulseRange, step: 0.5)
            Stepper("Brightest: \(config.brightnessCap)%", value: binding(\.brightnessCap), in: 10...100, step: 10)
            Stepper("Ignore new rings for \(config.cooldownSeconds) s after an alert", value: binding(\.cooldownSeconds), in: DoorbellAlertConfig.cooldownRange, step: 10)
            Text("Lights in Screen or Audio Sync, with DreamView on, or being changed are skipped. Cloud-only lights hold the color instead of pulsing, to stay inside Govee’s limits. Change a light during the alert and it stays as you set it.")
                .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }.font(.system(size: 13))
    }

    private var quietHours: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle("Quiet hours", isOn: Binding(get: { config.quietStart != nil }, set: { on in
                edit { $0.quietStart = on ? 22 * 60 : nil; $0.quietEnd = on ? 7 * 60 : nil }
            }))
            if let start = config.quietStart, let end = config.quietEnd {
                HStack(spacing: 12) {
                    DatePicker("From", selection: minuteBinding(start) { m in edit { $0.quietStart = m } }, displayedComponents: .hourAndMinute)
                    DatePicker("To", selection: minuteBinding(end) { m in edit { $0.quietEnd = m } }, displayedComponents: .hourAndMinute)
                }.fixedSize()
                Stepper(config.quietBrightnessCap == 0 ? "During quiet hours: leave lights alone" : "During quiet hours: up to \(config.quietBrightnessCap)%",
                        value: binding(\.quietBrightnessCap), in: 0...100, step: 10)
            }
        }.font(.system(size: 13))
    }

    private func minuteBinding(_ minute: Int, set: @escaping (Int) -> Void) -> Binding<Date> {
        Binding(get: { Calendar.current.date(bySettingHour: minute / 60, minute: minute % 60, second: 0, of: .now) ?? .now },
                set: { date in let c = Calendar.current.dateComponents([.hour, .minute], from: date); set((c.hour ?? 0) * 60 + (c.minute ?? 0)) })
    }

    @ViewBuilder private var alexa: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text("Alexa and your doorbell").font(.system(size: 14, weight: .semibold))
                StatusPill(text: alert.relayState, tint: alert.relayState.hasPrefix("Connected") ? .success : .secondary)
            }
            Text("An Alexa routine (When the doorbell is pressed → Control scene “Doorbell Alert”) reaches Luma through a small relay you deploy to your own accounts. Luma connects out to it; nothing on this \(PlatformCopy.device) is opened to the internet. Luma must be running and awake\(PlatformCopy.device == "Mac" ? "" : ", and in the foreground on iPhone and iPad").")
                .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if config.relayURL == nil || !alert.relayTokenSaved {
                TextField("Relay address (https://…)", text: $relayURL).textFieldStyle(.roundedBorder).autocorrectionDisabled()
                SecureField("Relay token (HUB_TOKEN)", text: $relayToken).textFieldStyle(.roundedBorder)
                Button("Connect Relay", systemImage: "link") {
                    do { try alert.saveRelay(url: relayURL, token: relayToken); relayToken = ""; error = nil } catch { self.error = error.localizedDescription }
                }.disabled(relayURL.isEmpty || relayToken.isEmpty || store.demo)
            } else {
                HStack(spacing: 8) {
                    Button("Get Pairing Code", systemImage: "number") { Task { await alert.requestPairingCode() } }
                    Button("Unlink Alexa") { Task { await alert.unlinkAlexa() } }
                    Button("Forget Relay", role: .destructive) { do { try alert.forgetRelay() } catch { self.error = error.localizedDescription } }
                }.controlSize(.small)
                if let pairing = alert.pairing {
                    HStack(spacing: 8) {
                        Text(pairing.code).font(.system(size: 22, weight: .semibold, design: .monospaced)).textSelection(.enabled)
                            .accessibilityLabel("Pairing code \(pairing.code.map(String.init).joined(separator: " "))")
                        Text("Enter this when the Alexa app asks you to link Luma. Expires \(Date(timeIntervalSince1970: pairing.expiresAt).formatted(date: .omitted, time: .shortened)).")
                            .font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                }
            }
            Text("Set-up steps: docs/DOORBELL-ALERT.md in the Luma repository. Home Assistant and scripts can also ring with POST /v1/alerts/doorbell on the webhook server.")
                .font(.system(size: 11)).foregroundStyle(.secondary).textSelection(.enabled)
        }
    }
}

/// Room chips that wrap; each toggles the room in or out.
private struct FlowRooms: View {
    let rooms: [String]
    let selected: Set<String>
    let toggle: (String, Bool) -> Void
    var body: some View {
        if rooms.isEmpty { Text("No rooms yet.").font(.system(size: 12)).foregroundStyle(.secondary) }
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 130), alignment: .leading)], alignment: .leading, spacing: 8) {
            ForEach(rooms, id: \.self) { room in
                let on = selected.contains(room)
                Button { toggle(room, !on) } label: {
                    Label(room, systemImage: on ? "checkmark.circle.fill" : "circle").font(.system(size: 13)).lineLimit(1)
                }
                .buttonStyle(.bordered).tint(on ? .accentColor : .secondary)
                .accessibilityAddTraits(on ? .isSelected : [])
            }
        }
    }
}
