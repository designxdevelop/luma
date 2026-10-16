import Foundation
import Security
import LumaCore

struct SavedHome: Codable {
    var devices: [LightDevice] = []
    var scenes: [LightScene] = []
    var schedules: [SceneSchedule] = []
    var webhookPort: UInt16 = 8787
    var allowLAN: Bool = false
}

struct HomeStorage {
    let folder: URL
    init(demo: Bool) {
        if let path = ProcessInfo.processInfo.environment["LUMA_DATA_DIR"] { folder = URL(fileURLWithPath: path) }
        else { folder = URL.applicationSupportDirectory.appending(path: demo ? "Luma-Demo" : "Luma") }
    }
    func load() throws -> SavedHome {
        let file = folder.appending(path: "home.json")
        guard FileManager.default.fileExists(atPath: file.path) else { return SavedHome() }
        return try JSONDecoder().decode(SavedHome.self, from: Data(contentsOf: file))
    }
    func save(_ home: SavedHome) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let file = folder.appending(path: "home.json")
        try JSONEncoder.pretty.encode(home).write(to: file, options: [.atomic, .completeFileProtectionUnlessOpen])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }
}

enum SecretStore {
    static let service = "app.luma.govee"
    static func read(_ account: String) throws -> String? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account, kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data, let value = String(data: data, encoding: .utf8) else { throw error(status) }
        return value
    }
    static func save(_ value: String, account: String) throws {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
        let data = Data(value.utf8)
        var status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var item = query; item[kSecValueData as String] = data; item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            status = SecItemAdd(item as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw error(status) }
    }
    static func delete(_ account: String) throws {
        let status = SecItemDelete([kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account] as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw error(status) }
    }
    static func token() throws -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        guard status == errSecSuccess else { throw error(status) }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }
    static func error(_ status: OSStatus) -> LumaError { .message("Keychain: \((SecCopyErrorMessageString(status, nil) as String?) ?? String(status))") }
}
