import Foundation
import Testing
@testable import LumaCore

/// Byte vectors come from ha-govee-led-ble @ b845c59 tests (`test_h6099.py`,
/// `test_h6099_dreamview.py`, `test_govee_encryption.py`). Crypto vectors were
/// produced separately with Python `cryptography` from the same algorithm
/// description, so CommonCrypto/CryptoKit are checked against another library.
struct GoveeBLETests {
    func f(_ hex: String) -> [UInt8] { GoveeBLE.frame(GoveeBLECrypto.hex(hex)) }
    func h(_ hex: String) -> [UInt8] { GoveeBLECrypto.hex(hex) }

    @Test func commandsMatchSourceVectors() throws {
        #expect(GoveeBLE.power(true) == f("330101"))
        #expect(try GoveeBLE.brightness(42) == f("33042a"))
        #expect(GoveeBLE.color(red: 1, green: 2, blue: 3, mask: 0x3FFF) == f("330515010102030000000000ff3f"))
        #expect(GoveeBLE.color(red: 1, green: 2, blue: 3, mask: 0x2000) == f("3305150101020300000000000020"))
        #expect(try GoveeBLE.videoMode(.game, wholeScreen: false, saturation: 42, soundEffects: true, softness: 55) == f("33050001082a010237"))
        let queries: [(GoveeBLE.Query, String)] = [(.power, "aa0100"), (.brightness, "aa0400"), (.colorMode, "aa0501"), (.firmware, "aa0600"), (.hardware, "aa0703")]
        for (query, prefix) in queries { #expect(query.frame == f(prefix)) }
        #expect(throws: (any Error).self) { try GoveeBLE.brightness(101) }
        #expect(throws: (any Error).self) { try GoveeBLE.videoMode(.movie, wholeScreen: true, saturation: 0, soundEffects: false, softness: 0) }
    }

    @Test func statusRepliesParseOnlyWhatTheSchemaDefines() {
        #expect(GoveeBLE.parseStatus(f("aa0101")) == .power(true))
        #expect(GoveeBLE.parseStatus(f("aa042a")) == .brightness(42))
        #expect(GoveeBLE.parseStatus(f("aa050001082a010237")) == .mode(.video(source: .game, wholeScreen: false, saturation: 42, soundEffects: true, softness: 55)))
        #expect(GoveeBLE.parseStatus(f("aa0515011194")) == .mode(.staticColor(kelvin: 4500)))
        #expect(GoveeBLE.parseStatus(f("aa05043412")) == .mode(.scene(id: 0x1234)))
        #expect(GoveeBLE.parseStatus(f("aa050a3412")) == .mode(.other(0x0A)))
        #expect(GoveeBLE.parseStatus(f("aa06" + "312e30322e3033")) == .firmware("1.02.03"))
        #expect(GoveeBLE.parseStatus(f("aa0703" + "312e3034")) == .hardware("1.04"))
        #expect(GoveeBLE.parseStatus(f("aa04ff")) == nil)
        #expect(GoveeBLE.parseStatus(f("330101")) == nil)
        #expect(GoveeBLE.parseStatus(Array(f("aa0101").dropLast()) + [0]) == nil)
    }

    @Test func dreamViewModuleReadsAndWrites() throws {
        typealias D = GoveeBLE.DreamView
        #expect(D.query(.switchGroup) == f("aa600101"))
        let reads: [(D.Setting, String)] = [(.memberBrightness, "aa6003"), (.sameBrightness, "aa6004"), (.memberConnect, "aa6005"), (.saturation, "aa6009"), (.videoSettings, "aa600a"), (.sound, "aa600b")]
        for (setting, prefix) in reads { #expect(D.query(setting) == f(prefix)) }
        #expect(D.setEnabled(true) == f("3360010101") && D.setEnabled(false) == f("3360010001"))
        #expect(try D.setSaturation(50) == f("33600932"))
        #expect(D.setVideo(wholeScreen: false, movie: true) == f("33600a0101"))
        #expect(D.parse(f("aa600aabcd")) == .videoSettings(applyArea: 0xAB, contentMode: 0xCD))
        #expect(D.parse(f("aa600101")) == .enabled(true))
        #expect(D.parse(f("aa600b014f")) == .sound(enabled: true, softness: 79))
        #expect(D.parse(f("aa600501000000000000007f00")) == .memberConnect(raw: [1, 0, 0, 0, 0, 0, 0, 0, 127, 0]))
        if case .memberBrightness(let raw)? = D.parse(f("aa6003")) { #expect(raw.count == 16) } else { Issue.record("brightness") }
        for bad in [f("aa600c"), f("3360010101"), f("aa600d"), f("aa6011"), Array(f("aa6009").dropLast()), Array(f("aa6009").dropLast()) + [0xFF], f("aa6109")] {
            #expect(D.parse(bad) == nil && GoveeBLE.parseStatus(bad) == nil)
        }
    }

    @Test func advertisementNameAndProfile() {
        let enc = GoveeBLE.Advertisement(manufacturerData: [0x43, 0x88] + h("ec00010100"))
        #expect(enc?.supportsEncryption == true && enc?.pact == .init(type: 1, code: 1))
        let plain = GoveeBLE.Advertisement(manufacturerData: [0x02, 0x88] + h("ec00020100"))
        #expect(plain?.supportsEncryption == false && plain?.pact == .init(type: 2, code: 1))
        #expect(GoveeBLE.Advertisement(manufacturerData: [0x01, 0x88] + h("ec000101"))?.pact == .init(type: 1, code: 1))
        #expect(GoveeBLE.Advertisement(manufacturerData: [0x43, 0x88, 0xEC]) == nil)
        #expect(GoveeBLE.Advertisement(manufacturerData: [0x4C, 0x00, 0x02, 0x15, 0, 0]) == nil)

        #expect(GoveeBLE.model(fromLocalName: "Govee_H6097_1A2B") == "H6097")
        #expect(GoveeBLE.model(fromLocalName: "ihoment_h66a0_ABCD") == "H66A0")
        #expect(GoveeBLE.model(fromLocalName: "GVH5075_1234") == "H5075")
        #expect(GoveeBLE.model(fromLocalName: "H6099_12AB") == "H6099")
        #expect(GoveeBLE.model(fromLocalName: "Living Room Speaker") == nil)

        let full = GoveeBLEProfile.resolve(model: "H6097", pact: .init(type: 2, code: 1))
        #expect(full?.supports(.dreamView) == true && full?.supports(.videoMode) == true && full?.limitation == nil)
        for pact in [nil, GoveeBLE.Pact(type: 3, code: 1)] {
            let reduced = GoveeBLEProfile.resolve(model: "H6097", pact: pact)
            #expect(reduced?.features == [.power, .brightness] && reduced?.limitation != nil)
        }
        let pro = GoveeBLEProfile.resolve(model: "h66a0", pact: nil)
        #expect(pro?.supports(.dreamView) == true && pro?.supports(.videoMode) == false && pro?.dreamViewMemberLimit == 10)
        #expect(GoveeBLEProfile.resolve(model: "H6127", pact: nil) == nil)
    }

    // MARK: Encryption selection (`test_selection_without_probe` and neighbours)

    @Test func selectionTableMatchesSource() throws {
        let rows: [(Bool, GoveeBLESession.Marker, Int)] = [
            (false, .absent, 0), (true, .absent, 1), (false, .value([1, 0]), 0), (false, .value([2, 0, 0, 0, 0, 0]), 0),
            (true, .value([1, 0]), 1), (true, .value([2, 0, 0, 0, 0, 0]), 1), (false, .value([1, 1]), 1), (true, .value([1, 2]), 2),
            (false, .value([2, 2, 0, 1, 2, 3]), 2), (false, .value([2, 1, 0, 1, 2, 3]), 1),
        ]
        for (advertised, marker, version) in rows {
            var s = GoveeBLESession()
            try s.select(marker: marker, advertisedEncryption: advertised)
            #expect(s.version == version)
            if version == 0 {
                let first = try s.startNegotiation(maxWriteLength: 20)
                let encoded = try s.encode(GoveeBLE.power(true))
                #expect(s.ready && first == nil && encoded == GoveeBLE.power(true))
            } else {
                #expect(!s.ready)
                #expect(throws: GoveeBLESession.Failure.notReady) { try s.encode(GoveeBLE.power(true)) }
            }
        }
        var pact = GoveeBLESession()
        try pact.select(marker: .value([2, 2, 0, 1, 2, 3]), advertisedEncryption: false)
        #expect(pact.markerPact == .init(type: 0x0102, code: 3))
    }

    @Test func encryptionEvidenceNeverFallsBackToPlaintext() throws {
        // A zero marker keeps an earlier connection's requirement.
        for version in [1, 2] {
            for zero: [UInt8] in [[1, 0], [2, 0, 0, 0, 0, 0]] {
                var s = GoveeBLESession()
                try s.select(marker: .value([1, UInt8(version)]), advertisedEncryption: false)
                try s.select(marker: .value(zero), advertisedEncryption: false)
                #expect(s.version == version && s.requiredVersion == version && !s.ready)
            }
        }
        let unrecognised: [[UInt8]] = [[], [0], [1], [2, 2], [2, 0], [3, 1], [1, 3]]
        for marker in unrecognised {
            var s = GoveeBLESession()
            #expect(throws: GoveeBLESession.Failure.selectionFailed) { try s.select(marker: .value(marker), advertisedEncryption: false) }
            // Once selection failed, a missing marker isn't treated as plaintext either.
            #expect(throws: GoveeBLESession.Failure.previousSelectionFailed) { try s.select(marker: .absent, advertisedEncryption: false) }
            // Plaintext advertisement may excuse an unreadable marker…
            var excused = GoveeBLESession()
            try excused.select(marker: .value(marker), advertisedEncryption: false, plaintextEvidence: true)
            #expect(excused.ready && excused.version == 0)
            // …but never over encryption evidence.
            var advertised = GoveeBLESession()
            #expect(throws: GoveeBLESession.Failure.selectionFailed) { try advertised.select(marker: .value(marker), advertisedEncryption: true, plaintextEvidence: true) }
            var earlier = GoveeBLESession()
            try earlier.select(marker: .value([1, 1]), advertisedEncryption: false)
            #expect(throws: GoveeBLESession.Failure.selectionFailed) { try earlier.select(marker: .value(marker), advertisedEncryption: false, plaintextEvidence: true) }
        }
        var failedRead = GoveeBLESession()
        #expect(throws: GoveeBLESession.Failure.selectionFailed) { try failedRead.select(marker: .readFailed, advertisedEncryption: false) }
    }

    // MARK: Handshakes against independent vectors

    final class Queue: @unchecked Sendable {
        var chunks: [[UInt8]]
        init(_ chunks: [[UInt8]]) { self.chunks = chunks }
        func take(_ n: Int) -> [UInt8] { let c = chunks.removeFirst(); precondition(c.count == n); return c }
    }

    @Test func v1TransformAndHandshake() throws {
        let key = Array(0..<16).map(UInt8.init)
        #expect(GoveeBLECrypto.v1(f("330101"), key: key, encrypt: true) == h("71a5d00cbe4136cf6d8a60dec77d07d8e99c40ca"))
        let odd = Array(0..<23).map(UInt8.init)
        #expect(GoveeBLECrypto.v1(odd, key: key, encrypt: true) == h("0a940bb5416ef045f1c39458c653ea5af98d52ea53f70f"))
        #expect(GoveeBLECrypto.v1(h("0a940bb5416ef045f1c39458c653ea5af98d52ea53f70f"), key: key, encrypt: false) == odd)

        let random = Queue([Array(0x20...0x30).map(UInt8.init), [UInt8](repeating: 7, count: 17)])
        var s = GoveeBLESession()
        s.random = { random.take($0) }
        try s.select(marker: .value([1, 1]), advertisedEncryption: false)
        #expect(try s.startNegotiation(maxWriteLength: 20) == h("a3774dcd1ecce7f1765b45e310b7938e46c17089"))
        guard case .write(let second) = try s.receive(h("4d59159c56527d09941c0344c948c99166e140b9")) else { Issue.record("phase 2"); return }
        #expect(GoveeBLECrypto.parseV1Handshake(second)?.opcode == 2)
        #expect(try s.receive(h("4d59159c56527d09941c0344c948c99166e140b9")) == .ignored)   // duplicate key reply
        #expect(try s.receive(h("42a3f946a5b02ec277402b74ca634efe66e140ba")) == .ready)
        #expect(s.encrypted)
        #expect(try s.encode(GoveeBLE.power(true)) == h("71a5d00cbe4136cf6d8a60dec77d07d8e99c40ca"))
        #expect(try s.receive(GoveeBLECrypto.v1(f("aa0101"), key: key, encrypt: true)) == .packet(f("aa0101")))
        #expect(try s.receive([UInt8](repeating: 0x55, count: 20)) == .ignored)
    }

    @Test func v2HandshakeSealAndReplay() throws {
        let iv = Array(0..<8).map(UInt8.init), nonce = Array(0..<12).map(UInt8.init)
        var small = GoveeBLESession()
        try small.select(marker: .value([1, 2]), advertisedEncryption: false)
        #expect(throws: GoveeBLESession.Failure.v2NeedsLargerWrites) { try small.startNegotiation(maxWriteLength: 49) }

        let random = Queue([iv, nonce])
        var s = GoveeBLESession()
        s.random = { random.take($0) }
        try s.select(marker: .value([1, 2]), advertisedEncryption: false)
        #expect(try s.startNegotiation(maxWriteLength: 182) == h("e71101000102030405060708090a0b10565850822a740b5ad5601139e0e749919dd22435e3d3643e"))
        #expect(try s.receive(h("e71100000102030405060708090a0b161810c26a344b1a8cdf4c31936cc20b4a34ae46de183aa540ff1ea4205daeac827c80")) == .ready)
        #expect(s.deviceSKU == "H6097" && s.deviceMAC == h("112233445566"))
        #expect(try s.encode(GoveeBLE.power(true)) == h("000000022703aecf1ecadcfdbfb6ccf9bcbeb3c9fc8b197427a1fac650fa64ae36cb1944f36a8afb"))
        let reply = h("000000056146a75887c99b728e89ba890486e4f39373393fa62e1af5d93d75b37b5b0e157988052e")
        #expect(try s.receive(reply) == .packet(f("aa0101")))
        #expect(try s.receive(reply) == .ignored)
        #expect(s.rejectedFrames == 1)
    }

    @Test func badHandshakeFailsClosed() throws {
        var s = GoveeBLESession()
        try s.select(marker: .absent, advertisedEncryption: true)
        _ = try s.startNegotiation(maxWriteLength: 20)
        #expect(throws: GoveeBLESession.Failure.handshakeRejected) { try s.receive(f("aa0101")) }
        #expect(!s.ready && s.requiredVersion == 1)
        #expect(throws: GoveeBLESession.Failure.notReady) { try s.encode(GoveeBLE.power(true)) }
    }

    // MARK: Capture decoding

    static let sourceMembers: [GoveeBLECapture.Member] = [
        .init(isRGBIC: true, cmdVer: 9, identity: .mac([0x11, 0x22, 0x33, 0x44, 0x55, 0x66]), areas: [0, 1, 10, 255]),
        .init(isRGBIC: false, cmdVer: 12, identity: .name("lamp"), areas: [2]),
    ]

    /// `transport.py fragment_a3` (terminator false), test-only: Luma never sends a group.
    func a3(_ type: UInt8, _ body: [UInt8]) -> [[UInt8]] {
        let data = [type] + body
        let count = (data.count + 2 + 16) / 17
        let trailing = count == 1
        let payload = [1, UInt8(count + (trailing ? 1 : 0))] + data
        let chunks = stride(from: 0, to: payload.count, by: 17).map { Array(payload[$0..<min($0 + 17, payload.count)]) }
        var frames = chunks.enumerated().map { i, c in GoveeBLE.frame([0xA3, trailing || i != chunks.count - 1 ? UInt8(i) : 0xFF] + c) }
        if trailing { frames.append(GoveeBLE.frame([0xA3, 0xFF])) }
        return frames
    }

    @Test func groupRecordsMatchSourceVector() throws {
        let body = GoveeBLECapture.encodeGroup(Self.sourceMembers)
        #expect(body == h("020100096655443322110400010aff00010c046c616d700102"))
        #expect(GoveeBLECapture.parseGroup(body + [0, 0, 0]) == Self.sourceMembers)
        #expect(GoveeBLECapture.parseGroup(h("0101010902c3a9010100"))?.first?.identity == .name("é"))
        #expect(GoveeBLECapture.parseGroup(body + [1]) == nil)
        #expect(GoveeBLECapture.parseGroup(Array(body.dropLast())) == nil)
        let frames = a3(0x50, body)
        let envelope = try #require(GoveeBLE.reassembleA3(frames))
        #expect(Array(envelope[2..<(3 + body.count)]) == [0x50] + body)
    }

    @Test func plaintextCaptureYieldsTheGroupAndCmdVer() throws {
        let text = (["# Govee Home saving a DreamView group", "N " + f("aa0101").map { String(format: "%02x", $0) }.joined()]
                    + a3(0x50, GoveeBLECapture.encodeGroup(Self.sourceMembers)).map { "W " + $0.map { String(format: "%02X", $0) }.joined(separator: ":") }
                    + ["N " + f("aa600101").map { String(format: "%02x", $0) }.joined(separator: " ")]).joined(separator: "\n")
        let report = try GoveeBLECapture.decode(text)
        #expect(report.encryption == 0 && report.groupUploads == [Self.sourceMembers] && report.dreamViewReadings == [.enabled(true)])
        #expect(report.summary.contains("cmd_ver 9") && report.summary.contains("cmd_ver 12"))
        #expect(!report.summary.contains("66") && !report.summary.contains("lamp"))
    }

    @Test func encryptedV2CaptureDecodesPassively() throws {
        let clientIV = Array(0..<8).map(UInt8.init)
        let req = h("e71101000102030405060708090a0b10565850822a740b5ad5601139e0e749919dd22435e3d3643e")
        let resp = h("e71100000102030405060708090a0b161810c26a344b1a8cdf4c31936cc20b4a34ae46de183aa540ff1ea4205daeac827c80")
        let id = try #require(GoveeBLECrypto.parseV2Response(resp))
        var counter: UInt32 = 2
        let writes = try a3(0x50, GoveeBLECapture.encodeGroup(Self.sourceMembers)).map { frame -> [UInt8] in
            defer { counter += 1 }
            return try GoveeBLECrypto.seal(frame, iv: clientIV, key: id.key, counter: counter)
        }
        let notify = try GoveeBLECrypto.seal(f("aa600a0101"), iv: id.deviceIV, key: id.key, counter: 3)
        func line(_ d: String, _ b: [UInt8]) -> String { d + " " + b.map { String(format: "%02x", $0) }.joined() }
        let text = ([line("W", req), line("N", resp)] + writes.map { line("W", $0) } + [line("N", notify), line("N", notify), "W zz", "N \u{FF11}\u{FF12}"]).joined(separator: "\n")
        let report = try GoveeBLECapture.decode(text)
        #expect(report.encryption == 2 && report.deviceSKU == "H6097")
        #expect(report.groupUploads.last == Self.sourceMembers)
        #expect(report.dreamViewReadings == [.videoSettings(applyArea: 1, contentMode: 1)])
        #expect(report.undecodable == 3)   // the replayed notification and two malformed lines (one fullwidth digits)
    }
}
