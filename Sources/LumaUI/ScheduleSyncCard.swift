import SwiftUI
import LumaCore

/// "Run schedules on [computer]": setup, pairing and sync health for shared schedules.
struct ScheduleSyncCard: View {
    @Bindable var store: HomeStore
    @State private var code = ""
    @State private var busy = false
    @State private var error: String?
    @State private var confirmForce = false
    @State private var confirmOff = false
    private var sync: ScheduleSyncController { store.scheduleSync }

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 12) {
                if store.demo {
                    Label("Shared schedules are off in the demo.", systemImage: "arrow.triangle.2.circlepath").font(.system(size: 13, weight: .semibold))
                } else {
                    switch sync.role {
                    case .off: offView
                    case .runner: runnerView
                    case .paired: pairedView
                    }
                }
                ForEach(Array(sync.notices.enumerated()), id: \.offset) { InlineMessage(text: $0.element) }
                if !sync.notices.isEmpty { Button("Dismiss") { sync.notices = [] }.buttonStyle(.borderless).font(.system(size: 12)) }
                if let error { InlineMessage(text: error) }
                Text("Shared: scenes, schedules, on/off and pause. Not shared: what your lights are showing right now. The computer that runs schedules must be on, awake and running Luma; times due while it sleeps are skipped. Changes reach it over your home network.")
                    .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
        .confirmationDialog("Run schedules here without confirmation?", isPresented: $confirmForce) {
            Button("Run Here When It Confirms", role: .destructive) { act { try await sync.takeOver(force: true) } }
        } message: {
            Text("\(sync.client?.runner?.name ?? "The current computer") can't be reached. This Mac will keep asking it to stop and runs nothing until it agrees, so no schedule runs twice. If that computer is gone for good, turn sharing off and back on here instead.")
        }
        .confirmationDialog("Stop sharing schedules?", isPresented: $confirmOff) {
            Button("Turn Off", role: .destructive) { sync.turnOff() }
        } message: {
            Text(sync.role == .runner && sync.mayExecute ? "Paired devices will no longer see or change these schedules." : "Schedules here will be turned off so they don't also run on the other computer.")
        }
    }

    private var offView: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Shared schedules", systemImage: "arrow.triangle.2.circlepath").font(.system(size: 13, weight: .semibold))
            Text(ScheduleSyncController.canRun
                 ? "Run your schedules on a computer that stays on, and change or pause them from your iPhone or other computers."
                 : "Let a Mac, Windows or Linux computer that stays on run your schedules while Luma is closed here. Changes and pauses you make on this \(PlatformCopy.device) reach it.")
                .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if ScheduleSyncController.canRun {
                Button("Run Schedules on This Mac", systemImage: "desktopcomputer") { act { try sync.becomeRunner() } }.buttonStyle(.borderedProminent)
            }
            pairField(label: "Pair with a computer")
        }
    }

    private func pairField(label: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label).font(.system(size: 12)).foregroundStyle(.secondary)
            HStack {
                TextField("luma1/…", text: $code).textFieldStyle(.roundedBorder).autocorrectionDisabled()
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    #endif
                    .accessibilityLabel("Pairing code")
                Button("Pair") { let c = code; act { try await sync.pair(c); code = "" } }.disabled(code.trimmingCharacters(in: .whitespaces).isEmpty || busy)
            }
            Text("On the computer that runs schedules: Automations › Shared schedules › copy its pairing code.").font(.system(size: 11)).foregroundStyle(.secondary)
        }
    }

    private var runnerView: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let retired = sync.runnerDoc?.retiredTo {
                Label("Schedules moved to \(retired.name)", systemImage: "arrow.right.circle").font(.system(size: 13, weight: .semibold))
                Text("This Mac stopped running them. Pair with \(retired.name) to keep changing them here.").font(.system(size: 12)).foregroundStyle(.secondary)
                pairField(label: "Pair with \(retired.name)")
            } else {
                Label(sync.saved.retirePending.map { "Waiting for \($0.name) to stop running schedules" } ?? "Schedules run on this Mac",
                      systemImage: sync.saved.retirePending == nil ? "checkmark.circle.fill" : "hourglass").font(.system(size: 13, weight: .semibold))
                Text(sync.serverStatus).font(.system(size: 12)).foregroundStyle(.secondary)
                if sync.pairingCodes.isEmpty {
                    Text("No network address found, so there's no pairing code yet. Connect to Wi-Fi or Ethernet.").font(.system(size: 12)).foregroundStyle(Color.warning)
                }
                ForEach(sync.pairingCodes, id: \.self) { c in
                    HStack {
                        Text(c).font(.system(size: 12, design: .monospaced)).textSelection(.enabled).lineLimit(1).truncationMode(.middle)
                        Button("Copy") { copy(c) }.buttonStyle(.borderless)
                    }
                }
                let clients = (sync.runnerDoc?.clients.values.sorted { $0.lastSeen > $1.lastSeen }) ?? []
                if !clients.isEmpty {
                    Text("Paired devices").font(.system(size: 12, weight: .medium))
                    ForEach(clients, id: \.id) { c in
                        Text("\(c.name) · last seen \(Date(timeIntervalSince1970: Double(c.lastSeen) / 1000).formatted(.relative(presentation: .named)))")
                            .font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                }
                Toggle("Keep this Mac awake while it runs schedules", isOn: Binding(get: { sync.saved.keepAwake }, set: { sync.setKeepAwake($0) }))
                    .font(.system(size: 12))
                Text("Prevents idle sleep only. Closing the lid or choosing Sleep still stops schedules.").font(.system(size: 11)).foregroundStyle(.secondary)
                HStack {
                    Button("New Pairing Code") { act { try sync.rotatePairing() } }
                    Button("Turn Off Sharing", role: .destructive) { confirmOff = true }
                }.buttonStyle(.bordered).controlSize(.small)
            }
            if sync.runnerDoc?.retiredTo != nil { Button("Turn Off Sharing", role: .destructive) { confirmOff = true }.buttonStyle(.bordered).controlSize(.small) }
        }
    }

    private var pairedView: some View {
        let client = sync.client
        let runner = client?.runner
        return VStack(alignment: .leading, spacing: 8) {
            Label("Schedules run on \(runner?.name ?? client?.host ?? "another computer")", systemImage: "desktopcomputer").font(.system(size: 13, weight: .semibold))
            if let moved = client?.moved {
                InlineMessage(text: moved)
                pairField(label: "Pair with the new computer")
            } else if let lastError = client?.lastError {
                Label("Not reachable: \(lastError)", systemImage: "wifi.exclamationmark").font(.system(size: 12)).foregroundStyle(Color.warning)
            }
            if let last = client?.lastSync {
                Text("Last synced \(last.formatted(.relative(presentation: .named))). This \(PlatformCopy.device) doesn't run them.").font(.system(size: 12)).foregroundStyle(.secondary)
            }
            if sync.unsent > 0 {
                Text("\(sync.unsent) change\(sync.unsent == 1 ? "" : "s") not yet delivered. They'll be sent when the runner is reachable; a change that conflicts with a newer one there is dropped and you'll see why.")
                    .font(.system(size: 12)).foregroundStyle(Color.warning).fixedSize(horizontal: false, vertical: true)
            }
            if let zone = runner?.timeZone, zone != TimeZone.current.identifier {
                Text("Times are in \(runner?.name ?? "the runner")'s time zone (\(zone)).").font(.system(size: 12)).foregroundStyle(Color.warning)
            }
            HStack {
                Button("Sync Now") { act { await sync.syncNow() } }.disabled(sync.syncing)
                if ScheduleSyncController.canRun {
                    Button("Run Schedules Here Instead") {
                        Task { busy = true; defer { busy = false }
                            do { try await sync.takeOver(force: false); error = nil } catch { confirmForce = true } }
                    }
                }
                Button("Unpair", role: .destructive) { confirmOff = true }
            }.buttonStyle(.bordered).controlSize(.small).disabled(busy)
        }
    }

    private func act(_ work: @escaping () async throws -> Void) {
        Task {
            busy = true; defer { busy = false }
            do { try await work(); error = nil } catch { self.error = error.localizedDescription }
        }
    }

    private func copy(_ text: String) {
        #if os(macOS)
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string)
        #else
        UIPasteboard.general.string = text
        #endif
    }
}

/// One line under a schedule: what the runner last observed. Telemetry, not settings.
struct ScheduleRunLine: View {
    let store: HomeStore
    let schedule: SceneSchedule
    var body: some View {
        let sync = store.scheduleSync
        if sync.role != .off, let report = sync.runReports[schedule.id.uuidString] {
            let at = Date(timeIntervalSince1970: Double(report.at) / 1000).formatted(date: .abbreviated, time: .shortened)
            let place = sync.role == .runner ? "this Mac" : (sync.client?.runner?.name ?? "the runner")
            let text = switch report.status {
            case "completed": "Ran on \(place) \(at). Sent to the lights, not confirmed by them."
            case "started", "running": "Started on \(place) \(at)."
            case "paused": "Skipped on \(place) \(at): paused."
            case "missed": "Missed on \(place) \(at). \(report.detail ?? "")"
            default: "Didn't run on \(place) \(at): \(report.detail ?? report.status)"
            }
            Text(text).font(.system(size: 11)).foregroundStyle(report.status == "completed" || report.status == "started" || report.status == "paused" ? Color.secondary : Color.warning)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
