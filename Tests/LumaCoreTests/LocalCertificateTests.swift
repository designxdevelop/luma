import Foundation
import Security
import CryptoKit
import XCTest
@testable import LumaCore

final class LocalCertificateTests: XCTestCase {
    func testCertificateParsesAndItsSignatureVerifies() throws {
        let cert = try LocalCertificate(now: Date(timeIntervalSince1970: 1_800_000_000))
        let parsed = try XCTUnwrap(SecCertificateCreateWithData(nil, cert.der as CFData))
        XCTAssertEqual(SecCertificateCopySubjectSummary(parsed) as String?, "Luma local webhooks")
        // The certificate's own key verifies the certificate.
        let key = try XCTUnwrap(SecCertificateCopyKey(parsed))
        XCTAssertEqual(SecKeyCopyExternalRepresentation(key, nil) as Data?, cert.privateKey.publicKey.x963Representation)
        XCTAssertEqual(cert.fingerprint.split(separator: ":").count, 32)
        XCTAssertTrue(cert.pem.hasPrefix("-----BEGIN CERTIFICATE-----\n"))
        XCTAssertLessThanOrEqual(cert.notAfter.timeIntervalSince1970 - 1_800_000_000, 825 * 86_400)
    }

    func testTrustEvaluationAcceptsItForLocalhostWhenPinned() throws {
        let cert = try LocalCertificate()
        let parsed = try XCTUnwrap(SecCertificateCreateWithData(nil, cert.der as CFData))
        var trust: SecTrust?
        XCTAssertEqual(SecTrustCreateWithCertificates(parsed, SecPolicyCreateSSL(true, "localhost" as CFString), &trust), errSecSuccess)
        let t = try XCTUnwrap(trust)
        SecTrustSetAnchorCertificates(t, [parsed] as CFArray)
        var error: CFError?
        XCTAssertTrue(SecTrustEvaluateWithError(t, &error), String(describing: error))
    }

    func testDEREncodings() {
        XCTAssertEqual(DER.oid("1.2.840.10045.2.1"), Data([0x06, 0x07, 0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x02, 0x01]))
        XCTAssertEqual(DER.tlv(0x04, Data(count: 200)).prefix(3), Data([0x04, 0x81, 0xC8]))
        XCTAssertEqual(DER.integer(Data([0x80])), Data([0x02, 0x02, 0x00, 0x80]))
    }
}
