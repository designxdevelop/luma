#if os(macOS) || os(iOS)
import CoreBluetooth
import LumaCore
import SwiftUI

/// CoreBluetooth transport for `GoveeBLE`: a passive scan, and one connection at a
/// time opened only when the person asks. Every connection follows the source's
/// order (connect → services → encryption marker → notifications → handshake →
/// status reads), keeps alive with power queries every 5 s, and drops after 20 s
/// without a reply or 3 minutes without use, so a light is never held.
///
/// The central manager is created on the first scan, not at launch: creating it
/// is what shows the Bluetooth permission prompt.
@Observable final class BluetoothLights: NSObject {
    enum Availability: Equatable { case notStarted, unsupported, unauthorized, off, ready }
    enum Phase: Equatable { case idle, connecting, securing, reading, ready, failed(String) }

    struct Nearby: Identifiable, Equatable {
        let id: UUID
        var localName: String
        var model: String?
        var advertisement: GoveeBLE.Advertisement?
        var rssi: Int
        var profile: GoveeBLEProfile? { model.flatMap { GoveeBLEProfile.resolve(model: $0, pact: advertisement?.pact) } }
    }

    /// What the connected light has reported this session. Nil = not read yet.
    struct Readback: Equatable {
        var power: Bool?
        var brightness: Int?
        var mode: GoveeBLE.Mode?
        var firmware: String?
        var hardware: String?
        var groupEnabled: Bool?
        /// Raw: 0 All / 1 Part, 0 Game / 1 Movie.
        var groupApplyArea: UInt8?
        var groupContentMode: UInt8?
        var groupSaturation: Int?
        var memberSlots: [UInt8]?
    }

    private(set) var availability = Availability.notStarted
    private(set) var scanning = false
    private(set) var nearby: [Nearby] = []
    private(set) var phase = Phase.idle
    private(set) var connectedID: UUID?
    private(set) var profile: GoveeBLEProfile?
    private(set) var readback = Readback()
    private(set) var session = GoveeBLESession()
    /// Per light, so one light's encryption requirement never applies to another.
    private var sessions: [UUID: GoveeBLESession] = [:]

    private var central: CBCentralManager?
    private var peripherals: [UUID: CBPeripheral] = [:]
    private var peripheral: CBPeripheral?
    private var writeCharacteristic: CBCharacteristic?
    private var notifyCharacteristic: CBCharacteristic?
    private var markerCharacteristic: CBCharacteristic?
    private var pendingServices = 0
    private var outbox: [Data] = []
    private var pumping = false
    private var deadline: Task<Void, Never>?
    private var keepAlive: Task<Void, Never>?
    private var lastReceived = Date.distantPast
    private var lastUsed = Date()
    private var scanStop: Task<Void, Never>?

    var connected: Nearby? { connectedID.flatMap { id in nearby.first { $0.id == id } } }

    var encryptionLabel: String {
        guard session.ready else { return "Not connected" }
        return session.version == 0 ? "Not encrypted" : "Encrypted (V\(session.version))"
    }

    // MARK: Scanning

    func scan() {
        guard let central else {
            central = CBCentralManager(delegate: self, queue: .main)   // state callback starts the scan
            return
        }
        guard central.state == .poweredOn, !scanning else { return }
        scanning = true
        central.scanForPeripherals(withServices: nil, options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
        scanStop?.cancel()
        scanStop = Task { [weak self] in
            try? await Task.sleep(for: .seconds(15))
            self?.stopScan()
        }
    }

    func stopScan() {
        scanStop?.cancel()
        if scanning { central?.stopScan() }
        scanning = false
    }

    // MARK: Connection

    func connect(_ id: UUID) {
        guard let central, let target = peripherals[id], connectedID == nil,
              nearby.first(where: { $0.id == id })?.profile != nil else { return }
        stopScan()
        connectedID = id; peripheral = target
        profile = nearby.first { $0.id == id }?.profile
        readback = Readback(); session = sessions[id] ?? GoveeBLESession(); session.reset(); outbox = []
        phase = .connecting; lastUsed = Date()
        setDeadline(30, "The light didn't finish connecting. Move closer and try again.")
        central.connect(target)
    }

    func disconnect(_ reason: String? = nil) {
        deadline?.cancel(); keepAlive?.cancel()
        if let peripheral { central?.cancelPeripheralConnection(peripheral) }
        peripheral = nil; writeCharacteristic = nil; notifyCharacteristic = nil; markerCharacteristic = nil
        session.reset()
        if let connectedID { sessions[connectedID] = session }
        outbox = []; connectedID = nil
        phase = reason.map(Phase.failed) ?? .idle
    }

    private func setDeadline(_ seconds: Double, _ message: String) {
        deadline?.cancel()
        deadline = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled else { return }
            self?.disconnect(message)
        }
    }

    private func discovered(_ p: CBPeripheral) {
        for service in p.services ?? [] {
            for c in service.characteristics ?? [] {
                switch c.uuid.uuidString.uppercased() {
                case GoveeBLE.writeCharacteristic: writeCharacteristic = c
                case GoveeBLE.notifyCharacteristic: notifyCharacteristic = c
                case GoveeBLE.encryptionCharacteristic: markerCharacteristic = c
                default: break
                }
            }
        }
        guard writeCharacteristic != nil, notifyCharacteristic != nil else { return disconnect("This light doesn't expose Govee's Bluetooth control service.") }
        // The source writes without response; a light that only takes acknowledged writes isn't the evidenced protocol.
        guard writeCharacteristic?.properties.contains(.writeWithoutResponse) == true else { return disconnect("This light's control characteristic doesn't accept the writes Luma sends, so nothing was sent.") }
        phase = .securing
        if let markerCharacteristic { p.readValue(for: markerCharacteristic) } else { select(.absent) }
    }

    private func select(_ marker: GoveeBLESession.Marker) {
        let ad = connected?.advertisement
        do {
            try session.select(marker: marker, advertisedEncryption: ad?.supportsEncryption ?? false,
                               plaintextEvidence: ad.map { !$0.supportsEncryption } ?? false)
        } catch { return disconnect("Luma couldn't tell how this light encrypts its connection, so it didn't send anything.") }
        if let model = connected?.model, let pact = session.markerPact ?? ad?.pact { profile = GoveeBLEProfile.resolve(model: model, pact: pact) }
        if let notifyCharacteristic { peripheral?.setNotifyValue(true, for: notifyCharacteristic) }
    }

    private func negotiate() {
        guard let peripheral else { return }
        do {
            guard let first = try session.startNegotiation(maxWriteLength: peripheral.maximumWriteValueLength(for: .withoutResponse)) else { return becameReady() }
            setDeadline(6, "The light didn't answer the encryption handshake.")
            enqueue(first)
        } catch { disconnect("This connection can't carry the light's encryption (the Bluetooth packet size is too small).") }
    }

    private func becameReady() {
        deadline?.cancel()
        phase = .reading
        var queries: [GoveeBLE.Query] = [.power, .brightness, .colorMode, .firmware]
        if profile?.supports(.hardwareQuery) == true { queries.append(.hardware) }
        queries.forEach { send($0.frame) }
        if profile?.supports(.dreamView) == true {
            [.switchGroup, .videoSettings, .saturation, .memberConnect].forEach { send(GoveeBLE.DreamView.query($0)) }
        }
        phase = .ready
        lastReceived = Date()
        keepAlive?.cancel()
        keepAlive = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                guard let self, !Task.isCancelled, self.phase == .ready else { return }
                if Date().timeIntervalSince(self.lastReceived) > 20 { return self.disconnect("The light stopped answering.") }
                if Date().timeIntervalSince(self.lastUsed) > 180 { return self.disconnect() }
                self.send(GoveeBLE.Query.power.frame)
            }
        }
    }

    private func received(_ bytes: [UInt8]) {
        lastReceived = Date()
        let event: GoveeBLESession.Event
        do { event = try session.receive(bytes) } catch { return disconnect("The light rejected the encryption handshake.") }
        switch event {
        case .write(let frame): enqueue(frame)
        case .ready: becameReady()
        case .ignored: break
        case .packet(let frame):
            switch GoveeBLE.parseStatus(frame) {
            case .power(let on)?: readback.power = on
            case .brightness(let v)?: readback.brightness = v
            case .mode(let m)?: readback.mode = m
            case .firmware(let s)?: readback.firmware = s
            case .hardware(let s)?: readback.hardware = s
            case .dreamView(.enabled(let on))?: readback.groupEnabled = on
            case .dreamView(.videoSettings(let area, let content))?: readback.groupApplyArea = area; readback.groupContentMode = content
            case .dreamView(.saturation(let v))?: readback.groupSaturation = v
            case .dreamView(.memberConnect(let raw))?: readback.memberSlots = raw
            default: break
            }
        }
    }

    // MARK: Writes

    /// Sends a logical frame through the session. Controls re-read what they change.
    func send(_ frame: [UInt8], thenRead query: [UInt8]? = nil) {
        guard session.ready, let packet = try? session.encode(frame) else { return }
        lastUsed = Date()
        enqueue(packet)
        if let query { send(query) }
    }

    private func enqueue(_ bytes: [UInt8]) {
        outbox.append(Data(bytes))
        guard !pumping else { return }
        pumping = true
        Task { [weak self] in
            // ponytail: fixed 60 ms pacing; tune per model if a light drops writes.
            while let self, !self.outbox.isEmpty, let p = self.peripheral, let w = self.writeCharacteristic {
                if p.canSendWriteWithoutResponse { p.writeValue(self.outbox.removeFirst(), for: w, type: .withoutResponse) }
                try? await Task.sleep(for: .milliseconds(60))
            }
            self?.pumping = false
        }
    }

    private func noteAdvertisement(_ p: CBPeripheral, _ data: [String: Any], rssi: Int) {
        let name = (data[CBAdvertisementDataLocalNameKey] as? String) ?? p.name ?? ""
        let ad = (data[CBAdvertisementDataManufacturerDataKey] as? Data).flatMap { GoveeBLE.Advertisement(manufacturerData: Array($0)) }
        let model = GoveeBLE.model(fromLocalName: name)
        guard ad != nil || model != nil else { return }
        peripherals[p.identifier] = p
        let entry = Nearby(id: p.identifier, localName: name, model: model, advertisement: ad, rssi: rssi)
        if let i = nearby.firstIndex(where: { $0.id == p.identifier }) {
            // Keep the advertisement already seen if this one is a scan response without it.
            nearby[i] = Nearby(id: entry.id, localName: name.isEmpty ? nearby[i].localName : name, model: model ?? nearby[i].model,
                               advertisement: ad ?? nearby[i].advertisement, rssi: rssi)
        } else {
            nearby.append(entry)
        }
    }
}

extension BluetoothLights: @preconcurrency CBCentralManagerDelegate, @preconcurrency CBPeripheralDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn: availability = .ready; scan()
        case .unauthorized: availability = .unauthorized
        case .unsupported: availability = .unsupported
        case .poweredOff: availability = .off
        default: break
        }
        if central.state != .poweredOn { scanning = false; if connectedID != nil { disconnect("Bluetooth turned off.") } }
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData: [String: Any], rssi RSSI: NSNumber) {
        noteAdvertisement(peripheral, advertisementData, rssi: RSSI.intValue)
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        guard peripheral == self.peripheral else { return }
        peripheral.delegate = self
        peripheral.discoverServices(nil)
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: (any Error)?) {
        if peripheral == self.peripheral { disconnect("Couldn't connect. The light may be connected to another phone or hub.") }
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: (any Error)?) {
        if peripheral == self.peripheral { disconnect(error == nil ? nil : "The light disconnected.") }
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: (any Error)?) {
        guard peripheral == self.peripheral else { return }
        let services = peripheral.services ?? []
        guard error == nil, !services.isEmpty else { return disconnect("Couldn't read the light's Bluetooth services.") }
        pendingServices = services.count
        services.forEach { peripheral.discoverCharacteristics(nil, for: $0) }
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: (any Error)?) {
        guard peripheral == self.peripheral else { return }
        pendingServices -= 1
        if pendingServices == 0 { discovered(peripheral) }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: (any Error)?) {
        guard peripheral == self.peripheral else { return }
        if characteristic == markerCharacteristic, phase == .securing, !session.ready, notifyCharacteristic?.isNotifying != true {
            let marker: GoveeBLESession.Marker = if error == nil, let value = characteristic.value { .value(Array(value)) } else { .readFailed }
            select(marker)
        } else if characteristic == notifyCharacteristic, let value = characteristic.value, error == nil {
            received(Array(value))
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: (any Error)?) {
        guard peripheral == self.peripheral, characteristic == notifyCharacteristic else { return }
        guard error == nil, characteristic.isNotifying else { return disconnect("The light refused status notifications.") }
        negotiate()
    }
}
#endif
