import Foundation
import Testing
@testable import LumaUI

@MainActor struct ActivityLogTests {
    @Test func persistsAndRotatesDiagnostics() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        try ActivityLog.append("Connection failed\nretry", isError: true, folder: folder)
        let file = folder.appendingPathComponent("activity.log")
        let first = try String(contentsOf: file, encoding: .utf8)
        #expect(first.contains("[ERROR] Connection failed retry\n"))
        let permissions = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber
        #expect(permissions?.intValue == 0o600)
        try Data(repeating: 65, count: 1_048_576).write(to: file)
        try ActivityLog.append("Recovered", isError: false, folder: folder)
        #expect(try Data(contentsOf: folder.appendingPathComponent("activity.previous.log")).count == 1_048_576)
        #expect(try String(contentsOf: file, encoding: .utf8).contains("[INFO] Recovered"))
    }
}
