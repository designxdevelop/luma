import SwiftUI
import LumaCore

/// Searchable Govee scene list for one light or a group of lights. Tapping a scene
/// sends it straight away; nothing is saved unless "Save as Luma Scene" is chosen.
/// For several lights, a name is applied to each light that lists it.
struct GoveeSceneList: View {
    let store: HomeStore
    let lights: [LightDevice]
    let target: String
    @State private var query = ""
    @State private var kind: GoveeSceneOption.Kind?
    @State private var applying: String?
    @State private var message: (text: String, isError: Bool)?
    @State private var loading = false

    struct Row: Identifiable {
        var kind: GoveeSceneOption.Kind
        var name: String
        /// Set when there is one light: its exact option.
        var option: GoveeSceneOption?
        var count: Int
        var id: String { kind.rawValue + "|" + name.lowercased() + "|" + (option?.id ?? "") }
    }

    /// One row per option for a single light; one row per kind+name across several.
    static func rows(for lights: [LightDevice]) -> [Row] {
        if lights.count == 1, let light = lights.first {
            return GoveeSceneLibrary.options(for: light).map { Row(kind: $0.kind, name: $0.name, option: $0, count: 1) }
        }
        var rows: [Row] = []
        var index: [String: Int] = [:]
        for light in lights {
            var seen = Set<String>()
            for option in GoveeSceneLibrary.options(for: light) {
                let key = option.kind.rawValue + "|" + option.name.lowercased()
                guard seen.insert(key).inserted else { continue }
                if let i = index[key] { rows[i].count += 1 } else { index[key] = rows.count; rows.append(Row(kind: option.kind, name: option.name, count: 1)) }
            }
        }
        return rows
    }

    var body: some View {
        let all = Self.rows(for: lights)
        let kinds = GoveeSceneOption.Kind.allCases.filter { k in all.contains { $0.kind == k } }
        let shown = all.filter { row in
            (kind == nil || row.kind == kind) && (query.isEmpty || row.name.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) != nil)
        }
        let blocked = unavailableReason
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(title: "Govee scenes", detail: all.isEmpty ? nil : counts(all)) {
                Button { Task { await load() } } label: {
                    HStack(spacing: 6) { if loading { ProgressView().controlSize(.small) }; Text(all.isEmpty ? "Load" : "Reload") }
                }
                .disabled(!store.cloudConnected || loading || lights.allSatisfy(\.isDemo))
                .help(store.cloudConnected ? "Download the built-in and DIY scene lists from Govee" : "Connect your Govee account in Settings first")
            }
            if let blocked { InlineMessage(text: blocked) }
            if all.isEmpty {
                Text(store.cloudConnected ? "No scenes loaded for \(target) yet. Load downloads the lists Govee's API has for \(lights.count == 1 ? "this model" : "these models")."
                                          : "Connect your Govee account in Settings to load scenes.")
                    .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            } else {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("Search \(all.count) scenes", text: $query).textFieldStyle(.plain)
                        .autocorrectionDisabled().accessibilityLabel("Search Govee scenes")
                    if !query.isEmpty {
                        Button { query = "" } label: { Image(systemName: "xmark.circle.fill") }
                            .buttonStyle(.borderless).foregroundStyle(.secondary).accessibilityLabel("Clear search")
                    }
                }
                .padding(.horizontal, 10).padding(.vertical, 7)
                .background(Color.well, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                if kinds.count > 1 {
                    Picker("Kind", selection: $kind) {
                        Text("All").tag(GoveeSceneOption.Kind?.none)
                        ForEach(kinds, id: \.self) { Text($0.title).tag(Optional($0)) }
                    }.pickerStyle(.segmented).labelsHidden()
                }
                if let message { InlineMessage(text: message.text, isError: message.isError) }
                if shown.isEmpty {
                    Text("No scenes match “\(query)”.").font(.system(size: 12)).foregroundStyle(.secondary).padding(.vertical, 8)
                } else {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(shown) { row in
                            sceneRow(row, disabled: blocked != nil || applying != nil)
                            Divider()
                        }
                    }
                }
            }
            Text("These are the scenes Govee's public API lists for \(lights.count == 1 ? "this model" : "these models"). Govee Home can show more, and some of its scenes are app-only. Scenes are sent through the Govee cloud.")
                .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func sceneRow(_ row: Row, disabled: Bool) -> some View {
        HStack(spacing: 10) {
            Button { apply(row) } label: {
                HStack(spacing: 10) {
                    Image(systemName: row.kind == .diy ? "paintbrush.pointed" : row.kind == .snapshot ? "camera" : "wand.and.stars")
                        .foregroundStyle(Color.lumaAccent).frame(width: 18)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(row.name).font(.system(size: 13)).foregroundStyle(.primary).lineLimit(1)
                        if lights.count > 1 || row.kind != .builtIn {
                            Text(lights.count > 1 ? "\(row.kind.title) · \(row.count) of \(lights.count) lights" : row.kind.title)
                                .font(.system(size: 11)).foregroundStyle(.secondary)
                        }
                    }
                    Spacer(minLength: 8)
                    if applying == row.id { ProgressView().controlSize(.small) }
                    else { Image(systemName: "play.circle").foregroundStyle(.secondary) }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain).disabled(disabled)
            .accessibilityLabel("Apply \(row.name)")
            .accessibilityHint(lights.count > 1 ? "Applies to \(row.count) of \(lights.count) lights" : "Applies to \(target)")
            Menu {
                Button("Save as Luma Scene", systemImage: "square.and.arrow.down") { save(row) }
            } label: { Image(systemName: "ellipsis.circle") }
                .menuStyle(.borderlessButton).fixedSize().accessibilityLabel("More for \(row.name)")
        }
        .padding(.vertical, 8)
    }

    /// Why nothing can be sent right now, if so. Unknown online state is allowed.
    private var unavailableReason: String? {
        if !store.cloudConnected && !lights.allSatisfy(\.isDemo) { return "Govee scenes are sent through the Govee cloud. Connect your account in Settings." }
        if !lights.isEmpty && lights.allSatisfy({ $0.online == false }) { return lights.count == 1 ? "\(target) is offline. Govee can't change its scene until it's back." : "These lights are offline." }
        return nil
    }

    private func counts(_ rows: [Row]) -> String {
        GoveeSceneOption.Kind.allCases.compactMap { k in
            let n = rows.filter { $0.kind == k }.count
            return n == 0 ? nil : "\(n) \(k == .diy ? k.title : k.title.lowercased())"
        }.joined(separator: " · ")
    }

    private func apply(_ row: Row) {
        applying = row.id; message = nil
        Task {
            do {
                let report: LightActionReport
                if let option = row.option, let light = lights.first {
                    report = try await store.run(on: [light], target: target, verb: "applied \(row.name) to") { _ in (option.command, "") }
                } else {
                    report = try await store.applyGoveeScene(kind: row.kind, name: row.name, to: lights, target: target)
                }
                message = (report.skipped.isEmpty && report.failed.isEmpty ? "Applied \(row.name)" : report.summary, !report.failed.isEmpty)
            } catch { message = (error.localizedDescription, true) }
            applying = nil
        }
    }

    private func save(_ row: Row) {
        let steps: [SceneStep] = lights.compactMap { light in
            let option = row.option ?? GoveeSceneLibrary.match(kind: row.kind, name: row.name, on: light)
            return option.map { SceneStep(deviceID: light.id, command: $0.command) }
        }
        do {
            try store.saveScene(.init(name: "\(target) · \(row.name)", symbol: "wand.and.stars", steps: steps))
            message = ("Saved “\(target) · \(row.name)” to Scenes", false)
        } catch { message = (error.localizedDescription, true) }
    }

    private func load() async {
        loading = true; defer { loading = false }
        for light in lights where !light.isDemo {
            if light.supports("lightScene") { await store.loadDeviceScenes(light, diy: false) }
            if light.supports("diyScene") { await store.loadDeviceScenes(light, diy: true) }
        }
    }
}

/// Scenes page browser: pick a room (or one light in it), then search and apply.
struct GoveeSceneBrowser: View {
    let store: HomeStore
    @Environment(\.dismiss) private var dismiss
    @State private var room = HomeStore.allLightsRoom
    /// Empty means every light in the room.
    @State private var lightID = ""

    var body: some View {
        let members = store.lights(inRoom: room).filter { GoveeSceneLibrary.advertisesScenes($0) }
        let targets = lightID.isEmpty ? members : members.filter { $0.id == lightID }
        VStack(spacing: 0) {
            HStack {
                Text("Govee Scenes").font(.system(size: 17, weight: .semibold))
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }.padding(.horizontal, compactSpacing(24, 16)).padding(.vertical, 14)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Card {
                        VStack(alignment: .leading, spacing: 10) {
                            Picker("Room", selection: $room) {
                                Text("All lights").tag(HomeStore.allLightsRoom)
                                ForEach(store.rooms, id: \.self) { Text($0).tag($0) }
                            }
                            Picker("Light", selection: $lightID) {
                                Text("Every light with scenes (\(members.count))").tag("")
                                ForEach(members) { Text($0.name).tag($0.id) }
                            }
                            Text(lightID.isEmpty ? "A scene is applied to each light that lists it by the same name; the rest are skipped." : "Shows this light's own scene list.")
                                .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    if targets.isEmpty {
                        Card { EmptyState(icon: "wand.and.stars", title: "No scene lights here", message: "None of the lights in \(store.roomTitle(room)) advertise Govee scenes.") }
                    } else {
                        Card {
                            GoveeSceneList(store: store, lights: targets, target: lightID.isEmpty ? store.roomTitle(room) : targets[0].name)
                                .id(room + "|" + lightID)
                        }
                    }
                }.padding(compactSpacing(24, 16))
            }
        }
        .sheetFrame(width: 620, height: 720).background(Color.canvas)
        .onChange(of: room) { _, _ in lightID = "" }
    }
}
