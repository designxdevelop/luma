import Foundation

/// Bounded local diagnostics. Callers supply activity text, never credentials or payloads.
enum ActivityLog {
    static func append(_ message: String, isError: Bool, folder: URL) throws {
        let manager = FileManager.default
        try manager.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let file = folder.appendingPathComponent("activity.log")
        let previous = folder.appendingPathComponent("activity.previous.log")
        let size = (try? manager.attributesOfItem(atPath: file.path)[.size] as? NSNumber)?.intValue ?? 0
        if size >= 1_048_576 {
            if manager.fileExists(atPath: previous.path) { try manager.removeItem(at: previous) }
            try manager.moveItem(at: file, to: previous)
        }
        if !manager.fileExists(atPath: file.path) {
            guard manager.createFile(atPath: file.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
                throw CocoaError(.fileWriteUnknown)
            }
        }
        let text = String(message.prefix(8192)).replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "\r", with: " ")
        let line = "\(Date().ISO8601Format()) [\(isError ? "ERROR" : "INFO")] \(text)\n"
        let handle = try FileHandle(forWritingTo: file)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(line.utf8))
    }
}
