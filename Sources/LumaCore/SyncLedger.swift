import Foundation

/// Durable per-field configuration mutations. Never put credentials or hardware observations here.
public struct SyncMutation: Codable, Equatable, Sendable {
    public var entity: String
    public var field: String
    public var value: Data?
    public var counter: UInt64
    public var writer: String
    public var key: String { entity + "/" + field }
    public init(entity: String, field: String, value: Data?, counter: UInt64, writer: String) {
        self.entity = entity; self.field = field; self.value = value; self.counter = counter; self.writer = writer
    }
    func supersedes(_ other: Self) -> Bool {
        counter > other.counter || (counter == other.counter && writer > other.writer)
    }
}

/// One ledger per cloud account. Nil values are permanent tombstones, including while offline.
public struct SyncLedger: Codable, Sendable {
    public let account: String
    public let writer: String
    public private(set) var clock: UInt64 = 0
    public private(set) var records: [String: SyncMutation] = [:]
    public private(set) var outbox: [String: SyncMutation] = [:]
    public init(account: String, writer: String = UUID().uuidString) { self.account = account; self.writer = writer }
    public mutating func edit(entity: String, field: String, value: Data?) {
        clock += 1
        let change = SyncMutation(entity: entity, field: field, value: value, counter: clock, writer: writer)
        records[change.key] = change; outbox[change.key] = change
    }
    public mutating func merge(_ changes: [SyncMutation], account incomingAccount: String) {
        guard account == incomingAccount else { return }
        for change in changes {
            clock = max(clock, change.counter)
            if let old = records[change.key], !change.supersedes(old) { continue }
            records[change.key] = change
            if let pending = outbox[change.key], change.supersedes(pending) { outbox.removeValue(forKey: change.key) }
        }
    }
    public mutating func acknowledge(_ sent: SyncMutation) {
        if outbox[sent.key] == sent { outbox.removeValue(forKey: sent.key) }
    }
}
