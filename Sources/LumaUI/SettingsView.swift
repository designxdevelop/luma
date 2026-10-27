import SwiftUI
#if os(macOS)
import AppKit
#endif
import LumaCore

struct SettingsView: View {
    @Bindable var store: HomeStore
    @AppStorage("appearance") private var appearance = Appearance.system
    @State private var connecting = false
    @State private var confirmingDisconnect = false
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
                            if store.demo {
                                Divider()
                                settingRow(icon: "sparkles", title: "Demo home", detail: "You are exploring sample lights. Nothing real is controlled and changes are not saved.") { EmptyView() }
                                Button("Leave Demo and Connect My Lights") { store.leaveDemo(); connecting = true }.padding(.leading, 40)
                            }
                        }
                    }
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
                        Text("Coverage depends on LAN support and the features Govee's API reports for each model. Bluetooth-only lights and features only available in the Govee app aren't supported yet.")
                            .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }.pagePadding().frame(maxWidth: 760, alignment: .leading).frame(maxWidth: .infinity)
        }
        .sheet(isPresented: $connecting) { ConnectionSheet(store: store) }
        .confirmationDialog("Disconnect your Govee account?", isPresented: $confirmingDisconnect) {
            Button("Disconnect and Remove Key", role: .destructive) { store.disconnectCloud() }
        } message: { Text("Your API key is removed from the Keychain. Local network lights keep working.") }
        .onChange(of: appearance) { _, value in value.apply() }
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
                SecureField("Paste your API key", text: $key).textFieldStyle(.roundedBorder).onSubmit { if !key.isEmpty { connect(saved: false) } }
                Link("Get a key in the Govee Home app ↗", destination: URL(string: "https://developer.govee.com/reference/apply-you-govee-api-key")!).font(.system(size: 12)).tint(Color.lumaAccent)
            }
            Label("Your key is stored in the macOS Keychain and sent only to Govee's official API.", systemImage: "lock.shield")
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
