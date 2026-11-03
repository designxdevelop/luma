import SwiftUI
import Observation
import LumaCore

struct ActivityEntry: Identifiable {
    let id = UUID()
    let time = Date()
    let message: String
    let isError: Bool
}

@Observable final class HomeStore {
    var iCloudStatus = "Checking iCloud…"
    private var configurationSync: CloudSyncCoordinator?
    private var scheduleOwners: [UUID: String] = [:]
    /// Explicit primary/fallback per schedule. Absent = legacy single-installation schedule.
    private(set) var coordinations: [UUID: ScheduleCoordination] = [:]
    private(set) var schedulerDevices: [SchedulerDevice] = []
    private(set) var scheduleStatus: [UUID: String] = [:]
    private var scheduleCoordinator: ScheduleCoordinator?
#if os(macOS)
    private var schedulerActivity: (any NSObjectProtocol)?
#endif
    private let installationID: String = {
        let defaults = UserDefaults.standard
        if let id = defaults.string(forKey: "LumaSyncInstallation") { return id }
        let id = UUID().uuidString; defaults.set(id, forKey: "LumaSyncInstallation"); return id
    }()
    var home = SavedHome()
    private(set) var floorPlans: [FloorPlan] = []
    private var canSaveFloorPlans = true
    private var floorPlanStorage: FloorPlanStorage { FloorPlanStorage(folder: HomeStorage(demo: demo).folder) }
    var activity: [ActivityEntry] = []
    var notice: String?
    var busy = false
    var scanning = false
    var cloudConnected = false
    var webhookRunning = false
    var webhookStatus = "Stopped"
    var webhookToken = ""
    /// SHA-256 fingerprint and PEM of the webhook server's certificate, once started.
    var webhookCertificate: (fingerprint: String, spkiPin: String, pem: String)?
    var runningSceneID: UUID?
    var runs: [AutomationRun] = []
    var demo: Bool
    var canSave = true
    let screenSync: ScreenSync
    private let storage: HomeStorage
    private let screenSyncDefaults: UserDefaults?
    private var shuttingDown = false
    private var cloud: GoveeCloud?
    private let lan = GoveeLAN()
    private let server = WebhookServer()
    private var timerTask: Task<Void, Never>?
    private var sceneTask: Task<Void, Never>?
    private var scanTask: Task<Void, Never>?
    private var reconnectTask: Task<Void, Never>?
    private var pendingControls: [ControlKey: PendingControl] = [:]
    private var commandQueues: [String: [QueuedControl]] = [:]
    private var commandWorkers: [String: Task<Void, Never>] = [:]
    private var inFlightControls: [String: QueuedControl] = [:]
    private var confirmationTasks: [ControlKey: Task<Void, Never>] = [:]
    private var deviceRevisions: [String: UInt64] = [:]
    private var recentConfirmations: [ControlKey: RecentConfirmation] = [:]

    // Requested values are a display overlay. Persistence and API telemetry keep
    // the last reported state, so an optimistic edit is never saved as confirmed.
    var devices: [LightDevice] {
        home.devices.map { device in
            var displayed = device
            displayed.name = device.customName ?? device.name
            for (key, pending) in pendingControls where key.deviceID == device.id { displayed.display(pending.command) }
            return displayed
        }
    }
    func controlStatus(for deviceID: String) -> String? {
        let pending = pendingControls.filter { $0.key.deviceID == deviceID }.map(\.value)
        if pending.contains(where: { $0.phase == .queued || $0.phase == .sending }) { return "Updating…" }
        return pending.isEmpty ? nil : "Waiting for light…"
    }
    func hasOrdinaryControl(for deviceID: String) -> Bool {
        pendingControls.keys.contains { $0.deviceID == deviceID }
            || !(commandQueues[deviceID]?.isEmpty ?? true)
            || inFlightControls[deviceID] != nil
    }
    var rooms: [String] { Array(Set(devices.map(\.room))).sorted() }
    /// Waits for the launch-time cloud reconnect, so early requests have a route.
    func ready() async { await reconnectTask?.value }
    var poweredCount: Int { devices.filter { $0.power == true }.count }

    init(demo demoOverride: Bool? = nil, cloud: GoveeCloud? = nil, screenSyncDefaults: UserDefaults? = .standard) {
        let isDemo = demoOverride ?? CommandLine.arguments.contains("--demo")
        demo = isDemo
        storage = HomeStorage(demo: false)
        self.screenSyncDefaults = screenSyncDefaults
        screenSync = ScreenSync(defaults: isDemo ? nil : screenSyncDefaults)
        self.cloud = cloud
        cloudConnected = cloud != nil
        do { home = try storage.load() }
        catch { canSave = false; notice = "Your saved home could not be read. It has been preserved at \(storage.folder.path)." }
        if let data = try? Data(contentsOf: storage.folder.appending(path: "schedule-owners.json")),
           let owners = try? JSONDecoder().decode([UUID: String].self, from: data) { scheduleOwners = owners }
        if let data = try? Data(contentsOf: storage.folder.appending(path: "schedule-coordination.json")),
           let saved = try? JSONDecoder().decode([UUID: ScheduleCoordination].self, from: data) { coordinations = saved }
        schedulerDevices = [thisSchedulerDevice]
        for i in home.devices.indices { home.devices[i].ip = nil; home.devices[i].online = nil }
        if demo { loadDemo() }
        do { floorPlans = try floorPlanStorage.load() }
        catch { canSaveFloorPlans = false; log("Could not read floor plans. Existing files have been preserved.", error: true) }
        if !isDemo && cloud == nil {
            reconnectTask = Task { [weak self] in
                guard let self else { return }
                do {
                    guard let key = try SecretStore.read("govee-api-key"), !Task.isCancelled else { return }
                    await self.connectCloud(key: key)
                } catch { self.log("Reconnect in Settings to unlock your saved API key.") }
            }
        }
        timerTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(15))
                guard !Task.isCancelled, let self else { return }
                self.tickSchedules()
            }
        }
        screenSync.store = self
        screenSync.send = { [weak self] device, update in try self?.streamToLight(device, update) }
        screenSync.restore = { [weak self] device, commands in try self?.restoreToLight(device, commands) }
        screenSync.readback = { [weak self] device in await self?.refresh(device) }
        screenSync.observeSystem()
        if !canSave, let notice { log(notice, error: true) }
        // CloudKit traps without the entitlement, so nothing CloudKit is created
        // unless this signed build carries the Luma container (ad-hoc and simulator builds stay local).
        if !isDemo && demoOverride == nil && CloudAvailability.isEntitled {
            let sync = CloudSyncCoordinator(folder: storage.folder,
                snapshot: { [weak self] in try self?.syncSnapshot() ?? [:] },
                apply: { [weak self] in try self?.applySync($0) },
                status: { [weak self] message in
                    guard let self else { return }
                    self.iCloudStatus = message
                    if !self.cloudConnected && !self.busy {
                        Task { [weak self] in
                            guard let self, let key = try? SecretStore.read("govee-api-key") else { return }
                            await self.connectCloud(key: key)
                        }
                    }
                })
            configurationSync = sync; sync.start()
            let coordinator = ScheduleCoordinator(device: installationID, store: CloudScheduleLeaseStore(), host: self,
                                                  file: storage.folder.appending(path: "schedule-runs.json"))
            coordinator.expectedAccount = { [weak sync] in sync?.account }
            coordinator.onStatus = { [weak self, weak coordinator] in self?.scheduleStatus = coordinator?.status ?? [:] }
            scheduleCoordinator = coordinator
        } else if !isDemo {
            iCloudStatus = "iCloud sync needs a signed build with Luma's iCloud container."
        }
    }

    func log(_ message: String, error: Bool = false) {
        if !demo {
            do { try ActivityLog.append(message, isError: error, folder: storage.folder) }
            catch { notice = "Could not write the activity log: \(error.localizedDescription)" }
        }
        activity.insert(.init(message: message, isError: error), at: 0)
        if activity.count > 200 { activity.removeLast(activity.count - 200) }
        if error { notice = message }
    }
    func persist() {
        guard canSave, !demo else { return }
        do { try storage.save(home); configurationSync?.changed() } catch { log("Could not save home: \(error.localizedDescription)", error: true) }
    }

    @discardableResult
    func importFloorPlan(name: String, image: Data) throws -> UUID {
        guard canSaveFloorPlans else { throw LumaError.message("Existing floor plans could not be read and have been preserved.") }
        let label = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !label.isEmpty, label.count <= 64 else { throw LumaError.message("Name the floor plan using 1–64 characters.") }
        let plan = FloorPlan(name: label)
        try floorPlanStorage.importImage(image, id: plan.id)
        do { try commitFloorPlans(floorPlans + [plan]) }
        catch { try? floorPlanStorage.removeImage(plan.id); throw error }
        return plan.id
    }

    func floorPlanImageURL(_ id: UUID) -> URL { floorPlanStorage.imageURL(id) }

    /// The UI confirms replacement and lets users reposition existing pins.
    func replaceFloorPlanImage(_ id: UUID, image: Data) throws {
        guard canSaveFloorPlans, floorPlans.contains(where: { $0.id == id }) else {
            throw LumaError.message("Floor plan is unavailable.")
        }
        // Keep positions: image replacement is a reskin of the same floor. A new
        // floor should be imported separately so existing placements stay intact.
        try floorPlanStorage.importImage(image, id: id)
        configurationSync?.changed()
    }


    func renameFloorPlan(_ id: UUID, name: String) throws {
        let label = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !label.isEmpty, label.count <= 64 else { throw LumaError.message("Name the floor plan using 1–64 characters.") }
        var plans = floorPlans
        guard let index = plans.firstIndex(where: { $0.id == id }) else { throw LumaError.message("Floor plan not found.") }
        plans[index].name = label
        try commitFloorPlans(plans)
    }

    func placeLight(_ deviceID: String, onFloorPlan id: UUID, x: Double, y: Double) throws {
        guard devices.contains(where: { $0.id == deviceID }) else { throw LumaError.message("Light not found.") }
        let pin = try FloorPlanPin(deviceID: deviceID, x: x, y: y)
        var plans = floorPlans
        guard let index = plans.firstIndex(where: { $0.id == id }) else { throw LumaError.message("Floor plan not found.") }
        // A physical light has one location across all floors.
        for i in plans.indices { plans[i].pins.removeAll { $0.deviceID == deviceID } }
        plans[index].pins.append(pin)
        try commitFloorPlans(plans)
    }

    func removeFloorPlanPin(_ deviceID: String, from id: UUID) throws {
        var plans = floorPlans
        guard let index = plans.firstIndex(where: { $0.id == id }) else { throw LumaError.message("Floor plan not found.") }
        plans[index].pins.removeAll { $0.deviceID == deviceID }
        try commitFloorPlans(plans)
    }

    func deleteFloorPlan(_ id: UUID) throws {
        try commitFloorPlans(floorPlans.filter { $0.id != id })
        try floorPlanStorage.removeImage(id)
    }

    private func commitFloorPlans(_ plans: [FloorPlan]) throws {
        guard canSaveFloorPlans else { throw LumaError.message("Existing floor plans could not be read and have been preserved.") }
        try floorPlanStorage.save(plans)
        floorPlans = plans
        configurationSync?.changed()
    }

    func connectCloud(key: String) async {
        guard !busy else { return }
        busy = true; defer { busy = false }
        do {
            let value: String
            if key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                guard let saved = try SecretStore.read("govee-api-key") else { throw LumaError.message("Enter your Govee API key first.") }
                value = saved
            } else { value = key.trimmingCharacters(in: .whitespacesAndNewlines) }
            let client = GoveeCloud(apiKey: value)
            let found = try await client.devices()
            try SecretStore.save(value, account: "govee-api-key")
            if demo { leaveDemo() }
            cloud = client; cloudConnected = true
            for device in found { merge(device) }
            persist(); log("Connected Govee cloud. Found \(found.count) lights.")
            for device in found {
                let revision = deviceRevisions[device.id, default: 0]
                do { merge(try await client.state(for: device), stateRevision: revision) }
                catch { log("Could not read \(device.name): \(error.localizedDescription)") }
            }
            persist()
        } catch { log("Cloud connection failed: \(error.localizedDescription)", error: true) }
    }
    func disconnectCloud() {
        cloud = nil; cloudConnected = false
        do { try SecretStore.delete("govee-api-key"); log("Cloud disconnected and API key removed.") }
        catch { log(error.localizedDescription, error: true) }
    }
    func discover() {
        guard !scanning else { return }
        if demo { log("Demo mode: LAN discovery is disabled. Leave demo to discover real lights."); return }
        do {
            try lan.start(onDevice: { [weak self] device in self?.merge(device); self?.persist() }, onError: { [weak self] message in self?.log(message, error: true) })
            try lan.discover(); scanning = true; log("Scanning home Wi-Fi for LAN-enabled Govee lights…")
            scanTask?.cancel()
            scanTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(5))
                guard !Task.isCancelled, let self else { return }
                self.scanning = false
                self.log("LAN scan complete. \(self.devices.filter { $0.ip != nil }.count) LAN lights known.")
                for d in self.devices where d.ip != nil { try? self.lan.requestStatus(ip: d.ip!) }
            }
        } catch { scanning = false; log("LAN discovery: \(error.localizedDescription)", error: true) }
    }
    func merge(_ packet: LightDevice, stateRevision: UInt64? = nil) {
        var incoming = packet
        let index = home.devices.firstIndex { $0.id.caseInsensitiveCompare(incoming.id) == .orderedSame || (incoming.ip != nil && $0.ip == incoming.ip) }
        if let index { incoming.id = home.devices[index].id }
        if let stateRevision, stateRevision != deviceRevisions[incoming.id, default: 0] { return }
        recentConfirmations = recentConfirmations.filter { $0.value.until > .now }
        // UDP status replies have no request identifier. During the brief settle
        // interval, a delayed older packet must not undo a confirmed newer edit.
        for (key, confirmation) in recentConfirmations where key.deviceID == incoming.id {
            if incoming.reportedValue(for: key.instance) != confirmation.value {
                switch key.instance {
                case "powerSwitch": incoming.power = nil
                case "brightness": incoming.brightness = nil
                case "colorRgb": incoming.rgb = nil
                case "colorTemperatureK": incoming.colorTemperature = nil
                default: break
                }
            }
        }
        if let i = index {
            var d = home.devices[i]
            if !incoming.capabilities.isEmpty { d.capabilities = mergedCapabilities(d.capabilities, incoming.capabilities); d.name = incoming.name }
            d.ip = incoming.ip ?? d.ip
            if !incoming.sku.isEmpty { d.sku = incoming.sku }
            if incoming.online != false {
                d.power = incoming.power ?? d.power; d.brightness = incoming.brightness ?? d.brightness
                d.rgb = incoming.rgb ?? d.rgb; d.colorTemperature = incoming.colorTemperature ?? d.colorTemperature
            }
            d.online = incoming.online ?? d.online; d.lastSeen = incoming.lastSeen ?? d.lastSeen
            home.devices[i] = d
        } else { home.devices.append(incoming); log("Found \(incoming.name) (\(incoming.sku)).") }
        for (key, pending) in pendingControls where key.deviceID == incoming.id && pending.phase == .confirming {
            if incoming.online != false && incoming.reportedValue(for: key.instance) == pending.command.value {
                pendingControls.removeValue(forKey: key)
                confirmationTasks.removeValue(forKey: key)?.cancel()
                if incoming.ip != nil {
                    recentConfirmations[key] = .init(value: pending.command.value, until: .now.advanced(by: .seconds(2)))
                }
            }
        }
    }
    func refresh(_ device: LightDevice) async {
        guard !shuttingDown, !Task.isCancelled else { return }
        do {
            if device.isDemo { log("Demo state refreshed.") }
            else if device.ip != nil {
                try lan.start(onDevice: { [weak self] incoming in self?.merge(incoming); self?.persist() }, onError: { [weak self] text in self?.log(text, error: true) })
                try lan.requestStatus(for: device)
            }
            else if let cloud {
                let revision = deviceRevisions[device.id, default: 0]
                let reported = home.devices.first { $0.id == device.id } ?? device
                merge(try await cloud.state(for: reported), stateRevision: revision); persist()
            }
            else { throw LumaError.message("Connect cloud or discover LAN lights to refresh state.") }
        } catch { log(error.localizedDescription, error: true) }
    }
    func send(_ command: CapabilityCommand, to id: String) async throws {
        let operationID = UUID()
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            try await withCheckedThrowingContinuation { continuation in
                do {
                    var operation = try prepare(command, deviceID: id, coalescible: false, operationID: operationID)
                    operation.completion = continuation
                    enqueue(operation)
                } catch { continuation.resume(throwing: error) }
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.cancelQueued(operationID) }
        }
        try Task.checkCancellation()
    }

    private func prepare(_ command: CapabilityCommand, deviceID: String, coalescible: Bool, operationID: UUID = UUID()) throws -> QueuedControl {
        guard let device = home.devices.first(where: { $0.id == deviceID }) else { throw LumaError.message("Light not found.") }
        try CommandValidation.validate(command, for: device)
        // Every UI, scene, schedule and webhook write passes here. Screen Sync
        // releases the light before the write is queued, so it never fights it.
        screenSync.yield(deviceID)
        let operation = QueuedControl(id: operationID, deviceID: deviceID, command: command, coalescible: coalescible)
        deviceRevisions[deviceID, default: 0] += 1
        confirmationTasks.removeValue(forKey: operation.key)?.cancel()
        recentConfirmations.removeValue(forKey: operation.key)
        pendingControls[operation.key] = .init(id: operation.id, command: command)
        if ["colorRgb", "colorTemperatureK"].contains(command.instance) {
            let other = ControlKey(deviceID: deviceID, instance: command.instance == "colorRgb" ? "colorTemperatureK" : "colorRgb")
            pendingControls.removeValue(forKey: other)
            confirmationTasks.removeValue(forKey: other)?.cancel()
            recentConfirmations.removeValue(forKey: other)
        }
        return operation
    }

    private func enqueue(_ operation: QueuedControl) {
        // Collapse unsent UI changes to this control. Explicit scene steps retain
        // their order; an in-flight write always finishes before the next write.
        if operation.coalescible {
            commandQueues[operation.deviceID]?.removeAll { $0.coalescible && $0.key == operation.key }
        }
        commandQueues[operation.deviceID, default: []].append(operation)
        guard commandWorkers[operation.deviceID] == nil else { return }
        commandWorkers[operation.deviceID] = Task { [weak self] in
            guard let self else { return }
            defer { self.commandWorkers.removeValue(forKey: operation.deviceID) }
            while !Task.isCancelled, var queue = self.commandQueues[operation.deviceID], !queue.isEmpty {
                let next = queue.removeFirst()
                self.commandQueues[operation.deviceID] = queue
                self.inFlightControls[operation.deviceID] = next
                do { try await self.transmit(next); next.completion?.resume() }
                catch {
                    self.fail(next, message: error.localizedDescription)
                    next.completion?.resume(throwing: error)
                }
                self.inFlightControls.removeValue(forKey: operation.deviceID)
            }
        }
    }

    private func transmit(_ operation: QueuedControl) async throws {
        guard let device = home.devices.first(where: { $0.id == operation.deviceID }) else { throw LumaError.message("Light not found.") }
        let command = operation.command
        let id = operation.deviceID
        if pendingControls[operation.key]?.id == operation.id { pendingControls[operation.key]?.phase = .sending }
        let route: String
        var usedLAN = false
        if device.isDemo { route = "Demo" }
        else if device.ip != nil && ["powerSwitch", "brightness", "colorRgb", "colorTemperatureK"].contains(command.instance) && (command.instance != "colorTemperatureK" || (2000...9000).contains(command.value.number ?? 0)) {
            try lan.start(onDevice: { [weak self] incoming in self?.merge(incoming); self?.persist() }, onError: { [weak self] message in self?.log(message, error: true) })
            try lan.control(device: device, command: command); route = "LAN sent; awaiting status"; usedLAN = true
        } else if let cloud {
            try await cloud.control(device: device, command: command); route = "Cloud accepted"
            submitted(operation, cloud: cloud)
            do {
                for _ in 0..<2 {
                    guard pendingControls[operation.key]?.id == operation.id else { break }
                    // Give newer queued writes priority over confirmation reads.
                    guard commandQueues[id, default: []].isEmpty else { break }
                    let revision = deviceRevisions[id, default: 0]
                    let latest = home.devices.first { $0.id == id } ?? device
                    let read = try await cloud.state(for: latest)
                    merge(read, stateRevision: revision)
                    if pendingControls[operation.key] == nil { break }
                }
                persist()
            }
            catch { log("Command accepted; state read failed for \(device.name): \(error.localizedDescription)") }
        }
        else { throw LumaError.message("Connect Govee cloud to use \(command.instance) on this light.") }
        // Only demo values are confirmed locally. Real controls keep a separate
        // requested-value overlay until telemetry confirms them or times out.
        if device.isDemo, let i = home.devices.firstIndex(where: { $0.id == id }) {
            switch command.instance {
            case "powerSwitch": home.devices[i].power = command.value.number == 1
            case "brightness": home.devices[i].brightness = command.value.number.map(Int.init)
            case "colorRgb":
                home.devices[i].rgb = command.value.number.map(Int.init)
                home.devices[i].colorTemperature = 0
            case "colorTemperatureK": home.devices[i].colorTemperature = command.value.number.map(Int.init)
            default: break
            }
        }
        if device.isDemo {
            if pendingControls[operation.key]?.id == operation.id { pendingControls.removeValue(forKey: operation.key) }
        } else if usedLAN { submitted(operation) }
        log("\(device.name): \(command.instance) · \(route)")
        if let ip = device.ip { try? lan.requestStatus(ip: ip) }
    }
    /// Screen Sync's latest-only path: direct LAN datagrams with no queue,
    /// pending overlay, readback, persistence, or activity entry. Values are
    /// validated by the LAN packet encoder; demo lights only update the preview.
    func streamToLight(_ device: LightDevice, _ update: StreamUpdate) throws {
        guard !shuttingDown, !hasOrdinaryControl(for: device.id) else { return }
        guard !device.isDemo else { return }
        guard device.ip != nil else { throw LumaError.message("Screen Sync needs local (LAN) control for this light.") }
        try startLAN()
        if update.sendsColor { try lan.control(device: device, command: .rgb(update.target.rgb)) }
        if update.sendsBrightness { try lan.control(device: device, command: .brightness(update.target.brightness)) }
    }
    /// Screen Sync's restore on Stop: LAN only, never cloud.
    func restoreToLight(_ device: LightDevice, _ commands: [CapabilityCommand]) throws {
        guard !shuttingDown, !device.isDemo else { return }
        guard device.ip != nil else { throw LumaError.message("Restoring needs local (LAN) control for this light.") }
        try startLAN()
        for command in commands { try lan.control(device: device, command: command) }
    }
    private func startLAN() throws {
        try lan.start(onDevice: { [weak self] incoming in self?.merge(incoming); self?.persist() }, onError: { [weak self] message in self?.log(message, error: true) })
    }
    func perform(_ command: CapabilityCommand, ids: [String]) {
        for id in ids {
            do { enqueue(try prepare(command, deviceID: id, coalescible: true)) }
            catch { log(error.localizedDescription, error: true) }
        }
    }
    private func submitted(_ operation: QueuedControl, cloud: GoveeCloud? = nil) {
        guard pendingControls[operation.key]?.id == operation.id else { return }
        guard ["powerSwitch", "brightness", "colorRgb", "colorTemperatureK"].contains(operation.command.instance) else {
            pendingControls.removeValue(forKey: operation.key); return
        }
        pendingControls[operation.key]?.phase = .confirming
        confirmationTasks[operation.key]?.cancel()
        confirmationTasks[operation.key] = Task { [weak self] in
            let deadline = ContinuousClock.now.advanced(by: .seconds(30))
            // Confirmation retries yield to writes. A slow cached cloud response
            // must not hold up a newer slider release in the device's write queue.
            for delay in [2, 4, 8] {
                do { try await Task.sleep(for: .seconds(delay)) } catch { return }
                guard let self, self.pendingControls[operation.key]?.id == operation.id else { return }
                guard self.commandWorkers[operation.deviceID] == nil,
                      let device = self.home.devices.first(where: { $0.id == operation.deviceID }) else { continue }
                do {
                    if let cloud {
                        let revision = self.deviceRevisions[device.id, default: 0]
                        self.merge(try await cloud.state(for: device), stateRevision: revision)
                        self.persist()
                    } else if device.ip != nil { try self.lan.requestStatus(for: device) }
                } catch is CancellationError { return }
                catch { self.log("State confirmation unavailable: \(error.localizedDescription)") }
            }
            do { if deadline > .now { try await ContinuousClock().sleep(until: deadline) } } catch { return }
            guard let self, self.pendingControls[operation.key]?.id == operation.id else { return }
            self.fail(operation, message: "Could not confirm \(operation.command.instance) for this light. Showing its last reported state; use Refresh to check it.")
        }
    }
    private func cancelQueued(_ id: UUID) {
        for deviceID in Array(commandQueues.keys) {
            guard let i = commandQueues[deviceID]?.firstIndex(where: { $0.id == id }),
                  let operation = commandQueues[deviceID]?.remove(at: i) else { continue }
            if pendingControls[operation.key]?.id == id {
                pendingControls.removeValue(forKey: operation.key)
                confirmationTasks.removeValue(forKey: operation.key)?.cancel()
                // A cancelled queued step no longer supersedes an earlier write
                // which is already in flight for the same control.
                if let previous = inFlightControls[deviceID], previous.key == operation.key {
                    pendingControls[previous.key] = .init(id: previous.id, command: previous.command)
                    submitted(previous, cloud: home.devices.first(where: { $0.id == deviceID })?.ip == nil ? cloud : nil)
                }
            }
            operation.completion?.resume(throwing: CancellationError())
            return
        }
    }
    private func stopCommands() {
        for queue in commandQueues.values { for operation in queue { operation.completion?.resume(throwing: CancellationError()) } }
        commandQueues.removeAll()
        for worker in commandWorkers.values { worker.cancel() }
        for task in confirmationTasks.values { task.cancel() }
        confirmationTasks.removeAll()
        pendingControls.removeAll()
        recentConfirmations.removeAll()
    }
    private func fail(_ operation: QueuedControl, message: String) {
        if pendingControls[operation.key]?.id == operation.id {
            pendingControls.removeValue(forKey: operation.key)
            confirmationTasks.removeValue(forKey: operation.key)?.cancel()
            log(message, error: true)
        } else { log(message) }
    }
    /// Empty, or the light's own name, clears the custom name.
    func rename(_ name: String, id: String) {
        guard let i = home.devices.firstIndex(where: { $0.id == id }) else { return }
        let trimmed = String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(64))
        home.devices[i].customName = trimmed.isEmpty || trimmed == home.devices[i].name ? nil : trimmed
        persist()
    }
    func assignRoom(_ room: String, id: String) {
        guard let i = home.devices.firstIndex(where: { $0.id == id }) else { return }
        let trimmed = room.trimmingCharacters(in: .whitespacesAndNewlines)
        home.devices[i].room = trimmed.isEmpty ? "Unassigned" : trimmed
        persist()
    }
    func saveScene(_ scene: LightScene) throws {
        try CommandValidation.validateScene(scene, devices: devices)
        if let i = home.scenes.firstIndex(where: { $0.id == scene.id }) { home.scenes[i] = scene }
        else { home.scenes.append(scene) }
        persist(); log("Saved scene: \(scene.name).")
    }
    func captureScene(name: String, ids: [String]) throws {
        var steps: [SceneStep] = []
        for device in home.devices where ids.contains(device.id) {
            if let power = device.power { steps.append(.init(deviceID: device.id, command: .power(power))) }
            if device.power == false { continue }
            if let b = device.brightness, b > 0, device.supports("brightness") { steps.append(.init(deviceID: device.id, command: .brightness(b))) }
            if let k = device.colorTemperature, k > 0, device.supports("colorTemperatureK") { steps.append(.init(deviceID: device.id, command: .kelvin(k))) }
            else if let rgb = device.rgb, device.supports("colorRgb") { steps.append(.init(deviceID: device.id, command: .rgb(rgb))) }
        }
        try saveScene(.init(name: name, steps: steps))
    }
    @discardableResult func runScene(_ scene: LightScene) throws -> UUID {
        guard runningSceneID == nil else { throw LumaError.message("A scene is already running. Stop it before starting another.") }
        try CommandValidation.validateScene(scene, devices: devices)
        let runID = UUID()
        runs.insert(.init(id: runID, sceneID: scene.id, name: scene.name, status: "running", startedAt: Date()), at: 0)
        if runs.count > 100 { runs.removeLast(runs.count - 100) }
        runningSceneID = scene.id; log("Running scene: \(scene.name).")
        sceneTask = Task { [weak self] in
            guard let self else { return }
            defer { self.runningSceneID = nil; self.sceneTask = nil }
            do {
                for step in scene.steps {
                    try Task.checkCancellation()
                    if step.delayMilliseconds > 0 { try await Task.sleep(for: .milliseconds(step.delayMilliseconds)) }
                    try await self.send(step.command, to: step.deviceID)
                }
                self.log("Scene finished: \(scene.name).")
                self.finishRun(runID, status: "completed")
            } catch is CancellationError { self.log("Scene stopped: \(scene.name)."); self.finishRun(runID, status: "cancelled") }
            catch { self.log("Scene stopped: \(error.localizedDescription)", error: true); self.finishRun(runID, status: "failed", error: error.localizedDescription) }
        }
        return runID
    }
    func finishRun(_ id: UUID, status: String, error: String? = nil) {
        if let i = runs.firstIndex(where: { $0.id == id }) { runs[i].status = status; runs[i].finishedAt = Date(); runs[i].error = error }
    }
    func stopScene() { sceneTask?.cancel(); scheduleCoordinator?.cancel() }
    func loadDeviceScenes(_ device: LightDevice, diy: Bool) async {
        guard let cloud else { log("Connect Govee cloud to load device effects.", error: true); return }
        do {
            let caps = try await cloud.scenes(for: device, diy: diy)
            if let i = home.devices.firstIndex(where: { $0.id == device.id }) {
                home.devices[i].capabilities = mergedCapabilities(home.devices[i].capabilities, caps)
            }
            persist(); log("Loaded \(diy ? "DIY" : "dynamic") effects for \(device.name).")
        } catch { log(error.localizedDescription, error: true) }
    }
    func tickSchedules(now: Date = Date()) {
        // Coordinated schedules never run on the legacy path, even offline.
        for i in home.schedules.indices where coordinations[home.schedules[i].id] == nil && (scheduleOwners[home.schedules[i].id] == nil || scheduleOwners[home.schedules[i].id] == installationID) && home.schedules[i].shouldRun(at: now) {
            let schedule = home.schedules[i]
            home.schedules[i].lastRunMinute = schedule.minuteKey(now)
            persist()
            guard let scene = home.scenes.first(where: { $0.id == schedule.sceneID }) else { log("Scheduled scene no longer exists.", error: true); continue }
            do { try runScene(scene) } catch { log("Schedule skipped: \(error.localizedDescription)", error: true) }
        }
        tickCoordinated()
    }
    func startWebhooks() {
        do {
            if webhookToken.isEmpty {
                if demo { webhookToken = try SecretStore.token() }
                else if let saved = try SecretStore.read("webhook-token") { webhookToken = saved }
                else { webhookToken = try SecretStore.token(); try SecretStore.save(webhookToken, account: "webhook-token") }
            }
            // HTTPS only, on loopback and LAN alike; there is no plain-HTTP fallback.
            let tls = try WebhookTLS.load(demo: demo, extraNames: home.allowLAN ? LocalCertificate.lanNames() : [])
            webhookCertificate = (tls.fingerprint, tls.spkiPin ?? "", tls.pem)
            try server.start(port: home.webhookPort, allowLAN: home.allowLAN, token: webhookToken, identity: tls.identity, handler: { [weak self] request in
                guard let self else { return WebhookResponse(status: 503, json: .object(["error": .string("App shutting down")])) }
                return await self.handle(request)
            }, onState: { [weak self] state in
                self?.webhookStatus = state
                let lower = state.lowercased()
                self?.webhookRunning = lower.contains("ready") || lower.contains("listening") || lower.contains("running")
            })
            persist(); log("Webhook listener starting on port \(home.webhookPort).")
        } catch { webhookRunning = false; log("Webhooks: \(error.localizedDescription)", error: true) }
    }
    func stopWebhooks() {
        server.stop(); webhookRunning = false; webhookStatus = "Stopped"; log("Webhook listener stopped.")
        if demo && webhookCertificate != nil { try? WebhookTLS.delete(demo: true); webhookCertificate = nil }
    }
    func rotateToken() {
        stopWebhooks()
        do {
            webhookToken = try SecretStore.token()
            if !demo { try SecretStore.save(webhookToken, account: "webhook-token") }
            log("Webhook token rotated. Update your callers.")
        } catch { log(error.localizedDescription, error: true) }
    }
    func handle(_ request: WebhookRequest) async -> WebhookResponse {
        let path = request.path.split(separator: "?")[0].split(separator: "/").map { String($0).removingPercentEncoding ?? String($0) }
        do {
            if request.method == "GET", path == ["health"] { return .init(status: 200, json: .object(["status": .string("ok"), "demo": .bool(demo)])) }
            if request.method == "GET", path == ["v1", "devices"] { return .init(status: 200, body: try JSONEncoder.pretty.encode(home.devices)) }
            if request.method == "GET", path == ["v1", "scenes"] { return .init(status: 200, body: try JSONEncoder.pretty.encode(home.scenes)) }
            if request.method == "GET", path == ["v1", "runs"] { return .init(status: 200, body: try JSONEncoder.pretty.encode(runs)) }
            if request.method == "GET", path.count == 3, path[0...1] == ["v1", "runs"], let id = UUID(uuidString: path[2]), let run = runs.first(where: { $0.id == id }) { return .init(status: 200, body: try JSONEncoder.pretty.encode(run)) }
            if request.method == "POST", path.count == 4, path[0...1] == ["v1", "scenes"], path[3] == "run" {
                guard let id = UUID(uuidString: path[2]), let scene = home.scenes.first(where: { $0.id == id }) else { return .init(status: 404, json: .object(["error": .string("Scene not found")])) }
                return accepted(try runScene(scene))
            }
            if request.method == "POST", path.count == 4, path[0...1] == ["v1", "devices"], path[3] == "commands" {
                let command = try JSONDecoder().decode(CapabilityCommand.self, from: request.body)
                return accepted(try runScene(.init(name: "Webhook command", steps: [.init(deviceID: path[2], command: command)])))
            }
            if request.method == "POST", path == ["v1", "actions"] {
                let action = try JSONDecoder().decode(AutomationAction.self, from: request.body)
                let ids = try action.deviceIDs(in: devices)
                let commands = try action.commands()
                // Validate the entire action before sending any commands.
                for id in ids {
                    guard let device = devices.first(where: { $0.id == id }) else { continue }
                    for command in commands { try CommandValidation.validate(command, for: device) }
                }
                let steps = ids.flatMap { id in commands.map { SceneStep(deviceID: id, command: $0) } }
                return accepted(try runScene(.init(name: "Webhook action", steps: steps)))
            }
            return .init(status: 404, json: .object(["error": .string("Route not found")]))
        } catch {
            log("Webhook failed: \(error.localizedDescription)", error: true)
            return .init(status: 400, json: .object(["error": .string(error.localizedDescription), "note": .string("An earlier command in a multi-light action may already have been submitted.")]))
        }
    }
    func accepted(_ runID: UUID) -> WebhookResponse {
        .init(status: 202, json: .object(["accepted": .bool(true), "runID": .string(runID.uuidString), "statusURL": .string("/v1/runs/\(runID.uuidString)"), "note": .string("Commands run asynchronously. Completed means submitted, not hardware-confirmed.")]))
    }
    func shutdown() { configurationSync?.stop(); scheduleCoordinator?.cancel(); shuttingDown = true; screenSync.shutdown(); server.stop(); if demo && webhookCertificate != nil { try? WebhookTLS.delete(demo: true) }; lan.stop(); timerTask?.cancel(); sceneTask?.cancel(); scanTask?.cancel(); reconnectTask?.cancel(); stopCommands() }
    func loadDemo() {
        configurationSync?.stop(); configurationSync = nil
        // Explore Demo can enter from a real home with a chosen or running
        // capture. Detach first so demo content and tuning remain isolated.
        screenSync.usePreferences(nil)
        let caps = [Capability(type: "devices.capabilities.on_off", instance: "powerSwitch"), Capability(type: "devices.capabilities.range", instance: "brightness"), Capability(type: "devices.capabilities.color_setting", instance: "colorRgb"), Capability(type: "devices.capabilities.color_setting", instance: "colorTemperatureK")]
        home.devices = [
            .init(id: "demo-floor", sku: "Demo lamp", name: "Corner glow", room: "Living room", capabilities: caps, power: true, brightness: 65, rgb: 0xFFB66A, online: true, isDemo: true),
            .init(id: "demo-strip", sku: "Demo strip", name: "Behind the sofa", room: "Living room", capabilities: caps, power: true, brightness: 42, rgb: 0xCA8BFF, online: true, isDemo: true),
            .init(id: "demo-desk", sku: "Demo light bars", name: "Desk lights", room: "Office", capabilities: caps, power: true, brightness: 80, rgb: 0x89CBD2, online: true, isDemo: true),
            .init(id: "demo-bed", sku: "Demo bulb", name: "Bedside", room: "Bedroom", capabilities: caps, power: false, brightness: 25, rgb: 0xFFC58B, online: true, isDemo: true)
        ]
        home.scenes = [LightScene(name: "Evening unwind", symbol: "moon.stars", steps: home.devices.prefix(2).flatMap { [.init(deviceID: $0.id, command: .power(true)), .init(deviceID: $0.id, command: .brightness(35)), .init(deviceID: $0.id, command: .rgb(0xFFAE64))] }), LightScene(name: "Focus time", symbol: "sun.max", steps: [.init(deviceID: "demo-desk", command: .power(true)), .init(deviceID: "demo-desk", command: .kelvin(4500))])]
        log("Demo home loaded. These are sample lights; no real devices are controlled.")
    }
    func leaveDemo() {
        screenSync.usePreferences(screenSyncDefaults); stopWebhooks(); stopScene(); stopCommands(); webhookToken = ""; demo = false
        do { home = try storage.load(); for i in home.devices.indices { home.devices[i].ip = nil; home.devices[i].online = nil } }
        catch { canSave = false; log("Saved home could not be loaded. Your file was preserved.", error: true) }
        log("Demo closed. Connect your Govee account or discover LAN lights.")
    }
}

func mergedCapabilities(_ existing: [Capability], _ incoming: [Capability]) -> [Capability] {
    var result = existing
    for capability in incoming {
        guard let i = result.firstIndex(where: { $0.id == capability.id }) else { result.append(capability); continue }
        if let oldOptions = result[i].parameters?["options"]?.array, let newOptions = capability.parameters?["options"]?.array, case .object(var parameters) = capability.parameters {
            var options = newOptions
            for option in oldOptions where !options.contains(where: { $0["value"] == option["value"] }) { options.append(option) }
            parameters["options"] = .array(options)
            var merged = capability; merged.parameters = .object(parameters); result[i] = merged
        } else { result[i] = capability }
    }
    return result
}

private struct SyncedPin: Codable {
    let floor: UUID
    let pin: FloorPlanPin
}

extension HomeStore {
    func refreshICloud() {
        guard !demo else { return }
        Task { [weak self] in await self?.configurationSync?.exchange() }
    }

    private func syncSnapshot() throws -> [String: Data] {
        var values: [String: Data] = [:]
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        for device in home.devices where !device.isDemo {
            let id = Data(device.id.utf8).base64EncodedString().replacingOccurrences(of: "/", with: "_")
            values["device:\(id)/room"] = try encoder.encode(device.room)
            if let name = device.customName { values["device:\(id)/name"] = try encoder.encode(name) }
        }
        for scene in home.scenes { values["scene:\(scene.id)/value"] = try encoder.encode(scene) }
        for var schedule in home.schedules {
            schedule.lastRunMinute = nil
            values["schedule:\(schedule.id)/value"] = try encoder.encode(schedule)
            // Older builds run a schedule only when owner == their installation; the sentinel stops them once synced.
            values["schedule:\(schedule.id)/owner"] = try encoder.encode(coordinations[schedule.id] != nil ? "coordinated" : scheduleOwners[schedule.id] ?? installationID)
            if let coordination = coordinations[schedule.id] { values["schedule:\(schedule.id)/coordination"] = try encoder.encode(coordination) }
        }
        if configurationSync != nil {
            values["scheduler:\(installationID)/name"] = try encoder.encode(thisSchedulerDevice.name)
        }
        for plan in floorPlans {
            values["floor:\(plan.id)/name"] = try encoder.encode(plan.name)
            values["floor:\(plan.id)/image"] = try Data(contentsOf: floorPlanImageURL(plan.id))
            for pin in plan.pins {
                let id = Data(pin.deviceID.utf8).base64EncodedString().replacingOccurrences(of: "/", with: "_")
                values["pin:\(id)/value"] = try encoder.encode(SyncedPin(floor: plan.id, pin: pin))
            }
        }
        return values
    }

    private func applySync(_ records: [String: SyncMutation]) throws {
        guard canSave, canSaveFloorPlans, !demo else { return }
        let decoder = JSONDecoder()
        let originalHome = home
        let originalOwners = scheduleOwners
        let originalCoordinations = coordinations
        var committed = false
        defer { if !committed { home = originalHome; scheduleOwners = originalOwners; coordinations = originalCoordinations } }
        for i in home.devices.indices {
            let id = Data(home.devices[i].id.utf8).base64EncodedString().replacingOccurrences(of: "/", with: "_")
            if let mutation = records["device:\(id)/name"] {
                home.devices[i].customName = try mutation.value.map { try decoder.decode(String.self, from: $0) }
            }
            if let data = records["device:\(id)/room"]?.value { home.devices[i].room = try decoder.decode(String.self, from: data) }
        }
        for mutation in records.values where mutation.field == "value" && mutation.entity.hasPrefix("scene:") {
            guard let id = UUID(uuidString: String(mutation.entity.dropFirst(6))) else { continue }
            home.scenes.removeAll { $0.id == id }
            if let data = mutation.value { home.scenes.append(try decoder.decode(LightScene.self, from: data)) }
        }
        for mutation in records.values where mutation.field == "value" && mutation.entity.hasPrefix("schedule:") {
            guard let id = UUID(uuidString: String(mutation.entity.dropFirst(9))) else { continue }
            let lastRun = home.schedules.first { $0.id == id }?.lastRunMinute
            home.schedules.removeAll { $0.id == id }
            if let data = mutation.value {
                var schedule = try decoder.decode(SceneSchedule.self, from: data)
                schedule.lastRunMinute = lastRun
                home.schedules.append(schedule)
                // An absent/invalid owner cannot silently enable execution here.
                scheduleOwners[id] = records["schedule:\(id)/owner"]?.value.flatMap { try? decoder.decode(String.self, from: $0) } ?? "unassigned"
            }
        }
        for id in home.schedules.map(\.id) {
            guard let mutation = records["schedule:\(id)/coordination"] else { continue }
            coordinations[id] = try mutation.value.map { try decoder.decode(ScheduleCoordination.self, from: $0) }
        }
        coordinations = coordinations.filter { id, _ in home.schedules.contains { $0.id == id } }
        var devices = [thisSchedulerDevice]
        for mutation in records.values where mutation.field == "name" && mutation.entity.hasPrefix("scheduler:") {
            let id = String(mutation.entity.dropFirst(10))
            guard id != installationID, let data = mutation.value, let name = try? decoder.decode(String.self, from: data) else { continue }
            devices.append(SchedulerDevice(id: id, name: name))
        }
        schedulerDevices = devices
        var plans = floorPlans
        for mutation in records.values where mutation.entity.hasPrefix("floor:") && mutation.field == "name" {
            guard let id = UUID(uuidString: String(mutation.entity.dropFirst(6))) else { continue }
            if let data = mutation.value {
                let name = try decoder.decode(String.self, from: data)
                if let image = records["floor:\(id)/image"]?.value {
                    if (try? Data(contentsOf: floorPlanImageURL(id))) != image {
                        try floorPlanStorage.importSyncedImage(image, id: id)
                    }
                }
                if let i = plans.firstIndex(where: { $0.id == id }) { plans[i].name = name }
                else { plans.append(FloorPlan(id: id, name: name)) }
            } else {
                plans.removeAll { $0.id == id }
                // Keep private orphan assets until cleanup; failed merges never destroy originals.
            }
        }
        for mutation in records.values where mutation.entity.hasPrefix("pin:") && mutation.field == "value" {
            let encoded = String(mutation.entity.dropFirst(4)).replacingOccurrences(of: "_", with: "/")
            guard let raw = Data(base64Encoded: encoded), let deviceID = String(data: raw, encoding: .utf8) else { continue }
            for i in plans.indices { plans[i].pins.removeAll { $0.deviceID == deviceID } }
            if let data = mutation.value {
                let placement = try decoder.decode(SyncedPin.self, from: data)
                if let i = plans.firstIndex(where: { $0.id == placement.floor }) { plans[i].pins.append(placement.pin) }
            }
        }
        try storage.save(home)
        try floorPlanStorage.save(plans)
        floorPlans = plans
        try JSONEncoder().encode(scheduleOwners).write(to: storage.folder.appending(path: "schedule-owners.json"), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        try saveCoordinations()
        committed = true
    }
}

// MARK: - Coordinated schedules

extension HomeStore: ScheduleHost {
    var thisSchedulerID: String { installationID }
    var coordinatedSchedulingAvailable: Bool { scheduleCoordinator != nil }
    var thisSchedulerDevice: SchedulerDevice {
#if os(macOS)
        SchedulerDevice(id: installationID, name: Host.current().localizedName ?? "Mac")
#else
        SchedulerDevice(id: installationID, name: UIDevice.current.name)
#endif
    }

    /// Enables (or, with nil, ends) coordinated mode. Ending it keeps the schedule on this installation.
    func setCoordination(_ coordination: ScheduleCoordination?, for id: UUID) {
        guard home.schedules.contains(where: { $0.id == id }) else { return }
        coordinations[id] = coordination
        if coordination == nil { scheduleOwners[id] = installationID; scheduleStatus[id] = nil }
        do {
            try saveCoordinations()
            try JSONEncoder().encode(scheduleOwners).write(to: storage.folder.appending(path: "schedule-owners.json"), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        } catch { log("Could not save schedule failover: \(error.localizedDescription)", error: true) }
        persist()
    }

    private func saveCoordinations() throws {
        guard canSave, !demo else { return }
        try JSONEncoder().encode(coordinations).write(to: storage.folder.appending(path: "schedule-coordination.json"), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    func tickCoordinated() {
        let mine = home.schedules.compactMap { schedule in coordinations[schedule.id].map { (schedule, $0) } }
        guard let scheduleCoordinator else {
            // No cloud claim is possible, so coordinated schedules must not run here at all.
            for (schedule, _) in mine { scheduleStatus[schedule.id] = "Paused: iCloud is unavailable in this build" }
            return
        }
#if os(macOS)
        // App Nap could delay ticks for minutes; sleep is still allowed and no wake is promised.
        let hasRole = mine.contains { ScheduleFailover.role(of: installationID, in: $0.1) != nil }
        if hasRole, schedulerActivity == nil {
            schedulerActivity = ProcessInfo.processInfo.beginActivity(options: .userInitiatedAllowingIdleSystemSleep, reason: "Running Luma schedules")
        } else if !hasRole, let activity = schedulerActivity {
            ProcessInfo.processInfo.endActivity(activity); schedulerActivity = nil
        }
#endif
        guard !mine.isEmpty else { return }
        Task { await scheduleCoordinator.tick(mine) }
    }

    func coordinatedSchedule(_ id: UUID) -> (SceneSchedule, ScheduleCoordination, LightScene)? {
        guard let schedule = home.schedules.first(where: { $0.id == id }), schedule.enabled,
              let coordination = coordinations[id],
              let scene = home.scenes.first(where: { $0.id == schedule.sceneID }) else { return nil }
        return (schedule, coordination, scene)
    }

    func beginScheduledRun(_ scene: LightScene) -> UUID? {
        guard runningSceneID == nil, (try? CommandValidation.validateScene(scene, devices: devices)) != nil else { return nil }
        let runID = UUID()
        runs.insert(.init(id: runID, sceneID: scene.id, name: scene.name, status: "running", startedAt: Date()), at: 0)
        if runs.count > 100 { runs.removeLast(runs.count - 100) }
        runningSceneID = scene.id; log("Running scheduled scene: \(scene.name).")
        return runID
    }

    func endScheduledRun(_ runID: UUID, status: String, error: String?) {
        runningSceneID = nil
        finishRun(runID, status: status, error: error)
        log(error.map { "Scheduled scene \(status): \($0)" } ?? "Scheduled scene \(status).", error: status != "completed")
    }

    func sendScheduled(_ step: SceneStep) async throws {
        guard let device = home.devices.first(where: { $0.id == step.deviceID }) else { throw CommandNotSent(underlying: LumaError.message("Light not found.")) }
        do { try CommandValidation.validate(step.command, for: device) } catch { throw CommandNotSent(underlying: error) }
        // After wake the cloud may still be reconnecting: nothing has been sent, so this step may retry.
        guard cloud != nil || device.ip != nil else { throw CommandNotSent(underlying: LumaError.message("No route to the light yet.")) }
        try await send(step.command, to: step.deviceID)
    }
}
