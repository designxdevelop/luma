import SwiftUI
import UniformTypeIdentifiers
import LumaCore

struct AutomationsView: View {
    @Bindable var store: HomeStore
    @State private var selectedScene: UUID?
    @State private var time = Calendar.current.date(bySettingHour: 7, minute: 0, second: 0, of: .now) ?? .now
    @State private var weekdays = Set(1...7)
    @State private var addedMessage: String?
    @State private var showToken = false
    @State private var confirmRotate = false
    @State private var showExamples = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                PageHeader(title: "Automations", subtitle: "Run scenes on a schedule, or let Shortcuts, Home Assistant, and scripts control your lights.")
                schedulesSection
                DoorbellAlertSection(store: store)
                webhooksSection
                if !store.runs.isEmpty { runsSection }
            }
            .pagePadding()
            .frame(maxWidth: 860, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: - Schedules

    private var schedulesSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader("Schedules", detail: store.home.schedules.isEmpty ? nil : "\(store.home.schedules.count)")
            ScheduleSyncCard(store: store)
            if store.home.scenes.isEmpty {
                Card { EmptyState(icon: "clock.badge.questionmark", title: "Create a scene first", message: "A schedule runs a scene at a set time. Save a scene on the Scenes page, then come back to schedule it.") }
            } else {
                newScheduleCard
            }
            ForEach(store.home.schedules) { scheduleRow($0) }
            Text(store.scheduleSync.role == .paired ? "Schedules run on \(store.scheduleSync.client?.runner?.name ?? "the paired computer"), even while Luma is closed here. Missed times are skipped." : PlatformCopy.scheduleNote)
                .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    private var newScheduleCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 16) {
                Text("New schedule").font(.system(size: 13, weight: .semibold))
                HStack(spacing: 16) {
                    Picker("Scene", selection: $selectedScene) {
                        Text("Choose a scene").tag(Optional<UUID>.none)
                        ForEach(store.home.scenes) { Text($0.name).tag(Optional($0.id)) }
                    }.frame(maxWidth: 320)
                    DatePicker("Time", selection: $time, displayedComponents: .hourAndMinute)
                    Spacer(minLength: 0)
                }
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Repeat on").font(.system(size: 12)).foregroundStyle(.secondary)
                        Spacer()
                        Menu("Presets") {
                            Button("Every Day") { weekdays = Set(1...7) }
                            Button("Weekdays") { weekdays = Set(2...6) }
                            Button("Weekends") { weekdays = [1, 7] }
                        }.menuStyle(.button).buttonStyle(.borderless).fixedSize()
                    }
                    HStack(spacing: 8) {
                        ForEach(orderedWeekdays, id: \.self) { day in
                            DayChip(symbol: Calendar.current.veryShortWeekdaySymbols[day - 1], name: Calendar.current.weekdaySymbols[day - 1], isOn: weekdays.contains(day)) {
                                if weekdays.contains(day) { weekdays.remove(day) } else { weekdays.insert(day) }
                            }
                        }
                        Spacer(minLength: 0)
                    }
                }
                HStack(spacing: 12) {
                    Button("Add Schedule", systemImage: "plus") { addSchedule() }
                        .buttonStyle(.borderedProminent)
                        .disabled(selectedScene == nil || weekdays.isEmpty)
                    if selectedScene == nil { Text("Choose a scene to schedule.").font(.system(size: 12)).foregroundStyle(.secondary) }
                    else if weekdays.isEmpty { Text("Pick at least one day.").font(.system(size: 12)).foregroundStyle(.secondary) }
                    else if let addedMessage { InlineMessage(text: addedMessage, isError: false) }
                }
                .task(id: addedMessage) { if addedMessage != nil { try? await Task.sleep(for: .seconds(4)); addedMessage = nil } }
            }
        }
    }

    private func scheduleRow(_ schedule: SceneSchedule) -> some View {
        let scene = store.home.scenes.first { $0.id == schedule.sceneID }
        let timeText = Self.timeText(hour: schedule.hour, minute: schedule.minute)
        let conflict = store.scheduleConflicts.first { $0.scheduleID == schedule.id }
        return Card(padding: 16) {
          VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 14) {
                Toggle("Enable \(scene?.name ?? "schedule") at \(timeText)", isOn: Binding(
                    get: { store.home.schedules.first { $0.id == schedule.id }?.enabled ?? false },
                    set: { value in
                        if let i = store.home.schedules.firstIndex(where: { $0.id == schedule.id }) { store.home.schedules[i].enabled = value; store.persist() }
                    })).labelsHidden().toggleStyle(.switch).controlSize(.small)
                VStack(alignment: .leading, spacing: 3) {
                    if let scene {
                        Label(scene.name, systemImage: scene.symbol).font(.system(size: 14, weight: .medium)).lineLimit(1)
                    } else {
                        Label("Scene was deleted", systemImage: "exclamationmark.triangle.fill").font(.system(size: 14, weight: .medium)).foregroundStyle(Color.warning)
                    }
                    Text(daysSummary(schedule.weekdays)).font(.system(size: 12)).foregroundStyle(.secondary)
                    failoverMenu(schedule)
                }
                .opacity(schedule.enabled ? 1 : 0.55)
                Spacer(minLength: 12)
                VStack(alignment: .trailing, spacing: 3) {
                    Text(timeText).font(.system(size: 17, weight: .semibold)).monospacedDigit()
                    Text(statusText(schedule))
                        .font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
                }
                .opacity(schedule.enabled ? 1 : 0.55)
                Menu {
                    Button("Pause Until Tomorrow") { setPause(schedule, Calendar.current.startOfDay(for: .now.addingTimeInterval(86_400)).addingTimeInterval(12 * 3600)) }
                    Button("Pause for a Week") { setPause(schedule, .now.addingTimeInterval(7 * 86_400)) }
                    if (schedule.pausedUntil ?? .distantPast) > .now { Button("Resume") { setPause(schedule, nil) } }
                } label: { Image(systemName: "pause.circle") }
                    .menuStyle(.borderlessButton).fixedSize().help("Pause schedule").accessibilityLabel("Pause schedule")
                Button { store.home.schedules.removeAll { $0.id == schedule.id }; store.persist() } label: { Image(systemName: "trash") }
                    .buttonStyle(.borderless).help("Delete schedule").accessibilityLabel("Delete schedule")
            }
            ScheduleRunLine(store: store, schedule: schedule)
            if let conflict {
                Label("Govee Home automation “\(conflict.automation)” also changes \(conflict.light) at this time. Whichever runs last wins; Govee's days weren't compared.", systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 11)).foregroundStyle(Color.warning).fixedSize(horizontal: false, vertical: true)
            }
          }
        }
    }

    /// Primary/fallback choice for same-account failover. Without it, the schedule stays on its original device.
    private func failoverMenu(_ schedule: SceneSchedule) -> some View {
        let coordination = store.coordinations[schedule.id]
        let name = { (id: String?) in store.schedulerDevices.first { $0.id == id }?.name ?? "Unknown device" }
        let summary = coordination.map { "Runs on \(name($0.primary))" + ($0.fallback.map { ", fallback \(name($0))" } ?? "") } ?? "Runs on its original device"
        return VStack(alignment: .leading, spacing: 2) {
            Menu(summary) {
                Section("Primary") {
                    ForEach(store.schedulerDevices) { device in
                        Button(device.name) {
                            var next = coordination ?? ScheduleCoordination(primary: device.id)
                            next.primary = device.id
                            if next.fallback == device.id { next.fallback = nil }
                            store.setCoordination(next, for: schedule.id)
                        }
                    }
                }
                if let coordination {
                    Section("Fallback if primary is offline") {
                        Button("None") { var next = coordination; next.fallback = nil; store.setCoordination(next, for: schedule.id) }
                        ForEach(store.schedulerDevices.filter { $0.id != coordination.primary }) { device in
                            Button(device.name) { var next = coordination; next.fallback = device.id; store.setCoordination(next, for: schedule.id) }
                        }
                    }
                    Button("Stop coordinating (run on this device)") { store.setCoordination(nil, for: schedule.id) }
                }
            }
            .menuStyle(.button).buttonStyle(.borderless).fixedSize().font(.system(size: 12)).disabled(!store.coordinatedSchedulingAvailable && coordination == nil)
            .accessibilityLabel("Schedule failover: \(summary)")
            if let status = store.scheduleStatus[schedule.id] {
                Text(status).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(2)
            }
        }
    }

    private func statusText(_ schedule: SceneSchedule) -> String {
        if !schedule.enabled { return "Off" }
        if let until = schedule.pausedUntil, until > .now { return "Paused until \(until.formatted(date: .abbreviated, time: .shortened))" }
        return "Next run: \(nextRunText(schedule))"
    }

    private func setPause(_ schedule: SceneSchedule, _ until: Date?) {
        guard let i = store.home.schedules.firstIndex(where: { $0.id == schedule.id }) else { return }
        store.home.schedules[i].pausedUntil = until; store.persist()
    }

    private var orderedWeekdays: [Int] { (0..<7).map { (Calendar.current.firstWeekday - 1 + $0) % 7 + 1 } }

    private static func timeText(hour: Int, minute: Int) -> String {
        (Calendar.current.date(bySettingHour: hour, minute: minute, second: 0, of: .now) ?? .now).formatted(date: .omitted, time: .shortened)
    }

    private func daysSummary(_ days: [Int]) -> String {
        let set = Set(days)
        if set == Set(1...7) { return "Every day" }
        if set == Set(2...6) { return "Weekdays" }
        if set == [1, 7] { return "Weekends" }
        if set.isEmpty { return "No days" }
        return orderedWeekdays.filter(set.contains).map { Calendar.current.shortWeekdaySymbols[$0 - 1] }.joined(separator: ", ")
    }

    private func nextRunText(_ schedule: SceneSchedule) -> String {
        let cal = Calendar.current
        let next = schedule.weekdays.compactMap {
            cal.nextDate(after: .now, matching: DateComponents(hour: schedule.hour, minute: schedule.minute, weekday: $0), matchingPolicy: .nextTime)
        }.min()
        guard let next else { return "—" }
        let clock = next.formatted(date: .omitted, time: .shortened)
        if cal.isDateInToday(next) { return "Today at \(clock)" }
        if cal.isDateInTomorrow(next) { return "Tomorrow at \(clock)" }
        return "\(next.formatted(.dateTime.weekday(.wide))) at \(clock)"
    }

    private func addSchedule() {
        guard let selectedScene else { return }
        let c = Calendar.current.dateComponents([.hour, .minute], from: time)
        let schedule = SceneSchedule(sceneID: selectedScene, hour: c.hour ?? 0, minute: c.minute ?? 0, weekdays: weekdays.sorted())
        store.home.schedules.append(schedule)
        store.persist()
        let name = store.home.scenes.first { $0.id == selectedScene }?.name ?? "Scene"
        addedMessage = "Added \(name) at \(Self.timeText(hour: schedule.hour, minute: schedule.minute)) — \(daysSummary(schedule.weekdays).lowercased())."
    }

    // MARK: - Webhooks

    private var statusLower: String { store.webhookStatus.lowercased() }
    private var hasServerError: Bool { ["fail", "error", "denied", "in use"].contains { statusLower.contains($0) } }

    private var webhooksSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader("Webhooks")
            Card {
                VStack(alignment: .leading, spacing: 16) {
                    serverStatusRow
                    Text("A webhook server lets other apps on this \(PlatformCopy.device)\(store.home.allowLAN ? " and your local network" : "") run scenes and control your lights. Every request needs the access token below.")
                        .font(.system(size: 13)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    endpointBlock
                    tokenRow
                    Divider()
                    serverSettings
                    DisclosureGroup(isExpanded: $showExamples) { examples.padding(.top, 8) } label: {
                        Text("Example requests").font(.system(size: 13, weight: .medium))
                    }
                }
            }
        }
    }

    private var serverStatusRow: some View {
        HStack(spacing: 12) {
            Image(systemName: "bolt.horizontal.circle.fill").font(.system(size: 26)).foregroundStyle(store.webhookRunning ? Color.success : Color.secondary).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text("Webhook server").font(.system(size: 14, weight: .semibold))
                    if store.webhookRunning { StatusPill(text: "Running", icon: "checkmark", tint: .success) }
                    else if hasServerError { StatusPill(text: "Problem", icon: "exclamationmark.triangle.fill", tint: .danger) }
                    else { StatusPill(text: "Stopped", tint: .secondary) }
                }
                if store.webhookStatus != "Stopped" {
                    Text(store.webhookStatus).font(.system(size: 12)).foregroundStyle(hasServerError ? Color.danger : .secondary)
                }
            }
            Spacer(minLength: 12)
            if store.webhookRunning {
                Button("Stop Server", systemImage: "stop.fill") { store.stopWebhooks() }.buttonStyle(.bordered)
            } else {
                Button("Start Server", systemImage: "play.fill") { store.startWebhooks() }.buttonStyle(.borderedProminent)
            }
        }
    }

    private var endpointBlock: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Address").font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
            CodeBlock(text: baseURL, copyLabel: "Copy address")
            if store.home.allowLAN { Text("Other devices can use this \(PlatformCopy.device)’s LAN address or its .local name instead of 127.0.0.1. The certificate lists them and is replaced if they change, so export it again after a network change.").font(.system(size: 12)).foregroundStyle(.secondary) }
            Text("HTTPS certificate").font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary).padding(.top, 6)
            if let certificate = store.webhookCertificate {
                Text("SHA-256 fingerprint").font(.system(size: 11)).foregroundStyle(.secondary)
                CodeBlock(text: certificate.fingerprint, copyLabel: "Copy fingerprint")
                if !certificate.spkiPin.isEmpty {
                    Text("Public key pin (curl --pinnedpubkey)").font(.system(size: 11)).foregroundStyle(.secondary)
                    CodeBlock(text: certificate.spkiPin, copyLabel: "Copy public key pin")
                }
                ShareLink(item: CertificateFile(pem: certificate.pem), preview: SharePreview("Luma webhook certificate")) {
                    Label("Export Certificate…", systemImage: "square.and.arrow.up")
                }.controlSize(.small)
                Text("The server uses a self-signed certificate made on this \(PlatformCopy.device). Callers should trust the exported file (curl --cacert luma.pem) or pin the public key, never turn off certificate checks. Apps that can only switch checks on or off, like Home Assistant’s rest_command or Shortcuts, should run on this \(PlatformCopy.device) against 127.0.0.1 or trust luma.pem at the system level.")
                    .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            } else {
                Text("A certificate is created the first time you start the server.").font(.system(size: 12)).foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder private var tokenRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Access token").font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
            if store.webhookToken.isEmpty {
                Text("A token is created the first time you start the server.").font(.system(size: 12)).foregroundStyle(.secondary)
            } else {
                HStack(spacing: 8) {
                    Text(showToken ? store.webhookToken : "Hidden · " + String(repeating: "•", count: 16))
                        .font(.system(size: 11.5, design: .monospaced)).lineLimit(1).truncationMode(.middle)
                        // Copy is a separate action. Selectable SwiftUI text with
                        // a custom AX label can recurse in AppKit accessibility.
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Button(showToken ? "Hide" : "Show") { showToken.toggle() }.controlSize(.small)
                    Button("Copy", systemImage: "doc.on.doc") { copyToPasteboard(store.webhookToken) }.controlSize(.small)
                    Button("Rotate…") { confirmRotate = true }.controlSize(.small)
                }
                .padding(.horizontal, 12).padding(.vertical, 8)
                .background(Color.well, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .confirmationDialog("Rotate the access token?", isPresented: $confirmRotate, titleVisibility: .visible) {
                    Button("Rotate Token", role: .destructive) { showToken = false; store.rotateToken() }
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text("This stops the webhook server and creates a new token. Anything using the old token, such as Shortcuts or scripts, must be updated.")
                }
            }
        }
    }

    private var serverSettings: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Server settings").font(.system(size: 13, weight: .semibold))
            HStack(spacing: 8) {
                Text("Port")
                TextField("8787", value: $store.home.webhookPort, format: .number.grouping(.never))
                    .frame(width: 80).textFieldStyle(.roundedBorder).disabled(store.webhookRunning)
                    .onChange(of: store.home.webhookPort) { store.persist() }
                if store.webhookRunning { Text("Stop the server to change settings.").font(.system(size: 12)).foregroundStyle(.secondary) }
            }
            Toggle("Allow devices on my local network", isOn: $store.home.allowLAN)
                .disabled(store.webhookRunning)
                .onChange(of: store.home.allowLAN) { store.persist() }
            if store.home.allowLAN {
                Label("Local network mode listens on all network interfaces. Traffic is encrypted with HTTPS and every request needs the token, but use it only on a trusted network and never port-forward it.", systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 12)).foregroundStyle(Color.warning).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // 127.0.0.1, not localhost: the listener is IPv4 and localhost often resolves to ::1 first.
    private var baseURL: String { "https://127.0.0.1:\(store.home.webhookPort)" }

    private var examples: some View {
        let sceneID = store.home.scenes.first?.id.uuidString ?? "<scene-id>"
        return VStack(alignment: .leading, spacing: 12) {
            Text("Set lights").font(.system(size: 12, weight: .medium))
            Text("Target a light ID, “all”, or “room:Living room”. Fields: power, brightness (1–100), and either color (hex) or kelvin.")
                .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            CodeBlock(text: "curl --cacert luma.pem -X POST \(baseURL)/v1/actions \\\n  -H \"Authorization: Bearer $LUMA_TOKEN\" \\\n  -H \"Content-Type: application/json\" \\\n  -d '{\"target\":\"all\",\"power\":true,\"brightness\":40,\"color\":\"#FFB870\"}'")
            Text("Run a scene").font(.system(size: 12, weight: .medium))
            CodeBlock(text: "curl --cacert luma.pem -X POST \(baseURL)/v1/scenes/\(sceneID)/run \\\n  -H \"Authorization: Bearer $LUMA_TOKEN\"")
            Text("Look things up").font(.system(size: 12, weight: .medium))
            CodeBlock(text: ["GET /v1/devices", "GET /v1/scenes", "GET /v1/runs/<run-id>", "GET /health"].joined(separator: "\n"), copyLabel: "Copy list")
            Text("Send the same Authorization header with each request. Requests are accepted right away (HTTP 202 with a run ID); “completed” means the commands were sent, not that each light confirmed them.")
                .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Recent runs

    private var runsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader("Recent runs")
            Card(padding: 4) {
                VStack(spacing: 0) {
                    let runs = Array(store.runs.prefix(8))
                    ForEach(runs) { run in
                        HStack(alignment: .firstTextBaseline, spacing: 12) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(run.name).font(.system(size: 13, weight: .medium)).lineLimit(1)
                                Text(run.startedAt.formatted(.relative(presentation: .named))).font(.system(size: 12)).foregroundStyle(.secondary)
                                if let error = run.error, !error.isEmpty { Text(error).font(.system(size: 12)).foregroundStyle(Color.danger).fixedSize(horizontal: false, vertical: true) }
                            }
                            Spacer(minLength: 12)
                            runPill(run.status)
                        }
                        .padding(.horizontal, 16).padding(.vertical, 10)
                        if run.id != runs.last?.id { Divider().padding(.horizontal, 16) }
                    }
                }
            }
        }
    }

    @ViewBuilder private func runPill(_ status: String) -> some View {
        switch status {
        case "completed": StatusPill(text: "Completed", icon: "checkmark", tint: .success)
        case "running": StatusPill(text: "Running", tint: .lumaAccent, busy: true)
        case "failed": StatusPill(text: "Failed", icon: "xmark", tint: .danger)
        case "cancelled": StatusPill(text: "Cancelled", icon: "slash.circle", tint: .secondary)
        default: StatusPill(text: status.capitalized)
        }
    }
}

/// Toggle-style weekday capsule.
private struct DayChip: View {
    let symbol: String
    let name: String
    let isOn: Bool
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Text(symbol).font(.system(size: 12, weight: .semibold))
                .frame(width: 34, height: 26)
                .foregroundStyle(isOn ? Color.white : Color.primary)
                .background(isOn ? Color.lumaAccentFill : Color.well, in: Capsule())
                .overlay(Capsule().strokeBorder(Color.hairline))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help(name)
        .accessibilityLabel(name)
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }
}

/// The webhook certificate as a .pem file for the share sheet.
struct CertificateFile: Transferable {
    let pem: String
    static var transferRepresentation: some TransferRepresentation {
        DataRepresentation(exportedContentType: .x509Certificate) { Data($0.pem.utf8) }
            .suggestedFileName("luma.pem")
    }
}
