import SwiftUI
#if os(macOS)
import AppKit
#else
import UIKit
#endif
import LumaCore

// Luma's visual language: neutral surfaces, one warm accent, and light colors
// drawn from the lights themselves. Every color resolves for light and dark.

extension Color {
    init(rgb: Int) { self.init(red: Double((rgb >> 16) & 255) / 255, green: Double((rgb >> 8) & 255) / 255, blue: Double(rgb & 255) / 255) }

    /// Window background behind pages.
    static let canvas = dynamic(light: 0xF5F5F7, dark: 0x161618)
    /// Cards and grouped content.
    static let surface = dynamic(light: 0xFFFFFF, dark: 0x202023)
    /// Wells inside cards: code samples, inline fields, segment tracks.
    static let well = dynamic(light: 0xF0F0F2, dark: 0x2A2A2E)
    /// Hairline borders around cards.
    static let hairline = dynamic(light: 0x000000, dark: 0xFFFFFF, lightAlpha: 0.07, darkAlpha: 0.08)
    /// Brand accent for text, icons, and tinted pills. Measured (WCAG):
    /// light #A84C00 is 5.7:1 on cards and 4.8:1 on its own 12% pill;
    /// dark #FFA347 is 8.2:1 on cards and 6.5:1 on its pill.
    static let lumaAccent = dynamic(light: 0xA84C00, dark: 0xFFA347)
    /// Brand accent for filled controls (the app-wide `.tint`): prominent
    /// buttons, switches, sliders. White labels on it measure 4.8:1 in both
    /// modes; as a fill it is 3.4:1 against dark cards.
    static let lumaAccentFill = dynamic(light: 0xB95500, dark: 0xB95500)
    /// Status colors, each at least 4.5:1 as text on cards and on their own
    /// 12% tinted pill (light 4.8–5.3:1, dark 4.9–7.1:1).
    static let success = dynamic(light: 0x1D7543, dark: 0x4CD483)
    static let warning = dynamic(light: 0x8C5200, dark: 0xFFB340)
    static let danger = dynamic(light: 0xB52A25, dark: 0xFF6961)
    /// Kept for older call sites; the sidebar now uses the system material.
    static let sidebar = canvas

    // nonisolated: SwiftUI resolves dynamic colors on its render thread during animations.
    nonisolated private static func dynamic(light: Int, dark: Int, lightAlpha: Double = 1, darkAlpha: Double = 1) -> Color {
        #if os(macOS)
        Color(nsColor: NSColor(name: nil) { @Sendable appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            let rgb = isDark ? dark : light
            return NSColor(srgbRed: CGFloat((rgb >> 16) & 255) / 255, green: CGFloat((rgb >> 8) & 255) / 255, blue: CGFloat(rgb & 255) / 255, alpha: isDark ? darkAlpha : lightAlpha)
        })
        #else
        Color(uiColor: UIColor { @Sendable traits in
            let isDark = traits.userInterfaceStyle == .dark
            let rgb = isDark ? dark : light
            return UIColor(red: CGFloat((rgb >> 16) & 255) / 255, green: CGFloat((rgb >> 8) & 255) / 255, blue: CGFloat(rgb & 255) / 255, alpha: isDark ? darkAlpha : lightAlpha)
        })
        #endif
    }
}

enum Appearance: String, CaseIterable, Identifiable {
    case system, light, dark
    var id: Self { self }
    var title: String { switch self { case .system: "System"; case .light: "Light"; case .dark: "Dark" } }
    /// Applied app-wide so sheets, Settings, and the menu bar extra follow it.
    func apply() {
        #if os(macOS)
        NSApp?.appearance = switch self { case .system: nil; case .light: NSAppearance(named: .aqua); case .dark: NSAppearance(named: .darkAqua) }
        #else
        let style: UIUserInterfaceStyle = switch self { case .system: .unspecified; case .light: .light; case .dark: .dark }
        for case let scene as UIWindowScene in UIApplication.shared.connectedScenes { scene.windows.forEach { $0.overrideUserInterfaceStyle = style } }
        #endif
    }
}

enum Links {
    static let source = URL(string: "https://github.com/designxdevelop/luma")!
    static let issues = URL(string: "https://github.com/designxdevelop/luma/issues")!
    static let attribution = "Luma is an open-source project built by Design X Develop LLC."
    static let warranty = "Provided as is, without warranty."
    static var version: String {
        let info = Bundle.main.infoDictionary
        guard let short = info?["CFBundleShortVersionString"] as? String else { return "Development build" }
        return "Version \(short)" + ((info?["CFBundleVersion"] as? String).map { " (\($0))" } ?? "")
    }
}

// MARK: - Light color

extension LightDevice {
    /// The best visual approximation of what the light is emitting right now.
    var displayColor: Color {
        if let k = colorTemperature, k > 0 { return kelvinColor(k) }
        return Color(rgb: rgb ?? 0xFFC98F)
    }
    var isStrip: Bool { let text = (sku + " " + name).lowercased(); return ["strip", "rope", "sofa", "neon", "ribbon"].contains { text.contains($0) } }
    var isBar: Bool { let text = (sku + " " + name).lowercased(); return ["bar", "tv", "backlight"].contains { text.contains($0) } }
    var symbol: String { isStrip ? "light.ribbon.fill" : isBar ? "light.beacon.max.fill" : name.lowercased().contains("lamp") || sku.lowercased().contains("lamp") ? "lamp.floor.fill" : "lightbulb.led.fill" }
    var connection: Connection {
        if isDemo { return .demo }
        if online == false { return .offline }
        return ip != nil ? .local : .cloud
    }
    enum Connection {
        case local, cloud, demo, offline
        var label: String { switch self { case .local: "Local"; case .cloud: "Cloud"; case .demo: "Sample"; case .offline: "Offline" } }
        var help: String {
            switch self {
            case .local: "Controlled directly on your Wi-Fi. Changes are confirmed by the light."
            case .cloud: "Controlled through your Govee account. Changes are confirmed when Govee reports them."
            case .demo: "A sample light. Nothing real is controlled."
            case .offline: "Govee reports this light as offline. Check its power and Wi-Fi."
            }
        }
        var icon: String { switch self { case .local: "wifi"; case .cloud: "cloud"; case .demo: "sparkles"; case .offline: "wifi.slash" } }
        var tint: Color { switch self { case .local, .cloud: .secondary; case .demo: .lumaAccent; case .offline: .danger } }
    }
}

/// Approximates black-body color for a white temperature (Tanner Helland's fit).
func kelvinColor(_ kelvin: Int) -> Color {
    let t = Double(min(max(kelvin, 1000), 40000)) / 100
    let r = t <= 66 ? 255 : 329.698727446 * pow(t - 60, -0.1332047592)
    let g = t <= 66 ? 99.4708025861 * log(t) - 161.1195681661 : 288.1221695283 * pow(t - 60, -0.0755148492)
    let b = t >= 66 ? 255 : t <= 19 ? 0 : 138.5177312231 * log(t - 10) - 305.0447927307
    func c(_ v: Double) -> Double { min(max(v, 0), 255) / 255 }
    return Color(red: c(r), green: c(g), blue: c(b))
}

func rgbValue(of color: Color) -> Int? {
    #if os(macOS)
    guard let c = NSColor(color).usingColorSpace(.sRGB) else { return nil }
    let (r, g, b) = (c.redComponent, c.greenComponent, c.blueComponent)
    #else
    var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0
    guard UIColor(color).getRed(&r, green: &g, blue: &b, alpha: nil) else { return nil }
    (r, g, b) = (min(max(r, 0), 1), min(max(g, 0), 1), min(max(b, 0), 1))
    #endif
    return (Int((r * 255).rounded()) << 16) | (Int((g * 255).rounded()) << 8) | Int((b * 255).rounded())
}

// MARK: - Shared views

/// Standard grouped surface. Use for every top-level block on a page.
struct Card<Content: View>: View {
    var padding: CGFloat = 20
    @ViewBuilder var content: Content
    var body: some View {
        content.padding(padding).frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.hairline))
    }
}
/// Older name kept so untouched pages still compile.
typealias Panel = Card

/// Page header: title, one line of context, and trailing actions.
struct PageHeader<Actions: View>: View {
    let title: String
    var subtitle: String?
    @ViewBuilder var actions: Actions
    var body: some View {
        // Actions drop below the title when the page is too narrow (iPhone).
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .firstTextBaseline, spacing: 16) {
                titles
                Spacer(minLength: 12)
                HStack(spacing: 8) { actions }.controlSize(.regular)
            }
            VStack(alignment: .leading, spacing: 12) {
                titles
                HStack(spacing: 8) { actions }.controlSize(.regular)
            }
            VStack(alignment: .leading, spacing: 12) {
                titles
                VStack(alignment: .leading, spacing: 8) { actions }.controlSize(.regular)
            }
        }
    }
    private var titles: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.system(size: 26, weight: .bold)).tracking(-0.5).accessibilityAddTraits(.isHeader)
            if let subtitle { Text(subtitle).font(.system(size: 13)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
        }
    }
}
extension PageHeader where Actions == EmptyView {
    init(title: String, subtitle: String? = nil) { self.init(title: title, subtitle: subtitle) { EmptyView() } }
}
/// Older name kept so untouched pages still compile.
struct PageHeading: View {
    let title: String
    let subtitle: String
    var body: some View { PageHeader(title: title, subtitle: subtitle) }
}

/// Section title inside a page, with an optional trailing accessory.
struct SectionHeader<Accessory: View>: View {
    let title: String
    var detail: String?
    @ViewBuilder var accessory: Accessory
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(title).font(.system(size: 15, weight: .semibold)).accessibilityAddTraits(.isHeader)
            if let detail { Text(detail).font(.system(size: 12)).foregroundStyle(.secondary).monospacedDigit() }
            Spacer(minLength: 8)
            accessory
        }
    }
}
extension SectionHeader where Accessory == EmptyView {
    init(_ title: String, detail: String? = nil) { self.init(title: title, detail: detail) { EmptyView() } }
}

/// Compact status capsule: "Local", "Running", "Offline", "Updating…".
struct StatusPill: View {
    let text: String
    var icon: String?
    var tint: Color = .secondary
    var busy = false
    var body: some View {
        HStack(spacing: 4) {
            if busy { ProgressView().controlSize(.mini).scaleEffect(0.7).frame(width: 10, height: 10) }
            else if let icon { Image(systemName: icon).imageScale(.small) }
            Text(text).lineLimit(1)
        }
        .font(.system(size: 11, weight: .medium)).foregroundStyle(tint)
        .padding(.horizontal, 7).padding(.vertical, 3)
        .background(tint.opacity(0.12), in: Capsule())
        .accessibilityElement(children: .combine)
    }
}

/// A glowing disc showing a light's current color, dimmed when it is off.
struct LightOrb: View {
    let device: LightDevice
    var size: CGFloat = 44
    var body: some View {
        let on = device.power == true && device.online != false
        let color = device.displayColor
        ZStack {
            Circle().fill(on ? color.opacity(0.22) : Color.primary.opacity(0.06))
            Circle().fill(on ? AnyShapeStyle(RadialGradient(colors: [color, color.opacity(0.75)], center: .center, startRadius: 0, endRadius: size * 0.36)) : AnyShapeStyle(Color.primary.opacity(0.08)))
                .padding(size * 0.2)
                .shadow(color: on ? color.opacity(0.6) : .clear, radius: size * 0.18)
            Image(systemName: device.symbol).font(.system(size: size * 0.3, weight: .semibold))
                .foregroundStyle(on ? Color.black.opacity(0.55) : Color.secondary)
        }
        .frame(width: size, height: size)
        .opacity(device.online == false ? 0.5 : 1)
        .animation(.easeOut(duration: 0.25), value: on)
        .animation(.easeOut(duration: 0.25), value: device.rgb)
        .accessibilityHidden(true)
    }
}

/// Centered placeholder for empty lists and first-run states.
struct EmptyState<Actions: View>: View {
    let icon: String
    let title: String
    let message: String
    @ViewBuilder var actions: Actions
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: icon).font(.system(size: 30, weight: .light)).foregroundStyle(Color.lumaAccent).frame(height: 40)
            Text(title).font(.system(size: 15, weight: .semibold))
            Text(message).font(.system(size: 13)).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 420).fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 10) { actions }.padding(.top, 6)
        }.frame(maxWidth: .infinity).padding(.vertical, 36).padding(.horizontal, 20)
    }
}
extension EmptyState where Actions == EmptyView {
    init(icon: String, title: String, message: String) { self.init(icon: icon, title: title, message: message) { EmptyView() } }
}

/// Inline error or confirmation text placed directly under the control that caused it.
struct InlineMessage: View {
    let text: String
    var isError = true
    var body: some View {
        Label(text, systemImage: isError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
            .font(.system(size: 12)).foregroundStyle(isError ? Color.warning : Color.success)
            .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
    }
}

/// Monospaced block with a copy action for URLs and sample requests.
struct CodeBlock: View {
    let text: String
    var copyLabel = "Copy"
    @State private var copied = false
    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Text(text).font(.system(size: 11.5, design: .monospaced)).frame(maxWidth: .infinity, alignment: .leading).fixedSize(horizontal: false, vertical: true)
            Button { copyToPasteboard(text); copied = true } label: { Label(copied ? "Copied" : copyLabel, systemImage: copied ? "checkmark" : "doc.on.doc").labelStyle(.iconOnly) }
                .buttonStyle(.borderless).help(copied ? "Copied" : copyLabel).accessibilityLabel(copyLabel)
        }
        .padding(12).background(Color.well, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .task(id: copied) { if copied { try? await Task.sleep(for: .seconds(1.5)); copied = false } }
    }
}

func copyToPasteboard(_ text: String) {
    #if os(macOS)
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(text, forType: .string)
    #else
    UIPasteboard.general.string = text
    #endif
}

/// Brightness control shared by light cards and the device sheet.
///
/// Holds a local draft while dragging so telemetry or pending-state updates
/// cannot snap the thumb back mid-drag. Non-drag edits (keyboard, scroll,
/// accessibility) commit immediately; a drag commits once on release, and only
/// if the freshest requested value differs.
struct BrightnessSlider: View {
    let store: HomeStore
    let device: LightDevice
    var showsLabel = true
    @State private var brightness: Double = 50
    @State private var editingBrightness = false
    var body: some View {
        VStack(spacing: 4) {
            if showsLabel {
                HStack {
                    Text("Brightness")
                    Spacer()
                    Text(editingBrightness ? "\(Int(brightness))%" : device.brightness.map { "\($0)%" } ?? "—").monospacedDigit()
                }.font(.system(size: 11)).foregroundStyle(.secondary)
            }
            HStack(spacing: 8) {
                Image(systemName: "sun.min").font(.system(size: 11)).foregroundStyle(.tertiary).accessibilityHidden(true)
                // No `step:` — macOS draws tick marks for stepped sliders. The
                // setter rounds instead, so every value stays a whole percent.
                Slider(value: Binding(get: { brightness }, set: { proposed in
                    let value = min(100, max(1, proposed.rounded()))
                    brightness = value
                    // Keyboard, accessibility and scroll-wheel edits may change
                    // the binding without a mouse drag's editing-end callback.
                    if !editingBrightness { requestBrightness(value) }
                }), in: 1...100) { editing in
                    editingBrightness = editing
                    if !editing { requestBrightness(brightness) }
                }
                .controlSize(.small)
                .disabled(!device.supports("brightness"))
                .accessibilityLabel("Brightness for \(device.name)")
                .accessibilityValue(device.brightness.map { "\($0) percent" } ?? "Unknown")
                Image(systemName: "sun.max.fill").font(.system(size: 11)).foregroundStyle(.tertiary).accessibilityHidden(true)
            }
        }
        .onAppear { brightness = Double(device.brightness ?? 50) }
        .onChange(of: device.brightness) { _, value in if !editingBrightness { brightness = Double(value ?? 50) } }
    }
    private func requestBrightness(_ value: Double) {
        guard store.devices.first(where: { $0.id == device.id })?.brightness != Int(value) else { return }
        store.perform(.brightness(Int(value)), ids: [device.id])
    }
}

// MARK: - Platform modifiers

extension View {
    /// Checkbox on macOS; iOS has no checkbox style, so a standard switch.
    @ViewBuilder func checkboxToggle() -> some View {
        #if os(macOS)
        toggleStyle(.checkbox)
        #else
        toggleStyle(.switch)
        #endif
    }

    /// Escape on macOS; iOS has no exit command.
    @ViewBuilder func onExitCommandIfAvailable(perform action: @escaping () -> Void) -> some View {
        #if os(macOS)
        onExitCommand(perform: action)
        #else
        self
        #endif
    }
}

extension View {
    /// Page margin: roomy on the Mac, phone-sized on iOS.
    func pagePadding() -> some View {
        #if os(macOS)
        padding(28)
        #else
        padding(16)
        #endif
    }

    /// Fixed sheet size on the Mac; iOS sheets fill the presentation.
    @ViewBuilder func sheetFrame(width: CGFloat, height: CGFloat? = nil) -> some View {
        #if os(macOS)
        frame(width: width, height: height)
        #else
        frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        #endif
    }
}

/// Mac value, or the tighter iOS one.
func compactSpacing(_ mac: CGFloat, _ iOS: CGFloat) -> CGFloat {
    #if os(macOS)
    mac
    #else
    iOS
    #endif
}

/// Wording that differs between the Mac (menu bar, always running) and iOS
/// (foreground only).
enum PlatformCopy {
    #if os(macOS)
    static let device = "Mac"
    static let tapVerb = "Click"
    static let scheduleNote = "Times use this Mac’s time zone. Luma must be running (the menu bar is fine) and your Mac awake. Missed times are skipped, and a scene that’s already running blocks another from starting."
    static let scenesEmpty = "Save your lighting as scenes you can run from the menu bar, schedules, and webhooks."
    static let scenesWhere = "Run them here, from the menu bar, on a schedule, or with a webhook."
    static let storageNote = "Closing the window keeps Luma in your menu bar so schedules and webhooks keep working. Quit Luma to stop them. Scenes and schedules are saved on this Mac; your API key and webhook token stay in the macOS Keychain. Activity is kept only until you quit."
    #else
    static var device: String { UIDevice.current.userInterfaceIdiom == .pad ? "iPad" : "iPhone" }
    static let tapVerb = "Tap"
    static var scheduleNote: String { "Times use this \(device)’s time zone. iOS pauses apps in the background, so schedules and webhooks run only while Luma is open. Missed times are skipped, and a scene that’s already running blocks another from starting." }
    static let scenesEmpty = "Save your lighting as scenes you can run here, on a schedule, or with a webhook."
    static let scenesWhere = "Run them here, on a schedule, or with a webhook."
    static var storageNote: String { "Schedules and webhooks run only while Luma is open; iOS pauses them in the background. Scenes and schedules are saved on this \(device); your API key and webhook token stay in the iOS Keychain. Activity is kept only until Luma closes." }
    #endif
}
