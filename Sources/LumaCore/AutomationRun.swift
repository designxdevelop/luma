import Foundation

public struct AutomationRun: Codable, Sendable, Identifiable {
    public var id: UUID
    public var sceneID: UUID
    public var name: String
    public var status: String
    public var startedAt: Date
    public var finishedAt: Date?
    public var error: String?
    public init(id: UUID, sceneID: UUID, name: String, status: String, startedAt: Date, finishedAt: Date? = nil, error: String? = nil) {
        self.id = id; self.sceneID = sceneID; self.name = name; self.status = status
        self.startedAt = startedAt; self.finishedAt = finishedAt; self.error = error
    }
}
