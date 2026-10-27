import SwiftUI
import LumaCore

/// Creates a valid starting shape using the device's own capability schema.
func defaultCapabilityValue(_ parameters: JSONValue) -> JSONValue {
    switch parameters["dataType"]?.string?.uppercased() {
    case "INTEGER": return .number(parameters["range"]?["min"]?.number ?? 0)
    case "ENUM": return parameters["options"]?.array?.first?["value"] ?? .null
    case "STRUCT":
        var object: [String: JSONValue] = [:]
        for field in parameters["fields"]?.array ?? [] where field["required"] == .bool(true) {
            if let name = field["fieldName"]?.string { object[name] = defaultCapabilityValue(field) }
        }
        return .object(object)
    case "ARRAY":
        guard let range = integerElementRange(parameters) else { return .array([]) }
        let minimum = boundedSize(parameters["size"]?["min"], fallback: 0)
        return .array(range.prefix(minimum).map { .number(Double($0)) })
    default: return .null
    }
}

struct CapabilityValueForm: View {
    let parameters: JSONValue
    @Binding var value: JSONValue

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            switch parameters["dataType"]?.string?.uppercased() {
            case "INTEGER": integerControl
            case "ENUM": enumControl
            case "STRUCT": structControl
            case "ARRAY":
                if parameters["elementType"]?.string?.uppercased() == "INTEGER" {
                    IntegerArrayControl(parameters: parameters, value: $value)
                } else {
                    Text("Open Advanced below to edit this list.").font(.system(size: 11)).foregroundStyle(.secondary)
                }
            default:
                Text("Open Advanced below to edit this value.").font(.system(size: 11)).foregroundStyle(.secondary)
            }
        }
    }

    private var lowerBound: Double? { parameters["range"]?["min"]?.number }
    private var upperBound: Double? { parameters["range"]?["max"]?.number }
    private var integerValue: Binding<Double> {
        Binding(get: { value.number ?? lowerBound ?? 0 }, set: { proposed in
            guard proposed.isFinite else { return }
            var result = proposed.rounded()
            if let minimum = lowerBound { result = max(minimum, result) }
            if let maximum = upperBound { result = min(maximum, result) }
            value = .number(result)
        })
    }

    private var integerControl: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                TextField("Value", value: integerValue, format: .number.precision(.fractionLength(0)))
                    .textFieldStyle(.roundedBorder).frame(maxWidth: 180)
                    .accessibilityLabel("Integer value")
                if let minimum = lowerBound, let maximum = upperBound, minimum <= maximum {
                    Stepper("Value", value: integerValue, in: minimum...maximum, step: 1).labelsHidden()
                }
                if parameters["unit"]?.string == "unit.percent" { Text("%").foregroundStyle(.secondary) }
                Spacer(minLength: 0)
            }
            if let minimum = lowerBound, let maximum = upperBound, minimum < maximum, maximum - minimum <= 10_000 {
                // No `step:` (it draws tick marks); `integerValue` rounds in its setter.
                Slider(value: integerValue, in: minimum...maximum).accessibilityLabel("Integer value")
            }
            if let minimum = lowerBound, let maximum = upperBound {
                Text("\(numberLabel(minimum))–\(numberLabel(maximum))").font(.system(size: 11)).foregroundStyle(.secondary).monospacedDigit()
            }
        }
    }

    @ViewBuilder private var enumControl: some View {
        if let options = parameters["options"]?.array, !options.isEmpty {
            Picker("Value", selection: Binding(get: {
                options.firstIndex { $0["value"] == value } ?? -1
            }, set: { index in
                if options.indices.contains(index), let selected = options[index]["value"] { value = selected }
            })) {
                if !options.contains(where: { $0["value"] == value }) { Text("Choose a value").tag(-1) }
                ForEach(Array(options.enumerated()), id: \.offset) { index, option in
                    Text(friendlyOptionName(option["name"]?.string) ?? option["value"]?.pretty ?? "Option \(index + 1)").tag(index)
                }
            }
            .pickerStyle(.menu).labelsHidden().fixedSize()
            .accessibilityLabel("Value")
        } else {
            Text("No options were supplied. Open Advanced below to enter a value.").font(.system(size: 11)).foregroundStyle(.secondary)
        }
    }

    private var structControl: some View {
        VStack(alignment: .leading, spacing: 16) {
            ForEach(Array((parameters["fields"]?.array ?? []).enumerated()), id: \.offset) { _, field in
                if let name = field["fieldName"]?.string {
                    VStack(alignment: .leading, spacing: 8) {
                        if field["required"] == .bool(true) {
                            Text(fieldLabel(name)).font(.callout.weight(.medium))
                            if name == "rgb" { RGBValueControl(value: fieldValue(name, field: field)) }
                            else if isStruct(field) { nested(CapabilityValueForm(parameters: field, value: fieldValue(name, field: field))) }
                            else { AnyView(CapabilityValueForm(parameters: field, value: fieldValue(name, field: field))) }
                        } else {
                            Toggle(fieldLabel(name), isOn: Binding(get: {
                                value[name] != nil
                            }, set: { include in
                                var object = objectValue
                                object[name] = include ? defaultCapabilityValue(field) : nil
                                value = .object(object)
                            }))
                            .checkboxToggle().font(.callout.weight(.medium))
                            .accessibilityLabel("Include \(fieldLabel(name).lowercased())")
                            if value[name] != nil {
                                if name == "rgb" { nested(RGBValueControl(value: fieldValue(name, field: field))) }
                                else { nested(CapabilityValueForm(parameters: field, value: fieldValue(name, field: field))) }
                            }
                        }
                    }
                }
            }
        }
    }

    private func isStruct(_ field: JSONValue) -> Bool { field["dataType"]?.string?.uppercased() == "STRUCT" }

    /// Indents a sub-field under its label with a subtle leading rule.
    private func nested<Content: View>(_ content: Content) -> some View {
        content.padding(.leading, 14)
            .overlay(alignment: .leading) { Capsule().fill(Color.primary.opacity(0.14)).frame(width: 2) }
            .padding(.leading, 2)
    }

    private var objectValue: [String: JSONValue] {
        if case .object(let object) = value { return object }
        return [:]
    }

    private func fieldValue(_ name: String, field: JSONValue) -> Binding<JSONValue> {
        Binding(get: { value[name] ?? defaultCapabilityValue(field) }, set: { newValue in
            var object = objectValue
            object[name] = newValue
            value = .object(object)
        })
    }
}

private struct RGBValueControl: View {
    @Binding var value: JSONValue
    var body: some View {
        HStack(spacing: 10) {
            ColorPicker("Color", selection: Binding(get: { Color(rgb: current) }, set: { color in
                guard let rgb = rgbValue(of: color) else { return }
                value = .number(Double(rgb))
            }), supportsOpacity: false).labelsHidden()
            Text(String(format: "#%06X", current)).font(.system(size: 12, design: .monospaced)).foregroundStyle(.secondary)
                .textSelection(.enabled)
            Spacer(minLength: 0)
        }
    }

    private var current: Int {
        let n = value.number ?? 0
        return n.isFinite && (0...16777215).contains(n) ? Int(n) : 0
    }
}

private struct IntegerArrayControl: View {
    let parameters: JSONValue
    @Binding var value: JSONValue
    @State private var text = ""

    private var selected: [Int] {
        (value.array ?? []).compactMap { item in
            guard let number = item.number, number.isFinite, number.rounded() == number,
                  (-1_000_000...1_000_000).contains(number) else { return nil }
            return Int(number)
        }
    }
    private var minimum: Int { boundedSize(parameters["size"]?["min"], fallback: 0) }
    private var maximum: Int { boundedSize(parameters["size"]?["max"], fallback: 64) }
    private var isSegment: Bool { parameters["fieldName"]?.string?.lowercased().contains("segment") == true }
    private var sizeLabel: String {
        isSegment ? "Choose \(minimum)–\(maximum) segments. Numbering follows the light." : "Choose \(minimum)–\(maximum) items. Numbering follows the light."
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let range = integerElementRange(parameters), range.count <= 64 {
                HStack {
                    Text("\(selected.count) selected").font(.system(size: 11)).foregroundStyle(.secondary).monospacedDigit()
                    Spacer()
                    if range.count <= maximum {
                        Button("Select All") { value = .array(range.map { .number(Double($0)) }) }
                    }
                    if minimum == 0 { Button("Clear") { value = .array([]) } }
                }
                .buttonStyle(.borderless).controlSize(.small)
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 36), spacing: 6)], spacing: 6) {
                    ForEach(Array(range), id: \.self) { item in
                        let included = selected.contains(item)
                        Button {
                            var items = selected
                            if included { items.removeAll { $0 == item } } else { items.append(item) }
                            value = .array(items.sorted().map { .number(Double($0)) })
                        } label: {
                            Text("\(item)").font(.system(size: 12, weight: .medium)).monospacedDigit()
                                .foregroundStyle(included ? Color.white : Color.primary)
                                .frame(maxWidth: .infinity, minHeight: 28)
                                .background(included ? Color.lumaAccentFill : Color.well, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                                .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("\(isSegment ? "Segment" : "Item") \(item), \(included ? "selected" : "unselected")")
                        .accessibilityAddTraits(included ? .isSelected : [])
                        .disabled(included ? selected.count <= minimum : selected.count >= maximum)
                    }
                }
            } else {
                TextField("Integers separated by commas", text: $text).textFieldStyle(.roundedBorder)
                    .onAppear { synchronizeText() }
                    .onChange(of: text) { _, proposed in
                        if let parsed = parseIntegerArray(proposed) { value = .array(parsed.map { .number($0) }) }
                    }
                    .onChange(of: value) { _, newValue in
                        let current = parseIntegerArray(text).map { JSONValue.array($0.map { .number($0) }) }
                        if current != newValue { synchronizeText() }
                    }
                if parseIntegerArray(text) == nil {
                    Text("Enter whole numbers separated by commas.").font(.system(size: 11)).foregroundStyle(Color.warning)
                }
                if let minimum = parameters["elementRange"]?["min"]?.number,
                   let maximum = parameters["elementRange"]?["max"]?.number {
                    Text("Each value: \(numberLabel(minimum))–\(numberLabel(maximum))").font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
            Text(sizeLabel).font(.system(size: 11)).foregroundStyle(.secondary)
        }
    }

    private func synchronizeText() {
        text = (value.array ?? []).compactMap { $0.number }.map(numberLabel).joined(separator: ", ")
    }

    private func parseIntegerArray(_ source: String) -> [Double]? {
        if source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return [] }
        let pieces = source.split(separator: ",", omittingEmptySubsequences: false)
        var numbers: [Double] = []
        for piece in pieces {
            guard let number = Double(piece.trimmingCharacters(in: .whitespacesAndNewlines)),
                  number.isFinite, number.rounded() == number else { return nil }
            numbers.append(number)
        }
        return numbers
    }
}

private func integerElementRange(_ parameters: JSONValue) -> ClosedRange<Int>? {
    guard let minimum = parameters["elementRange"]?["min"]?.number,
          let maximum = parameters["elementRange"]?["max"]?.number,
          minimum.isFinite, maximum.isFinite, minimum.rounded() == minimum, maximum.rounded() == maximum,
          minimum >= -1_000_000, maximum <= 1_000_000, minimum <= maximum else { return nil }
    return Int(minimum)...Int(maximum)
}

private func boundedSize(_ value: JSONValue?, fallback: Int) -> Int {
    guard let number = value?.number, number.isFinite else { return fallback }
    return Int(min(1_000_000, max(0, number.rounded(.up))))
}

private func numberLabel(_ number: Double) -> String {
    number.formatted(.number.grouping(.never).precision(.fractionLength(0)))
}

/// Option names from Govee are sometimes identifiers ("sunriseGlow"); make those readable.
private func friendlyOptionName(_ name: String?) -> String? {
    guard let name, !name.isEmpty else { return nil }
    return name.contains(" ") ? name : fieldLabel(name)
}

private func fieldLabel(_ name: String) -> String {
    let spaced = name.replacingOccurrences(of: "([a-z])([A-Z])", with: "$1 $2", options: .regularExpression)
        .replacingOccurrences(of: "_", with: " ")
    return spaced.prefix(1).uppercased() + spaced.dropFirst()
}
