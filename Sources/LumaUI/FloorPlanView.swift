import SwiftUI
import PhotosUI
import ImageIO
import UniformTypeIdentifiers
import LumaCore

/// Aspect-fit image rectangle inside a container (excludes letterboxing).
nonisolated func fittedImageRect(image: CGSize, in container: CGSize) -> CGRect {
    guard image.width > 0, image.height > 0, container.width > 0, container.height > 0 else { return .zero }
    let scale = min(container.width / image.width, container.height / image.height)
    let size = CGSize(width: image.width * scale, height: image.height * scale)
    return CGRect(x: (container.width - size.width) / 2, y: (container.height - size.height) / 2, width: size.width, height: size.height)
}

/// Converts a point in the unzoomed container into 0…1 image coordinates, or nil when outside the image.
nonisolated func normalizedPoint(_ point: CGPoint, in rect: CGRect) -> CGPoint? {
    guard rect.width > 0, rect.height > 0 else { return nil }
    let x = (point.x - rect.minX) / rect.width, y = (point.y - rect.minY) / rect.height
    return (0...1).contains(x) && (0...1).contains(y) ? CGPoint(x: x, y: y) : nil
}

/// Undoes `.scaleEffect(zoom)` (centre anchor) followed by `.offset(offset)`: a point seen in the transformed
/// container maps back to unzoomed container space.
nonisolated func unzoomPoint(_ p: CGPoint, size: CGSize, zoom: CGFloat, offset: CGSize) -> CGPoint {
    let c = CGPoint(x: size.width / 2, y: size.height / 2)
    return CGPoint(x: (p.x - offset.width - c.x) / zoom + c.x, y: (p.y - offset.height - c.y) / zoom + c.y)
}

/// The forward transform of `unzoomPoint`, as SwiftUI renders it.
nonisolated func zoomPoint(_ p: CGPoint, size: CGSize, zoom: CGFloat, offset: CGSize) -> CGPoint {
    let c = CGPoint(x: size.width / 2, y: size.height / 2)
    return CGPoint(x: (p.x - c.x) * zoom + c.x + offset.width, y: (p.y - c.y) * zoom + c.y + offset.height)
}

/// Pin position during a drag. `translation` must come from the stable, unscaled pin-layer coordinate space
/// (`pinSpace`), never from the moving pin's own `.local` space: there the view chases the finger and a pin
/// moved only about half the finger travel.
nonisolated func draggedPinPoint(base: CGPoint, translation: CGSize) -> CGPoint {
    CGPoint(x: base.x + translation.width, y: base.y + translation.height)
}

let pinSpace = "floorPlanPins"

struct FloorPlanView: View {
    let store: HomeStore
    let open: (LightDevice) -> Void
    @AppStorage("floorPlanID") private var selectedID = ""
    @State private var editing = false
    @State private var listMode = false
    @State private var importing: Data?
    @State private var replacing = false
    @State private var pendingReplace: Data?
    @State private var confirmDelete = false
    @State private var renaming = false
    @State private var newName = ""
    @State private var photo: PhotosPickerItem?
    @State private var showFiles = false
    @State private var error: String?

    private var plan: FloorPlan? { store.floorPlans.first { $0.id.uuidString == selectedID } ?? store.floorPlans.first }
    private var placedIDs: Set<String> { Set(store.floorPlans.flatMap { $0.pins.map(\.deviceID) }) }
    private var unplaced: [LightDevice] { store.devices.filter { !placedIDs.contains($0.id) } }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            floorBar
            if let plan {
                if listMode || loadImage(plan.id) == nil {
                    if !listMode { Label("The floor image can't be shown. Lights are listed instead.", systemImage: "photo.badge.exclamationmark").font(.footnote).foregroundStyle(.secondary) }
                    PinList(store: store, plan: plan, open: open)
                } else if let image = loadImage(plan.id) {
                    PlanCanvas(store: store, plan: plan, image: image, editing: editing, open: open) { show($0) }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    if editing { tray(plan) }
                }
            } else {
                emptyState
            }
        }
        .photosPicker(isPresented: $showPhotos, selection: $photo, matching: .images)
        .onChange(of: photo) { _, item in
            Task { if let data = try? await item?.loadTransferable(type: Data.self) { received(data) }; photo = nil }
        }
        .fileImporter(isPresented: $showFiles, allowedContentTypes: [.image]) { result in
            guard case .success(let url) = result else { return }
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            if let data = try? Data(contentsOf: url) { received(data) } else { show("Could not read that file.") }
        }
        .sheet(isPresented: Binding(get: { importing != nil }, set: { if !$0 { importing = nil } })) { nameSheet }
        .confirmationDialog("Replace the floor image?", isPresented: Binding(get: { pendingReplace != nil }, set: { if !$0 { pendingReplace = nil } }), titleVisibility: .visible) {
            Button("Replace Image") {
                if let plan, let data = pendingReplace { attempt { try store.replaceFloorPlanImage(plan.id, image: data) } }
                pendingReplace = nil
            }
        } message: { Text("Pins keep their positions. You can move them afterwards.") }
        .confirmationDialog("Delete \(plan?.name ?? "floor")?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete Floor", role: .destructive) {
                if let plan { attempt { try store.deleteFloorPlan(plan.id) }; selectedID = "" }
                editing = false
            }
        } message: { Text("The image and its pins are removed. Your lights are not changed.") }
        .alert("Rename floor", isPresented: $renaming) {
            TextField("Name", text: $newName)
            Button("Save") { if let plan { attempt { try store.renameFloorPlan(plan.id, name: newName) } } }
            Button("Cancel", role: .cancel) {}
        }
        .alert("Floor plan", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(error ?? "") }
    }

    // MARK: Floors

    private var floorBar: some View {
        HStack(spacing: 8) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(store.floorPlans) { floor in
                        Button(floor.name) { selectedID = floor.id.uuidString }
                            .buttonStyle(.bordered).tint(floor.id == plan?.id ? .lumaAccent : .secondary)
                            .frame(minHeight: 44)
                            .accessibilityAddTraits(floor.id == plan?.id ? .isSelected : [])
                    }
                    addMenu(label: Label("Add floor", systemImage: "plus"), replace: false)
                        .frame(minHeight: 44)
                }
            }
            if plan != nil {
                Button(listMode ? "Map" : "List") { listMode.toggle() }.frame(minHeight: 44)
                    .accessibilityLabel(listMode ? "Show map" : "Show as list")
                    .keyboardShortcut("l", modifiers: [.command, .shift])
                    .help("Switch between the map and a list (⇧⌘L)")
                Button(editing ? "Done" : "Edit") { editing.toggle() }
                    .buttonStyle(.borderedProminent).frame(minHeight: 44)
                    .keyboardShortcut("e", modifiers: .command)
                    .help(editing ? "Finish placing lights (⌘E)" : "Move pins and place lights (⌘E)")
                    .disabled(listMode)
                Menu {
                    Button("Rename Floor…", systemImage: "pencil") { newName = plan?.name ?? ""; renaming = true }
                    addMenu(label: Label("Replace Image…", systemImage: "photo"), replace: true)
                    Button("Delete Floor…", systemImage: "trash", role: .destructive) { confirmDelete = true }
                } label: { Image(systemName: "ellipsis.circle").frame(width: 44, height: 44) }
                .accessibilityLabel("Floor options")
            }
        }
    }

    private func addMenu(label: some View, replace: Bool) -> some View {
        Menu {
            Button("Photos…", systemImage: "photo.on.rectangle") { replacing = replace; showPhotos = true }
            Button("Files…", systemImage: "folder") { replacing = replace; showFiles = true }
        } label: { label }
    }
    @State private var showPhotos = false

    private func received(_ data: Data) {
        if replacing { pendingReplace = data } else { newName = "Floor \(store.floorPlans.count + 1)"; importing = data }
    }

    private var nameSheet: some View {
        NavigationStack {
            Form {
                TextField("Floor name", text: $newName)
                Text("The image stays on your devices. Location data in photos is removed.").font(.footnote).foregroundStyle(.secondary)
            }
            .navigationTitle("Name this floor")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { importing = nil } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") {
                        guard let data = importing else { return }
                        attempt { selectedID = try store.importFloorPlan(name: newName, image: data).uuidString; editing = true }
                        importing = nil
                    }.disabled(newName.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
        .presentationDetents([.medium])
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            Image(systemName: "map").font(.system(size: 40)).foregroundStyle(.secondary)
            Text("Add a floor plan").font(.title3.weight(.semibold))
            Text("Use a photo or image of your floor plan, then place your lights on it.")
                .font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
            addMenu(label: Label("Choose Image", systemImage: "plus"), replace: false)
                .buttonStyle(.borderedProminent).frame(minHeight: 44)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity).padding()
    }

    private func tray(_ plan: FloorPlan) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(unplaced.isEmpty ? "Every light has a place. Drag a pin here to remove it." : "Not on any floor — tap or drag onto the plan")
                .font(.footnote).foregroundStyle(.secondary)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(unplaced) { device in
                        Button { attempt { try store.placeLight(device.id, onFloorPlan: plan.id, x: 0.5, y: 0.5) } } label: {
                            Label(device.name, systemImage: "lightbulb").font(.footnote).lineLimit(1)
                                .padding(.horizontal, 12).frame(minHeight: 44).background(.thinMaterial, in: Capsule())
                        }
                        .buttonStyle(.plain)
                        .draggable(device.id)
                        .accessibilityHint("Places it in the middle of the plan; then drag it into position.")
                    }
                }
            }
        }
        .padding(10).frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 14).fill(.quaternary.opacity(0.5)))
        .dropDestination(for: String.self) { ids, _ in
            for id in ids { attempt { try store.removeFloorPlanPin(id, from: plan.id) } }
            return true
        }
    }

    private func loadImage(_ id: UUID) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(store.floorPlanImageURL(id) as CFURL, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }
    private func attempt(_ work: () throws -> Void) { do { try work() } catch { show(error.localizedDescription) } }
    private func show(_ message: String) { error = message }
}

// MARK: Map

private struct PlanCanvas: View {
    let store: HomeStore
    let plan: FloorPlan
    let image: CGImage
    let editing: Bool
    let open: (LightDevice) -> Void
    let fail: (String) -> Void
    @State private var zoom: CGFloat = 1
    @State private var baseZoom: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var baseOffset: CGSize = .zero
    @State private var dragging: [String: CGPoint] = [:]

    var body: some View {
        GeometryReader { geo in
            let rect = fittedImageRect(image: CGSize(width: image.width, height: image.height), in: geo.size)
            // Pins are a sibling of the gesture/drop layer, not its child: under an ancestor's dropDestination
            // SwiftUI reports every pin's accessibility frame as the whole plan (seen in VoiceOver/XCUITest).
            ZStack {
                Image(decorative: image, scale: 1).resizable().frame(width: rect.width, height: rect.height).position(x: rect.midX, y: rect.midY)
                    .frame(width: geo.size.width, height: geo.size.height)
                    .scaleEffect(zoom).offset(offset)
                    .contentShape(Rectangle())
                    .gesture(MagnifyGesture().onChanged { zoom = min(5, max(1, baseZoom * $0.magnification)) }.onEnded { _ in baseZoom = zoom; if zoom == 1 { offset = .zero; baseOffset = .zero } })
                    .simultaneousGesture(editing ? nil : DragGesture().onChanged { v in
                        guard zoom > 1 else { return }
                        offset = CGSize(width: baseOffset.width + v.translation.width, height: baseOffset.height + v.translation.height)
                    }.onEnded { _ in baseOffset = offset })
                    .dropDestination(for: String.self) { ids, location in
                        // `location` is in the zoomed/offset space; undo the transform first.
                        let p = unzoomPoint(location, size: geo.size, zoom: zoom, offset: offset)
                        guard let n = normalizedPoint(p, in: rect) else { fail("Drop the light inside the floor plan."); return false }
                        for id in ids { place(id, n) }
                        return true
                    }
                    .accessibilityHidden(true)
                ZStack(alignment: .topLeading) {
                    ForEach(plan.pins) { pin in
                        let base = CGPoint(x: rect.minX + pin.x * rect.width, y: rect.minY + pin.y * rect.height)
                        let p = dragging[pin.deviceID] ?? base
                        PinMark(store: store, pin: pin, editing: editing, open: open)
                            .gesture(editing ? pinDrag(pin, rect: rect) : nil)
                            .offset(x: p.x - 22, y: p.y - 22)
                    }
                }
                .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
                // Named before the scale: drag values are in unzoomed space and don't move with the pin.
                .coordinateSpace(.named(pinSpace))
                .scaleEffect(zoom).offset(offset)
            }
            .clipped()
        }
        .background(RoundedRectangle(cornerRadius: 18).fill(.quaternary.opacity(0.4)))
        .clipShape(RoundedRectangle(cornerRadius: 18))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Floor plan \(plan.name)")
    }

    /// Pin positions are in unzoomed container space, the same space as `pinSpace`.
    private func pinDrag(_ pin: FloorPlanPin, rect: CGRect) -> some Gesture {
        DragGesture(minimumDistance: 2, coordinateSpace: .named(pinSpace)).onChanged { v in
            let base = CGPoint(x: rect.minX + pin.x * rect.width, y: rect.minY + pin.y * rect.height)
            dragging[pin.deviceID] = draggedPinPoint(base: base, translation: v.translation)
        }.onEnded { _ in
            guard let p = dragging.removeValue(forKey: pin.deviceID) else { return }
            let clamped = CGPoint(x: min(rect.maxX, max(rect.minX, p.x)), y: min(rect.maxY, max(rect.minY, p.y)))
            if let n = normalizedPoint(clamped, in: rect) { place(pin.deviceID, n) }
        }
    }

    private func place(_ id: String, _ n: CGPoint) {
        do { try store.placeLight(id, onFloorPlan: plan.id, x: n.x, y: n.y) } catch { fail(error.localizedDescription) }
    }
}

private struct PinMark: View {
    let store: HomeStore
    let pin: FloorPlanPin
    let editing: Bool
    let open: (LightDevice) -> Void
    private var device: LightDevice? { store.devices.first { $0.id == pin.deviceID } }

    var body: some View {
        let d = device
        let offline = d?.online == false
        let on = d?.power == true && !offline
        ZStack {
            Circle().fill(d.map { on ? $0.displayColor : Color.gray.opacity(0.35) } ?? .clear).frame(width: 30, height: 30)
                .shadow(color: on ? (d?.displayColor ?? .clear).opacity(0.7) : .clear, radius: 10)
            if d == nil || offline {
                Circle().strokeBorder(d == nil ? Color.secondary : Color.danger, style: StrokeStyle(lineWidth: 2, dash: [4, 3])).frame(width: 32, height: 32)
            }
            if d == nil { Image(systemName: "questionmark").font(.caption.bold()).foregroundStyle(.secondary) }
        }
        .frame(width: 44, height: 44).contentShape(Circle())
        .overlay(alignment: .bottom) {
            Text(d?.name ?? "Not found").font(.caption2.weight(.medium)).lineLimit(1).padding(.horizontal, 6).padding(.vertical, 2)
                .background(.thinMaterial, in: Capsule()).fixedSize().offset(y: 18)
        }
        #if os(macOS)
        .onHover { $0 ? NSCursor.pointingHand.push() : NSCursor.pop() }
        .help(d.map { "\($0.name): click to switch on or off, hold for controls" } ?? "This light wasn't found. Its place is kept.")
        #endif
        .onTapGesture { if !editing, let d, d.online != false { store.perform(.power(!(d.power ?? false)), ids: [d.id]) } }
        .onLongPressGesture { if !editing, let d { open(d) } }
        .accessibilityElement()
        .accessibilityLabel(d?.name ?? "Light not found")
        .accessibilityValue(pinState(d))
        .accessibilityAddTraits(.isButton)
        .accessibilityHint(editing ? "Editing. Drag to move." : "")
        .accessibilityAction { if !editing, let d, d.online != false { store.perform(.power(!(d.power ?? false)), ids: [d.id]) } }
        .accessibilityAction(named: "Details") { if let d { open(d) } }
        .modifier(PinAdjust(store: store, device: editing ? nil : d))
        .frame(width: 44, height: 44)
    }
}

/// VoiceOver swipe up/down changes brightness by 10, only for an online light that advertises brightness.
private struct PinAdjust: ViewModifier {
    let store: HomeStore
    let device: LightDevice?
    func body(content: Content) -> some View {
        if let device, pinBrightness(device, increment: true) != nil {
            content.accessibilityAdjustableAction { dir in
                if let v = pinBrightness(device, increment: dir == .increment) { store.perform(.brightness(v), ids: [device.id]) }
            }
        } else { content }
    }
}

/// Next brightness for a 10-point step, clamped to the advertised range (within 1...100); nil when not adjustable.
func pinBrightness(_ d: LightDevice, increment: Bool) -> Int? {
    guard d.online != false, d.supports("brightness") else { return nil }
    let r = d.capabilities.first { $0.instance == "brightness" }?.parameters?["range"]
    let lo = max(1, Int(r?["min"]?.number ?? 1)), hi = min(100, Int(r?["max"]?.number ?? 100))
    guard lo <= hi else { return nil }
    let current = d.power == true ? (d.brightness ?? lo) : (increment ? lo - 10 : lo)
    return min(hi, max(lo, current + (increment ? 10 : -10)))
}

private func pinState(_ d: LightDevice?) -> String {
    guard let d else { return "Not found. Its place is kept." }
    if d.online == false { return "Offline" }
    return d.power == true ? (d.brightness.map { "On, \($0)%" } ?? "On") : "Off"
}

/// Accessible list alternative, also used when the image can't load. Top-to-bottom, then left-to-right.
private struct PinList: View {
    let store: HomeStore
    let plan: FloorPlan
    let open: (LightDevice) -> Void
    var body: some View {
        List {
            ForEach(plan.pins.sorted { ($0.y, $0.x) < ($1.y, $1.x) }) { pin in
                let d = store.devices.first { $0.id == pin.deviceID }
                Button { if let d { open(d) } } label: {
                    HStack {
                        Circle().fill(d?.displayColor ?? .gray).frame(width: 14, height: 14)
                        Text(d?.name ?? "Light not found")
                        Spacer()
                        Text(pinState(d)).foregroundStyle(.secondary)
                    }.frame(minHeight: 44)
                }
                .disabled(d == nil)
            }
            if plan.pins.isEmpty { Text("No lights placed on this floor yet.").foregroundStyle(.secondary) }
        }
        .listStyle(.plain)
    }
}
