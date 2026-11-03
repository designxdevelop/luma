// GoveeDreamViewReceiver — a BLE peripheral that impersonates a Govee RGBIC
// light so a Govee TV-backlight controller ("DreamView sync centre") will
// connect to it and push the live, camera-derived colours it would send to a
// real follower. We log and parse those writes; nothing is sent to real lights
// here. This is an evidence-gathering prototype, not a product feature.
//
// HYPOTHESIS under test (observation vs. inference kept separate):
//   Observed (public RE corpus, teh-hippo/ha-govee-led-ble @ b845c59):
//     - Members are addressed by BLE identity: reversed 6-byte MAC or UTF-8 name
//       (h6099_dreamview_group.ksy; dreamview.py DreamviewMember).
//     - "DreamView member devices are single-client BLE peripherals claimed
//       directly by the sync centre after 0x50 group upload" and HA must
//       "confirm physical BLE disconnect before uploading 0x50"
//       (coordinator_dreamview.py). => the controller is the GATT *client*; the
//       follower is the peripheral.
//     - Standard Govee GATT (transport.py): service 00010203-…-1910,
//       WRITE 2b11, READ/notify 2b10, ENCRYPTION 2b12. Control frames are
//       20 bytes: 0x33|opcode|17-body|XOR (command_write.ksy), or the 7-byte
//       music push 0xa5 0x02 0x83 R G B SUM (music_stream.ksy).
//     - Link encryption is advertised by manufacturer-data flag bit 0x40
//       (advertisement.py). We DO NOT set it, so the controller should write
//       plaintext.
//   Inferred (to confirm on hardware): that once enrolled, the sync centre
//     actually connects and streams per-area colour writes to this peripheral,
//     and in which exact opcode. The WRITE characteristic + frame envelope are
//     known, so this logger captures whatever arrives regardless of opcode.
//
// RUN (macOS, needs Bluetooth permission; no third-party deps):
//   swift GoveeDreamViewReceiver.swift [advertisedName]
// Default advertised name is "Luma-Bridge"; enrol that exact name as a
// name-addressed member via build_member_record.py from the Govee phone app's
// controller, or via the HA integration's replace_dreamview_group.
//
// GATE (do not skip): a 0x50 upload REPLACES the whole group and there is no
// membership readback, so the user's existing DreamView group cannot be
// restored programmatically — they must rebuild it in the Govee app afterwards.
// Get explicit consent before enrolling this bridge on real hardware.

import CoreBluetooth
import Foundation

let goveeService = CBUUID(string: "00010203-0405-0607-0809-0a0b0c0d1910")
let writeUUID    = CBUUID(string: "00010203-0405-0607-0809-0a0b0c0d2b11")
let readUUID     = CBUUID(string: "00010203-0405-0607-0809-0a0b0c0d2b10")
let encryptUUID  = CBUUID(string: "00010203-0405-0607-0809-0a0b0c0d2b12")

func xorChecksum(_ d: ArraySlice<UInt8>) -> UInt8 { d.reduce(0, ^) }

/// Best-effort decode of a frame the sync centre writes to a follower. Returns
/// a human-readable note plus any RGB triples recovered. Unknown frames are
/// logged raw — absence of a match is not evidence of absence.
func describeFrame(_ bytes: [UInt8]) -> String {
    guard !bytes.isEmpty else { return "empty" }
    // 7-byte microphone/colour push: a5 02 83 R G B SUM (music_stream.ksy)
    if bytes.count == 7, bytes[0] == 0xA5, bytes[1] == 0x02, bytes[2] == 0x83 {
        let sum = UInt8((Int(bytes[0]) + Int(bytes[1]) + Int(bytes[2])
                         + Int(bytes[3]) + Int(bytes[4]) + Int(bytes[5])) & 0xFF)
        let ok = sum == bytes[6] ? "✓" : "✗(\(sum))"
        return "music-push rgb=(\(bytes[3]),\(bytes[4]),\(bytes[5])) sum\(ok)"
    }
    // 20-byte command envelope: 33|opcode|…|XOR (command_write.ksy)
    if bytes.count == 20 {
        let trailerOK = xorChecksum(bytes[0..<19]) == bytes[19] ? "✓" : "✗"
        if bytes[0] == 0x33 {
            let op = String(format: "0x%02x", bytes[1])
            // opcode 0x05 multi, sub 0x15 static → RGB sits in the body; surface candidate triples.
            let rgbs = stride(from: 2, to: 17, by: 3).compactMap { i -> String? in
                i + 2 < bytes.count ? "(\(bytes[i]),\(bytes[i+1]),\(bytes[i+2]))" : nil
            }
            return "cmd op=\(op) xor\(trailerOK) body=\(hex(Array(bytes[2..<19]))) rgb?=\(rgbs.joined(separator:" "))"
        }
        if bytes[0] == 0xA3 {
            return "A3 frag index=\(String(format:"0x%02x",bytes[1])) xor\(trailerOK) chunk=\(hex(Array(bytes[2..<19])))"
        }
    }
    return "raw(\(bytes.count))"
}

func hex(_ b: [UInt8]) -> String { b.map { String(format: "%02x", $0) }.joined() }

func stamp() -> String {
    let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return f.string(from: Date())
}

final class Receiver: NSObject, CBPeripheralManagerDelegate {
    let name: String
    var manager: CBPeripheralManager!
    init(name: String) { self.name = name; super.init() }

    func start() { manager = CBPeripheralManager(delegate: self, queue: nil) }

    func peripheralManagerDidUpdateState(_ peripheral: CBPeripheralManager) {
        guard peripheral.state == .poweredOn else {
            FileHandle.standardError.write("[\(stamp())] bluetooth not ready: \(peripheral.state.rawValue)\n".data(using: .utf8)!)
            return
        }
        // Writable (so the controller can push colours) + notify (so it can read us back).
        let write = CBMutableCharacteristic(type: writeUUID, properties: [.write, .writeWithoutResponse],
                                            value: nil, permissions: [.writeable])
        let read = CBMutableCharacteristic(type: readUUID, properties: [.read, .notify],
                                           value: nil, permissions: [.readable])
        let enc = CBMutableCharacteristic(type: encryptUUID, properties: [.read, .write, .notify],
                                          value: nil, permissions: [.readable, .writeable])
        let svc = CBMutableService(type: goveeService, primary: true)
        svc.characteristics = [write, read, enc]
        peripheral.add(svc)
        // No manufacturer data (CBPeripheralManager can't set it) and no 0x40
        // encryption flag advertised. KNOWN UNKNOWN: if the controller filters
        // followers on Govee manufacturer data, macOS peripheral mode is
        // insufficient and the next input is an ESP32/BlueZ peripheral.
        peripheral.startAdvertising([
            CBAdvertisementDataLocalNameKey: name,
            CBAdvertisementDataServiceUUIDsKey: [goveeService],
        ])
        print("[\(stamp())] advertising as \"\(name)\" with Govee service; waiting for sync centre to connect…")
    }

    func peripheralManager(_ peripheral: CBPeripheralManager, didReceiveWrite requests: [CBATTRequest]) {
        for r in requests {
            let bytes = [UInt8](r.value ?? Data())
            let char = r.characteristic.uuid == writeUUID ? "WRITE"
                     : r.characteristic.uuid == encryptUUID ? "ENC" : r.characteristic.uuid.uuidString
            print("[\(stamp())] \(char) <- \(hex(bytes))  | \(describeFrame(bytes))")
            peripheral.respond(to: r, withResult: .success)
        }
    }

    func peripheralManager(_ peripheral: CBPeripheralManager, central: CBCentral,
                           didSubscribeTo characteristic: CBCharacteristic) {
        print("[\(stamp())] central subscribed to \(characteristic.uuid) — sync centre is talking to us")
    }
}

let advertisedName = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "Luma-Bridge"
let receiver = Receiver(name: advertisedName)
receiver.start()
print("Govee DreamView receiver prototype. Ctrl-C to stop. Logging all writes.")
RunLoop.main.run()
