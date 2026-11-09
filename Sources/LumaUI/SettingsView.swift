import SwiftUI
#if os(iOS)
import AppIntents
#endif
#if os(macOS)
import AppKit
#endif
import LumaCore
import UniformTypeIdentifiers

struct SettingsView: View {
    @Bindable var store: HomeStore
    @AppStorage("appearance") private var appearance = Appearance.system
    @State private var connecting = false
    @State private var confirmingDisconnect = false
    @State private var importingSetup = false
    @State private var setupPlan: GoveeHomeImport.Plan?
    @State private var setupError: String?
    @State private var signingIn = false
    @State private var importingAccount = false
    @State private var showingBluetooth = false
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                PageHeader(title: "Settings", subtitle: "Connections, appearance, and information about Luma.")
                VStack(alignment: .leading, spacing: 10) {
                    SectionHeader("Connections")
                    Card {
                        VStack(alignment: .leading, spacing: 16) {
                            settingRow(icon: "cloud", title: "Govee account", detail: store.cloudConnected ? "Connected. Lights, effects, and model features sync from your account." : "Connect to find every light on your account and unlock effects, segments, and music modes.") {
                                StatusPill(text: store.cloudConnected ? "Connected" : "Not connected", icon: store.cloudConnected ? "checkmark.circle.fill" : "circle", tint: store.cloudConnected ? .success : .secondary)
                            }
                            HStack(spacing: 8) {
                                Button(store.cloudConnected ? "Change API Key…" : "Connect Account…") { connecting = true }
                                    .buttonStyle(.borderedProminent)
                                if store.cloudConnected { Button("Disconnect…", role: .destructive) { confirmingDisconnect = true } }
                            }.padding(.leading, 40)
                            Divider()
                            settingRow(icon: "wifi", title: "Local network", detail: "Faster, private control for lights with LAN Control turned on in the Govee Home app (Light › Settings › LAN Control). This \(PlatformCopy.device) must be on the same Wi-Fi.") {
                                StatusPill(text: "\(store.devices.filter { $0.ip != nil }.count) local", icon: "wifi", tint: .secondary)
                            }
                            HStack(spacing: 8) {
                                Button(store.scanning ? "Looking for Lights…" : "Find Lights on Wi-Fi") { store.discover() }.disabled(store.scanning || store.demo)
                                Link("LAN setup guide", destination: URL(string: "https://app-h5.govee.com/user-manual/wlan-guide")!).font(.system(size: 12)).tint(Color.lumaAccent)
                            }.padding(.leading, 40)
                            Divider()
                            settingRow(icon: "house", title: "Govee Home sign-in", detail: "Optional, read-only. Brings in rooms and shows your DreamView groups and automations, with a preview first. Uses Govee Home's private sign-in, which Govee can change at any time.") {
                                StatusPill(text: store.accountSignedIn ? "Signed in" : "Not signed in", icon: store.accountSignedIn ? "checkmark.circle.fill" : "circle", tint: store.accountSignedIn ? .success : .secondary)
                            }
                            VStack(alignment: .leading, spacing: 6) {
                                HStack(spacing: 8) {
                                    if store.accountSignedIn {
                                        Button { importFromAccount() } label: {
                                            HStack(spacing: 6) { if importingAccount { ProgressView().controlSize(.small) }; Text("Import from Govee Home") }
                                        }.buttonStyle(.borderedProminent).disabled(importingAccount)
                                        Button("Sign Out") { store.signOutOfGoveeHome() }
                                    } else {
                                        Button("Sign In to Govee Home…") { signingIn = true }.disabled(store.demo)
                                    }
                                    Button("Import Saved File…") { importingSetup = true }
                                        .help("Import a saved GET /bff-app/v1/device/list response instead of signing in")
                                }
                                if let setupError { InlineMessage(text: setupError) }
                            }.padding(.leading, 40)
                            Divider()
                            settingRow(icon: "dot.radiowaves.left.and.right", title: "Bluetooth", detail: "Control supported Govee TV backlights nearby without Wi-Fi, including their video mode and DreamView group settings. Luma connects only when you choose a light.") { EmptyView() }
                            Button("Bluetooth Lights…") { showingBluetooth = true }.padding(.leading, 40)
                            if store.demo {
                                Divider()
                                settingRow(icon: "sparkles", title: "Demo home", detail: "You are exploring sample lights. Nothing real is controlled and changes are not saved.") { EmptyView() }
                                Button("Leave Demo and Connect My Lights") { store.leaveDemo(); connecting = true }.padding(.leading, 40)
                            }
                        }
                    }
                }
#if os(iOS)
                Card {
                    VStack(alignment: .leading, spacing: 8) {
                        Label("iCloud", systemImage: "icloud")
                        Text(store.demo ? "Demo stays on this device." : store.iCloudStatus)
                            .font(.subheadline).foregroundStyle(.secondary)
                        Text("Your Govee key uses iCloud Keychain. Names, rooms, scenes and floor plans sync across devices using the same Apple Account. Light status refreshes from your lights.")
                            .font(.caption).foregroundStyle(.secondary)
                        Button("Sync Now") { store.refreshICloud() }.disabled(store.demo).frame(minHeight: 44)
                    }
                }
                VStack(alignment: .leading, spacing: 10) {
                    SectionHeader("Advanced")
                    Card {
                        VStack(alignment: .leading, spacing: 0) {
                            NavigationLink { ActivityView(store: store).background(Color.canvas) } label: {
                                Label("Activity", systemImage: Page.activity.icon).frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                            }
                            Divider()
                            NavigationLink { ScreenSyncView(store: store, sync: store.screenSync).background(Color.canvas) } label: {
                                Label("Screen Sync", systemImage: Page.screenSync.icon).frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                            }
                        }
                    }
                }
#endif
                VStack(alignment: .leading, spacing: 10) {
                    SectionHeader("Your data")
                    BackupCard(store: store)
                }
                VStack(alignment: .leading, spacing: 10) {
                    SectionHeader("Siri & Shortcuts")
                    SiriCard(store: store)
                }
                VStack(alignment: .leading, spacing: 10) {
                    SectionHeader("Appearance")
                    Card {
                        HStack {
                            VStack(alignment: .leading, spacing: 3) {
                                Text("Theme").font(.system(size: 13, weight: .medium))
                                Text("Match your \(PlatformCopy.device), or keep Luma light or dark.").font(.system(size: 12)).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Picker("Theme", selection: $appearance) { ForEach(Appearance.allCases) { Text($0.title).tag($0) } }
                                .pickerStyle(.segmented).labelsHidden().frame(width: 220)
                        }
                    }
                }
                VStack(alignment: .leading, spacing: 10) {
                    SectionHeader("About")
                    AboutCard()
                }
                Card {
                    VStack(alignment: .leading, spacing: 8) {
                        Label("How Luma runs", systemImage: "info.circle").font(.system(size: 13, weight: .medium))
                        Text(PlatformCopy.storageNote)
                            .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        Text("Coverage depends on LAN support and the features Govee's API reports for each model. Over Bluetooth, only the TV backlights with a verified profile (H6097, H6099, H66A0) can be controlled; other Bluetooth-only lights and features only available in the Govee app aren't supported yet.")
                            .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }.pagePadding().frame(maxWidth: 760, alignment: .leading).frame(maxWidth: .infinity, alignment: .leading)
        }
        .sheet(isPresented: $connecting) { ConnectionSheet(store: store) }
        .sheet(isPresented: $showingBluetooth) { BluetoothLightsView(store: store).sheetFrame(width: 680, height: 640) }
        .fileImporter(isPresented: $importingSetup, allowedContentTypes: [.json]) { readSetup($0) }
        .sheet(item: $setupPlan) { GoveeImportSheet(store: store, plan: $0) }
        .sheet(isPresented: $signingIn) { GoveeHomeSignInSheet(store: store) { importFromAccount() } }
        .confirmationDialog("Disconnect your Govee account?", isPresented: $confirmingDisconnect) {
            Button("Disconnect and Remove Key", role: .destructive) { store.disconnectCloud() }
        } message: { Text("Your API key is removed from the Keychain. Local network lights keep working.") }
        .onChange(of: appearance) { _, value in value.apply() }
    }
    private func readSetup(_ result: Result<URL, any Error>) {
        do {
            let url = try result.get()
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            setupPlan = try store.previewImport(Data(contentsOf: url))
            setupError = nil
        } catch { setupError = error.localizedDescription }
    }
    private func importFromAccount() {
        importingAccount = true; setupError = nil
        Task {
            do { setupPlan = try await store.previewGoveeHomeImport() } catch { setupError = error.localizedDescription }
            importingAccount = false
        }
    }
    private func settingRow<Accessory: View>(icon: String, title: String, detail: String, @ViewBuilder accessory: () -> Accessory) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon).font(.system(size: 15)).foregroundStyle(Color.lumaAccent).frame(width: 28, height: 28).background(Color.lumaAccent.opacity(0.12), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.system(size: 13, weight: .semibold))
                Text(detail).font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            accessory()
        }
    }
}

struct AboutCard: View {
    var body: some View {
        Card {
            HStack(alignment: .top, spacing: 16) {
                #if os(macOS)
                Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 56, height: 56).accessibilityHidden(true)
                #else
                Image(systemName: "lightbulb.led.wide.fill").font(.system(size: 34)).foregroundStyle(Color.lumaAccent).frame(width: 56, height: 56).accessibilityHidden(true)
                #endif
                VStack(alignment: .leading, spacing: 6) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("Luma").font(.system(size: 17, weight: .bold))
                        Text(Links.version).font(.system(size: 12)).foregroundStyle(.secondary).textSelection(.enabled)
                    }
                    Text(platformTagline).font(.system(size: 13))
                    Text(Links.attribution).font(.system(size: 12)).foregroundStyle(.secondary)
                    Text(Links.warranty).font(.system(size: 12)).foregroundStyle(.secondary)
                    Text("Luma is not affiliated with or endorsed by Govee.").font(.system(size: 12)).foregroundStyle(.secondary)
                    HStack(spacing: 14) {
                        Link(destination: Links.source) { Label("Source Code", systemImage: "chevron.left.forwardslash.chevron.right") }
                        Link(destination: Links.issues) { Label("Report an Issue", systemImage: "exclamationmark.bubble") }
                    }.font(.system(size: 12, weight: .medium)).tint(Color.lumaAccent).padding(.top, 4)
                }
                Spacer(minLength: 0)
            }
        }
    }
}

#if os(macOS)
private let platformTagline = "A native Mac home for your Govee lights."
#else
private let platformTagline = "A native iPhone and iPad home for your Govee lights."
#endif

#if os(macOS)
/// Standard About panel, with the same attribution and links as Settings.
func showAboutPanel() {
    let credits = NSMutableAttributedString()
    let body: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.secondaryLabelColor]
    credits.append(NSAttributedString(string: "\(Links.attribution)\n\(Links.warranty)\n\n", attributes: body))
    credits.append(NSAttributedString(string: "Source code", attributes: [.font: NSFont.systemFont(ofSize: 11), .link: Links.source]))
    credits.append(NSAttributedString(string: "  ·  ", attributes: body))
    credits.append(NSAttributedString(string: "Report an issue", attributes: [.font: NSFont.systemFont(ofSize: 11), .link: Links.issues]))
    let centered = NSMutableParagraphStyle(); centered.alignment = .center
    credits.addAttribute(.paragraphStyle, value: centered, range: NSRange(location: 0, length: credits.length))
    NSApp.orderFrontStandardAboutPanel(options: [.credits: credits, .applicationName: "Luma"])
    NSApp.activate(ignoringOtherApps: true)
}
#endif

struct ConnectionSheet: View {
    let store: HomeStore
    @Environment(\.dismiss) private var dismiss
    @State private var key = ""
    @State private var failure: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 12) {
                Image(systemName: "cloud").font(.system(size: 18)).foregroundStyle(Color.lumaAccent).frame(width: 36, height: 36).background(Color.lumaAccent.opacity(0.12), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                VStack(alignment: .leading, spacing: 2) {
                    Text("Connect your Govee account").font(.system(size: 17, weight: .semibold))
                    Text("Luma uses a personal API key from Govee.").font(.system(size: 12)).foregroundStyle(.secondary)
                }
            }
            VStack(alignment: .leading, spacing: 6) {
                #if os(iOS)
                TextField("Paste your API key", text: $key).textFieldStyle(.roundedBorder).textInputAutocapitalization(.never).autocorrectionDisabled().onSubmit { if !key.isEmpty { connect(saved: false) } }
                PasteButton(payloadType: String.self) { key = ($0.first ?? "").trimmingCharacters(in: .whitespacesAndNewlines) }.buttonBorderShape(.capsule).tint(Color.lumaAccent)
                #else
                SecureField("Paste your API key", text: $key).textFieldStyle(.roundedBorder).onSubmit { if !key.isEmpty { connect(saved: false) } }
                #endif
                Text("LAN Control works without a key for lights on the same Wi-Fi. You need a free Govee API key for cloud actions and to control lights when you're not on their network.")
                    .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Text("No key yet? In the Govee Home app, open Profile › Settings › Apply for API Key. Govee emails it to you, usually within minutes.")
                    .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Link("How to get a Govee API key ↗", destination: Links.goveeAPIKey).font(.system(size: 12)).tint(Color.lumaAccent)
            }
            Label("Your key is stored in the \(PlatformCopy.keychain) and sent only to Govee's official API.", systemImage: "lock.shield")
                .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if let failure { InlineMessage(text: failure) }
            HStack {
                Button("Use Saved Key") { connect(saved: true) }.disabled(store.busy).help("Reconnect with the key already in your Keychain")
                Spacer()
                Button("Cancel") { key = ""; dismiss() }.keyboardShortcut(.cancelAction)
                Button { connect(saved: false) } label: {
                    HStack(spacing: 6) { if store.busy { ProgressView().controlSize(.small) }; Text(store.busy ? "Connecting…" : "Connect") }
                }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction).disabled(key.isEmpty || store.busy)
            }
        }.padding(24).sheetFrame(width: 460)
    }
    func connect(saved: Bool) {
        failure = nil
        let before = store.activity.first?.id
        Task {
            await store.connectCloud(key: saved ? "" : key)
            if store.cloudConnected { key = ""; dismiss() }
            else if let entry = store.activity.first, entry.id != before, entry.isError { failure = entry.message }
        }
    }
}

/// Preview of a Govee Home room import. Rows a person moved in Luma start
/// unselected, so an import never silently undoes their edits.
private struct GoveeImportSheet: View {
    let store: HomeStore
    let plan: GoveeHomeImport.Plan
    @Environment(\.dismiss) private var dismiss
    @State private var selected: Set<String> = []

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Import Govee Home rooms").font(.system(size: 19, weight: .semibold))
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if plan.changes.isEmpty {
                        Text("No room changes to import.").font(.system(size: 13))
                    } else {
                        Card {
                            VStack(alignment: .leading, spacing: 10) {
                                SectionHeader("Rooms to update")
                                ForEach(plan.changes) { change in
                                    Toggle(isOn: Binding(get: { selected.contains(change.id) },
                                                         set: { if $0 { selected.insert(change.id) } else { selected.remove(change.id) } })) {
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(change.name).font(.system(size: 13, weight: .medium))
                                            Text("\(change.currentRoom) → \(change.goveeRoom)\(change.selectedByDefault ? "" : " · you set this room in Luma")")
                                                .font(.system(size: 11)).foregroundStyle(.secondary)
                                        }
                                    }
                                }
                            }
                        }
                    }
                    if !plan.groups.isEmpty || !plan.automations.isEmpty {
                        Card {
                            VStack(alignment: .leading, spacing: 8) {
                                SectionHeader("Also in Govee Home")
                                ForEach(plan.groups.filter(\.isDreamView)) { group in
                                    let main = store.home.devices.first { $0.id.caseInsensitiveCompare(group.mainDevice ?? "") == .orderedSame }
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text("DreamView: \(group.name)").font(.system(size: 13, weight: .medium))
                                        Text("Main light \(main.map { $0.customName ?? $0.name } ?? group.mainSKU ?? "not in Luma")\(group.reportedLightCount.map { " · \($0) lights reported" } ?? "")\(group.enabled ? "" : " · off")")
                                            .font(.system(size: 11)).foregroundStyle(.secondary)
                                    }
                                }
                                ForEach(plan.automations) { automation in
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text("Automation: \(automation.name)").font(.system(size: 13, weight: .medium))
                                        Text(automationText(automation)).font(.system(size: 11)).foregroundStyle(.secondary)
                                    }
                                }
                                Text("Shown for reference; Luma doesn't change them. DreamView groups appear on the TV light's card. Luma schedules that run at the same time as an enabled automation are flagged in Automations.")
                                    .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                    VStack(alignment: .leading, spacing: 6) {
                        if plan.unchanged > 0 { Text(lights(plan.unchanged) + (plan.unchanged == 1 ? " already matches." : " already match.")) }
                        if plan.withoutRoom > 0 { Text(lights(plan.withoutRoom) + (plan.withoutRoom == 1 ? " has" : " have") + " no room in Govee Home.") }
                        if !plan.notInLuma.isEmpty {
                            Text(lights(plan.notInLuma.count) + " not in Luma yet: " + "\(plan.notInLuma.prefix(5).map(\.name).joined(separator: ", "))\(plan.notInLuma.count > 5 ? "…" : ""). Connect your Govee account or find lights on Wi-Fi first; Luma can't control a light from this file alone.")
                        }
                        if !plan.unavailable.isEmpty { Text("Couldn't read \(plan.unavailable.joined(separator: " or ")) from Govee Home this time.") }
                        Text("Only rooms are changed. Bluetooth names and firmware stay in memory; group names and automation times are saved with your home until you sign out.")
                    }.font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Import \(selected.count) Room\(selected.count == 1 ? "" : "s")") {
                    store.applyRoomImport(plan.changes.filter { selected.contains($0.id) }); dismiss()
                }.buttonStyle(.borderedProminent).disabled(selected.isEmpty).keyboardShortcut(.defaultAction)
            }
        }
        .padding(compactSpacing(24, 16)).sheetFrame(width: 520, height: 560).background(Color.canvas)
        .onAppear { selected = Set(plan.changes.filter(\.selectedByDefault).map(\.id)) }
    }
    private func lights(_ count: Int) -> String { "\(count) light\(count == 1 ? "" : "s")" }
    private func automationText(_ a: GoveeHomeImport.Automation) -> String {
        let times = a.times.map { String(format: "%02d:%02d", $0.hour, $0.minute) }.joined(separator: ", ")
        let days = a.everyDay ? "every day" : a.repeatDays.isEmpty ? "once" : "\(a.repeatDays.count) days a week"
        let lights = a.targets.map(\.name).joined(separator: ", ")
        return [times.isEmpty ? nil : "\(times) \(days)", lights.isEmpty ? nil : lights, a.enabled ? nil : "off"].compactMap { $0 }.joined(separator: " · ")
    }
}

/// Govee Home email sign-in. The password and code live only in this sheet and
/// are cleared when it closes; only the session token goes to the Keychain.
private struct GoveeHomeSignInSheet: View {
    let store: HomeStore
    let onSignedIn: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var email = ""
    @State private var password = ""
    @State private var code = ""
    @State private var needsCode = false
    @State private var working = false
    @State private var failure: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Sign in to Govee Home").font(.system(size: 17, weight: .semibold))
                Text("Read-only: Luma reads your device list. It doesn't change your Govee Home setup.").font(.system(size: 12)).foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 8) {
                TextField("Email", text: $email).textFieldStyle(.roundedBorder).textContentType(.username)
                    #if os(iOS)
                    .textInputAutocapitalization(.never).keyboardType(.emailAddress)
                    #endif
                    .autocorrectionDisabled().disabled(needsCode)
                SecureField("Password", text: $password).textFieldStyle(.roundedBorder).textContentType(.password).disabled(needsCode)
                if needsCode {
                    Text("Govee emailed you a code.").font(.system(size: 12))
                    TextField("Code", text: $code).textFieldStyle(.roundedBorder).textContentType(.oneTimeCode)
                        #if os(iOS)
                        .keyboardType(.numberPad)
                        #endif
                }
            }
            Label("Your password is sent only to Govee and never saved. The sign-in token is kept in the \(PlatformCopy.keychain).", systemImage: "lock.shield")
                .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if let failure { InlineMessage(text: failure) }
            HStack {
                Spacer()
                Button("Cancel") { close() }.keyboardShortcut(.cancelAction)
                Button { submit() } label: {
                    HStack(spacing: 6) { if working { ProgressView().controlSize(.small) }; Text(needsCode ? "Verify" : "Sign In") }
                }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                    .disabled(working || email.isEmpty || password.isEmpty || (needsCode && code.isEmpty))
            }
        }.padding(24).sheetFrame(width: 440)
        .onDisappear { password = ""; code = "" }
    }

    private func submit() {
        working = true; failure = nil
        Task {
            do {
                if try await store.signInToGoveeHome(email: email, password: password, code: needsCode ? code : nil) {
                    close(); onSignedIn()
                } else { needsCode = true }
            } catch { failure = error.localizedDescription; code = "" }
            working = false
        }
    }
    private func close() { password = ""; code = ""; dismiss() }
}

/// Whole-home backup and restore, plus the redacted compatibility report.
/// Its own view so its file panels don't collide with the Govee Home importer.
private struct BackupCard: View {
    let store: HomeStore
    @State private var exporting: SceneFile?
    @State private var showExporter = false
    @State private var importing = false
    @State private var pending: HomeBackup?
    @State private var message: (text: String, isError: Bool)?

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 12) {
                Text("A backup holds your scenes, schedules, light names, rooms, and DreamView drafts. It has no API key, sign-in, or network addresses.")
                    .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                // Wraps to a column when the row doesn't fit (iPhone).
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 8) { backupButtons; Spacer(); reportButton }
                    VStack(alignment: .leading, spacing: 8) { HStack(spacing: 8) { backupButtons }; reportButton }
                }
                if store.demo { Text("Backups are off in the demo.").font(.system(size: 11)).foregroundStyle(.secondary) }
                if let message { InlineMessage(text: message.text, isError: message.isError) }
            }
        }
        .fileExporter(isPresented: $showExporter, document: exporting, contentType: .json, defaultFilename: exporting?.name) { result in
            if case .failure(let error) = result { message = (error.localizedDescription, true) }
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.json]) { read($0) }
        .confirmationDialog("Restore this backup?", isPresented: Binding(get: { pending != nil }, set: { if !$0 { pending = nil } }), titleVisibility: .visible, presenting: pending) { backup in
            Button("Replace Scenes and Schedules", role: .destructive) { restore(backup) }
            Button("Cancel", role: .cancel) {}
        } message: { backup in
            Text("\(backup.scenes.count) scenes and \(backup.schedules.count) schedules replace yours. Names and rooms apply only to lights Luma already has. Your current home is saved beside it first as home-before-restore.json.")
        }
    }

    @ViewBuilder private var backupButtons: some View {
        Button("Export Backup…") { export() }.disabled(store.demo).fixedSize()
        Button("Restore Backup…") { importing = true }.disabled(store.demo).fixedSize()
    }
    private var reportButton: some View {
                    Button("Copy Compatibility Report") {
                        copyToPasteboard(CompatibilityReport.text(for: store.home.devices, app: "Luma \(Links.version)"))
                        message = ("Copied. It lists models and features only, with no IDs, names, or addresses.", false)
                    }.fixedSize().help("For issue reports: what each light model supports in Luma")
    }

    private func export() {
        do {
            let day = Date().formatted(.iso8601.year().month().day())
            exporting = SceneFile(name: "Luma backup \(day)", data: try store.backup().encoded()); showExporter = true; message = nil
        } catch { message = (error.localizedDescription, true) }
    }
    private func read(_ result: Result<URL, any Error>) {
        do {
            let url = try result.get()
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            pending = try HomeBackup.decode(Data(contentsOf: url)); message = nil
        } catch { message = (error.localizedDescription, true) }
    }
    private func restore(_ backup: HomeBackup) {
        do {
            let r = try store.restore(backup)
            var text = "Restored \(r.scenes) scenes, \(r.schedules) schedules, and names/rooms for \(r.lightsUpdated) lights."
            if r.lightsNotFound > 0 { text += " \(r.lightsNotFound) lights in the backup aren't in Luma." }
            if r.scenesWithMissingLights > 0 { text += " \(r.scenesWithMissingLights) scenes use lights Luma doesn't have." }
            message = (text, false)
        } catch { message = (error.localizedDescription, true) }
    }
}

/// Explains the built-in Siri phrases. Rooms are resolved when a phrase runs, so
/// moving a light into a room needs no shortcut changes.
private struct SiriCard: View {
    let store: HomeStore
    var body: some View {
        let room = store.rooms.first ?? "Bedroom"
        Card {
            VStack(alignment: .leading, spacing: 10) {
                Text("Say these to Siri, or find them as Luma actions in the Shortcuts app. They control whatever lights are in the room at that moment, so adding a light to a room includes it automatically.")
                    .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(["“Turn on \(room) in Luma”", "“Turn off \(room) in Luma”", "“Set \(room) brightness in Luma”", "“Change \(room) color in Luma”",
                             "“Run \(store.home.scenes.first?.name ?? "Movie night") in Luma”", "“Apply a scene to \(room) in Luma”"], id: \.self) {
                        Text($0).font(.system(size: 12, weight: .medium))
                    }
                }
                Text("Room names must match Luma's. Luma runs the action in the background and sends it through Govee's cloud (or your Wi-Fi when Luma is open and has found the light). Siri asks for a brightness, color, or scene when the phrase doesn't include one. Govee scenes use the lists loaded on the Scenes page.")
                    .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                #if os(iOS)
                ShortcutsLink().shortcutsLinkStyle(.automaticOutline)
                #endif
            }
        }
    }
}
