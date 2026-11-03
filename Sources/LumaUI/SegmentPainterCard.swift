import SwiftUI
import LumaCore

/// Paints RGBIC segments, then sends one command per color (or brightness) group in
/// segment order. Painting stays local until Apply; unpainted segments are left as they
/// are. Shown only for models whose `segmentedColorRgb` / `segmentedBrightness` schema
/// `SegmentPaint` can read. Uses only `HomeStore.send` and `saveScene`.
struct SegmentPainterCard: View {
    let store: HomeStore
    let device: LightDevice
    @State private var instance = ""
    @State private var paint: [String: [Int: Int]] = [:]
    @State private var selected: Set<Int> = []
    @State private var color = Color(red: 1, green: 0.7, blue: 0.28)
    @State private var level = 60.0
    @State private var sending = false
    @State private var message: (text: String, isError: Bool)?

    private var schemas: [SegmentPaint] { SegmentPaint.all(for: device) }

    var body: some View {
        if let schema = schemas.first(where: { $0.instance == instance }) ?? schemas.first {
            Card {
                VStack(alignment: .leading, spacing: 12) {
                    SectionHeader(title: "Segment painter", detail: "\(painted(schema).count) of \(schema.indexes.count) painted") { EmptyView() }
                    if schemas.count > 1 {
                        Picker("Paint", selection: Binding(get: { schema.instance }, set: { instance = $0; selected = [] })) {
                            ForEach(schemas, id: \.instance) { Text($0.isColor ? "Color" : "Brightness").tag($0.instance) }
                        }.pickerStyle(.segmented).labelsHidden().fixedSize()
                    }
                    grid(schema)
                    HStack(spacing: 8) {
                        Button("Select All") { selected = Set(schema.indexes) }
                        Button("Every Other") { selected = Set(schema.indexes.enumerated().filter { $0.offset.isMultiple(of: 2) }.map(\.element)) }
                        Button("Select None") { selected = [] }.disabled(selected.isEmpty)
                        Spacer()
                    }.controlSize(.small)
                    HStack(spacing: 10) {
                        if schema.isColor {
                            ColorPicker("Paint color", selection: $color, supportsOpacity: false).fixedSize()
                        } else {
                            Slider(value: $level, in: Double(schema.valueRange.lowerBound)...Double(schema.valueRange.upperBound), step: 1) { Text("Segment brightness") }
                            Text("\(Int(level))%").monospacedDigit().font(.system(size: 12)).frame(width: 40, alignment: .trailing)
                        }
                        Button("Paint Selected") { fill(schema) }.disabled(selected.isEmpty)
                        if schema.isColor { Button("Rainbow") { rainbow(schema) }.disabled(selected.count < 2) }
                    }
                    HStack(spacing: 8) {
                        Button { apply(schema) } label: {
                            HStack(spacing: 6) { if sending { ProgressView().controlSize(.small) }; Text("Apply to Light") }
                        }.buttonStyle(.borderedProminent).disabled(painted(schema).isEmpty || sending)
                        Button("Save as Scene") { save(schema) }.disabled(painted(schema).isEmpty)
                        Button("Clear") { paint[schema.instance] = [:]; selected = [] }.disabled(painted(schema).isEmpty)
                        Spacer()
                    }
                    if let message { InlineMessage(text: message.text, isError: message.isError) }
                    Text("Segments sharing a value are sent as one command, in segment order.")
                        .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private func painted(_ schema: SegmentPaint) -> [Int: Int] { paint[schema.instance] ?? [:] }

    private func grid(_ schema: SegmentPaint) -> some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 34, maximum: 48), spacing: 4)], spacing: 4) {
            ForEach(schema.indexes, id: \.self) { index in
                let value = painted(schema)[index], isOn = selected.contains(index)
                Button { if isOn { selected.remove(index) } else { selected.insert(index) } } label: {
                    Text("\(index + 1)").font(.system(size: 11, weight: isOn ? .bold : .regular)).monospacedDigit()
                        .frame(maxWidth: .infinity, minHeight: 28)
                        .foregroundStyle(value == nil ? Color.primary : .white)
                        .background(swatch(value, schema: schema), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(isOn ? Color.lumaAccent : Color.hairline, lineWidth: isOn ? 2 : 1))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Segment \(index + 1)\(value.map { schema.isColor ? String(format: ", color %06X", $0) : ", \($0)%" } ?? "")")
                .accessibilityAddTraits(isOn ? .isSelected : [])
            }
        }
    }

    private func swatch(_ value: Int?, schema: SegmentPaint) -> Color {
        guard let value else { return Color.well }
        if schema.isColor { return Color(red: Double(value >> 16 & 0xFF) / 255, green: Double(value >> 8 & 0xFF) / 255, blue: Double(value & 0xFF) / 255) }
        return Color.lumaAccent.opacity(0.2 + 0.8 * Double(value) / Double(max(1, schema.valueRange.upperBound)))
    }

    private func fill(_ schema: SegmentPaint) {
        let value = schema.isColor ? rgb(color) : min(max(Int(level), schema.valueRange.lowerBound), schema.valueRange.upperBound)
        for index in selected { paint[schema.instance, default: [:]][index] = value }
    }

    private func rainbow(_ schema: SegmentPaint) {
        let picked = schema.indexes.filter(selected.contains)
        for (n, index) in picked.enumerated() { paint[schema.instance, default: [:]][index] = rgb(Color(hue: Double(n) / Double(picked.count), saturation: 1, brightness: 1)) }
    }

    private func rgb(_ color: Color) -> Int {
        let c = color.resolve(in: EnvironmentValues())
        let byte = { (v: Float) in Int((min(max(v, 0), 1) * 255).rounded()) }
        return byte(c.red) << 16 | byte(c.green) << 8 | byte(c.blue)
    }

    private func apply(_ schema: SegmentPaint) {
        let commands: [CapabilityCommand]
        do {
            commands = try schema.commands(for: painted(schema))
            for command in commands { try CommandValidation.validate(command, for: device) } // nothing is sent unless all pass
        } catch { message = (error.localizedDescription, true); return }
        sending = true
        Task {
            do {
                for command in commands { try await store.send(command, to: device.id) }
                message = ("Sent \(commands.count) segment command\(commands.count == 1 ? "" : "s")", false)
            } catch { message = (error.localizedDescription, true) }
            sending = false
        }
    }

    private func save(_ schema: SegmentPaint) {
        do {
            var steps = device.supports("powerSwitch") ? [SceneStep(deviceID: device.id, command: .power(true))] : []
            steps += try schema.commands(for: painted(schema)).map { SceneStep(deviceID: device.id, command: $0) }
            try store.saveScene(.init(name: "\(device.name) · Segments", symbol: "paintpalette", steps: steps))
            message = ("Saved to Scenes", false)
        } catch { message = (error.localizedDescription, true) }
    }
}
