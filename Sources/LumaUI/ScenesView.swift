import SwiftUI
import LumaCore
import UniformTypeIdentifiers

// MARK: - Shared helpers

private let sceneSymbols = ["sparkles", "moon.stars", "sun.max", "sunrise", "sunset", "sofa", "bed.double", "film",
                            "tv", "gamecontroller", "book", "cup.and.saucer", "fork.knife", "party.popper", "music.note", "leaf"]
private let defaultSceneSymbol = "sparkles"
private let amberRGB = 0xFFB347

private func formatSeconds(_ ms: Int) -> String {
    ms % 1000 == 0 ? "\(ms / 1000) s" : String(format: "%.1f s", Double(ms) / 1000)
}

private func humanized(_ camelCase: String) -> String {
    var out = ""
    for ch in camelCase { if ch.isUppercase, !out.isEmpty { out += " " }; out += ch.lowercased() }
    return out.prefix(1).uppercased() + out.dropFirst()
}

/// Friendly title for commands the structured editor has no dedicated control for.
private func friendlyTitle(for instance: String) -> String {
    switch instance {
    case "musicMode": "Music mode"
    case "segmentedColorRgb": "Segment color"
    case "segmentedBrightness": "Segment brightness"
    case "lightScene": "Light effect"
    case "diyScene": "DIY effect"
    case "snapshot": "Saved snapshot"
    case "gradientToggle": "Gradient"
    case "nightlightToggle": "Nightlight"
    default: humanized(instance)
    }
}

/// Distinct color/white values a scene uses, for the preview dots on a card.
private func swatchKeys(for scene: LightScene) -> [Int] {
    var seen = Set<Int>()
    var keys: [Int] = []
    for step in scene.steps {
        guard let n = step.command.value.number else { continue }
        let key: Int
        switch step.command.instance {
        case "colorRgb": key = Int(n)
        case "colorTemperatureK": key = -Int(n)
        default: continue
        }
        if seen.insert(key).inserted { keys.append(key) }
    }
    return Array(keys.prefix(8))
}

private func swatchColor(_ key: Int) -> Color { key >= 0 ? Color(rgb: key) : kelvinColor(-key) }

// MARK: - Symbol picker

private struct SymbolGrid: View {
    @Binding var selection: String
    var body: some View {
        let options = sceneSymbols.contains(selection) ? sceneSymbols : [selection] + sceneSymbols
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 36), spacing: 8)], alignment: .leading, spacing: 8) {
            ForEach(options, id: \.self) { symbol in
                let selected = symbol == selection
                Button { selection = symbol } label: {
                    Image(systemName: symbol).font(.system(size: 15)).frame(width: 36, height: 32)
                        .foregroundStyle(selected ? Color.lumaAccent : Color.secondary)
                        .background(selected ? Color.lumaAccent.opacity(0.14) : Color.well, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(selected ? Color.lumaAccent : Color.clear, lineWidth: 1.5))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(symbol.replacingOccurrences(of: ".", with: " "))
                .accessibilityLabel(symbol.replacingOccurrences(of: ".", with: " "))
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
    }
}

// MARK: - Scenes page

struct ScenesView: View {
    let store: HomeStore
    @State private var showNew = false
    @State private var editor: LightScene?
    @State private var deleting: LightScene?
    @State private var errorText: String?
    @State private var importing = false
    @State private var exporting: SceneFile?
    @State private var showExporter = false

    var body: some View {
        let scenes = store.home.scenes
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                PageHeader(title: "Scenes", subtitle: scenes.isEmpty
                           ? PlatformCopy.scenesEmpty
                           : "\(scenes.count) \(scenes.count == 1 ? "scene" : "scenes") · \(PlatformCopy.scenesWhere)") {
                    Button("Import…", systemImage: "square.and.arrow.down") { importing = true }
                        .help("Import a scene from a JSON file")
                    Button("New Scene", systemImage: "plus") { showNew = true }
                        .buttonStyle(.borderedProminent)
                        .disabled(store.devices.isEmpty)
                        .help(store.devices.isEmpty ? "Connect your lights first" : "Save your current lighting as a scene")
                }
                if let errorText { InlineMessage(text: errorText) }
                if store.runningSceneID != nil { runningBanner }
                if scenes.isEmpty { emptyState } else { sceneGrid(scenes) }
                if !store.runs.isEmpty { recentRuns }
                Text("Scenes run their steps in order, with optional pauses in between. Stopping a scene skips the remaining steps, but it doesn't undo anything already sent to your lights.")
                    .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            .pagePadding()
        }
        .sheet(isPresented: $showNew) { NewSceneSheet(store: store) }
        .sheet(item: $editor) { SceneEditor(store: store, scene: $0) }
        .confirmationDialog(deleting.map { "Delete “\($0.name)”?" } ?? "Delete scene?",
                            isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
                            titleVisibility: .visible, presenting: deleting) { scene in
            Button("Delete Scene", role: .destructive) { delete(scene) }
            Button("Cancel", role: .cancel) {}
        } message: { scene in
            let count = store.home.schedules.filter { $0.sceneID == scene.id }.count
            Text(count == 0 ? "This can't be undone." : "This also removes \(count) \(count == 1 ? "schedule" : "schedules") that \(count == 1 ? "runs" : "run") it. This can't be undone.")
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.json]) { importScene(from: $0) }
        // A plain flag: a Binding(get:set:) here crashes the Swift 6.3 compiler (IRGen).
        .fileExporter(isPresented: $showExporter, document: exporting,
                      contentType: .json, defaultFilename: exporting?.name) { result in
            if case .failure(let error) = result { errorText = error.localizedDescription } else { errorText = nil }
        }
    }

    // MARK: Sections

    private var runningBanner: some View {
        let id = store.runningSceneID
        let name = store.home.scenes.first { $0.id == id }?.name ?? store.runs.first { $0.status == "running" }?.name ?? "scene"
        return Card(padding: 12) {
            HStack(spacing: 12) {
                ProgressView().controlSize(.small)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Running \(name)").font(.system(size: 13, weight: .semibold)).lineLimit(1)
                    Text("Stopping skips the remaining steps. It doesn't undo commands already sent.").font(.system(size: 12)).foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                Button("Stop", systemImage: "stop.fill") { store.stopScene() }
                    .help("Stop the running scene")
            }
        }
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.lumaAccent.opacity(0.4)))
    }

    private var emptyState: some View {
        Card {
            EmptyState(icon: "sparkles", title: "No scenes yet",
                       message: store.devices.isEmpty
                       ? "Connect your lights first, then save them the way you like them as a scene."
                       : "Set your lights the way you like them, then save it as a scene. You can run it later with one click, a schedule, or a webhook.") {
                Button("New Scene", systemImage: "plus") { showNew = true }
                    .buttonStyle(.borderedProminent).disabled(store.devices.isEmpty)
            }
        }
    }

    private func sceneGrid(_ scenes: [LightScene]) -> some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 240), spacing: 16, alignment: .top)], alignment: .leading, spacing: 16) {
            ForEach(scenes) { card($0) }
        }
    }

    private func card(_ scene: LightScene) -> some View {
        let running = store.runningSceneID == scene.id
        let lights = Set(scene.steps.map(\.deviceID)).count
        let total = scene.steps.reduce(0) { $0 + $1.delayMilliseconds }
        var summary = "\(lights) \(lights == 1 ? "light" : "lights") · \(scene.steps.count) \(scene.steps.count == 1 ? "step" : "steps")"
        if total > 0 { summary += " · \(formatSeconds(total))" }
        return Card(padding: 16) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: scene.symbol).font(.system(size: 17)).foregroundStyle(Color.lumaAccent)
                        .frame(width: 36, height: 36)
                        .background(Color.lumaAccent.opacity(0.12), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(scene.name).font(.system(size: 14, weight: .semibold)).lineLimit(1)
                        Text(summary).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer(minLength: 4)
                    Menu { sceneActions(scene) } label: { Image(systemName: "ellipsis.circle").font(.system(size: 15)) }
                        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                        .help("More actions")
                        .accessibilityLabel("More actions for \(scene.name)")
                }
                HStack(spacing: 5) {
                    ForEach(swatchKeys(for: scene), id: \.self) { key in
                        Circle().fill(swatchColor(key)).frame(width: 14, height: 14)
                            .overlay(Circle().strokeBorder(Color.primary.opacity(0.15)))
                    }
                    Spacer(minLength: 0)
                }
                .frame(height: 14).accessibilityHidden(true)
                HStack {
                    if running {
                        StatusPill(text: "Running", tint: .lumaAccent, busy: true)
                        Spacer(minLength: 8)
                        Button("Stop", systemImage: "stop.fill") { store.stopScene() }
                            .controlSize(.small).accessibilityLabel("Stop \(scene.name)")
                    } else {
                        Button("Run", systemImage: "play.fill") { run(scene) }
                            .buttonStyle(.borderedProminent).controlSize(.small)
                            .disabled(store.runningSceneID != nil)
                            .help(store.runningSceneID != nil ? "Another scene is running" : "Run this scene")
                            .accessibilityLabel("Run \(scene.name)")
                        Spacer(minLength: 0)
                    }
                }
            }
        }
        .contextMenu { sceneActions(scene) }
    }

    @ViewBuilder private func sceneActions(_ scene: LightScene) -> some View {
        Button("Edit…", systemImage: "pencil") { editor = scene }
        Button("Duplicate", systemImage: "plus.square.on.square") { duplicate(scene) }
        Button("Export…", systemImage: "square.and.arrow.up") { exportScene(scene) }
        Divider()
        Button("Delete…", systemImage: "trash", role: .destructive) { deleting = scene }
    }

    private var recentRuns: some View {
        let runs = Array(store.runs.prefix(6))
        return VStack(alignment: .leading, spacing: 12) {
            SectionHeader("Recent runs")
            Card(padding: 4) {
                VStack(spacing: 0) {
                    ForEach(runs) { run in
                        runRow(run)
                        if run.id != runs.last?.id { Divider().padding(.horizontal, 12) }
                    }
                }
            }
        }
    }

    private func runRow(_ run: AutomationRun) -> some View {
        let (label, icon, tint, busy): (String, String?, Color, Bool) = switch run.status {
        case "completed": ("Completed", "checkmark.circle.fill", .success, false)
        case "running": ("Running", nil, .lumaAccent, true)
        case "cancelled": ("Stopped", "stop.circle", .secondary, false)
        case "failed": ("Failed", "exclamationmark.triangle.fill", .danger, false)
        default: (run.status.capitalized, nil, .secondary, false)
        }
        return HStack(alignment: .firstTextBaseline, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(run.name).font(.system(size: 13)).lineLimit(1)
                if let error = run.error, run.status == "failed" {
                    Text(error).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(2)
                }
            }
            Spacer(minLength: 8)
            Text(run.startedAt.formatted(.relative(presentation: .named))).font(.system(size: 12)).foregroundStyle(.secondary)
            StatusPill(text: label, icon: icon, tint: tint, busy: busy)
                .help(run.error ?? label)
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .accessibilityElement(children: .combine)
    }

    // MARK: Actions

    private func run(_ scene: LightScene) {
        do { try store.runScene(scene); errorText = nil } catch { errorText = error.localizedDescription }
    }

    private func duplicate(_ scene: LightScene) {
        let copy = LightScene(name: "\(scene.name) Copy", symbol: scene.symbol,
                              steps: scene.steps.map { SceneStep(deviceID: $0.deviceID, command: $0.command, delayMilliseconds: $0.delayMilliseconds) })
        do { try store.saveScene(copy); errorText = nil } catch { errorText = error.localizedDescription }
    }

    private func delete(_ scene: LightScene) {
        store.home.scenes.removeAll { $0.id == scene.id }
        store.home.schedules.removeAll { $0.sceneID == scene.id }
        store.persist()
    }

    private func importScene(from result: Result<URL, any Error>) {
        do {
            let url = try result.get()
            // Files from the iOS document picker are security scoped.
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            let data = try Data(contentsOf: url)
            guard data.count < 1024 * 1024 else { throw LumaError.message("Scene file must be smaller than 1 MB.") }
            try store.saveScene(JSONDecoder().decode(LightScene.self, from: data)); errorText = nil
        } catch { errorText = error.localizedDescription }
    }

    private func exportScene(_ scene: LightScene) {
        do { exporting = SceneFile(name: scene.name, data: try JSONEncoder.pretty.encode(scene)); showExporter = true; errorText = nil } catch { errorText = error.localizedDescription }
    }
}

/// A scene's JSON for the system save panel or document picker.
struct SceneFile: FileDocument {
    static let readableContentTypes: [UTType] = [.json]
    let name: String
    let data: Data
    init(name: String, data: Data) { self.name = name; self.data = data }
    init(configuration: ReadConfiguration) throws { name = "Scene"; data = configuration.file.regularFileContents ?? Data() }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper { FileWrapper(regularFileWithContents: data) }
}

// MARK: - New scene sheet

private struct NewSceneSheet: View {
    let store: HomeStore
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var symbol = defaultSceneSymbol
    @State private var selected: Set<String>
    @State private var errorText: String?
    @FocusState private var nameFocused: Bool

    init(store: HomeStore) {
        self.store = store
        _selected = State(initialValue: Set(store.devices.map(\.id)))
    }

    private var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        let devices = store.devices
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 4) {
                Text("New Scene").font(.system(size: 20, weight: .bold)).accessibilityAddTraits(.isHeader)
                Text("Save your lights as they are right now.").font(.system(size: 13)).foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("Name").font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
                TextField("e.g. Movie night", text: $name).textFieldStyle(.roundedBorder).focused($nameFocused)
                    .onSubmit(save).accessibilityLabel("Scene name")
            }
            VStack(alignment: .leading, spacing: 8) {
                Text("Symbol").font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
                SymbolGrid(selection: $symbol)
            }
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Lights").font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
                    Text("\(selected.count) of \(devices.count) selected").font(.system(size: 12)).foregroundStyle(.tertiary).monospacedDigit()
                    Spacer()
                    Button("Select All") { selected = Set(devices.map(\.id)) }.disabled(selected.count == devices.count)
                    Button("Select None") { selected = [] }.disabled(selected.isEmpty)
                }
                .buttonStyle(.borderless).font(.system(size: 12))
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(devices) { device in
                            Toggle(isOn: Binding(get: { selected.contains(device.id) },
                                                 set: { if $0 { selected.insert(device.id) } else { selected.remove(device.id) } })) {
                                HStack(spacing: 10) {
                                    LightOrb(device: device, size: 24)
                                    Text(device.name).lineLimit(1)
                                    Spacer(minLength: 8)
                                    Text(device.room).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
                                }.frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .checkboxToggle().padding(.horizontal, 12).frame(height: 36)
                        }
                    }
                }
                .frame(height: min(CGFloat(max(devices.count, 1)) * 36, 216))
                .background(Color.well, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                Text("Each light's last known state is saved, so refresh your lights first for accuracy. Lights that are off are saved as off.")
                    .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            if let errorText { InlineMessage(text: errorText) }
            HStack {
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("Save Scene", action: save).keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(trimmedName.isEmpty || selected.isEmpty)
            }
        }
        .padding(24).sheetFrame(width: 520).background(Color.canvas)
        .onAppear { nameFocused = true }
    }

    private func save() {
        guard !trimmedName.isEmpty, !selected.isEmpty else { return }
        do {
            let ids = store.devices.map(\.id).filter(selected.contains)
            try store.captureScene(name: trimmedName, ids: ids)
            if symbol != defaultSceneSymbol, var scene = store.home.scenes.last(where: { $0.name == trimmedName }) {
                scene.symbol = symbol
                try store.saveScene(scene)
            }
            dismiss()
        } catch { errorText = error.localizedDescription }
    }
}

// MARK: - Scene editor

struct SceneEditor: View {
    let store: HomeStore
    let scene: LightScene
    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var symbol: String
    @State private var steps: [SceneStep]
    @State private var jsonMode = false
    @State private var jsonText = ""
    @State private var errorText: String?
    @State private var newStepID: UUID?

    init(store: HomeStore, scene: LightScene) {
        self.store = store
        self.scene = scene
        _name = State(initialValue: scene.name)
        _symbol = State(initialValue: scene.symbol)
        _steps = State(initialValue: Self.editableSteps(scene.steps))
    }

    static func editableSteps(_ original: [SceneStep]) -> [SceneStep] {
        var seen = Set<UUID>()
        return original.map { step in
            var step = step
            while !seen.insert(step.id).inserted { step.id = UUID() }
            return step
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Edit Scene").font(.system(size: 20, weight: .bold)).accessibilityAddTraits(.isHeader)
                Text("Steps run from top to bottom. Add a wait to pause before a step.").font(.system(size: 13)).foregroundStyle(.secondary)
            }
            HStack(alignment: .top, spacing: 20) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Name").font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
                    TextField("Scene name", text: $name).textFieldStyle(.roundedBorder).accessibilityLabel("Scene name")
                }.frame(width: 240)
                VStack(alignment: .leading, spacing: 6) {
                    Text("Symbol").font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
                    SymbolGrid(selection: $symbol)
                }
            }
            .disabled(jsonMode)
            SectionHeader(title: "Steps", detail: jsonMode ? nil : "\(steps.count)") {
                if !jsonMode { addStepMenu }
            }
            if jsonMode { jsonEditor } else { stepList }
            if let errorText { InlineMessage(text: errorText) }
            DisclosureGroup("Advanced") {
                VStack(alignment: .leading, spacing: 4) {
                    Toggle("Edit as JSON", isOn: Binding(get: { jsonMode }, set: setJSONMode(_:)))
                    Text("For power users and effects the step editor doesn't cover. Switching back checks your changes.")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                }.padding(.top, 6)
            }
            HStack {
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("Save Changes", action: save).keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(24).sheetFrame(width: 720, height: 620).background(Color.canvas)
    }

    // MARK: Steps

    private var stepList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                if steps.isEmpty {
                    Text("No steps yet. Use Add Step to choose a light and what it should do.")
                        .font(.system(size: 13)).foregroundStyle(.secondary).frame(maxWidth: .infinity).padding(.vertical, 32)
                }
                LazyVStack(spacing: 8) {
                    ForEach($steps) { $step in
                        let index = steps.firstIndex { $0.id == step.id } ?? 0
                        StepRow(step: $step, number: index + 1, device: store.devices.first { $0.id == step.deviceID },
                                canMoveUp: index > 0, canMoveDown: index < steps.count - 1,
                                onMoveUp: { steps.swapAt(index, index - 1) },
                                onMoveDown: { steps.swapAt(index, index + 1) },
                                onDelete: { steps.removeAll { $0.id == step.id } })
                        .id(step.id)
                    }
                }.padding(8)
            }
            .frame(maxHeight: .infinity)
            .background(Color.well, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .onChange(of: newStepID) { _, id in
                guard let id else { return }
                withAnimation { proxy.scrollTo(id, anchor: .bottom) }
                newStepID = nil
            }
        }
    }

    private var addStepMenu: some View {
        Menu {
            ForEach(store.devices) { device in
                Menu(device.name) {
                    Button("Turn On") { add(device, .power(true)) }
                    Button("Turn Off") { add(device, .power(false)) }
                    if device.supports("brightness") { Button("Brightness 50%") { add(device, .brightness(50)) } }
                    if device.supports("colorRgb") { Button("Color") { add(device, .rgb(device.rgb ?? amberRGB)) } }
                    if device.supports("colorTemperatureK") {
                        let initial = min(max(3000, sceneWhiteRange(for: device).lowerBound), sceneWhiteRange(for: device).upperBound)
                        Button("White \(initial) K") { add(device, .kelvin(initial)) }
                    }
                }
            }
        } label: { Label("Add Step", systemImage: "plus") }
            .menuStyle(.borderlessButton).fixedSize()
            .disabled(store.devices.isEmpty)
            .help(store.devices.isEmpty ? "Connect your lights first" : "Add a step for one of your lights")
    }

    private func add(_ device: LightDevice, _ command: CapabilityCommand) {
        let step = SceneStep(deviceID: device.id, command: command)
        steps.append(step)
        newStepID = step.id
    }

    // MARK: JSON

    private var jsonEditor: some View {
        TextEditor(text: $jsonText).font(.system(size: 12, design: .monospaced)).scrollContentBackground(.hidden)
            .padding(8).frame(maxHeight: .infinity)
            .background(Color.well, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .accessibilityLabel("Scene JSON")
    }

    private var draft: LightScene { LightScene(id: scene.id, name: name, symbol: symbol, steps: steps) }

    private func setJSONMode(_ on: Bool) {
        errorText = nil
        if on {
            jsonText = (try? String(data: JSONEncoder.pretty.encode(draft), encoding: .utf8)) ?? ""
            jsonMode = true
        } else {
            do { try applyJSON(); jsonMode = false } catch { errorText = error.localizedDescription }
        }
    }

    private func applyJSON() throws {
        let decoded = try Self.validatedJSON(jsonText, devices: store.devices)
        name = decoded.name; symbol = decoded.symbol; steps = decoded.steps
    }

    static func validatedJSON(_ text: String, devices: [LightDevice]) throws -> LightScene {
        let decoded: LightScene
        do { decoded = try JSONDecoder().decode(LightScene.self, from: Data(text.utf8)) }
        catch { throw LumaError.message("That JSON isn't a valid scene: \(error.localizedDescription)") }
        try CommandValidation.validateScene(decoded, devices: devices)
        return decoded
    }

    private func save() {
        do {
            if jsonMode { try applyJSON() }
            var updated = draft
            updated.name = updated.name.trimmingCharacters(in: .whitespacesAndNewlines)
            try store.saveScene(updated)
            dismiss()
        } catch { errorText = error.localizedDescription }
    }
}

// MARK: - Step row

private struct StepRow: View {
    @Binding var step: SceneStep
    let number: Int
    let device: LightDevice?
    let canMoveUp: Bool
    let canMoveDown: Bool
    let onMoveUp: () -> Void
    let onMoveDown: () -> Void
    let onDelete: () -> Void

    private var value: Double? { step.command.value.number }
    private var integerValue: Int? { value.flatMap { Int(exactly: $0) } }
    private var delaySeconds: Binding<Double> {
        Binding(get: { Double(step.delayMilliseconds) / 1000 },
                set: { step.delayMilliseconds = Int((min(max($0, 0), 60) * 1000).rounded()) })
    }

    var body: some View {
        Card(padding: 12) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 10) {
                    Text("\(number)").font(.system(size: 12, weight: .semibold)).monospacedDigit().foregroundStyle(.secondary)
                        .frame(width: 22, height: 22).background(Color.well, in: Circle()).accessibilityHidden(true)
                    if let device {
                        Text(device.name).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                    } else {
                        Label("Missing light", systemImage: "exclamationmark.triangle.fill")
                            .font(.system(size: 13, weight: .semibold)).foregroundStyle(Color.warning)
                            .help("This light isn't connected anymore (\(step.deviceID)). Delete this step or the scene won't run.")
                    }
                    Spacer(minLength: 8)
                    HStack(spacing: 2) {
                        Button { onMoveUp() } label: { Image(systemName: "chevron.up") }
                            .disabled(!canMoveUp).help("Move up").accessibilityLabel("Move step \(number) up")
                        Button { onMoveDown() } label: { Image(systemName: "chevron.down") }
                            .disabled(!canMoveDown).help("Move down").accessibilityLabel("Move step \(number) down")
                        Button(role: .destructive) { onDelete() } label: { Image(systemName: "trash") }
                            .help("Delete step").accessibilityLabel("Delete step \(number)")
                    }.buttonStyle(.borderless)
                }
                HStack(spacing: 12) {
                    commandEditor
                    Spacer(minLength: 8)
                    HStack(spacing: 6) {
                        Text("Wait before").font(.system(size: 12)).foregroundStyle(.secondary)
                        Stepper(value: delaySeconds, in: 0...60, step: 0.5) {
                            HStack(spacing: 3) {
                                TextField("0", value: delaySeconds, format: .number.precision(.fractionLength(0...1)))
                                    .textFieldStyle(.roundedBorder).multilineTextAlignment(.trailing).frame(width: 52)
                                Text("s").font(.system(size: 12)).foregroundStyle(.secondary)
                            }
                        }
                        .accessibilityLabel("Wait before step \(number), in seconds")
                    }
                }
            }
        }
    }

    @ViewBuilder private var commandEditor: some View {
        let command = step.command
        switch command.instance {
        case "powerSwitch":
            Picker("Power", selection: Binding(get: { value == 1 }, set: { step.command = .power($0) })) {
                Text("Turn on").tag(true)
                Text("Turn off").tag(false)
            }
            .pickerStyle(.segmented).labelsHidden().frame(width: 150).accessibilityLabel("Power for step \(number)")
        case "brightness":
            Stepper(value: Binding(get: { integerValue ?? 50 }, set: { step.command = .brightness($0) }), in: 1...100) {
                Text("Brightness \(integerValue ?? 50)%").monospacedDigit()
            }
            .accessibilityLabel("Brightness for step \(number)")
        case "colorRgb":
            let rgb = integerValue ?? 0
            HStack(spacing: 8) {
                ColorPicker("Color", selection: Binding(get: { Color(rgb: rgb) },
                                                        set: { if let v = rgbValue(of: $0) { step.command = .rgb(v) } }))
                    .labelsHidden().accessibilityLabel("Color for step \(number)")
                Text("Color").foregroundStyle(.secondary)
                Text(String(format: "#%06X", rgb)).font(.system(size: 12, design: .monospaced)).foregroundStyle(.secondary)
            }
        case "colorTemperatureK":
            let kelvin = integerValue ?? 3000
            HStack(spacing: 8) {
                Circle().fill(kelvinColor(kelvin)).frame(width: 16, height: 16).overlay(Circle().strokeBorder(Color.primary.opacity(0.15)))
                    .accessibilityHidden(true)
                Stepper(value: Binding(get: { kelvin }, set: { step.command = .kelvin($0) }), in: sceneWhiteRange(for: device), step: 100) {
                    Text("White \(kelvin) K").monospacedDigit()
                }
                .accessibilityLabel("White temperature for step \(number)")
            }
        default:
            Text(friendlyTitle(for: command.instance)).foregroundStyle(.secondary)
                .help("Set with the Advanced JSON editor (\(command.instance))")
        }
    }
}

/// Match the model's advertised range; LAN-only lights use the local protocol range.
func sceneWhiteRange(for device: LightDevice?) -> ClosedRange<Int> {
    let schema = device?.capabilities.first { $0.instance == "colorTemperatureK" }?.parameters?["range"]
    let lower = schema?["min"]?.number.flatMap { Int(exactly: $0) } ?? 2000
    let upper = schema?["max"]?.number.flatMap { Int(exactly: $0) } ?? 9000
    let boundedLower = max(1000, lower), boundedUpper = min(10000, upper)
    return boundedLower <= boundedUpper ? boundedLower...boundedUpper : 2000...9000
}
